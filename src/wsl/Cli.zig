const std = @import("std");
const windows = @import("../windows.zig");
const utf = @import("../utf.zig");

const console = @import("ConsoleUtils.zig");
const console_msg = @import("../server/ConsoleMsg.zig");

const alpc = @import("Alpc.zig");
const socket = @import("Socket.zig");
const interop = @import("Interop.zig");
const env = @import("Environment.zig");
const io = @import("Io.zig");

pub const Options = struct {
    distribution_name: ?[]const u8 = null,
    show_help: bool = false,
};

const usage =
    \\Usage: wslz [options]
    \\
    \\Options:
    \\  -d, --distribution <name>  Launch the named WSL distribution.
    \\  -h, --help                 Show this help message.
    \\
;
const supported_wsl_version_prefix = utf.utf8ToUtf16LeStringLiteral("WSL version: 2.7.");

fn wslzCtrlHandler(event: windows.DWORD) callconv(.winapi) windows.BOOL {
    return switch (event) {
        windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => .TRUE,
        else => .FALSE,
    };
}

pub inline fn run() !void {
    // Keyboard Ctrl+C is broadcast to all clients attached to the console.
    // wslz.exe is infrastructure for the WSL-side session, so it must not die
    // with the foreground Windows console process that the user is interrupting.
    if (windows.SetConsoleCtrlHandler(wslzCtrlHandler, .TRUE) == .FALSE) {
        return error.ConsoleCtrlHandlerInstallFailed;
    }
    defer _ = windows.SetConsoleCtrlHandler(wslzCtrlHandler, .FALSE);

    const allocator = std.heap.smp_allocator;

    var args = try std.process.argsWithAllocator(allocator);
    defer args.deinit();

    const options = try parseOptions(&args);
    if (options.show_help) {
        try printUsage();
        return;
    }

    if (std.process.hasEnvVarConstant("WSLZ_SESSION")) {
        try printMessage("wslz: already inside a wslz session; launching wsl.exe instead");
        try fallbackToWsl(allocator, options);
        return;
    }

    if (!checkWslVersion(allocator)) {
        try printMessage("wslz: this system has an unsupported WSL version; launching wsl.exe instead");
        try fallbackToWsl(allocator, options);
        return;
    }

    const stdout: windows.HANDLE = std.os.windows.peb().ProcessParameters.hStdOutput;
    var bootstrap = std.mem.zeroes(console_msg.L3.CONSOLE_WSLZ_BOOTSTRAP_MSG);
    console.bootstrapWslz(stdout, &bootstrap) catch {
        try printMessage("wslz: this terminal does not support wslz; launching wsl.exe instead");
        try fallbackToWsl(allocator, options);
        return;
    };

    var session: *windows.ILxssUserSession = undefined;

    // Initialize COM
    const initialize_hr = windows.CoInitializeEx(null, windows.COINIT_MULTITHREADED);
    if (initialize_hr != windows.S_OK and initialize_hr != windows.S_FALSE) {
        return error.ComInitializationFailed;
    }

    // Initialize COM security
    const security_init_status = windows.CoInitializeSecurity(
        null,
        -1,
        null,
        null,
        .DEFAULT,
        .IMPERSONATE,
        null,
        .DYNAMIC_CLOAKING,
        null,
    );
    if (security_init_status != windows.S_OK) return error.ComSecurityInitializationFailed;
    defer windows.CoUninitialize();

    const instance_hr = windows.CoCreateInstance(
        &windows.CLSID_LxssUserSession,
        null,
        windows.CLSCTX_LOCAL_SERVER,
        &windows.IID_ILxssUserSession,
        @ptrCast(&session),
    );
    if (instance_hr != windows.S_OK) return error.InstanceInitializationFailed;
    defer _ = session.Release();

    // Initialize WSA
    var wsa_data: windows.WSAData = undefined;
    const wsa_status = windows.WSAStartup(windows.WINSOCK_2_2, &wsa_data);
    if (wsa_status != 0) return error.WsaStartupFailed;
    defer _ = windows.WSACleanup();

    // These are only used for WSL1 and ignored.
    var process_handle: windows.HANDLE = undefined;
    var server_port_handle: windows.HANDLE = undefined;

    // Sockets for WSL2 communication and interop.
    var stdin_socket: windows.HANDLE = undefined;
    var stdout_socket: windows.HANDLE = undefined;
    // We don't need the stderr socket since Linux stdout and stderr
    // are both passed through `stdout_socket` for interactive use.
    var stderr_socket: windows.HANDLE = undefined;

    var control_socket: windows.HANDLE = undefined;
    var interop_socket: windows.HANDLE = undefined;

    var distribution_guid: windows.GUID = undefined;
    const distribution_guid_ptr: ?*const windows.GUID = if (options.distribution_name) |distribution_name| blk: {
        var error_info: windows.LXSS.ERROR_INFO = undefined;
        const name_utf16 = try utf.utf8ToUtf16LeAllocZ(allocator, distribution_name);
        defer allocator.free(name_utf16);
        const id_hr = session.GetDistributionId(name_utf16, 0, &error_info, &distribution_guid);
        if (id_hr != windows.S_OK) return error.DistributionDetectionFailed;
        break :blk &distribution_guid;
    } else null;

    var cols: u16 = undefined;
    var rows: u16 = undefined;
    try console.getTerminalSize(stdout, &cols, &rows);

    const cwd = try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);
    const cwd_utf16: [:0]u16 = try utf.utf8ToUtf16LeAllocZ(allocator, cwd);
    defer allocator.free(cwd_utf16);

    // Query the current NT PATH environment variable.
    // TODO(Zig 0.16): Thread this from main() or use the PEB directly.
    const nt_path = try std.process.getEnvVarOwned(allocator, &[_]u8{ 'P', 'A', 'T', 'H' });
    defer allocator.free(nt_path);
    const nt_path_utf16: [:0]u16 = try utf.utf8ToUtf16LeAllocZ(allocator, nt_path);
    defer allocator.free(nt_path_utf16);

    const peb = std.os.windows.peb();
    const nt_environment = peb.ProcessParameters.Environment;
    const nt_environment_length: u32 = @intCast(env.windowsBlockLength(nt_environment));

    // The distribition that was actually launched. Used for interop.
    var distribution_id: windows.GUID = undefined;
    // ID for this instance of the distribution. Used for interop.
    var instance_id: windows.GUID = undefined;

    const handles: windows.LXSS.STD_HANDLES = .{
        .StdIn = .{
            .Handle = windows.LXSS_HANDLE_USE_CONSOLE,
            .HandleType = .LxssHandleConsole,
        },
        .StdOut = .{
            .Handle = windows.LXSS_HANDLE_USE_CONSOLE,
            .HandleType = .LxssHandleConsole,
        },
        .StdErr = .{
            .Handle = windows.LXSS_HANDLE_USE_CONSOLE,
            .HandleType = .LxssHandleConsole,
        },
    };

    // Get the reference handle to zconpty from the PEB
    const reference_handle: windows.HANDLE = std.os.windows.peb().ProcessParameters.ConsoleHandle;

    var error_info: windows.LXSS.ERROR_INFO = std.mem.zeroes(windows.LXSS.ERROR_INFO);

    // Match `wsl.exe` for an interactive shell with no command: use a login
    // shell so profile scripts can construct the Linux environment.
    const flags = windows.LXSS_CREATE_INSTANCE_FLAGS_ALLOW_FS_UPGRADE |
        windows.LXSS_CREATE_INSTANCE_FLAGS_SHELL_LOGIN;

    const create_result = session.CreateLxProcess(
        distribution_guid_ptr,
        null,
        0,
        null,
        cwd_utf16,
        nt_path_utf16,
        @ptrCast(nt_environment),
        nt_environment_length,
        null,
        @intCast(cols),
        @intCast(rows),
        @intCast(@intFromPtr(reference_handle)),
        @constCast(&handles),
        flags,
        &distribution_id,
        &instance_id,
        &process_handle,
        &server_port_handle,
        &stdin_socket,
        &stdout_socket,
        &stderr_socket,
        &control_socket,
        &interop_socket,
        &error_info,
    );
    if (create_result != windows.S_OK) return error.SpawnFailed;

    const alpc_port = try alpc.sendSockets(
        allocator,
        bootstrap.portName[0..bootstrap.portNameLength],
        .{
            .stdin = stdin_socket,
            .stdout = stdout_socket,
            .control = control_socket,
        },
    );
    defer _ = windows.NtClose(alpc_port);

    // The main interop loop
    while (try socket.recvMessage(allocator, interop_socket)) |msg| {
        const header: *const windows.LX.MESSAGE_HEADER = @ptrCast(@alignCast(msg.ptr));
        defer allocator.free(msg);
        switch (header.MessageType) {
            .LxInitMessageCreateProcessUtilityVm => {
                if (msg.len < @sizeOf(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM)) {
                    return error.InvalidMessage;
                }
                // Spawn a detached thread to handle the interop request
                const thread = try std.Thread.spawn(
                    .{},
                    interop.handleInterop,
                    .{ allocator, instance_id, try allocator.dupe(u8, msg), bootstrap.token },
                );
                try thread.setName("Interop handler");
                thread.detach();
            },
            .LxInitMessageExitStatus => {
                if (@sizeOf(windows.LX.MESSAGE.LX_INIT_PROCESS_EXIT_STATUS) != msg.len) {
                    return error.InvalidMessage;
                }

                const exit_msg: *windows.LX.MESSAGE.LX_INIT_PROCESS_EXIT_STATUS =
                    @ptrCast(@alignCast(msg.ptr));

                // Echo the message back to unblock the Linux side
                try io.writeAll(interop_socket, msg);
                windows.RtlExitUserProcess(@bitCast(exit_msg.ExitCode));
            },
            else => {},
        }
    }
    // The socket was closed without a LxInitMessageExitStatus message
    windows.RtlExitUserProcess(1);
}

