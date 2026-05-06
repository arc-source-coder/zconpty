const Self = @This();

const std = @import("std");
const windows = @import("../windows.zig");

const api_msg = @import("ApiMsg.zig");
const cooked_read = @import("CookedRead.zig");
const condrv = @import("Condrv.zig");
const console_msg = @import("ConsoleMsg.zig");
const condrv_handler = @import("ConDrvHandler.zig");
const input_types = @import("InputTypes.zig");
const io_completion = @import("IoCompletion.zig");
const session_state = @import("SessionState.zig");
const terminal_mod = @import("Terminal.zig");
const utf = @import("utf.zig");
const utils = @import("../utils.zig");

const ConDrvHandler = condrv_handler.ConDrvHandler;
const CookedRead = cooked_read;
const InputMode = session_state.InputMode;
const ReadTarget = CookedRead.PendingRead.Target;
const State = session_state.State;
const Terminal = terminal_mod;

const ntSuccess = utils.ntSuccess;

var empty_write_byte: u8 = 0;

pub const KeyAction = input_types.KeyAction;
pub const KeyEvent = input_types.KeyEvent;
pub const MouseEvent = input_types.MouseEvent;
pub const MouseButton = input_types.MouseButton;
pub const W3CCode = input_types.W3CCode;

allocator: std.mem.Allocator,
server_handle: windows.HANDLE,
state: *State,
terminal: Terminal,
input_mode: *std.atomic.Value(windows.ULONG),
input_available_event: windows.HANDLE,
vt_input_slot: VtInputSlot,
cooked_read_slot: CookedRead.Slot,
cooked_history_pool: CookedRead.HistoryPool,
input_buffer: InputBuffer,
preferred_reader: std.atomic.Value(u8),

pub const BeginResult = union(enum) {
    completed,
    pending,
    failed: windows.NTSTATUS,
};

pub const VtInputSlot = struct {
    mutex: std.Thread.Mutex = .{},
    pending_read: ?PendingByteRead = null,
    overflow: std.ArrayList(u8) = .empty,
};

pub const PendingByteRead = struct {
    target: ReadTarget = .read_console,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity: windows.ULONG,
    reply: console_msg.L1.CONSOLE_READCONSOLE_MSG,
};

pub const InputBuffer = struct {
    mutex: std.Thread.Mutex = .{},
    storage: std.ArrayList(windows.INPUT_RECORD) = .empty,
    vt_byte_storage: std.ArrayList(u8) = .empty,
    pending_text_read: ?PendingByteRead = null,
    pending_waiter: ?PendingWaiter = null,
};

const ReadConsoleBegin = struct {
    identifier: windows.LUID,
    reply: *console_msg.L1.CONSOLE_READCONSOLE_MSG,
    write_offset: windows.ULONG,
    capacity: windows.ULONG,
};

const ReadConsolePayload = struct {
    exe_name: []u8,
    initial_text: []u8,

    fn deinit(self: *ReadConsolePayload, allocator: std.mem.Allocator) void {
        allocator.free(self.exe_name);
        allocator.free(self.initial_text);
        self.* = undefined;
    }
};

pub const PendingWaiter = struct {
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    max_records: windows.ULONG,
    reply: console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
};

