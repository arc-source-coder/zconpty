const std = @import("std");
const windows = @import("../windows.zig");
const process = @import("Process.zig");
const utf = @import("utf.zig");
const utils = @import("../utils.zig");

pub const Terminal = @import("Terminal.zig");

const Process = process.Process;
const Handle = process.Process.Handle;
const handleIsValid = utils.handleIsValid;

pub const CursorState = struct {
    size_percent: u32 = 25,
};

pub const TextAttributes = packed struct(u16) {
    foreground: u4 = 0x7,
    background: u4 = 0x0,
    leading_byte: bool = false,
    trailing_byte: bool = false,
    grid_horizontal: bool = false,
    grid_left_vertical: bool = false,
    grid_right_vertical: bool = false,
    /// Unused bit position in the legacy console API attribute word.
    reserved: bool = false,
    reverse_video: bool = false,
    underscore: bool = false,

    pub fn fromWord(word: windows.WORD) TextAttributes {
        return @bitCast(word);
    }

    pub fn toWord(self: TextAttributes) windows.WORD {
        return @bitCast(self);
    }

    pub fn foregroundSgr(self: TextAttributes) u8 {
        return sgrColorCode(self.foreground, false);
    }

    pub fn backgroundSgr(self: TextAttributes) u8 {
        return sgrColorCode(self.background, true);
    }

    pub fn writeSgr(self: TextAttributes, buffer: []u8) ![]const u8 {
        var stream = std.io.fixedBufferStream(buffer);
        const writer = stream.writer();

        try writer.writeAll("\x1b[0");

        if (self.reverse_video) {
            try writer.writeAll(";7");
        }

        if (!self.isDefaultForeground()) {
            try writer.print(";{d}", .{self.foregroundSgr()});
        }

        if (!self.isDefaultBackground()) {
            try writer.print(";{d}", .{self.backgroundSgr()});
        }

        try writer.writeByte('m');
        return stream.getWritten();
    }

    pub fn toSurfaceStyle(self: TextAttributes) Terminal.Style {
        return .{
            .fg = self.foreground,
            .bg = self.background,
            .underline = self.underscore,
            .inverse = self.reverse_video,
            ._reserved = 0,
        };
    }

    fn isDefaultForeground(self: TextAttributes) bool {
        return self.foreground == windows.DEFAULT_FOREGROUND_ATTRIBUTES;
    }

    fn isDefaultBackground(self: TextAttributes) bool {
        return self.background == (windows.DEFAULT_BACKGROUND_ATTRIBUTES >> 4);
    }

    fn sgrColorCode(index: u4, background: bool) u8 {
        const ansi_index = ansiPaletteIndex(index);
        const base: u8 = if (background) 40 else 30;
        const bright_base: u8 = if (background) 100 else 90;
        return if ((ansi_index & 0x8) != 0)
            bright_base + (ansi_index & 0x7)
        else
            base + (ansi_index & 0x7);
    }

    fn ansiPaletteIndex(index: u4) u4 {
        const blue = index & 0x1;
        const green = index & 0x2;
        const red = index & 0x4;
        const intensity = index & 0x8;
        return intensity | (blue << 2) | green | (red >> 2);
    }
};

pub const ConsoleAttributes = struct {
    current: TextAttributes = TextAttributes.fromWord(windows.DEFAULT_TEXT_ATTRIBUTES),
    popup: TextAttributes = TextAttributes.fromWord(windows.DEFAULT_POPUP_ATTRIBUTES),
};

pub const HistorySettings = struct {
    history_buffer_size: u32 = 50,
    number_of_history_buffers: u32 = 4,
    history_no_dup: bool = false,
};

pub const InputMode = packed struct(u32) {
    enable_processed_input: bool = true,
    enable_line_input: bool = true,
    enable_echo_input: bool = true,
    enable_window_input: bool = false,
    enable_mouse_input: bool = true,
    enable_insert_mode: bool = false,
    enable_quick_edit_mode: bool = false,
    enable_extended_flags: bool = false,
    enable_auto_position: bool = false,
    enable_virtual_terminal_input: bool = false,
    _reserved: u22 = 0,

    pub fn fromInt(value: windows.ULONG) InputMode {
        return @bitCast(value);
    }

    pub fn toInt(self: InputMode) windows.ULONG {
        return @bitCast(self);
    }
};

pub const OutputMode = packed struct(u32) {
    enable_processed_output: bool = true,
    enable_wrap_at_eol_output: bool = true,
    enable_virtual_terminal_processing: bool = false,
    disable_newline_auto_return: bool = false,
    enable_lvb_grid_worldwide: bool = false,
    _reserved: u27 = 0,

    pub fn fromInt(value: windows.ULONG) OutputMode {
        return @bitCast(value);
    }

    pub fn toInt(self: OutputMode) windows.ULONG {
        return @bitCast(self);
    }
};

