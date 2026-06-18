const std = @import("std");
const windows = @import("../windows.zig");
const utf = @import("../utf.zig");

const console = @import("ConsoleUtils.zig");
const socket = @import("Socket.zig");
const env = @import("Environment.zig");
const io = @import("Io.zig");
const utils = @import("../utils.zig");

const ProcThreadAttributes = utils.ProcThreadAttributes;

const common_data_start = @offsetOf(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_COMMON, "Buffer");
const utility_vm_common_start = @offsetOf(
    windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM,
    "Common",
);

const InteropRequest = struct {
    message: *align(1) const windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM,
    common: *align(1) const windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_COMMON,
    common_buf: []const u8,

    fn parse(msg: []const u8) !InteropRequest {
        if (msg.len < @sizeOf(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM)) {
            return error.InvalidArguments;
        }

        const message = std.mem.bytesAsValue(
            windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM,
            msg[0..@sizeOf(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM)],
        );
        if (message.Header.MessageType != .LxInitMessageCreateProcessUtilityVm) {
            return error.InvalidArguments;
        }

        const common_buf = msg[utility_vm_common_start..];
        const common = std.mem.bytesAsValue(
            windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_COMMON,
            common_buf[0..@sizeOf(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_COMMON)],
        );

        return .{ .message = message, .common = common, .common_buf = common_buf };
    }
};

const ChildProcessArgs = struct {
    application_name: [:0]u16,
    command_line: [:0]u16,
    cwd: ?[:0]u16,
    environment: ?[]u16,

    fn init(allocator: std.mem.Allocator, request: InteropRequest) !ChildProcessArgs {
        const application_name = try messageString(request.common_buf, request.common.FilenameOffset);
        const application_name_utf16 = try utf.utf8ToUtf16LeAllocZ(allocator, application_name);
        errdefer allocator.free(application_name_utf16);

        const command_line = try buildCommandLine(
            allocator,
            request.common_buf,
            request.common.CommandLineOffset,
            request.common.CommandLineCount,
        );
        defer allocator.free(command_line);

        const command_line_utf16 = try utf.utf8ToUtf16LeAllocZ(allocator, command_line);
        errdefer allocator.free(command_line_utf16);

        const cwd = try messageString(request.common_buf, request.common.CurrentWorkingDirectoryOffset);
        var cwd_utf16: ?[:0]u16 = null;
        if (cwd.len > 0) cwd_utf16 = try utf.utf8ToUtf16LeAllocZ(allocator, cwd);
        errdefer if (cwd_utf16) |buffer| allocator.free(buffer);

        var environment: ?[]u16 = null;
        if (request.common.EnvironmentOffset != 0) {
            const start: usize = @intCast(request.common.EnvironmentOffset);
            if (start < common_data_start) return error.InvalidEnvironment;
            if (start >= request.common_buf.len) return error.InvalidEnvironment;

            const peb = std.os.windows.peb().ProcessParameters;
            environment = try env.buildInteropBlock(
                allocator,
                peb.Environment,
                request.common_buf[start..],
            );
        }
        errdefer if (environment) |buffer| allocator.free(buffer);

        return .{
            .application_name = application_name_utf16,
            .command_line = command_line_utf16,
            .cwd = cwd_utf16,
            .environment = environment,
        };
    }

    fn deinit(self: *ChildProcessArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.application_name);
        allocator.free(self.command_line);
        if (self.cwd) |buffer| allocator.free(buffer);
        if (self.environment) |buffer| allocator.free(buffer);
        self.* = undefined;
    }
};