const ReadConsoleResult = struct {
    reply: console_msg.L1.CONSOLE_READCONSOLE_MSG,
    payload: []u8,
    consume: RawReadConsume,

    fn deinit(self: *ReadConsoleResult, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const RawReadConsume = struct {
    records_to_remove: usize = 0,
    record_repeat_remaining: ?windows.WORD = null,
    vt_bytes_to_remove: usize = 0,
};

const GetConsoleInputResult = struct {
    reply: console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
    payload: []u8,
    record_count: usize,
    consumed_records: usize,
    consumed_vt_bytes: usize,

    fn deinit(self: *GetConsoleInputResult, allocator: std.mem.Allocator) void {
        allocator.free(self.payload);
        self.* = undefined;
    }
};

const LegacyCompletion = union(enum) {
    none,
    text_read: struct {
        pending: PendingByteRead,
        result: ReadConsoleResult,
    },
    waiter: struct {
        pending: PendingWaiter,
        result: GetConsoleInputResult,
    },

    fn deinit(self: *LegacyCompletion, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .none => {},
            .text_read => |*value| value.result.deinit(allocator),
            .waiter => |*value| value.result.deinit(allocator),
        }
        self.* = undefined;
    }
};

const ReadyGetConsoleInput = enum {
    none,
    records,
    vt_bytes,
};

const Route = enum {
    pending_read,
    legacy_waiter,
    fallback_vt,
    fallback_legacy,
};

// This is a hack because programs like wsl.exe set ENABLE_VIRTUAL_TERMINAL_INPUT
// but call GetConsoleInput. If a process issues a legacy call, assume it wants legacy.
const PreferredReader = enum(u8) {
    none,
    vt,
    legacy,
};

pub fn init(
    self: *Self,
    allocator: std.mem.Allocator,
    server_handle: windows.HANDLE,
    state: *State,
    terminal: Terminal,
    input_mode: *std.atomic.Value(windows.ULONG),
) void {
    self.* = .{
        .allocator = allocator,
        .server_handle = server_handle,
        .state = state,
        .terminal = terminal,
        .input_mode = input_mode,
        .input_available_event = windows.INVALID_HANDLE_VALUE,
        .vt_input_slot = .{},
        .cooked_read_slot = .{},
        .cooked_history_pool = .{},
        .input_buffer = .{},
        .preferred_reader = std.atomic.Value(u8).init(@intFromEnum(PreferredReader.none)),
    };
}

pub fn deinit(self: *Self) void {
    self.vt_input_slot.overflow.deinit(self.allocator);
    self.cooked_read_slot.deinit(self.allocator);
    self.cooked_history_pool.deinit(self.allocator);
    self.input_buffer.storage.deinit(self.allocator);
    self.input_buffer.vt_byte_storage.deinit(self.allocator);
    self.* = undefined;
}

pub fn setInputAvailableEvent(self: *Self, input_available_event: windows.HANDLE) void {
    self.input_available_event = input_available_event;
}

pub fn sendKey(self: *Self, event: KeyEvent) void {
    self.handleKey(event);
}

pub fn sendMouse(self: *Self, event: MouseEvent) void {
    self.handleMouse(event);
}

pub fn sendFocus(self: *Self, focused: bool) void {
    self.handleFocus(focused);
}

pub fn sendPaste(self: *Self, text: []const u8) void {
    if (text.len == 0) return;
    self.handlePaste(text);
}

pub fn sendResize(self: *Self, cols: u16, rows: u16) void {
    self.redrawCookedIfActive();

    var record: windows.INPUT_RECORD = .{
        .EventType = windows.WINDOW_BUFFER_SIZE_EVENT,
        .Event = .{ .WindowBufferSizeEvent = .{
            .dwSize = .{
                .X = @intCast(cols),
                .Y = @intCast(rows),
            },
        } },
    };
    self.deliverLegacyRecords((&record)[0..1]);
}

pub fn writeInput(self: *Self, bytes: []const u8) void {
    if (bytes.len == 0) return;
    self.deliverBytes(bytes);
}

pub fn flushInputBuffer(self: *Self) void {
    self.vt_input_slot.mutex.lock();
    self.vt_input_slot.overflow.items.len = 0;
    self.vt_input_slot.mutex.unlock();

    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    self.input_buffer.storage.items.len = 0;
    self.input_buffer.vt_byte_storage.items.len = 0;
    self.resetInputAvailableIfDrained();
}

pub fn getNumberOfInputEvents(self: *Self) windows.ULONG {
    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    const record_count = self.input_buffer.storage.items.len;
    const vt_byte_count = self.input_buffer.vt_byte_storage.items.len;

    // Only count input inside the legacy input queue.
    const total = record_count + vt_byte_count;
    std.debug.assert(total <= std.math.maxInt(windows.ULONG));
    return @intCast(total);
}

/// Waiters installed after routing begins do not steal the current event.
/// They apply to the next event. This keeps routing single-pass and avoids
/// dual-build work on the common path.
pub fn beginReadConsole(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    const input_mode = self.loadInputMode();
    if (input_mode.enable_line_input) {
        return self.beginCookedReadConsole(message);
    }

    if (!input_mode.enable_virtual_terminal_input) {
        return self.beginRawReadConsole(message, completion);
    }

    return self.beginVtReadConsole(message, completion);
}

pub fn beginRawRead(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    if (message.Descriptor.OutputSize == 0) {
        return .{ .failed = .BUFFER_TOO_SMALL };
    }

    const input_mode = self.loadInputMode();
    if (input_mode.enable_line_input) {
        return self.beginCookedRawRead(message);
    }

    if (!input_mode.enable_virtual_terminal_input) {
        return self.beginLegacyRead(rawReadPending(self, message), null, completion);
    }

    return self.beginVtRead(rawReadPending(self, message), null, completion);
}

pub fn redrawCookedAfterHostOutput(self: *Self) void {
    self.redrawCookedIfActive();
}

fn redrawCookedIfActive(self: *Self) void {
    self.cooked_read_slot.mutex.lock();
    defer self.cooked_read_slot.mutex.unlock();

    if (self.cooked_read_slot.active) |*active| {
        CookedRead.redraw(self.allocator, self.terminal, self.loadInputMode(), active) catch return;
    }
}

fn beginVtReadConsole(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    const begin = readConsoleBegin(message) orelse return .{ .failed = .INVALID_PARAMETER };
    return self.beginVtRead(.{
        .identifier = begin.identifier,
        .write_offset = begin.write_offset,
        .capacity = begin.capacity,
        .reply = begin.reply.*,
    }, begin.reply, completion);
}

fn beginVtRead(
    self: *Self,
    pending_read: PendingByteRead,
    reply_out: ?*console_msg.L1.CONSOLE_READCONSOLE_MSG,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    self.setPreferredReader(.vt);

    var overflow: std.ArrayList(u8) = .empty;
    defer overflow.deinit(self.allocator);

    self.vt_input_slot.mutex.lock();
    var vt_locked = true;
    defer if (vt_locked) self.vt_input_slot.mutex.unlock();

    if (self.vt_input_slot.pending_read != null) return .{ .failed = .INVALID_PARAMETER };

    if (self.vt_input_slot.overflow.items.len > 0) {
        std.mem.swap(std.ArrayList(u8), &overflow, &self.vt_input_slot.overflow);
        self.vt_input_slot.mutex.unlock();
        vt_locked = false;

        const written = self.finishPendingVtReadInline(
            completion,
            pending_read,
            reply_out,
            overflow.items,
        ) catch |err| return .{ .failed = utils.mapError(err) };

        consumePrefixBytes(&overflow, written);
        self.vt_input_slot.mutex.lock();
        if (overflow.items.len > 0) {
            self.vt_input_slot.overflow.appendSlice(self.allocator, overflow.items) catch {
                self.vt_input_slot.overflow.items.len = 0;
            };
        }
        overflow.items.len = 0;
        self.vt_input_slot.mutex.unlock();
        return .completed;
    }

    self.vt_input_slot.pending_read = pending_read;
    return .pending;
}

fn beginCookedReadConsole(self: *Self, message: *api_msg.CONSOLE_DATA_PACKET) BeginResult {
    const begin = readConsoleBegin(message) orelse return .{ .failed = .INVALID_PARAMETER };
    var payload = self.decodeReadConsolePayload(begin.reply, message) catch |err| return .{ .failed = utils.mapError(err) };
    defer payload.deinit(self.allocator);

    self.cooked_read_slot.mutex.lock();
    defer self.cooked_read_slot.mutex.unlock();

    if (self.cooked_read_slot.active != null) return .{ .failed = .INVALID_PARAMETER };

    self.setPreferredReader(.legacy);

    const history = self.cooked_history_pool.acquire(
        self.allocator,
        self.state.console.history,
        payload.exe_name,
    ) catch |err| return .{ .failed = utils.mapError(err) };

    const pending: CookedRead.PendingRead = .{
        .identifier = begin.identifier,
        .write_offset = begin.write_offset,
        .capacity = begin.capacity,
        .reply = begin.reply.*,
    };

    self.cooked_read_slot.active = CookedRead.initActive(
        self.allocator,
        pending,
        history,
        payload.initial_text,
    ) catch |err| return .{ .failed = utils.mapError(err) };
    return .pending;
}

fn beginCookedRawRead(self: *Self, message: *api_msg.CONSOLE_DATA_PACKET) BeginResult {
    self.cooked_read_slot.mutex.lock();
    defer self.cooked_read_slot.mutex.unlock();

    if (self.cooked_read_slot.active != null) return .{ .failed = .INVALID_PARAMETER };

    self.setPreferredReader(.legacy);

    self.cooked_read_slot.active = CookedRead.initActive(
        self.allocator,
        .{
            .target = .raw_io,
            .identifier = message.Descriptor.Identifier,
            .write_offset = 0,
            .capacity = message.Descriptor.OutputSize,
            .reply = rawReadReply(self),
        },
        null,
        "",
    ) catch |err| return .{ .failed = utils.mapError(err) };
    return .pending;
}

fn beginRawReadConsole(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    const begin = readConsoleBegin(message) orelse return .{ .failed = .INVALID_PARAMETER };
    return self.beginLegacyRead(.{
        .identifier = begin.identifier,
        .write_offset = begin.write_offset,
        .capacity = begin.capacity,
        .reply = begin.reply.*,
    }, begin.reply, completion);
}

fn beginLegacyRead(
    self: *Self,
    pending_read: PendingByteRead,
    reply_out: ?*console_msg.L1.CONSOLE_READCONSOLE_MSG,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    self.setPreferredReader(.legacy);

    var result: ?ReadConsoleResult = null;
    defer if (result) |*value| value.deinit(self.allocator);

    self.input_buffer.mutex.lock();
    var input_locked = true;
    defer if (input_locked) self.input_buffer.mutex.unlock();

    if (self.input_buffer.pending_text_read != null) {
        return .{ .failed = .INVALID_PARAMETER };
    }

    if (self.rawReadReadyLocked()) {
        result = self.collectReadConsoleResultLocked(
            pending_read.capacity,
            pending_read.reply,
        ) catch |err| {
            return .{ .failed = utils.mapError(err) };
        };
        self.input_buffer.mutex.unlock();
        input_locked = false;

        self.finishPendingReadResultInline(completion, pending_read, reply_out, result.?) catch |err| {
            return .{ .failed = utils.mapError(err) };
        };

        self.input_buffer.mutex.lock();
        commitReadConsoleResultLocked(&self.input_buffer, result.?);
        self.resetInputAvailableIfDrained();
        self.input_buffer.mutex.unlock();
        return .completed;
    }

    self.input_buffer.pending_text_read = pending_read;
    return .pending;
}

fn rawReadPending(self: *const Self, message: *const api_msg.CONSOLE_DATA_PACKET) PendingByteRead {
    return .{
        .target = .raw_io,
        .identifier = message.Descriptor.Identifier,
        .write_offset = 0,
        .capacity = message.Descriptor.OutputSize,
        .reply = rawReadReply(self),
    };
}

fn rawReadReply(self: *const Self) console_msg.L1.CONSOLE_READCONSOLE_MSG {
    var reply: console_msg.L1.CONSOLE_READCONSOLE_MSG = std.mem.zeroes(console_msg.L1.CONSOLE_READCONSOLE_MSG);
    reply.ProcessControlZ = if (self.processedInputModeEnabled()) .TRUE else .FALSE;
    return reply;
}

fn finishPendingVtReadInline(
    self: *Self,
    completion: *condrv.CD_IO_COMPLETE,
    pending: PendingByteRead,
    reply_out: ?*console_msg.L1.CONSOLE_READCONSOLE_MSG,
    bytes: []const u8,
) !usize {
    const delivered = pendingReadDelivery(pending, bytes);
    if (delivered.delivered > 0) {
        try self.writeOutput(
            pending.identifier,
            pending.write_offset,
            bytes[0..delivered.delivered],
        );
    }

    switch (pending.target) {
        .read_console => finishReadConsoleInlineCompletion(
            completion,
            reply_out orelse return error.InvalidParameter,
            pending.reply,
            delivered.delivered,
        ),
        .raw_io => finishRawReadInlineCompletion(completion, delivered.delivered),
    }
    return delivered.consumed;
}

fn finishPendingReadResultInline(
    self: *Self,
    completion: *condrv.CD_IO_COMPLETE,
    pending: PendingByteRead,
    reply_out: ?*console_msg.L1.CONSOLE_READCONSOLE_MSG,
    result: ReadConsoleResult,
) !void {
    if (result.payload.len > 0) {
        try self.writeOutput(
            pending.identifier,
            pending.write_offset,
            result.payload,
        );
    }

    switch (pending.target) {
        .read_console => finishReadConsoleInlineCompletion(
            completion,
            reply_out orelse return error.InvalidParameter,
            result.reply,
            result.payload.len,
        ),
        .raw_io => finishRawReadInlineCompletion(completion, result.payload.len),
    }
}

fn finishPendingVtReadAsync(
    self: *Self,
    pending: PendingByteRead,
    bytes: []const u8,
) !usize {
    const delivered = pendingReadDelivery(pending, bytes);
    if (delivered.delivered > 0) {
        try self.writeOutput(
            pending.identifier,
            pending.write_offset,
            bytes[0..delivered.delivered],
        );
    }

    switch (pending.target) {
        .read_console => try self.completeReadConsoleStatus(
            pending.identifier,
            pending.reply,
            .SUCCESS,
            delivered.delivered,
        ),
        .raw_io => try self.completeRawReadStatus(
            pending.identifier,
            .SUCCESS,
            delivered.delivered,
        ),
    }
    return delivered.consumed;
}

fn finishPendingReadResultAsync(
    self: *Self,
    pending: PendingByteRead,
    result: ReadConsoleResult,
    status: windows.NTSTATUS,
    control_key_state: windows.ULONG,
) !void {
    switch (pending.target) {
        .read_console => try self.completeReadConsoleResult(
            pending.identifier,
            pending.write_offset,
            result,
            status,
            control_key_state,
        ),
        .raw_io => try self.completeRawReadResult(
            pending.identifier,
            pending.write_offset,
            result.payload,
            status,
        ),
    }
}

fn finishReadConsoleInlineCompletion(
    completion: *condrv.CD_IO_COMPLETE,
    reply_out: *console_msg.L1.CONSOLE_READCONSOLE_MSG,
    reply_template: console_msg.L1.CONSOLE_READCONSOLE_MSG,
    delivered: usize,
) void {
    reply_out.* = reply_template;
    reply_out.NumBytes = @intCast(delivered);
    reply_out.ControlKeyState = 0;
    io_completion.setWriteBuffer(
        completion,
        @ptrCast(reply_out),
        @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG),
    );
    io_completion.setSuccessWithInformation(completion, delivered);
}