pub const ConsoleState = struct {
    input_mode: std.atomic.Value(windows.ULONG),
    output_mode: OutputMode,
    windows_code_page: windows.UINT,
    output_code_page: windows.UINT,
    original_title: std.ArrayList(u8),
    cursor: CursorState,
    attributes: ConsoleAttributes,
    history: HistorySettings,

    pub fn init() ConsoleState {
        return .{
            .input_mode = std.atomic.Value(windows.ULONG).init(windows.DEFAULT_CONSOLE_INPUT_MODE),
            .output_mode = OutputMode.fromInt(windows.DEFAULT_CONSOLE_OUTPUT_MODE),
            .windows_code_page = windows.GetACP(),
            .output_code_page = windows.GetOEMCP(),
            .original_title = .empty,
            .cursor = .{},
            .attributes = .{},
            .history = .{},
        };
    }

    pub fn deinit(self: *ConsoleState, allocator: std.mem.Allocator) void {
        self.original_title.deinit(allocator);
        self.* = undefined;
    }

    pub fn loadInputMode(self: *const ConsoleState, comptime order: std.builtin.AtomicOrder) InputMode {
        return InputMode.fromInt(self.input_mode.load(order));
    }

    pub fn storeInputMode(self: *ConsoleState, comptime order: std.builtin.AtomicOrder, mode: InputMode) void {
        self.input_mode.store(mode.toInt(), order);
    }
};

const ConsoleControlFn = *const fn (
    command: windows.DWORD,
    console_information: ?*const anyopaque,
    console_information_length: windows.DWORD,
) callconv(.winapi) windows.NTSTATUS;

const ControlTarget = struct {
    pid: windows.DWORD,
    process_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
};

pub const ControlTargetSnapshot = struct {
    allocator: std.mem.Allocator,
    targets: std.ArrayList(ControlTarget),

    pub fn init(allocator: std.mem.Allocator) ControlTargetSnapshot {
        return .{ .allocator = allocator, .targets = .empty };
    }

    pub fn deinit(self: *ControlTargetSnapshot) void {
        for (self.targets.items) |target| {
            if (handleIsValid(target.process_handle)) {
                _ = windows.NtClose(target.process_handle);
            }
        }
        self.targets.deinit(self.allocator);
        self.* = undefined;
    }
};