pub fn handleInterop(
    allocator: std.mem.Allocator,
    vm_id: windows.GUID,
    msg: []u8,
    interop_token: [16]u8,
) !void {
    defer allocator.free(msg);

    const request = try InteropRequest.parse(msg);
    var child_args = try ChildProcessArgs.init(allocator, request);
    defer child_args.deinit(allocator);

    var response = std.mem.zeroes(windows.LX.MESSAGE.LX_INIT_CREATE_PROCESS_RESPONSE);
    response.Header = .{
        .MessageType = .LxInitMessageCreateProcessResponse,
        .MessageSize = @sizeOf(windows.LX.MESSAGE.LX_INIT_CREATE_PROCESS_RESPONSE),
    };
    response.Result = .SUCCESS;

    const peb = std.os.windows.peb().ProcessParameters;

    // The Linux side accepts four connections on the port.
    const wsl_stdin_socket = try socket.openHvSocket(vm_id, request.message.Port);
    const wsl_stdout_socket = try socket.openHvSocket(vm_id, request.message.Port);
    const wsl_stderr_socket = try socket.openHvSocket(vm_id, request.message.Port);
    const wsl_control_socket = try socket.openHvSocket(vm_id, request.message.Port);
    defer _ = windows.NtClose(wsl_control_socket);

    // The Linux binfmt side always accepts stdin/stdout/stderr sockets and,
    // after exit status, waits for stdout/stderr EOF to flush any relayed data.
    // CPC=true bypasses those sockets, so close them when the handler returns.
    defer if (request.common.CreatePseudoconsole) {
        _ = windows.NtClose(wsl_stdin_socket);
        _ = windows.NtClose(wsl_stdout_socket);
        _ = windows.NtClose(wsl_stderr_socket);
    };

    var relays: [3]?PipeRelay = .{ null, null, null };
    defer for (&relays) |*relay_opt| if (relay_opt.*) |*relay| {
        relay.closeChildHandle();
        relay.thread.join();
    };

    var startup_info: windows.STARTUPINFOEXW = .{
        .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
        .lpAttributeList = null,
    };
    startup_info.StartupInfo.cb = @sizeOf(windows.STARTUPINFOEXW);
    startup_info.StartupInfo.dwFlags = windows.STARTF_USESTDHANDLES;

    var creation_flags: windows.CreateProcessFlags = .{
        .create_unicode_environment = true,
        // WSL sets desktop app policy for both redirected and CPC interop.
        .extended_startupinfo_present = true,
    };

    const attribute_count: windows.DWORD = if (request.common.CreatePseudoconsole) 1 else 2;
    var attributes = try ProcThreadAttributes.init(allocator, attribute_count);
    defer attributes.deinit();
    startup_info.lpAttributeList = attributes.list;

    // Ref: src\windows\common\interop.cpp in https://github.com/microsoft/WSL/
    var desktop_app_policy: windows.DWORD = windows.PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_OVERRIDE;

    try attributes.update(
        windows.PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY,
        @ptrCast(&desktop_app_policy),
        @sizeOf(@TypeOf(desktop_app_policy)),
    );

    if (request.common.CreatePseudoconsole == false) {
        // Don't spawn a new window in case this is a console process.
        // From WSL: GUI applications are unaffected by this flag.
        creation_flags.create_no_window = true;

        relays[0] = try startPipeRelay(wsl_stdin_socket, .socket_to_child);
        relays[1] = try startPipeRelay(wsl_stdout_socket, .child_to_socket);
        relays[2] = try startPipeRelay(wsl_stderr_socket, .child_to_socket);

        startup_info.StartupInfo.hStdInput = relays[0].?.child_handle;
        startup_info.StartupInfo.hStdOutput = relays[1].?.child_handle;
        startup_info.StartupInfo.hStdError = relays[2].?.child_handle;
    } else {
        // Spawn like a shell child attached to the same console as wslz.exe.
        startup_info.StartupInfo.hStdInput = try utils.duplicateHandle(peb.hStdInput, windows.OBJ_INHERIT);
        startup_info.StartupInfo.hStdOutput = try utils.duplicateHandle(peb.hStdOutput, windows.OBJ_INHERIT);
        startup_info.StartupInfo.hStdError = try utils.duplicateHandle(peb.hStdError, windows.OBJ_INHERIT);
    }

    if (!request.common.CreatePseudoconsole) {
        var inherited_handle_list: [3]windows.HANDLE = .{
            startup_info.StartupInfo.hStdInput.?,
            startup_info.StartupInfo.hStdOutput.?,
            startup_info.StartupInfo.hStdError.?,
        };

        try attributes.update(
            windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
            @ptrCast(&inherited_handle_list),
            @sizeOf(@TypeOf(inherited_handle_list)),
        );
    }

    var process_info = std.mem.zeroes(windows.PROCESS.INFORMATION);
    const process_created = windows.CreateProcessW(
        child_args.application_name.ptr,
        child_args.command_line.ptr,
        null,
        null,
        .TRUE,
        @bitCast(creation_flags),
        if (child_args.environment) |buf| buf.ptr else null,
        if (child_args.cwd) |dir| dir.ptr else null,
        &startup_info.StartupInfo,
        &process_info,
    );

    // CreateProcessW only needs these handles during the call. Keeping the
    // parent copies open prevents the stdout/stderr relays from observing EOF.
    if (request.common.CreatePseudoconsole) {
        _ = windows.NtClose(startup_info.StartupInfo.hStdInput.?);
        _ = windows.NtClose(startup_info.StartupInfo.hStdOutput.?);
        _ = windows.NtClose(startup_info.StartupInfo.hStdError.?);
    } else {
        for (&relays) |*relay_opt| if (relay_opt.*) |*relay| relay.closeChildHandle();
    }

    if (process_created == .FALSE) {
        switch (windows.GetLastError()) {
            .FILE_NOT_FOUND => response.Result = .ENOENT,
            .ELEVATION_REQUIRED => response.Result = .EACCESS,
            else => response.Result = .EINVAL,
        }
        try io.writeAll(wsl_control_socket, std.mem.asBytes(&response));
        return;
    }
    defer _ = windows.NtClose(process_info.hThread);
    defer _ = windows.NtClose(process_info.hProcess);

    try setGuiFlagFromProcess(process_info.hProcess, &response.Flags);
    const use_condrv_input = request.common.CreatePseudoconsole and
        ((response.Flags & windows.LX.LX_INIT_CREATE_PROCESS_RESULT_FLAG_GUI_APPLICATION) == 0);

    if (use_condrv_input) {
        console.setInteropMode(peb.hStdOutput, interop_token, .TRUE) catch {
            _ = windows.NtTerminateProcess(process_info.hProcess, .UNSUCCESSFUL);
            response.Result = .EINVAL;
            try io.writeAll(wsl_control_socket, std.mem.asBytes(&response));
            return;
        };
    }
    try io.writeAll(wsl_control_socket, std.mem.asBytes(&response));
    defer if (use_condrv_input) {
        console.setInteropMode(peb.hStdOutput, interop_token, .FALSE) catch {};
    };

    var exit_status_msg = std.mem.zeroes(windows.LX.MESSAGE.LX_INIT_PROCESS_EXIT_STATUS);
    exit_status_msg.Header = .{
        .MessageType = .LxInitMessageExitStatus,
        .MessageSize = @sizeOf(windows.LX.MESSAGE.LX_INIT_PROCESS_EXIT_STATUS),
    };

    const wait_status = windows.NtWaitForSingleObject(process_info.hProcess, .FALSE, null);

    if (wait_status != windows.NTSTATUS.WAIT_0) return windows.unexpectedStatus(wait_status);

    var exit_info = std.mem.zeroes(windows.PROCESS.BASIC_INFORMATION);
    var info_len: windows.ULONG = undefined;

    _ = windows.NtQueryInformationProcess(
        process_info.hProcess,
        .BasicInformation,
        &exit_info,
        @sizeOf(windows.PROCESS.BASIC_INFORMATION),
        &info_len,
    );

    exit_status_msg.ExitCode = @bitCast(@intFromEnum(exit_info.ExitStatus));

    // Write the exit status to the Linux side
    try io.writeAll(wsl_control_socket, std.mem.asBytes(&exit_status_msg));
}