fn finishRawReadInlineCompletion(completion: *condrv.CD_IO_COMPLETE, delivered: usize) void {
    io_completion.setSuccessWithInformation(completion, delivered);
}

fn pendingReadDelivery(
    pending: PendingByteRead,
    bytes: []const u8,
) struct { consumed: usize, delivered: usize } {
    const consumed = @min(bytes.len, @as(usize, @intCast(pending.capacity)));
    var delivered = consumed;
    if (pending.reply.ProcessControlZ != .FALSE and consumed > 0 and bytes[0] == 0x1A) {
        delivered = 0;
    }

    return .{ .consumed = consumed, .delivered = delivered };
}

pub fn beginGetConsoleInput(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    self.setPreferredReader(.legacy);

    const reply = &message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleInput;
    const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
    if (message.Descriptor.OutputSize <= write_offset) return .{ .failed = .INVALID_PARAMETER };

    var result: ?GetConsoleInputResult = null;
    defer if (result) |*value| value.deinit(self.allocator);

    self.input_buffer.mutex.lock();
    var input_locked = true;
    defer if (input_locked) self.input_buffer.mutex.unlock();

    const ready = self.readyGetConsoleInputLocked();
    if (ready != .none) {
        result = self.collectGetConsoleInputResultLocked(
            ready,
            message.Descriptor.OutputSize - write_offset,
            reply.*,
        ) catch |err| {
            return .{ .failed = utils.mapError(err) };
        };
        self.input_buffer.mutex.unlock();
        input_locked = false;

        self.completeGetConsoleInputResult(
            message.Descriptor.Identifier,
            write_offset,
            result.?,
        ) catch |err| return .{ .failed = utils.mapError(err) };

        self.input_buffer.mutex.lock();
        if ((reply.Flags & windows.CONSOLE_READ_NOREMOVE) == 0) {
            commitGetConsoleInputResultLocked(&self.input_buffer, result.?);
            self.resetInputAvailableIfDrained();
        }
        self.input_buffer.mutex.unlock();

        reply.* = result.?.reply;
        self.finishGetConsoleInputCompletion(completion, reply, result.?.record_count);
        return .completed;
    }

    if ((reply.Flags & windows.CONSOLE_READ_NOWAIT) != 0) {
        self.input_buffer.mutex.unlock();
        input_locked = false;
        reply.NumRecords = 0;
        io_completion.setSuccess(completion);
        return .completed;
    }

    if (self.input_buffer.pending_waiter != null) {
        return .{ .failed = .INVALID_PARAMETER };
    }

    self.input_buffer.pending_waiter = .{
        .identifier = message.Descriptor.Identifier,
        .write_offset = write_offset,
        .max_records = (message.Descriptor.OutputSize - write_offset) / @sizeOf(windows.INPUT_RECORD),
        .reply = reply.*,
    };
    return .pending;
}

fn handleKey(self: *Self, event: KeyEvent) void {
    const resolved_event = resolveKeyEvent(event);

    if (self.handleCookedKey(resolved_event)) return;

    const delivery_route = self.route();

    if (self.tryHandleControlKey(resolved_event)) return;

    switch (delivery_route) {
        .pending_read, .fallback_vt => {
            var buf: [128]u8 = undefined;
            const written = self.terminal.vtEncodeKey(&resolved_event, buf[0..]);
            if (written == 0) return;
            self.deliverVtBytes(buf[0..written]);
        },
        .legacy_waiter, .fallback_legacy => {
            if (self.shouldWrapVtForLegacy(delivery_route)) {
                var buf: [128]u8 = undefined;
                const written = self.terminal.vtEncodeKey(&resolved_event, buf[0..]);
                if (written == 0) return;
                self.deliverLegacyVtBytes(buf[0..written]);
            } else {
                var records: [1]windows.INPUT_RECORD = undefined;
                const count = synthesizeKeyEvent(&records, resolved_event);
                self.deliverLegacyRecords(records[0..count]);
            }
        },
    }
}

fn resolveKeyEvent(event: KeyEvent) KeyEvent {
    if (event.has_win_vk == 0) return event;

    const control_key_state = input_types.effectiveControlKeyState(event, false);

    const code = input_types.codeFromWindowsNative(
        event.win_vk,
        event.win_scan,
        control_key_state,
    ) orelse event.code;

    var resolved = event;
    resolved.code = code;
    return resolved;
}

fn handleMouse(self: *Self, event: MouseEvent) void {
    const delivery_route = self.route();

    switch (delivery_route) {
        .pending_read, .fallback_vt => {
            var buf: [128]u8 = undefined;
            const written = self.terminal.vtEncodeMouse(&event, buf[0..]);
            if (written == 0) return;
            self.deliverVtBytes(buf[0..written]);
        },
        .legacy_waiter, .fallback_legacy => {
            if (self.shouldWrapVtForLegacy(delivery_route)) {
                var buf: [128]u8 = undefined;
                const written = self.terminal.vtEncodeMouse(&event, buf[0..]);
                if (written == 0) return;
                self.deliverLegacyVtBytes(buf[0..written]);
                return;
            }

            var record: windows.INPUT_RECORD = synthesizeMouseEvent(event);
            self.deliverLegacyRecords((&record)[0..1]);
        },
    }
}

fn handleFocus(self: *Self, focused: bool) void {
    const delivery_route = self.route();

    switch (delivery_route) {
        .pending_read, .fallback_vt => {
            var buf: [8]u8 = undefined;
            const written = self.terminal.vtEncodeFocus(focused, buf[0..]);
            if (written == 0) return;
            self.deliverVtBytes(buf[0..written]);
        },
        .legacy_waiter, .fallback_legacy => {
            if (!self.shouldWrapVtForLegacy(delivery_route)) return;

            var buf: [8]u8 = undefined;
            const written = self.terminal.vtEncodeFocus(focused, buf[0..]);
            if (written == 0) return;
            self.deliverLegacyVtBytes(buf[0..written]);
        },
    }
}

fn handlePaste(self: *Self, text: []const u8) void {
    if (self.handleCookedText(text)) return;

    const delivery_route = self.route();

    switch (delivery_route) {
        .pending_read, .fallback_vt => {
            const max_len = text.len + 16;
            const encoded = self.allocator.alloc(u8, max_len) catch return;
            defer self.allocator.free(encoded);

            const written = self.terminal.vtEncodePaste(encoded.ptr, text.ptr, text.len, max_len);
            if (written == 0) return;
            self.deliverVtBytes(encoded[0..written]);
        },
        .legacy_waiter, .fallback_legacy => {
            if (!self.shouldWrapVtForLegacy(delivery_route)) {
                self.deliverLegacyText(text);
                return;
            }

            const max_len = text.len + 16;
            const encoded = self.allocator.alloc(u8, max_len) catch return;
            defer self.allocator.free(encoded);

            const written = self.terminal.vtEncodePaste(encoded.ptr, text.ptr, text.len, max_len);
            if (written == 0) return;
            self.deliverLegacyVtBytes(encoded[0..written]);
        },
    }
}

