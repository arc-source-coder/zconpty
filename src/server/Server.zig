const std = @import("std");
const windows = @import("../windows.zig");

const apiMsg = @import("ApiMsg.zig");
const conMsg = @import("ConsoleMsg.zig");
const condrv = @import("Condrv.zig");
const cdHandler = @import("ConDrvHandler.zig");
const dispatcher = @import("Dispatcher.zig");
const ioCompletion = @import("IoCompletion.zig");
const input_mod = @import("Input.zig");
const logger = @import("logger.zig");
const sessionState = @import("SessionState.zig");
const utf = @import("utf.zig");
const utils = @import("../utils.zig");

const ntSuccess = utils.ntSuccess;
const handleIsValid = utils.handleIsValid;
const ConDrvHandler = cdHandler.ConDrvHandler;

pub const Session = struct {
    allocator: std.mem.Allocator,
    server_handle: windows.HANDLE,
    input_available_event: windows.HANDLE,
    thread: ?std.Thread,
    child_process: windows.HANDLE,
    stop_requested: std.atomic.Value(bool),
    state: State,
    input_subsystem: Input,

    pub const Terminal = sessionState.Terminal;
    pub const State = sessionState.State;
    pub const Input = input_mod;
};

pub fn create(
    allocator: std.mem.Allocator,
    terminal: Session.Terminal,
    out_session: *?*Session,
) windows.HRESULT {
    out_session.* = null;

    const session = allocator.create(Session) catch return windows.E_OUTOFMEMORY;
    errdefer allocator.destroy(session);

    session.* = .{
        .allocator = allocator,
        .stop_requested = std.atomic.Value(bool).init(false),
        .server_handle = windows.INVALID_HANDLE_VALUE,
        .input_available_event = windows.INVALID_HANDLE_VALUE,
        .thread = null,
        .child_process = windows.INVALID_HANDLE_VALUE,
        .state = Session.State.init(allocator, terminal),
        .input_subsystem = undefined,
    };
    errdefer session.state.deinit();

    const server_hr = openServerHandle(&session.server_handle);
    if (server_hr != windows.S_OK) return server_hr;
    errdefer {
        if (handleIsValid(session.server_handle)) {
            _ = windows.NtClose(session.server_handle);
            session.server_handle = windows.INVALID_HANDLE_VALUE;
        }
    }

    Session.Input.init(
        &session.input_subsystem,
        allocator,
        session.server_handle,
        &session.state,
        session.state.terminal,
        &session.state.console.input_mode,
    );
    errdefer session.input_subsystem.deinit();

    const setup_hr = configureServerInformation(session);
    if (setup_hr != windows.S_OK) return setup_hr;
    errdefer {
        if (handleIsValid(session.input_available_event)) {
            _ = windows.NtClose(session.input_available_event);
            session.input_available_event = windows.INVALID_HANDLE_VALUE;
        }
    }

    out_session.* = session;
    return windows.S_OK;
}

pub fn start(session: *Session) windows.HRESULT {
    std.debug.assert(session.thread == null);

    const thread = std.Thread.spawn(.{}, runLoopMain, .{session}) catch return windows.E_FAIL;
    session.thread = thread;

    std.Thread.setName(thread, "Console Server") catch |err| {
        std.log.warn("failed to set inproc thread name: {}", .{err});
    };

    const launch_hr = launchChildWithConsoleReference(session);
    if (launch_hr != windows.S_OK) {
        session.stop_requested.store(true, .release);
        if (handleIsValid(session.server_handle)) {
            _ = windows.NtClose(session.server_handle);
            session.server_handle = windows.INVALID_HANDLE_VALUE;
        }
        thread.join();
        session.thread = null;
        return launch_hr;
    }

    return windows.S_OK;
}

pub fn stop(session: *Session) void {
    session.state.dispatchControlEvent(windows.CTRL_CLOSE_EVENT, 0) catch |err| {
        switch (err) {
            error.InvalidParameter => {},
        }
    };

    session.stop_requested.store(true, .release);

    if (handleIsValid(session.server_handle)) {
        _ = windows.NtClose(session.server_handle);
        session.server_handle = windows.INVALID_HANDLE_VALUE;
    }

    if (handleIsValid(session.input_available_event)) {
        _ = windows.NtClose(session.input_available_event);
        session.input_available_event = windows.INVALID_HANDLE_VALUE;
    }

    // Best effort: this may still block if the ConDrv read does not unwind promptly.
    if (session.thread) |thread| {
        thread.join();
        session.thread = null;
    }

    if (handleIsValid(session.child_process)) {
        _ = windows.NtTerminateProcess(session.child_process, .SUCCESS);
        _ = windows.NtClose(session.child_process);
        session.child_process = windows.INVALID_HANDLE_VALUE;
    }

    const allocator = session.allocator;
    session.input_subsystem.deinit();
    session.state.deinit();
    allocator.destroy(session);
}