pub const State = struct {
    allocator: std.mem.Allocator,
    terminal: Terminal,
    closing: bool,
    /// Serializes the one cross-thread access we keep: processed Ctrl+C can
    /// dispatch from the host input thread while connect/disconnect mutate the
    /// process list on the console thread.
    processes_mutex: std.Thread.Mutex,
    processes: std.ArrayList(*Process),
    connected_process_count: std.atomic.Value(u32),
    console: ConsoleState,

    pub fn init(allocator: std.mem.Allocator, terminal: Terminal) State {
        return .{
            .allocator = allocator,
            .terminal = terminal,
            .closing = false,
            .processes_mutex = .{},
            .processes = .empty,
            .connected_process_count = std.atomic.Value(u32).init(0),
            .console = ConsoleState.init(),
        };
    }

    pub fn deinit(self: *State) void {
        self.processes_mutex.lock();
        for (self.processes.items) |entry| {
            self.destroyProcess(entry);
        }
        self.processes.deinit(self.allocator);
        self.console.deinit(self.allocator);
        self.closing = false;
        self.connected_process_count.store(0, .release);
        self.processes_mutex.unlock();
        self.* = undefined;
    }

    pub fn beginClose(self: *State) !ControlTargetSnapshot {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        self.closing = true;
        return self.snapshotControlTargetsLocked(0, false);
    }

    pub fn snapshotRemainingCloseTargets(self: *State) !ControlTargetSnapshot {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        return self.snapshotControlTargetsLocked(0, true);
    }

    pub fn sendControlEventToSnapshot(
        snapshot: *const ControlTargetSnapshot,
        event_type: windows.ULONG,
    ) !void {
        const console_flags = consoleFlagsForEvent(event_type) orelse return error.InvalidParameter;
        for (snapshot.targets.items) |target| {
            sendConsoleEndTask(target.pid, event_type, console_flags);
        }
    }

    pub fn forceTerminateSnapshot(snapshot: *const ControlTargetSnapshot) void {
        for (snapshot.targets.items) |target| {
            const duplicated_handle = target.process_handle;
            const opened_handle = if (handleIsValid(duplicated_handle))
                windows.INVALID_HANDLE_VALUE
            else
                windows.OpenProcess(windows.MAXIMUM_ALLOWED, .FALSE, target.pid) orelse windows.INVALID_HANDLE_VALUE;
            const handle = if (handleIsValid(duplicated_handle)) duplicated_handle else opened_handle;
            if (!handleIsValid(handle)) {
                continue;
            }
            defer if (handleIsValid(opened_handle)) {
                _ = windows.NtClose(opened_handle);
            };

            _ = windows.NtTerminateProcess(handle, .SUCCESS);
        }
    }

    pub fn dispatchControlEvent(
        self: *State,
        event_type: windows.ULONG,
        process_group_id: windows.ULONG,
    ) !void {
        self.processes_mutex.lock();
        var snapshot = self.snapshotControlTargetsLocked(process_group_id, false) catch |err| {
            self.processes_mutex.unlock();
            return err;
        };
        self.processes_mutex.unlock();
        defer snapshot.deinit();

        try sendControlEventToSnapshot(&snapshot, event_type);
    }

    pub fn connectedProcessCount(self: *const State) u32 {
        return self.connected_process_count.load(.acquire);
    }

    pub fn isPowershellClient(self: *State, client_process: windows.ULONG_PTR) bool {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        for (self.processes.items) |entry| {
            if (client_process == @intFromPtr(entry)) {
                return entry.shim_policy.is_powershell_exe;
            }
        }
        return false;
    }

    pub fn isCmdClient(self: *State, client_process: windows.ULONG_PTR) bool {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        for (self.processes.items) |entry| {
            if (client_process == @intFromPtr(entry)) {
                return entry.shim_policy.is_cmd_exe;
            }
        }
        return false;
    }

    pub fn registerProcess(
        self: *State,
        pid: windows.DWORD,
        tid: windows.DWORD,
        process_group_id: windows.ULONG,
        process_handle: ?windows.HANDLE,
    ) !*Process {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        if (self.closing) {
            if (process_handle) |handle| {
                _ = windows.NtClose(handle);
            }
            return error.SessionClosing;
        }

        for (self.processes.items) |entry| {
            if (entry.pid != pid) continue;

            // Reconnect for an existing client PID: refresh transient metadata.
            entry.tid = tid;
            entry.process_group_id = process_group_id;

            // Keep the originally tracked process handle; close the
            // newly opened duplicate handle from this connect attempt.
            if (process_handle) |handle| {
                _ = windows.NtClose(handle);
            }
            return entry;
        }

        const process_entry = try self.allocator.create(Process);
        errdefer self.allocator.destroy(process_entry);
        errdefer if (process_handle) |handle| {
            _ = windows.NtClose(handle);
        };

        process_entry.* = Process.init(pid, tid, process_group_id, process_handle);

        try self.processes.append(self.allocator, process_entry);
        self.connected_process_count.store(@intCast(self.processes.items.len), .release);
        return process_entry;
    }

    pub fn unregisterProcessByClientPointer(self: *State, client_process: windows.ULONG_PTR) bool {
        self.processes_mutex.lock();
        defer self.processes_mutex.unlock();

        for (self.processes.items, 0..) |entry, index| {
            if (client_process == @intFromPtr(entry)) {
                removeProcessAt(self, index);
                self.connected_process_count.store(@intCast(self.processes.items.len), .release);
                self.destroyProcess(entry);
                return true;
            }
        }
        return false;
    }

    pub fn createHandle(
        self: *State,
        access_mask: windows.ACCESS_MASK,
        share_access: windows.FILE.SHARE,
        handle_type: Handle.HandleType,
        client_pointer: ?*anyopaque,
    ) !*Handle {
        const handle = try self.allocator.create(Handle);
        handle.* = .{
            .access_mask = access_mask,
            .share_access = share_access,
            .type = handle_type,
            .client_pointer = client_pointer,
        };
        return handle;
    }

    pub fn destroyHandle(self: *State, handle: *Handle) void {
        self.allocator.destroy(handle);
    }

    fn destroyProcess(self: *State, process_entry: *Process) void {
        if (process_entry.input_handle) |handle| {
            self.destroyHandle(handle);
        }
        if (process_entry.output_handle) |handle| {
            self.destroyHandle(handle);
        }
        if (process_entry.process_handle) |handle| {
            _ = windows.NtClose(handle);
        }
        self.allocator.destroy(process_entry);
    }

    fn removeProcessAt(self: *State, index: usize) void {
        const last_index = self.processes.items.len - 1;
        if (index < last_index) {
            @memmove(
                self.processes.items[index..last_index],
                self.processes.items[index + 1 .. self.processes.items.len],
            );
        }
        self.processes.items.len -= 1;
    }

    fn snapshotControlTargetsLocked(
        self: *State,
        process_group_id: windows.ULONG,
        duplicate_handles: bool,
    ) !ControlTargetSnapshot {
        var snapshot = ControlTargetSnapshot.init(self.allocator);
        errdefer snapshot.deinit();

        var matched = false;
        var index = self.processes.items.len;
        while (index > 0) {
            index -= 1;
            const entry = self.processes.items[index];
            if (process_group_id != 0 and entry.process_group_id != process_group_id) {
                continue;
            }

            matched = true;
            try snapshot.targets.append(self.allocator, .{
                .pid = entry.pid,
                .process_handle = if (duplicate_handles)
                    duplicateTrackedProcessHandle(entry)
                else
                    windows.INVALID_HANDLE_VALUE,
            });
        }

        if (process_group_id != 0 and !matched) return error.InvalidParameter;

        return snapshot;
    }

    fn duplicateTrackedProcessHandle(process_entry: *const Process) windows.HANDLE {
        const source_handle = process_entry.process_handle orelse return windows.INVALID_HANDLE_VALUE;

        var duplicate_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
        const current_process = windows.GetCurrentProcess();
        if (windows.DuplicateHandle(
            current_process,
            source_handle,
            current_process,
            &duplicate_handle,
            0,
            .FALSE,
            windows.DUPLICATE_SAME_ACCESS,
        ) == .FALSE) {
            std.log.warn("failed to duplicate process handle for pid={d}", .{process_entry.pid});
            return windows.INVALID_HANDLE_VALUE;
        }

        return duplicate_handle;
    }

    fn consoleFlagsForEvent(event_type: windows.ULONG) ?windows.ULONG {
        return switch (event_type) {
            windows.CTRL_C_EVENT => windows.CONSOLE_CTRL_C_FLAG,
            windows.CTRL_BREAK_EVENT => windows.CONSOLE_CTRL_BREAK_FLAG,
            windows.CTRL_CLOSE_EVENT => windows.CONSOLE_CTRL_CLOSE_FLAG,
            windows.CTRL_LOGOFF_EVENT => windows.CONSOLE_CTRL_LOGOFF_FLAG,
            windows.CTRL_SHUTDOWN_EVENT => windows.CONSOLE_CTRL_SHUTDOWN_FLAG,
            else => null,
        };
    }

    fn sendConsoleEndTask(
        pid: windows.DWORD,
        event_type: windows.ULONG,
        console_flags: windows.ULONG,
    ) void {
        const console_control = resolveConsoleControl() orelse {
            std.log.warn("ConsoleControl unavailable; skipping ConsoleEndTask for pid={d}", .{pid});
            return;
        };

        const params: windows.CONSOLEENDTASK = .{
            .ProcessId = @ptrFromInt(@as(usize, pid)),
            .hwnd = null,
            .ConsoleEventCode = event_type,
            .ConsoleFlags = console_flags,
        };
        const status = console_control(
            windows.CONSOLE_CONTROL_END_TASK,
            &params,
            @sizeOf(windows.CONSOLEENDTASK),
        );
        if (@as(i32, @bitCast(@intFromEnum(status))) < 0) {
            std.log.warn(
                "ConsoleEndTask failed: pid={d} event=0x{x:0>8} status=0x{x:0>8}",
                .{ pid, event_type, @intFromEnum(status) },
            );
        }
    }

    fn resolveConsoleControl() ?ConsoleControlFn {
        const user32_name = utf.utf8ToUtf16LeStringLiteral("user32.dll");
        const user32 = windows.GetModuleHandleW(user32_name);
        if (user32 == null) return null;

        const proc = windows.GetProcAddress(user32, "ConsoleControl");
        if (proc == null) return null;

        return @ptrCast(proc);
    }

    pub fn getMode(self: *const State, handle_type: Handle.HandleType) windows.ULONG {
        return switch (handle_type) {
            .Input => self.console.loadInputMode(.acquire).toInt(),
            .Output => self.console.output_mode.toInt(),
            .NotReady => 0,
        };
    }

    pub fn setMode(self: *State, handle_type: Handle.HandleType, mode: windows.ULONG) void {
        switch (handle_type) {
            .Input => self.console.storeInputMode(.release, InputMode.fromInt(mode)),
            .Output => self.console.output_mode = OutputMode.fromInt(mode),
            .NotReady => {},
        }
    }

    pub fn getCodePage(self: *const State, output: bool) windows.UINT {
        if (output) {
            return self.console.output_code_page;
        } else {
            return self.console.windows_code_page;
        }
    }

    pub fn setCodePage(self: *State, output: bool, code_page: windows.UINT) void {
        if (output) {
            self.console.output_code_page = code_page;
        } else {
            self.console.windows_code_page = code_page;
        }
    }

    pub fn getOriginalTitle(self: *const State) []const u8 {
        return self.console.original_title.items;
    }

    pub fn setOriginalTitleIfUnset(self: *State, title: []const u8) !void {
        if (self.console.original_title.items.len != 0) return;
        try self.console.original_title.appendSlice(self.allocator, title);
    }
};