fn deliverBytes(self: *Self, bytes: []const u8) void {
    if (self.handleCookedText(bytes)) return;

    const delivery_route = self.route();

    switch (delivery_route) {
        .pending_read, .fallback_vt => self.deliverVtBytes(bytes),
        .legacy_waiter, .fallback_legacy => {
            if (self.shouldWrapVtForLegacy(delivery_route)) {
                self.deliverLegacyVtBytes(bytes);
            } else {
                self.deliverLegacyText(bytes);
            }
        },
    }
}

fn route(self: *Self) Route {
    self.vt_input_slot.mutex.lock();
    const has_pending_read = self.vt_input_slot.pending_read != null;
    self.vt_input_slot.mutex.unlock();
    if (has_pending_read) return .pending_read;

    self.input_buffer.mutex.lock();
    const has_pending_waiter = self.input_buffer.pending_waiter != null;
    self.input_buffer.mutex.unlock();
    if (has_pending_waiter) return .legacy_waiter;

    const preferred_reader = self.preferredReader();
    if (preferred_reader == .legacy) return .fallback_legacy;
    if (preferred_reader == .vt) return .fallback_vt;

    return if (self.vtInputModeEnabled()) .fallback_vt else .fallback_legacy;
}

fn setPreferredReader(self: *Self, preferred: PreferredReader) void {
    self.preferred_reader.store(@intFromEnum(preferred), .release);
}

fn preferredReader(self: *const Self) PreferredReader {
    return @enumFromInt(self.preferred_reader.load(.acquire));
}

fn deliverVtBytes(self: *Self, bytes: []const u8) void {
    var overflow = bytes;

    self.vt_input_slot.mutex.lock();
    if (self.vt_input_slot.pending_read) |pending_value| {
        const pending = pending_value;
        self.vt_input_slot.pending_read = null;
        self.vt_input_slot.mutex.unlock();

        const consumed = self.finishPendingVtReadAsync(
            pending,
            bytes,
        ) catch {
            self.vt_input_slot.mutex.lock();
            self.vt_input_slot.pending_read = pending;
            self.vt_input_slot.mutex.unlock();
            return;
        };

        if (consumed == bytes.len) return;

        overflow = bytes[consumed..];
        self.vt_input_slot.mutex.lock();
    }

    defer self.vt_input_slot.mutex.unlock();
    self.vt_input_slot.overflow.appendSlice(self.allocator, overflow) catch return;
}

fn deliverLegacyRecords(self: *Self, records: []const windows.INPUT_RECORD) void {
    var completion: LegacyCompletion = .none;
    defer completion.deinit(self.allocator);

    self.input_buffer.mutex.lock();
    var input_locked = true;
    defer if (input_locked) self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.flushLegacyVtBytesLocked() catch return;
    self.input_buffer.storage.appendSlice(self.allocator, records) catch return;
    if (was_empty) self.signalInputAvailableLocked();
    completion = self.takeLegacyCompletionLocked(true) catch .none;
    self.input_buffer.mutex.unlock();
    input_locked = false;
    self.finishLegacyCompletion(&completion);
}

fn deliverLegacyText(self: *Self, text: []const u8) void {
    var completion: LegacyCompletion = .none;
    defer completion.deinit(self.allocator);

    self.input_buffer.mutex.lock();
    var input_locked = true;
    defer if (input_locked) self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.flushLegacyVtBytesLocked() catch return;
    utf.appendUtf8Text(self.allocator, &self.input_buffer.storage, text) catch return;
    if (was_empty and self.input_buffer.storage.items.len > 0) self.signalInputAvailableLocked();
    completion = self.takeLegacyCompletionLocked(true) catch .none;
    self.input_buffer.mutex.unlock();
    input_locked = false;
    self.finishLegacyCompletion(&completion);
}

fn deliverLegacyVtBytes(self: *Self, bytes: []const u8) void {
    var completion: LegacyCompletion = .none;
    defer completion.deinit(self.allocator);

    self.input_buffer.mutex.lock();
    var input_locked = true;
    defer if (input_locked) self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.input_buffer.vt_byte_storage.appendSlice(self.allocator, bytes) catch return;
    if (was_empty and !self.inputBufferDrainedLocked()) self.signalInputAvailableLocked();
    completion = self.takeLegacyCompletionLocked(false) catch .none;
    self.input_buffer.mutex.unlock();
    input_locked = false;
    self.finishLegacyCompletion(&completion);
}

fn writeOutput(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    bytes: []const u8,
) !void {
    var io = ConDrvHandler.init(self.server_handle);
    var operation: condrv.CD_IO_OPERATION = .{
        .Identifier = identifier,
        .Buffer = .{
            .Data = if (bytes.len == 0) @ptrCast(&empty_write_byte) else @constCast(bytes.ptr),
            .Size = @intCast(bytes.len),
            .Offset = write_offset,
        },
    };
    const status = io.writeOutput(&operation);
    if (!ntSuccess(status)) return error.WriteOutputFailed;
}

fn completeReply(
    self: *Self,
    identifier: windows.LUID,
    reply_ptr: *anyopaque,
    reply_size: windows.ULONG,
    information: usize,
) !void {
    var io = ConDrvHandler.init(self.server_handle);
    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    completion.Identifier = identifier;
    io_completion.setWriteBuffer(&completion, reply_ptr, reply_size);
    io_completion.setSuccessWithInformation(&completion, @as(windows.ULONG_PTR, information));
    const status = io.completeIo(&completion);
    if (!ntSuccess(status)) return error.CompleteIoFailed;
}

fn completeReplyStatus(
    self: *Self,
    identifier: windows.LUID,
    reply_ptr: *anyopaque,
    reply_size: windows.ULONG,
    status: windows.NTSTATUS,
    information: usize,
) !void {
    var io = ConDrvHandler.init(self.server_handle);
    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    completion.Identifier = identifier;
    io_completion.setWriteBuffer(&completion, reply_ptr, reply_size);
    io_completion.setCompletion(&completion, status, @as(windows.ULONG_PTR, information));
    const ntstatus = io.completeIo(&completion);
    if (!ntSuccess(ntstatus)) return error.CompleteIoFailed;
}

fn completeReadConsoleStatus(
    self: *Self,
    identifier: windows.LUID,
    reply_template: console_msg.L1.CONSOLE_READCONSOLE_MSG,
    status: windows.NTSTATUS,
    information: usize,
) !void {
    var reply = reply_template;
    reply.NumBytes = @intCast(information);
    reply.ControlKeyState = 0;
    try self.completeReplyStatus(
        identifier,
        @ptrCast(&reply),
        @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG),
        status,
        information,
    );
}

fn completeRawReadStatus(
    self: *Self,
    identifier: windows.LUID,
    status: windows.NTSTATUS,
    information: usize,
) !void {
    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    completion.Identifier = identifier;
    io_completion.setWritePlaceholder(&completion);
    io_completion.setCompletion(&completion, status, @as(windows.ULONG_PTR, information));

    var io = ConDrvHandler.init(self.server_handle);
    const ntstatus = io.completeIo(&completion);
    if (!ntSuccess(ntstatus)) return error.CompleteIoFailed;
}

fn completeRawReadResult(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    payload: []const u8,
    status: windows.NTSTATUS,
) !void {
    if (payload.len > 0) {
        try self.writeOutput(identifier, write_offset, payload);
    }

    try self.completeRawReadStatus(identifier, status, payload.len);
}

fn signalInputAvailableLocked(self: *Self) void {
    if (self.input_available_event == windows.INVALID_HANDLE_VALUE) return;
    _ = windows.NtSetEvent(self.input_available_event, null);
}

fn resetInputAvailableIfDrained(self: *Self) void {
    if (!self.inputBufferDrainedLocked()) return;
    if (self.input_available_event == windows.INVALID_HANDLE_VALUE) return;
    _ = windows.ResetEvent(self.input_available_event);
}

fn readyGetConsoleInputLocked(self: *const Self) ReadyGetConsoleInput {
    if (self.input_buffer.storage.items.len > 0) return .records;
    if (self.input_buffer.vt_byte_storage.items.len > 0) return .vt_bytes;
    return .none;
}

fn takeLegacyCompletionLocked(self: *Self, allow_vt_waiter: bool) !LegacyCompletion {
    if (self.input_buffer.pending_text_read) |pending| {
        if (self.rawReadReadyLocked()) {
            const result = try self.collectReadConsoleResultLocked(
                pending.capacity,
                pending.reply,
            );
            self.input_buffer.pending_text_read = null;
            return .{ .text_read = .{
                .pending = pending,
                .result = result,
            } };
        }
    }

    if (!allow_vt_waiter and self.input_buffer.storage.items.len != 0) return .none;

    if (self.input_buffer.pending_waiter) |pending| {
        const ready = self.readyGetConsoleInputLocked();
        if (ready == .none) return .none;

        const result = try self.collectGetConsoleInputResultLocked(
            ready,
            pending.max_records * @sizeOf(windows.INPUT_RECORD),
            pending.reply,
        );
        self.input_buffer.pending_waiter = null;
        return .{ .waiter = .{
            .pending = pending,
            .result = result,
        } };
    }

    return .none;
}