pub fn writeInputCallback(
    userdata: ?*anyopaque,
    bytes_ptr: [*]const u8,
    len: usize,
) callconv(.c) void {
    const session_ptr = userdata orelse return;
    if (len == 0) return;

    const session: *Session = @ptrCast(@alignCast(session_ptr));
    session.input_subsystem.writeInput(bytes_ptr[0..len]);
}

fn openServerHandle(out_server_handle: *windows.HANDLE) windows.HRESULT {
    out_server_handle.* = windows.INVALID_HANDLE_VALUE;

    var status = createServerHandle(out_server_handle, .FALSE);
    if (!ntSuccess(status)) {
        ensureDriverIsLoaded();
        status = createServerHandle(out_server_handle, .TRUE);
        if (!ntSuccess(status)) return utils.hresultFromNt(status);
    }
    return windows.S_OK;
}

fn ensureDriverIsLoaded() void {
    var info: windows.SYSTEM_CONSOLE_INFORMATION = .{ .DriverLoaded = 1 };
    _ = windows.NtSetSystemInformation(
        windows.SYSTEM_CONSOLE_INFORMATION_CLASS,
        &info,
        @sizeOf(windows.SYSTEM_CONSOLE_INFORMATION),
    );
}

fn configureServerInformation(session: *Session) windows.HRESULT {
    var input_event: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    const desired_access: windows.ACCESS_MASK = @bitCast(@as(windows.DWORD, windows.GENERIC_ALL));
    const event_status = windows.NtCreateEvent(
        &input_event,
        desired_access,
        null,
        .Notification,
        .FALSE,
    );
    if (!ntSuccess(event_status)) return utils.hresultFromNt(event_status);

    var handler = ConDrvHandler.init(session.server_handle);

    var server_info: condrv.CD_IO_SERVER_INFORMATION = .{
        .InputAvailableEvent = input_event,
    };
    const status = handler.setServerInformation(&server_info);
    if (!ntSuccess(status)) {
        _ = windows.NtClose(input_event);
        return utils.hresultFromNt(status);
    }

    session.input_available_event = input_event;
    session.input_subsystem.setInputAvailableEvent(input_event);
    return windows.S_OK;
}