fn setGuiFlagFromProcess(process: windows.HANDLE, flags: *u32) !void {
    var info = std.mem.zeroes(windows.PROCESS.BASIC_INFORMATION);
    var return_len: windows.ULONG = undefined;

    _ = windows.NtQueryInformationProcess(
        process,
        .BasicInformation,
        &info,
        @sizeOf(windows.PROCESS.BASIC_INFORMATION),
        &return_len,
    );

    var image_subsystem: windows.IMAGE_SUBSYSTEM = .UNKNOWN;
    var bytes_read: usize = 0;

    const image_subsystem_offset = @offsetOf(windows.PEB, "ImageSubSystem");
    const address: usize = @intFromPtr(info.PebBaseAddress) + image_subsystem_offset;

    _ = windows.NtReadVirtualMemory(
        process,
        @ptrFromInt(address),
        &image_subsystem,
        @sizeOf(windows.ULONG),
        &bytes_read,
    );

    if (bytes_read < @sizeOf(@TypeOf(image_subsystem))) return error.UnexpectedEof;

    if (image_subsystem == .WINDOWS_GUI) {
        flags.* |= windows.LX.LX_INIT_CREATE_PROCESS_RESULT_FLAG_GUI_APPLICATION;
    }
}

fn openPipes(read_end: *windows.HANDLE, write_end: *windows.HANDLE) !void {
    const sattr: windows.SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(windows.SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = .TRUE,
    };
    try windows.CreatePipe(read_end, write_end, @ptrCast(&sattr));
}

const PipeRelay = struct {
    child_handle: ?windows.HANDLE,
    thread: std.Thread,

    fn closeChildHandle(self: *PipeRelay) void {
        if (self.child_handle) |handle| _ = windows.NtClose(handle);
        self.child_handle = null;
    }
};

const PipeRelayDirection = enum { socket_to_child, child_to_socket };