fn finishLegacyCompletion(self: *Self, completion: *LegacyCompletion) void {
    switch (completion.*) {
        .none => {},
        .text_read => |value| {
            self.finishPendingReadResultAsync(
                value.pending,
                value.result,
                .SUCCESS,
                0,
            ) catch {
                self.input_buffer.mutex.lock();
                defer self.input_buffer.mutex.unlock();
                if (self.input_buffer.pending_text_read == null) {
                    self.input_buffer.pending_text_read = value.pending;
                }
                return;
            };

            self.input_buffer.mutex.lock();
            defer self.input_buffer.mutex.unlock();
            commitReadConsoleResultLocked(&self.input_buffer, value.result);
            self.resetInputAvailableIfDrained();
        },
        .waiter => |value| {
            self.completeGetConsoleInputResult(
                value.pending.identifier,
                value.pending.write_offset,
                value.result,
            ) catch {
                self.input_buffer.mutex.lock();
                defer self.input_buffer.mutex.unlock();
                if (self.input_buffer.pending_waiter == null) {
                    self.input_buffer.pending_waiter = value.pending;
                }
                return;
            };

            self.input_buffer.mutex.lock();
            defer self.input_buffer.mutex.unlock();
            if ((value.result.reply.Flags & windows.CONSOLE_READ_NOREMOVE) == 0) {
                commitGetConsoleInputResultLocked(&self.input_buffer, value.result);
                self.resetInputAvailableIfDrained();
            }
        },
    }
}

fn collectGetConsoleInputResultLocked(
    self: *Self,
    ready: ReadyGetConsoleInput,
    capacity_bytes: windows.ULONG,
    reply: console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
) !GetConsoleInputResult {
    var prepared_reply = reply;
    const max_records = @as(usize, @intCast(capacity_bytes)) / @sizeOf(windows.INPUT_RECORD);

    return switch (ready) {
        .records => blk: {
            const record_count = @min(self.input_buffer.storage.items.len, max_records);
            const payload = try self.allocator.dupe(u8, std.mem.sliceAsBytes(self.input_buffer.storage.items[0..record_count]));
            prepared_reply.NumRecords = @intCast(record_count);
            break :blk .{
                .reply = prepared_reply,
                .payload = payload,
                .record_count = record_count,
                .consumed_records = record_count,
                .consumed_vt_bytes = 0,
            };
        },
        .vt_bytes => blk: {
            const record_count = @min(self.input_buffer.vt_byte_storage.items.len, max_records);
            const records = try self.allocator.alloc(windows.INPUT_RECORD, record_count);
            errdefer self.allocator.free(records);
            fillVtByteRecords(records, self.input_buffer.vt_byte_storage.items[0..record_count]);
            const payload = try self.allocator.dupe(u8, std.mem.sliceAsBytes(records));
            self.allocator.free(records);
            prepared_reply.NumRecords = @intCast(record_count);
            break :blk .{
                .reply = prepared_reply,
                .payload = payload,
                .record_count = record_count,
                .consumed_records = 0,
                .consumed_vt_bytes = record_count,
            };
        },
        .none => error.InvalidParameter,
    };
}

fn completeGetConsoleInputResult(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    result: GetConsoleInputResult,
) !void {
    if (result.payload.len > 0) {
        try self.writeOutput(identifier, write_offset, result.payload);
    }

    var reply = result.reply;
    try self.completeReply(
        identifier,
        @ptrCast(&reply),
        @sizeOf(console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG),
        result.payload.len,
    );
}

fn commitGetConsoleInputResultLocked(input_buffer: *InputBuffer, result: GetConsoleInputResult) void {
    if (result.consumed_records > 0) {
        consumePrefixRecords(&input_buffer.storage, result.consumed_records);
    }
    if (result.consumed_vt_bytes > 0) {
        consumePrefixBytes(&input_buffer.vt_byte_storage, result.consumed_vt_bytes);
    }
}

fn collectReadConsoleResultLocked(
    self: *Self,
    capacity: windows.ULONG,
    reply: console_msg.L1.CONSOLE_READCONSOLE_MSG,
) !ReadConsoleResult {
    var prepared_reply = reply;
    const payload, const consume = try self.collectReadConsolePayloadLocked(
        @intCast(capacity),
        reply.Unicode != .FALSE,
        reply.ProcessControlZ != .FALSE,
    );

    prepared_reply.NumBytes = @intCast(payload.len);
    prepared_reply.ControlKeyState = 0;

    return .{
        .reply = prepared_reply,
        .payload = payload,
        .consume = consume,
    };
}

fn completeReadConsoleResult(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    result: ReadConsoleResult,
    status: windows.NTSTATUS,
    control_key_state: windows.ULONG,
) !void {
    if (result.payload.len > 0) {
        try self.writeOutput(identifier, write_offset, result.payload);
    }

    var reply = result.reply;
    reply.ControlKeyState = control_key_state;
    try self.completeReplyStatus(
        identifier,
        @ptrCast(&reply),
        @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG),
        status,
        result.payload.len,
    );
}

fn commitReadConsoleResultLocked(input_buffer: *InputBuffer, result: ReadConsoleResult) void {
    if (result.consume.records_to_remove > 0) {
        consumePrefixRecords(&input_buffer.storage, result.consume.records_to_remove);
    }

    if (result.consume.record_repeat_remaining) |remaining| {
        if (input_buffer.storage.items.len > 0) {
            input_buffer.storage.items[0].Event.KeyEvent.wRepeatCount = remaining;
        }
    }

    if (result.consume.vt_bytes_to_remove > 0) {
        consumePrefixBytes(&input_buffer.vt_byte_storage, result.consume.vt_bytes_to_remove);
    }
}

fn collectReadConsolePayloadLocked(
    self: *Self,
    capacity_bytes: usize,
    unicode: bool,
    process_control_z: bool,
) !struct { []u8, RawReadConsume } {
    var payload: std.ArrayList(u8) = .empty;
    errdefer payload.deinit(self.allocator);

    var consume: RawReadConsume = .{};
    const unit_bytes: usize = if (unicode) @sizeOf(u16) else 1;
    const payload_limit = if (unicode)
        (capacity_bytes / @sizeOf(u16)) * @sizeOf(u16)
    else
        capacity_bytes;

    if (payload_limit > 0) {
        try self.collectReadConsoleRecordsLocked(&payload, &consume, payload_limit, unit_bytes, unicode, process_control_z);
    }

    if (payload.items.len == 0 and self.input_buffer.vt_byte_storage.items.len > 0) {
        try collectReadConsoleVtBytes(
            self.allocator,
            self.input_buffer.vt_byte_storage.items,
            &payload,
            &consume,
            payload_limit,
            unicode,
            process_control_z,
        );
    }

    return .{ try payload.toOwnedSlice(self.allocator), consume };
}

fn collectReadConsoleRecordsLocked(
    self: *Self,
    payload: *std.ArrayList(u8),
    consume: *RawReadConsume,
    payload_limit: usize,
    unit_bytes: usize,
    unicode: bool,
    process_control_z: bool,
) !void {
    var record_index: usize = 0;
    while (record_index < self.input_buffer.storage.items.len) : (record_index += 1) {
        if (payload.items.len >= payload_limit) break;

        const record = self.input_buffer.storage.items[record_index];
        if (record.EventType != windows.KEY_EVENT) continue;
        if (record.Event.KeyEvent.bKeyDown == .FALSE) continue;

        const wchar = record.Event.KeyEvent.uChar.UnicodeChar;
        if (wchar == 0) continue;

        const repeat_total: usize = if (record.Event.KeyEvent.wRepeatCount == 0) 1 else record.Event.KeyEvent.wRepeatCount;
        if (process_control_z and payload.items.len == 0 and wchar == 0x1A) {
            if (repeat_total == 1) {
                consume.records_to_remove = record_index + 1;
            } else {
                consume.records_to_remove = record_index;
                consume.record_repeat_remaining = @intCast(repeat_total - 1);
            }
            break;
        }

        if (!unicode and wchar > 0xFF) break;

        var emitted: usize = 0;
        while (emitted < repeat_total and payload.items.len + unit_bytes <= payload_limit) : (emitted += 1) {
            if (unicode) {
                try appendUtf16CodeUnit(self.allocator, payload, wchar);
            } else {
                try payload.append(self.allocator, @truncate(wchar));
            }
        }

        if (emitted == 0) break;
        if (emitted == repeat_total) {
            consume.records_to_remove = record_index + 1;
            continue;
        }

        consume.records_to_remove = record_index;
        consume.record_repeat_remaining = @intCast(repeat_total - emitted);
        break;
    }
}