fn launchChildWithConsoleReference(session: *Session) windows.HRESULT {
    var reference_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var stdin_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var stdout_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var stderr_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    errdefer {
        if (handleIsValid(stderr_handle)) _ = windows.NtClose(stderr_handle);
        if (handleIsValid(stdout_handle)) _ = windows.NtClose(stdout_handle);
        if (handleIsValid(stdin_handle)) _ = windows.NtClose(stdin_handle);
        if (handleIsValid(reference_handle)) _ = windows.NtClose(reference_handle);
    }

    const reference_name = utf.utf8ToUtf16LeStringLiteral("\\Reference");
    var status = createClientHandle(&reference_handle, session.server_handle, reference_name, .FALSE);
    if (!ntSuccess(status)) return utils.hresultFromNt(status);

    const stdin_name = utf.utf8ToUtf16LeStringLiteral("\\Input");
    status = createClientHandle(&stdin_handle, session.server_handle, stdin_name, .TRUE);
    if (!ntSuccess(status)) return utils.hresultFromNt(status);

    const stdout_name = utf.utf8ToUtf16LeStringLiteral("\\Output");
    status = createClientHandle(&stdout_handle, session.server_handle, stdout_name, .TRUE);
    if (!ntSuccess(status)) return utils.hresultFromNt(status);

    const current_process = windows.GetCurrentProcess();
    if (windows.DuplicateHandle(
        current_process,
        stdout_handle,
        current_process,
        &stderr_handle,
        0,
        .TRUE,
        windows.DUPLICATE_SAME_ACCESS,
    ) == .FALSE) {
        return utils.hresultFromWin32(windows.GetLastError());
    }

    var startup_info: windows.STARTUPINFOEXW = .{
        .StartupInfo = std.mem.zeroes(windows.STARTUPINFOW),
        .lpAttributeList = null,
    };
    startup_info.StartupInfo.cb = @sizeOf(windows.STARTUPINFOEXW);
    startup_info.StartupInfo.dwFlags = windows.STARTF_USESTDHANDLES;
    startup_info.StartupInfo.hStdInput = stdin_handle;
    startup_info.StartupInfo.hStdOutput = stdout_handle;
    startup_info.StartupInfo.hStdError = stderr_handle;

    var attr_list_size: windows.SIZE_T = 0;
    _ = windows.InitializeProcThreadAttributeList(null, 2, 0, &attr_list_size);

    const attr_list_mem = session.allocator.alloc(u8, attr_list_size) catch return windows.E_OUTOFMEMORY;
    defer session.allocator.free(attr_list_mem);

    startup_info.lpAttributeList = @ptrCast(attr_list_mem.ptr);
    if (windows.InitializeProcThreadAttributeList(startup_info.lpAttributeList, 2, 0, &attr_list_size) == .FALSE) {
        return utils.hresultFromWin32(windows.GetLastError());
    }
    defer windows.DeleteProcThreadAttributeList(startup_info.lpAttributeList);

    if (windows.UpdateProcThreadAttribute(
        startup_info.lpAttributeList,
        0,
        windows.PROC_THREAD_ATTRIBUTE_CONSOLE_REFERENCE,
        @ptrCast(&reference_handle),
        @sizeOf(windows.HANDLE),
        null,
        null,
    ) == .FALSE) {
        return utils.hresultFromWin32(windows.GetLastError());
    }

    var inherited_handle_list: [3]windows.HANDLE = .{
        stdin_handle,
        stdout_handle,
        stderr_handle,
    };
    if (windows.UpdateProcThreadAttribute(
        startup_info.lpAttributeList,
        0,
        windows.PROC_THREAD_ATTRIBUTE_HANDLE_LIST,
        @ptrCast(&inherited_handle_list),
        @sizeOf(@TypeOf(inherited_handle_list)),
        null,
        null,
    ) == .FALSE) {
        return utils.hresultFromWin32(windows.GetLastError());
    }

    const shell = utf.utf8ToUtf16LeAllocZ(session.allocator, "powershell.exe") catch return windows.E_OUTOFMEMORY;
    defer session.allocator.free(shell);

    const creation_flags: windows.DWORD = @bitCast(windows.CreateProcessFlags{
        .extended_startupinfo_present = true,
    });

    var process_info: windows.PROCESS_INFORMATION = undefined;
    if (windows.CreateProcessW(
        null,
        shell.ptr,
        null,
        null,
        .TRUE,
        creation_flags,
        null,
        null,
        &startup_info.StartupInfo,
        &process_info,
    ) == .FALSE) {
        return utils.hresultFromWin32(windows.GetLastError());
    }

    _ = windows.NtClose(process_info.hThread);
    session.child_process = process_info.hProcess;

    _ = windows.NtClose(reference_handle);
    _ = windows.NtClose(stdin_handle);
    _ = windows.NtClose(stdout_handle);
    _ = windows.NtClose(stderr_handle);

    return windows.S_OK;
}