fn startPipeRelay(socket_handle: windows.HANDLE, direction: PipeRelayDirection) !PipeRelay {
    errdefer _ = windows.NtClose(socket_handle);

    var read_end: windows.HANDLE = undefined;
    var write_end: windows.HANDLE = undefined;
    try openPipes(&read_end, &write_end);
    errdefer _ = windows.NtClose(read_end);
    errdefer _ = windows.NtClose(write_end);

    const child_handle, const source, const destination = switch (direction) {
        .socket_to_child => .{ read_end, socket_handle, write_end },
        .child_to_socket => .{ write_end, read_end, socket_handle },
    };
    const thread = try std.Thread.spawn(.{}, relayLoop, .{ source, destination });

    return .{ .child_handle = child_handle, .thread = thread };
}

fn relayLoop(source: windows.HANDLE, destination: windows.HANDLE) !void {
    defer _ = windows.NtClose(source);
    defer _ = windows.NtClose(destination);

    const allocator = std.heap.smp_allocator;
    const buffer = try allocator.alloc(u8, 128 * 1024);
    defer allocator.free(buffer);

    while (true) {
        const bytes_read = io.read(source, buffer) catch return;
        if (bytes_read == 0) return;

        io.writeAll(destination, buffer[0..bytes_read]) catch return;
    }
}

fn messageString(buffer: []const u8, start: usize) ![]const u8 {
    if (start < common_data_start) return error.InvalidArguments;
    if (start >= buffer.len) return error.InvalidArguments;

    const tail = buffer[start..];
    const end = std.mem.indexOfScalar(u8, tail, 0) orelse {
        return error.InvalidArguments;
    };
    return tail[0..end];
}

fn buildCommandLine(
    allocator: std.mem.Allocator,
    common_buf: []const u8,
    command_line_offset: u32,
    command_line_count: u16,
) ![]u8 {
    var command_line: std.ArrayList(u8) = .empty;
    errdefer command_line.deinit(allocator);

    var position: usize = @intCast(command_line_offset);
    const delimiters: [5]u8 = .{ ' ', '\t', '\r', '\n', '"' };

    // Logic based on FormatCommandLine in https://github.com/microsoft/WSL/
    for (0..command_line_count) |index| {
        const command = try messageString(common_buf, position);
        if (command.len != 0 and (std.mem.indexOfAny(u8, command, &delimiters) == null)) {
            try command_line.appendSlice(allocator, command);
        } else {
            // Quote the command
            try command_line.append(allocator, '"');
            var backslash_count: u32 = 0;
            // Ref: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-commandlinetoargvw
            for (command) |char| {
                switch (char) {
                    '\\' => {
                        backslash_count += 1;
                    },
                    '"' => {
                        try command_line.appendNTimes(allocator, '\\', (backslash_count * 2) + 1);
                        backslash_count = 0;
                        try command_line.append(allocator, '"');
                    },
                    else => {
                        try command_line.appendNTimes(allocator, '\\', backslash_count);
                        backslash_count = 0;
                        try command_line.append(allocator, char);
                    },
                }
            }
            // Escape and close the quote
            try command_line.appendNTimes(allocator, '\\', backslash_count * 2);
            try command_line.append(allocator, '"');
        }

        // Add a space between command line arguments.
        if (index < (command_line_count - 1)) {
            try command_line.append(allocator, ' ');
        }

        position += command.len + 1;
    }
    return command_line.toOwnedSlice(allocator);
}

test "buildCommandLine quotes arguments without scanning past message" {
    const allocator = std.testing.allocator;
    const buffer = @as([common_data_start]u8, @splat(0)) ++ "cmd.exe\x00hello world\x00quote\"x\x00";

    const command_line = try buildCommandLine(allocator, buffer[0..], common_data_start, 3);
    defer allocator.free(command_line);

    try std.testing.expectEqualStrings("cmd.exe \"hello world\" \"quote\\\"x\"", command_line);
}

test "InteropRequest rejects other LX message types" {
    var message = std.mem.zeroes(windows.LX.MESSAGE.LX_INIT_CREATE_NT_PROCESS_UTILITY_VM);
    message.Header.MessageType = .LxInitMessageExitStatus;

    try std.testing.expectError(error.InvalidArguments, InteropRequest.parse(std.mem.asBytes(&message)));
}

test "buildCommandLine rejects unterminated argument" {
    const buffer = @as([common_data_start]u8, @splat(0)) ++ "cmd";

    try std.testing.expectError(
        error.InvalidArguments,
        buildCommandLine(std.testing.allocator, buffer[0..], common_data_start, 1),
    );
}

test "buildCommandLine rejects offset inside common header" {
    const allocator = std.testing.allocator;
    const common = "ignored\x00cmd\x00";
    try std.testing.expectError(error.InvalidArguments, buildCommandLine(allocator, common, 8, 1));
}