fn collectReadConsoleVtBytes(
    allocator: std.mem.Allocator,
    vt_bytes: []const u8,
    payload: *std.ArrayList(u8),
    consume: *RawReadConsume,
    payload_limit: usize,
    unicode: bool,
    process_control_z: bool,
) !void {
    if (payload_limit == 0) return;

    if (process_control_z and vt_bytes[0] == 0x1A) {
        consume.vt_bytes_to_remove = 1;
        return;
    }

    if (unicode) {
        const available = @min(payload_limit / @sizeOf(u16), vt_bytes.len);
        try payload.ensureUnusedCapacity(allocator, available * @sizeOf(u16));
        for (vt_bytes[0..available]) |byte| {
            appendUtf16CodeUnitAssumeCapacity(payload, byte);
        }
        consume.vt_bytes_to_remove = available;
        return;
    }

    const available = @min(payload_limit, vt_bytes.len);
    try payload.appendSlice(allocator, vt_bytes[0..available]);
    consume.vt_bytes_to_remove = available;
}

fn appendUtf16CodeUnit(allocator: std.mem.Allocator, out: *std.ArrayList(u8), code_unit: u16) !void {
    try out.ensureUnusedCapacity(allocator, @sizeOf(u16));
    appendUtf16CodeUnitAssumeCapacity(out, code_unit);
}

fn appendUtf16CodeUnitAssumeCapacity(out: *std.ArrayList(u8), code_unit: u16) void {
    out.appendAssumeCapacity(@truncate(code_unit));
    out.appendAssumeCapacity(@truncate(code_unit >> 8));
}

fn finishGetConsoleInputCompletion(
    self: *Self,
    completion: *condrv.CD_IO_COMPLETE,
    reply: *console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
    written_records: usize,
) void {
    _ = self;
    io_completion.setWriteBuffer(
        completion,
        @ptrCast(reply),
        @sizeOf(console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG),
    );
    io_completion.setSuccessWithInformation(
        completion,
        @as(windows.ULONG_PTR, written_records * @sizeOf(windows.INPUT_RECORD)),
    );
}

fn inputBufferDrainedLocked(self: *const Self) bool {
    return self.input_buffer.storage.items.len == 0 and self.input_buffer.vt_byte_storage.items.len == 0;
}

fn flushLegacyVtBytesLocked(self: *Self) !void {
    if (self.input_buffer.vt_byte_storage.items.len == 0) return;

    const vt_bytes = self.input_buffer.vt_byte_storage.items;
    try self.input_buffer.storage.ensureUnusedCapacity(self.allocator, vt_bytes.len);

    for (vt_bytes) |byte| {
        self.input_buffer.storage.appendAssumeCapacity(utf.makeByteKeyRecord(byte));
    }

    self.input_buffer.vt_byte_storage.items.len = 0;
}

fn fillVtByteRecords(records: []windows.INPUT_RECORD, bytes: []const u8) void {
    std.debug.assert(records.len == bytes.len);

    for (records, bytes) |*record, byte| {
        record.* = utf.makeByteKeyRecord(byte);
    }
}

fn vtInputModeEnabled(self: *const Self) bool {
    return self.loadInputMode().enable_virtual_terminal_input;
}

fn processedInputModeEnabled(self: *const Self) bool {
    return self.loadInputMode().enable_processed_input;
}

fn loadInputMode(self: *const Self) InputMode {
    return InputMode.fromInt(self.input_mode.load(.acquire));
}

fn shouldWrapVtForLegacy(self: *const Self, delivery_route: Route) bool {
    if (!self.vtInputModeEnabled()) return false;

    return switch (delivery_route) {
        .legacy_waiter => true,
        .fallback_legacy => self.preferredReader() == .legacy,
        .pending_read, .fallback_vt => false,
    };
}

fn handleCookedKey(self: *Self, event: KeyEvent) bool {
    self.cooked_read_slot.mutex.lock();

    var active = self.cooked_read_slot.active orelse {
        self.cooked_read_slot.mutex.unlock();
        return false;
    };
    const outcome = CookedRead.handleKey(
        self.allocator,
        self.terminal,
        self.loadInputMode(),
        &active,
        event,
    ) catch {
        self.cooked_read_slot.active = active;
        self.cooked_read_slot.mutex.unlock();
        return true;
    };
    self.cooked_read_slot.active = active;

    switch (outcome) {
        .pending => self.cooked_read_slot.mutex.unlock(),
        .complete => |completion| self.finishCookedCompletionLocked(completion),
    }
    return true;
}

fn handleCookedText(self: *Self, text: []const u8) bool {
    self.cooked_read_slot.mutex.lock();

    var active = self.cooked_read_slot.active orelse {
        self.cooked_read_slot.mutex.unlock();
        return false;
    };
    const outcome = CookedRead.handleText(
        self.allocator,
        self.terminal,
        self.loadInputMode(),
        &active,
        text,
    ) catch {
        self.cooked_read_slot.active = active;
        self.cooked_read_slot.mutex.unlock();
        return true;
    };
    self.cooked_read_slot.active = active;

    switch (outcome) {
        .pending => self.cooked_read_slot.mutex.unlock(),
        .complete => |completion| self.finishCookedCompletionLocked(completion),
    }
    return true;
}

fn finishCookedCompletionLocked(self: *Self, completion: CookedRead.Completion) void {
    var active = self.cooked_read_slot.active.?;
    self.cooked_read_slot.active = null;

    const pending = active.pending;
    const history = active.history;
    const history_line = if (completion.kind == .enter)
        self.allocator.dupe(u8, active.line.items) catch {
            self.cooked_read_slot.active = active;
            self.allocator.free(completion.payload);
            return;
        }
    else
        null;
    defer if (history_line) |line| self.allocator.free(line);
    self.cooked_read_slot.mutex.unlock();

    defer self.allocator.free(completion.payload);

    if (completion.kind == .cancel) {
        self.state.dispatchControlEvent(windows.CTRL_C_EVENT, 0) catch |err| {
            std.log.warn("failed to dispatch CTRL_C_EVENT: {}", .{err});
        };
    }

    const delivered = @min(completion.payload.len, @as(usize, @intCast(pending.capacity)));
    var completion_failed = false;
    if (!completion_failed) {
        const result: ReadConsoleResult = .{
            .reply = pending.reply,
            .payload = completion.payload[0..delivered],
            .consume = .{},
        };
        self.finishPendingReadResultAsync(
            .{
                .target = pending.target,
                .identifier = pending.identifier,
                .write_offset = pending.write_offset,
                .capacity = pending.capacity,
                .reply = pending.reply,
            },
            result,
            completion.status,
            completion.control_key_state,
        ) catch {
            completion_failed = true;
        };
    }

    self.cooked_read_slot.mutex.lock();
    defer self.cooked_read_slot.mutex.unlock();

    if (completion_failed) {
        self.cooked_read_slot.active = active;
        return;
    }

    if (history_line) |line| {
        if (history) |history_ref| {
            history_ref.append(
                self.allocator,
                self.state.console.history,
                line,
            ) catch |err| {
                std.log.warn("failed to append cooked history entry: {}", .{err});
            };
        }
    }

    active.deinit(self.allocator);
}

fn readReadConsolePayload(self: *Self, message: *const api_msg.CONSOLE_DATA_PACKET) ![]u8 {
    const payload_offset = @sizeOf(console_msg.CONSOLE_MSG_HEADER) + @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG);
    const input_size: usize = message.Descriptor.InputSize;
    if (input_size < payload_offset) return error.InvalidParameter;

    const payload_size = input_size - payload_offset;
    const payload = try self.allocator.alloc(u8, payload_size);
    errdefer self.allocator.free(payload);

    if (payload.len == 0) return payload;

    var io = ConDrvHandler.init(self.server_handle);
    var operation: condrv.CD_IO_OPERATION = .{
        .Identifier = message.Descriptor.Identifier,
        .Buffer = .{
            .Data = payload.ptr,
            .Size = @intCast(payload.len),
            .Offset = @intCast(payload_offset),
        },
    };
    const status = io.readInput(&operation);
    if (!ntSuccess(status)) return error.ReadInputFailed;
    return payload;
}