fn runLoopMain(session: *Session) void {
    var handler = ConDrvHandler.init(session.server_handle);

    var stats: logger.Stats = .{};
    var request_logger: logger.RequestLogger = logger.RequestLogger.init(session.allocator);
    defer request_logger.deinit();

    defer {
        std.log.info(
            "Stats:" ++
                "read_attempts={d} read_ok={d} " ++
                "read_pending={d} read_err={d}" ++
                "complete_ok={d} complete_err={d} " ++
                "raw_write={d} raw_read={d}" ++
                "user_defined={d} disconnects={d}",
            .{
                stats.read_attempts,
                stats.read_success,
                stats.read_pending,
                stats.read_errors,
                stats.complete_success,
                stats.complete_errors,
                stats.raw_write,
                stats.raw_read,
                stats.user_defined,
                stats.disconnects,
            },
        );

        var buf: [4096]u8 = undefined;
        var writer = std.fs.File.stderr().writer(&buf);
        defer writer.interface.flush() catch |err| {
            std.log.warn("failed to flush request logger output: {}", .{err});
        };
        request_logger.dumpPriorityList(&writer.interface) catch |err| {
            std.log.warn("failed to dump request logger summary: {}", .{err});
        };
    }

    var last_complete: condrv.CD_IO_COMPLETE = undefined;
    var has_previous_complete = false;
    const context: dispatcher.Context = .{
        .state = &session.state,
        .io = &handler,
        .input = &session.input_subsystem,
    };

    while (!session.stop_requested.load(.acquire)) {
        stats.read_attempts += 1;

        var message: apiMsg.CONSOLE_DATA_PACKET = undefined;
        const read_status = handler.readIo(
            if (has_previous_complete) &last_complete else null,
            &message,
        );
        if (!ntSuccess(read_status)) {
            stats.read_errors += 1;
            break;
        }

        stats.read_success += 1;
        if (has_previous_complete) {
            stats.complete_success += 1;
        }

        var next_complete: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
        next_complete.Identifier = message.Descriptor.Identifier;
        ioCompletion.setWritePlaceholder(&next_complete);
        ioCompletion.setUnsupported(&next_complete);

        stats.onFunction(message.Descriptor.Function);
        request_logger.recordDescriptor(message.Descriptor.Function) catch |err| {
            std.log.warn("failed to record descriptor function: {}", .{err});
        };

        if (message.Descriptor.Function == condrv.CONSOLE_IO_USER_DEFINED and
            message.Descriptor.InputSize >= @sizeOf(conMsg.CONSOLE_MSG_HEADER))
        {
            request_logger.recordUserApi(message.Body.api_msg.msgHeader.ApiNumber) catch |err| {
                std.log.warn("failed to record USER_DEFINED API: {}", .{err});
            };
        }

        const dispatch_result = switch (message.Descriptor.Function) {
            condrv.CONSOLE_IO_RAW_READ => dispatcher.handleRead(&message, &next_complete),
            condrv.CONSOLE_IO_RAW_WRITE => dispatcher.handleWrite(
                &message,
                &next_complete,
                &context,
            ),
            condrv.CONSOLE_IO_USER_DEFINED => dispatcher.handleDispatch(
                &message,
                &next_complete,
                &context,
            ),
            condrv.CONSOLE_IO_CONNECT => dispatcher.handleConnect(
                &message,
                &next_complete,
                &context,
            ),
            condrv.CONSOLE_IO_DISCONNECT => dispatcher.handleDisconnect(
                &message,
                &next_complete,
                &context,
            ),
            condrv.CONSOLE_IO_RAW_FLUSH => dispatcher.handleFlush(&message, &next_complete),
            condrv.CONSOLE_IO_CREATE_OBJECT => dispatcher.handleCreateObject(
                &message,
                &next_complete,
                &context,
            ),
            condrv.CONSOLE_IO_CLOSE_OBJECT => dispatcher.handleCloseObject(
                &message,
                &next_complete,
                &context,
            ),
            else => dispatcher.handleUnknown(&message, &next_complete),
        };

        if (dispatch_result == .complete) {
            last_complete = next_complete;
            has_previous_complete = true;
        } else {
            has_previous_complete = false;
        }
    }
}

fn createClientHandle(
    handle: *windows.HANDLE,
    server_handle: windows.HANDLE,
    name: [*:0]const windows.WCHAR,
    inheritable: windows.BOOLEAN,
) windows.NTSTATUS {
    const desired_access: windows.ACCESS_MASK = @bitCast(@as(
        windows.DWORD,
        windows.GENERIC_WRITE | windows.GENERIC_READ | windows.SYNCHRONIZE,
    ));

    return createHandle(
        handle,
        name,
        desired_access,
        server_handle,
        inheritable,
        windows.FILE_SYNCHRONOUS_IO_NONALERT,
    );
}

fn createServerHandle(
    handle: *windows.HANDLE,
    inheritable: windows.BOOLEAN,
) windows.NTSTATUS {
    const device_name = utf.utf8ToUtf16LeStringLiteral("\\Device\\ConDrv\\Server");
    const desired_access: windows.ACCESS_MASK = @bitCast(@as(windows.DWORD, windows.GENERIC_ALL));
    return createHandle(handle, device_name, desired_access, null, inheritable, 0);
}

fn createHandle(
    handle: *windows.HANDLE,
    device_name: [*:0]const windows.WCHAR,
    desired_access: windows.ACCESS_MASK,
    parent: ?windows.HANDLE,
    inheritable: windows.BOOLEAN,
    open_options: windows.ULONG,
) windows.NTSTATUS {
    var object_flags: windows.OBJECT.ATTRIBUTES.Flags = .{ .CASE_INSENSITIVE = true };
    if (inheritable != .FALSE) object_flags.INHERIT = true;

    const name_len_bytes = std.mem.len(device_name) * @sizeOf(windows.WCHAR);
    var name: windows.UNICODE_STRING = .{
        .Length = @intCast(name_len_bytes),
        .MaximumLength = @intCast(name_len_bytes + @sizeOf(windows.WCHAR)),
        .Buffer = @constCast(device_name),
    };

    var object_attributes: windows.OBJECT.ATTRIBUTES = .{
        .RootDirectory = parent,
        .ObjectName = &name,
        .Attributes = object_flags,
        .SecurityDescriptor = null,
        .SecurityQualityOfService = null,
    };

    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const share_access: windows.FILE.SHARE = .{ .READ = true, .WRITE = true, .DELETE = true };

    return windows.NtOpenFile(
        handle,
        desired_access,
        &object_attributes,
        &iosb,
        share_access,
        @bitCast(open_options),
    );
}