fn parseOptions(args: *std.process.ArgIterator) !Options {
    var options: Options = .{};
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            options.show_help = true;
            return options;
        }

        if (std.mem.eql(u8, arg, "-d") or std.mem.eql(u8, arg, "--distribution")) {
            options.distribution_name = args.next() orelse {
                try printUsageError("missing distribution name");
                return error.MissingDistributionName;
            };
            continue;
        }

        try printUsageError("unknown argument");
        return error.InvalidArgument;
    }

    return options;
}

fn checkWslVersion(allocator: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "wsl.exe", "--version" },
        .max_output_bytes = 4096,
    }) catch return false;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);

    switch (result.term) {
        .Exited => |code| if (code != 0) return false,
        else => return false,
    }

    // wsl.exe output is UTF16-LE encoded
    const output = std.mem.bytesAsSlice(u16, result.stdout);
    return std.mem.startsWith(u16, @alignCast(output), std.mem.sliceTo(supported_wsl_version_prefix, 0));
}

fn fallbackToWsl(allocator: std.mem.Allocator, options: Options) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);

    try argv.append(allocator, "wsl.exe");
    if (options.distribution_name) |distribution_name| {
        try argv.append(allocator, "-d");
        try argv.append(allocator, distribution_name);
    }

    var child = std.process.Child.init(argv.items, allocator);
    const term = child.spawnAndWait() catch |err| switch (err) {
        error.FileNotFound => {
            try printMessage("wslz: WSL is not installed");
            std.process.exit(1);
        },
        else => return err,
    };
    const exit_code: u8 = switch (term) {
        .Exited => |code| code,
        else => 1,
    };
    std.process.exit(exit_code);
}

fn printUsage() !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    defer writer.interface.flush() catch {};

    try writer.interface.writeAll(usage);
}

fn printMessage(message: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    defer writer.interface.flush() catch {};

    try writer.interface.print("{s}\n", .{message});
}

fn printUsageError(message: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    defer writer.interface.flush() catch {};

    try writer.interface.print("error: {s}\n\n{s}", .{ message, usage });
}