fn decodeReadConsolePayload(
    self: *Self,
    reply: *const console_msg.L1.CONSOLE_READCONSOLE_MSG,
    message: *const api_msg.CONSOLE_DATA_PACKET,
) !ReadConsolePayload {
    const payload = try self.readReadConsolePayload(message);
    defer self.allocator.free(payload);

    const exe_name_bytes_len = @as(usize, reply.ExeNameLength) * @sizeOf(windows.WCHAR);
    if (exe_name_bytes_len > payload.len) {
        return error.InvalidParameter;
    }

    const exe_name_bytes = payload[0..exe_name_bytes_len];
    const initial_available = payload[exe_name_bytes_len..];
    const initial_len = @min(initial_available.len, @as(usize, reply.InitialNumBytes));

    const exe_name = if (exe_name_bytes.len == 0)
        try self.allocator.alloc(u8, 0)
    else
        try utf.utf16BytesToUtf8Alloc(self.allocator, exe_name_bytes);
    errdefer self.allocator.free(exe_name);

    const initial_text = if (reply.Unicode != .FALSE)
        try utf.utf16BytesToUtf8Alloc(self.allocator, initial_available[0..initial_len])
    else
        try self.allocator.dupe(u8, initial_available[0..initial_len]);
    errdefer self.allocator.free(initial_text);

    return .{
        .exe_name = exe_name,
        .initial_text = initial_text,
    };
}

fn readConsoleBegin(message: *api_msg.CONSOLE_DATA_PACKET) ?ReadConsoleBegin {
    const reply = &message.Body.api_msg.msgBody.consoleMsgL1.ReadConsole;
    const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
    if (message.Descriptor.OutputSize <= write_offset) return null;

    return .{
        .identifier = message.Descriptor.Identifier,
        .reply = reply,
        .write_offset = write_offset,
        .capacity = message.Descriptor.OutputSize - write_offset,
    };
}

fn rawReadReadyLocked(self: *const Self) bool {
    return self.input_buffer.storage.items.len > 0 or self.input_buffer.vt_byte_storage.items.len > 0;
}

fn tryHandleControlKey(self: *Self, event: KeyEvent) bool {
    if (!self.processedInputModeEnabled()) return false;
    if (event.action != .press) return false;

    const control_state = input_types.effectiveControlKeyState(event, true);
    if (input_types.isCtrlC(event, control_state)) {
        self.state.dispatchControlEvent(windows.CTRL_C_EVENT, 0) catch |err| {
            std.log.warn("failed to dispatch CTRL_C_EVENT: {}", .{err});
        };
        return true;
    }

    // TODO: Exact Ctrl+Break parity needs native Windows VK/scancode metadata
    // from GPUI. Until that lands, leave Ctrl+Break on the normal input path.
    return false;
}

fn consumePrefixBytes(list: *std.ArrayList(u8), count: usize) void {
    if (count == 0) return;
    if (count >= list.items.len) {
        list.items.len = 0;
        return;
    }

    @memmove(list.items[0 .. list.items.len - count], list.items[count..]);
    list.items.len -= count;
}

fn consumePrefixRecords(list: *std.ArrayList(windows.INPUT_RECORD), count: usize) void {
    if (count == 0) return;
    if (count >= list.items.len) {
        list.items.len = 0;
        return;
    }

    @memmove(list.items[0 .. list.items.len - count], list.items[count..]);
    list.items.len -= count;
}

fn synthesizeKeyEvent(out: *[1]windows.INPUT_RECORD, event: KeyEvent) usize {
    const key_down: windows.BOOL = switch (event.action) {
        .release => .FALSE,
        .press, .repeat => .TRUE,
    };

    const control_state = input_types.effectiveControlKeyState(event, true);
    const utf16_char = deriveLegacyUnicodeChar(event, control_state);

    out[0] = .{
        .EventType = windows.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = key_down,
            .wRepeatCount = if (event.repeat_count == 0) 1 else event.repeat_count,
            .wVirtualKeyCode = if (event.has_win_vk != 0) event.win_vk else 0,
            .wVirtualScanCode = if (event.has_win_scan != 0) event.win_scan else 0,
            .uChar = .{ .UnicodeChar = utf16_char },
            .dwControlKeyState = control_state,
        } },
    };
    return 1;
}

fn deriveLegacyUnicodeChar(event: KeyEvent, control_state: windows.DWORD) windows.WCHAR {
    if (event.text_len > 0) {
        if (event.has_win_vk != 0) {
            const ctrl_char = deriveCtrlLetterUnicodeChar(event.win_vk, control_state);
            if (ctrl_char != 0) return ctrl_char;
        }
        return utf.utf16CodeUnit(event.text[0..@as(usize, event.text_len)]);
    }

    const win_vk = if (event.has_win_vk != 0) event.win_vk else 0;
    if (win_vk != 0) {
        return switch (win_vk) {
            0x0D => '\r', // VK_RETURN
            0x08 => if (input_types.shouldUseCtrlBackspaceWordErase(control_state)) 0x7F else 0x08, // VK_BACK
            0x09 => '\t', // VK_TAB
            0x1B => 0x1B, // VK_ESCAPE
            else => deriveCtrlLetterUnicodeChar(win_vk, control_state),
        };
    }

    return switch (event.code) {
        .enter => '\r',
        .backspace => 0x08,
        .tab => '\t',
        .escape => 0x1B,
        else => 0,
    };
}

fn deriveCtrlLetterUnicodeChar(win_vk: u16, control_state: windows.DWORD) windows.WCHAR {
    const ctrl_pressed = (control_state &
        (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;
    const alt_pressed = (control_state &
        (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED)) != 0;
    if (!ctrl_pressed or alt_pressed) return 0;
    if (win_vk < 'A' or win_vk > 'Z') return 0;

    return @as(windows.WCHAR, @intCast((win_vk - 'A') + 1));
}

const TestTerminal = struct {
    const vtable: Terminal.VTable = .{
        .feed = feed,
        .vt_encode_key = noVtEncodeKey,
        .vt_encode_mouse = noVtEncodeMouse,
        .vt_encode_focus = noVtEncodeFocus,
        .vt_encode_paste = noVtEncodePaste,
        .get_size = getSize,
        .get_cursor_position = getCursorPosition,
        .get_cursor_visible = getCursorVisible,
        .get_cell_size = getCellSize,
        .get_title = getTitle,
        .get_base16_palette = getBase16Palette,
        .read_rect = readRect,
        .write_rect = writeRect,
        .fill_span = fillSpan,
    };

    fn terminal(self: *TestTerminal) Terminal {
        return Terminal.init(self, &vtable);
    }

    fn feed(_: *anyopaque, _: []const u8) void {}
    fn noVtEncodeKey(_: *anyopaque, _: *const input_types.KeyEvent, _: [*]u8, _: usize) usize {
        return 0;
    }
    fn noVtEncodeMouse(_: *anyopaque, _: *const input_types.MouseEvent, _: [*]u8, _: usize) usize {
        return 0;
    }
    fn noVtEncodeFocus(_: *anyopaque, _: bool, _: [*]u8, _: usize) usize {
        return 0;
    }
    fn noVtEncodePaste(_: *anyopaque, _: [*]u8, _: [*]const u8, _: usize, _: usize) usize {
        return 0;
    }
    fn getSize(_: *anyopaque, cols: *u16, rows: *u16) void {
        cols.* = 80;
        rows.* = 25;
    }
    fn getCursorPosition(_: *anyopaque, col: *u16, row: *u16) void {
        col.* = 0;
        row.* = 0;
    }
    fn getCursorVisible(_: *anyopaque, visible: *bool) void {
        visible.* = true;
    }
    fn getCellSize(_: *anyopaque, width_px: *u16, height_px: *u16) void {
        width_px.* = 8;
        height_px.* = 16;
    }
    fn getTitle(_: *anyopaque, _: [*]u8, _: usize) usize {
        return 0;
    }
    fn getBase16Palette(_: *anyopaque, out: *[16]terminal_mod.RGB) void {
        out.* = std.mem.zeroes([16]terminal_mod.RGB);
    }
    fn readRect(_: *anyopaque, rect: terminal_mod.Rect, _: [*]terminal_mod.Cell) terminal_mod.Rect {
        return rect;
    }
    fn writeRect(_: *anyopaque, rect: terminal_mod.Rect, _: [*]const terminal_mod.Cell) terminal_mod.Rect {
        return rect;
    }
    fn fillSpan(_: *anyopaque, _: terminal_mod.Point, _: u32, _: terminal_mod.FillKind, _: terminal_mod.Cell) u32 {
        return 0;
    }
};

test "raw read with line input installs cooked pending read" {
    var terminal_state: TestTerminal = .{};
    var state = State.init(std.testing.allocator, terminal_state.terminal());
    defer state.deinit();

    var input: Self = undefined;
    input.init(
        std.testing.allocator,
        windows.INVALID_HANDLE_VALUE,
        &state,
        terminal_state.terminal(),
        &state.console.input_mode,
    );
    defer input.deinit();

    var message: api_msg.CONSOLE_DATA_PACKET = std.mem.zeroes(api_msg.CONSOLE_DATA_PACKET);
    message.Descriptor.OutputSize = 1;

    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    const result = input.beginRawRead(&message, &completion);
    try std.testing.expect(result == .pending);

    input.cooked_read_slot.mutex.lock();
    defer input.cooked_read_slot.mutex.unlock();
    try std.testing.expect(input.cooked_read_slot.active != null);
    try std.testing.expectEqual(ReadTarget.raw_io, input.cooked_read_slot.active.?.pending.target);
    try std.testing.expect(input.cooked_read_slot.active.?.pending.reply.ProcessControlZ != .FALSE);
}

test "raw read with vt input installs pending vt read" {
    var terminal_state: TestTerminal = .{};
    var state = State.init(std.testing.allocator, terminal_state.terminal());
    defer state.deinit();

    var mode = state.console.loadInputMode(.acquire);
    mode.enable_line_input = false;
    mode.enable_echo_input = false;
    mode.enable_virtual_terminal_input = true;
    state.console.storeInputMode(.release, mode);

    var input: Self = undefined;
    input.init(
        std.testing.allocator,
        windows.INVALID_HANDLE_VALUE,
        &state,
        terminal_state.terminal(),
        &state.console.input_mode,
    );
    defer input.deinit();

    var message: api_msg.CONSOLE_DATA_PACKET = std.mem.zeroes(api_msg.CONSOLE_DATA_PACKET);
    message.Descriptor.OutputSize = 8;

    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    const result = input.beginRawRead(&message, &completion);
    try std.testing.expect(result == .pending);

    input.vt_input_slot.mutex.lock();
    defer input.vt_input_slot.mutex.unlock();
    try std.testing.expect(input.vt_input_slot.pending_read != null);
    try std.testing.expectEqual(ReadTarget.raw_io, input.vt_input_slot.pending_read.?.target);
}

test "raw read inline completion converts ctrl-z to eof" {
    var terminal_state: TestTerminal = .{};
    var state = State.init(std.testing.allocator, terminal_state.terminal());
    defer state.deinit();

    var input: Self = undefined;
    input.init(
        std.testing.allocator,
        windows.INVALID_HANDLE_VALUE,
        &state,
        terminal_state.terminal(),
        &state.console.input_mode,
    );
    defer input.deinit();

    var completion: condrv.CD_IO_COMPLETE = std.mem.zeroes(condrv.CD_IO_COMPLETE);
    io_completion.setWritePlaceholder(&completion);

    const pending: PendingByteRead = .{
        .target = .raw_io,
        .identifier = std.mem.zeroes(windows.LUID),
        .write_offset = 0,
        .capacity = 1,
        .reply = rawReadReply(&input),
    };
    const consumed = try input.finishPendingVtReadInline(
        &completion,
        pending,
        null,
        &[_]u8{0x1A},
    );

    try std.testing.expectEqual(@as(usize, 1), consumed);
    try std.testing.expectEqual(@as(windows.ULONG_PTR, 0), completion.IoStatus.Information);
}

test "legacy key synthesis maps ctrl+backspace to word erase" {
    var event: KeyEvent = std.mem.zeroes(KeyEvent);
    event.has_win_vk = 1;
    event.win_vk = 0x08; // VK_BACK
    event.has_win_control_key_state = 1;
    event.win_control_key_state = windows.LEFT_CTRL_PRESSED;

    try std.testing.expectEqual(
        @as(windows.WCHAR, 0x7F),
        deriveLegacyUnicodeChar(event, event.win_control_key_state),
    );
}

test "legacy key synthesis keeps ctrl+shift+backspace as backspace" {
    var event: KeyEvent = std.mem.zeroes(KeyEvent);
    event.has_win_vk = 1;
    event.win_vk = 0x08; // VK_BACK
    event.has_win_control_key_state = 1;
    event.win_control_key_state = windows.LEFT_CTRL_PRESSED | windows.SHIFT_PRESSED;

    try std.testing.expectEqual(
        @as(windows.WCHAR, 0x08),
        deriveLegacyUnicodeChar(event, event.win_control_key_state),
    );
}

test "legacy key synthesis keeps ctrl+h as backspace control char" {
    var event: KeyEvent = std.mem.zeroes(KeyEvent);
    event.has_win_vk = 1;
    event.win_vk = 'H';
    event.has_win_control_key_state = 1;
    event.win_control_key_state = windows.LEFT_CTRL_PRESSED;

    try std.testing.expectEqual(
        @as(windows.WCHAR, 0x08),
        deriveLegacyUnicodeChar(event, event.win_control_key_state),
    );
}

fn synthesizeMouseEvent(event: MouseEvent) windows.INPUT_RECORD {
    const button_state, const event_flags = legacyMouseState(event);

    return .{
        .EventType = windows.MOUSE_EVENT,
        .Event = .{ .MouseEvent = .{
            .dwMousePosition = .{
                .X = @intCast(event.position.x),
                .Y = @intCast(event.position.y),
            },
            .dwButtonState = button_state,
            .dwControlKeyState = input_types.controlKeyStateFromMods(event.mods),
            .dwEventFlags = event_flags,
        } },
    };
}

fn legacyMouseState(event: MouseEvent) struct { windows.DWORD, windows.DWORD } {
    return switch (event.action) {
        .press => legacyMousePressState(event.button),
        .release => .{ 0, 0 },
        .motion => .{ legacyPointerButtonState(event.button), windows.MOUSE_MOVED },
    };
}

fn legacyMousePressState(button: MouseButton) struct { windows.DWORD, windows.DWORD } {
    return switch (button) {
        .four => .{ windows.SCROLL_DELTA_FORWARD, windows.MOUSE_WHEELED },
        .five => .{ windows.SCROLL_DELTA_BACKWARD, windows.MOUSE_WHEELED },
        .six => .{ windows.SCROLL_DELTA_BACKWARD, windows.MOUSE_HWHEELED },
        .seven => .{ windows.SCROLL_DELTA_FORWARD, windows.MOUSE_HWHEELED },
        else => .{ legacyPointerButtonState(button), 0 },
    };
}

fn legacyPointerButtonState(button: MouseButton) windows.DWORD {
    return switch (button) {
        .left => windows.FROM_LEFT_1ST_BUTTON_PRESSED,
        .middle => windows.FROM_LEFT_2ND_BUTTON_PRESSED,
        .right => windows.RIGHTMOST_BUTTON_PRESSED,
        else => 0,
    };
}

test "legacy mouse motion keeps pressed button state" {
    const record = synthesizeMouseEvent(.{
        .button = .middle,
        .action = .motion,
        .mods = .{},
        .position = .{
            .x = 7,
            .y = 9,
            .x_px = 56, // 7 * 8px
            .y_px = 144, // 9 * 16px
        },
    });

    try std.testing.expectEqual(windows.MOUSE_EVENT, record.EventType);
    try std.testing.expectEqual(windows.FROM_LEFT_2ND_BUTTON_PRESSED, record.Event.MouseEvent.dwButtonState);
    try std.testing.expectEqual(windows.MOUSE_MOVED, record.Event.MouseEvent.dwEventFlags);
    try std.testing.expectEqual(@as(windows.SHORT, 7), record.Event.MouseEvent.dwMousePosition.X);
    try std.testing.expectEqual(@as(windows.SHORT, 9), record.Event.MouseEvent.dwMousePosition.Y);
}

test "legacy mouse wheel uses wheel flags and delta" {
    const record = synthesizeMouseEvent(.{
        .button = .four,
        .action = .press,
        .mods = .{},
        .position = .{
            .x = 3,
            .y = 4,
            .x_px = 24, // 3 * 8px
            .y_px = 64, // 4 * 16px
        },
    });

    try std.testing.expectEqual(windows.MOUSE_EVENT, record.EventType);
    try std.testing.expectEqual(windows.SCROLL_DELTA_FORWARD, record.Event.MouseEvent.dwButtonState);
    try std.testing.expectEqual(windows.MOUSE_WHEELED, record.Event.MouseEvent.dwEventFlags);
}

test "legacy mouse press preserves modifier state" {
    const record = synthesizeMouseEvent(.{
        .button = .left,
        .action = .press,
        .mods = .{ .shift = true, .ctrl = true },
        .position = .{
            .x = 1,
            .y = 2,
            .x_px = 8, // 1 * 8px
            .y_px = 32, // 2 * 16px
        },
    });

    try std.testing.expectEqual(windows.MOUSE_EVENT, record.EventType);
    try std.testing.expectEqual(windows.FROM_LEFT_1ST_BUTTON_PRESSED, record.Event.MouseEvent.dwButtonState);
    try std.testing.expectEqual(
        windows.SHIFT_PRESSED | windows.LEFT_CTRL_PRESSED,
        record.Event.MouseEvent.dwControlKeyState,
    );
    try std.testing.expectEqual(@as(windows.DWORD, 0), record.Event.MouseEvent.dwEventFlags);
}
