const Self = @This();

const std = @import("std");
const windows = @import("../windows.zig");

const api_msg = @import("ApiMsg.zig");
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
const InputMode = session_state.InputMode;
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
input_buffer: InputBuffer,
preferred_reader: std.atomic.Value(u8),

pub const BeginResult = enum {
    completed,
    pending,
    unsupported,
};

pub const VtInputSlot = struct {
    mutex: std.Thread.Mutex = .{},
    pending_read: ?PendingRead = null,
    overflow: std.ArrayList(u8) = .empty,
};

pub const PendingRead = struct {
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity: windows.ULONG,
    reply: console_msg.L1.CONSOLE_READCONSOLE_MSG,
};

pub const InputBuffer = struct {
    mutex: std.Thread.Mutex = .{},
    storage: std.ArrayList(windows.INPUT_RECORD) = .empty,
    vt_byte_storage: std.ArrayList(u8) = .empty,
    pending_waiter: ?PendingWaiter = null,
};

pub const PendingWaiter = struct {
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    max_records: windows.ULONG,
    reply: console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
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
        .input_buffer = .{},
        .preferred_reader = std.atomic.Value(u8).init(@intFromEnum(PreferredReader.none)),
    };
}

pub fn deinit(self: *Self) void {
    self.vt_input_slot.overflow.deinit(self.allocator);
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
    if (!input_mode.enable_virtual_terminal_input) {
        // ReadConsole is only supported through VT input mode.
        // Cooked/line input is a separate subsystem.
        // TODO: Implement Cooked Read
        // if (input_mode.enable_line_input) { ... }
        return .unsupported;
    }

    self.setPreferredReader(.vt);

    const reply = &message.Body.api_msg.msgBody.consoleMsgL1.ReadConsole;
    const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
    if (message.Descriptor.OutputSize < write_offset) return .unsupported;
    if (message.Descriptor.OutputSize == write_offset) return .unsupported;

    self.vt_input_slot.mutex.lock();
    defer self.vt_input_slot.mutex.unlock();

    if (self.vt_input_slot.overflow.items.len > 0) {
        const written = self.completeReadConsole(
            message.Descriptor.Identifier,
            write_offset,
            message.Descriptor.OutputSize - write_offset,
            reply,
            self.vt_input_slot.overflow.items,
        ) catch return .unsupported;
        consumePrefixBytes(&self.vt_input_slot.overflow, written);
        io_completion.setWriteBuffer(completion, @ptrCast(reply), @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG));
        io_completion.setSuccessWithInformation(completion, reply.NumBytes);
        return .completed;
    }

    self.vt_input_slot.pending_read = .{
        .identifier = message.Descriptor.Identifier,
        .write_offset = write_offset,
        .capacity = message.Descriptor.OutputSize - write_offset,
        .reply = reply.*,
    };
    return .pending;
}

pub fn beginGetConsoleInput(
    self: *Self,
    message: *api_msg.CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) BeginResult {
    self.setPreferredReader(.legacy);

    const reply = &message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleInput;
    const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
    if (message.Descriptor.OutputSize < write_offset) return .unsupported;
    if (message.Descriptor.OutputSize == write_offset) return .unsupported;

    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    const ready = self.readyGetConsoleInputLocked();
    if (ready != .none) {
        const written_records = self.completeReadyGetConsoleInputLocked(
            ready,
            message.Descriptor.Identifier,
            write_offset,
            message.Descriptor.OutputSize - write_offset,
            reply,
        ) catch return .unsupported;
        self.finishGetConsoleInputCompletion(completion, reply, written_records);
        return .completed;
    }

    if ((reply.Flags & windows.CONSOLE_READ_NOWAIT) != 0) {
        reply.NumRecords = 0;
        io_completion.setSuccess(completion);
        return .completed;
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

    const control_key_state = if (event.has_win_control_key_state != 0)
        event.win_control_key_state
    else
        input_types.controlKeyStateFromMods(event.mods);

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
    if (self.vt_input_slot.pending_read) |_| {
        var pending = self.vt_input_slot.pending_read.?;
        self.vt_input_slot.pending_read = null;
        self.vt_input_slot.mutex.unlock();

        const consumed = self.completeReadConsole(
            pending.identifier,
            pending.write_offset,
            pending.capacity,
            &pending.reply,
            bytes,
        ) catch 0;

        if (consumed == bytes.len) return;

        overflow = bytes[consumed..];
        self.vt_input_slot.mutex.lock();
    }

    defer self.vt_input_slot.mutex.unlock();
    self.vt_input_slot.overflow.appendSlice(self.allocator, overflow) catch return;
}

fn deliverLegacyRecords(self: *Self, records: []const windows.INPUT_RECORD) void {
    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.flushLegacyVtBytesLocked() catch return;
    self.input_buffer.storage.appendSlice(self.allocator, records) catch return;
    if (was_empty) self.signalInputAvailableLocked();

    if (self.input_buffer.pending_waiter) |pending| {
        self.input_buffer.pending_waiter = null;
        self.completePendingWaiterLocked(pending);
    }
}

fn deliverLegacyText(self: *Self, text: []const u8) void {
    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.flushLegacyVtBytesLocked() catch return;
    utf.appendUtf8Text(self.allocator, &self.input_buffer.storage, text) catch return;
    if (was_empty and self.input_buffer.storage.items.len > 0) self.signalInputAvailableLocked();

    if (self.input_buffer.pending_waiter) |pending| {
        self.input_buffer.pending_waiter = null;
        self.completePendingWaiterLocked(pending);
    }
}

fn deliverLegacyVtBytes(self: *Self, bytes: []const u8) void {
    self.input_buffer.mutex.lock();
    defer self.input_buffer.mutex.unlock();

    const was_empty = self.inputBufferDrainedLocked();
    self.input_buffer.vt_byte_storage.appendSlice(self.allocator, bytes) catch return;
    if (was_empty and !self.inputBufferDrainedLocked()) self.signalInputAvailableLocked();

    if (self.input_buffer.pending_waiter) |pending| {
        if (self.input_buffer.storage.items.len != 0) return;

        self.input_buffer.pending_waiter = null;
        self.completePendingWaiterLocked(pending);
    }
}

fn completeReadConsole(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity: windows.ULONG,
    reply: *console_msg.L1.CONSOLE_READCONSOLE_MSG,
    bytes: []const u8,
) !usize {
    const consumed = @min(bytes.len, @as(usize, @intCast(capacity)));
    var delivered = consumed;
    if (reply.ProcessControlZ != .FALSE and consumed > 0 and bytes[0] == 0x1a) {
        delivered = 0;
    }

    if (delivered > 0) {
        try self.writeOutput(identifier, write_offset, bytes[0..delivered]);
    }

    reply.NumBytes = @intCast(delivered);
    reply.ControlKeyState = 0;
    try self.completeReply(identifier, @ptrCast(reply), @sizeOf(console_msg.L1.CONSOLE_READCONSOLE_MSG), delivered);
    return consumed;
}

fn completeGetConsoleInputRecords(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity_bytes: windows.ULONG,
    reply: *console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
    records: []const windows.INPUT_RECORD,
) !usize {
    const max_records = @as(usize, @intCast(capacity_bytes)) / @sizeOf(windows.INPUT_RECORD);
    const record_count = @min(records.len, max_records);
    const byte_count = record_count * @sizeOf(windows.INPUT_RECORD);

    if (byte_count > 0) {
        const payload = std.mem.sliceAsBytes(records[0..record_count]);
        try self.writeOutput(identifier, write_offset, payload);
    }

    reply.NumRecords = @intCast(record_count);
    try self.completeReply(
        identifier,
        @ptrCast(reply),
        @sizeOf(console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG),
        byte_count,
    );
    return record_count;
}

fn completeGetConsoleInputVtBytes(
    self: *Self,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity_bytes: windows.ULONG,
    reply: *console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
    bytes: []const u8,
) !usize {
    const max_records = @as(usize, @intCast(capacity_bytes)) / @sizeOf(windows.INPUT_RECORD);
    const record_count = @min(bytes.len, max_records);
    const byte_count = record_count * @sizeOf(windows.INPUT_RECORD);

    if (byte_count > 0) {
        if (record_count <= 64) {
            var stack_records: [64]windows.INPUT_RECORD = undefined;
            fillVtByteRecords(stack_records[0..record_count], bytes[0..record_count]);
            try self.writeOutput(identifier, write_offset, std.mem.sliceAsBytes(stack_records[0..record_count]));
        } else {
            const heap_records = try self.allocator.alloc(windows.INPUT_RECORD, record_count);
            defer self.allocator.free(heap_records);
            fillVtByteRecords(heap_records, bytes[0..record_count]);
            try self.writeOutput(identifier, write_offset, std.mem.sliceAsBytes(heap_records));
        }
    }

    reply.NumRecords = @intCast(record_count);
    try self.completeReply(
        identifier,
        @ptrCast(reply),
        @sizeOf(console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG),
        byte_count,
    );
    return record_count;
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

fn signalInputAvailableLocked(self: *Self) void {
    if (self.input_available_event == windows.INVALID_HANDLE_VALUE) return;
    _ = windows.NtSetEvent(self.input_available_event, null);
}

fn resetInputAvailableIfDrained(self: *Self) void {
    if (!self.inputBufferDrainedLocked()) return;
    if (self.input_available_event == windows.INVALID_HANDLE_VALUE) return;
    _ = windows.ResetEvent(self.input_available_event);
}

fn completePendingWaiterLocked(self: *Self, pending_value: PendingWaiter) void {
    var pending = pending_value;
    const ready = self.readyGetConsoleInputLocked();
    if (ready == .none) return;

    _ = self.completeReadyGetConsoleInputLocked(
        ready,
        pending.identifier,
        pending.write_offset,
        pending.max_records * @sizeOf(windows.INPUT_RECORD),
        &pending.reply,
    ) catch return;
}

fn readyGetConsoleInputLocked(self: *const Self) ReadyGetConsoleInput {
    if (self.input_buffer.storage.items.len > 0) return .records;
    if (self.input_buffer.vt_byte_storage.items.len > 0) return .vt_bytes;
    return .none;
}

fn completeReadyGetConsoleInputLocked(
    self: *Self,
    ready: ReadyGetConsoleInput,
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity_bytes: windows.ULONG,
    reply: *console_msg.L1.CONSOLE_GETCONSOLEINPUT_MSG,
) !usize {
    const written = switch (ready) {
        .records => try self.completeGetConsoleInputRecords(
            identifier,
            write_offset,
            capacity_bytes,
            reply,
            self.input_buffer.storage.items,
        ),
        .vt_bytes => try self.completeGetConsoleInputVtBytes(
            identifier,
            write_offset,
            capacity_bytes,
            reply,
            self.input_buffer.vt_byte_storage.items,
        ),
        .none => return 0,
    };

    if ((reply.Flags & windows.CONSOLE_READ_NOREMOVE) == 0) {
        switch (ready) {
            .records => consumePrefixRecords(&self.input_buffer.storage, written),
            .vt_bytes => consumePrefixBytes(&self.input_buffer.vt_byte_storage, written),
            .none => {},
        }
        self.resetInputAvailableIfDrained();
    }

    return written;
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

fn tryHandleControlKey(self: *Self, event: KeyEvent) bool {
    if (!self.processedInputModeEnabled()) return false;
    if (event.action != .press) return false;

    const control_state = effectiveControlState(event);
    const ctrl_pressed = (control_state &
        (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;
    const alt_pressed = (control_state &
        (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED)) != 0;
    if (!ctrl_pressed or alt_pressed) return false;

    if (event.code == .key_c) {
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

    const control_state = effectiveControlState(event);
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

fn effectiveControlState(event: KeyEvent) windows.DWORD {
    var state: windows.DWORD = if (event.has_win_control_key_state != 0)
        event.win_control_key_state
    else
        input_types.controlKeyStateFromMods(event.mods);

    if (event.has_win_vk != 0 and shouldSetEnhancedFlag(event.win_vk)) {
        state |= windows.ENHANCED_KEY;
    }

    return state;
}

fn shouldSetEnhancedFlag(win_vk: u16) bool {
    return switch (win_vk) {
        0x21, // VK_PRIOR (Page Up)
        0x22, // VK_NEXT  (Page Down)
        0x23, // VK_END
        0x24, // VK_HOME
        0x25, // VK_LEFT
        0x26, // VK_UP
        0x27, // VK_RIGHT
        0x28, // VK_DOWN
        0x2D, // VK_INSERT
        0x2E, // VK_DELETE
        0x6F, // VK_DIVIDE (numpad)
        => true,
        else => false,
    };
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
            0x08 => if (shouldUseCtrlBackspaceWordErase(control_state)) 0x7F else 0x08, // VK_BACK
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

fn shouldUseCtrlBackspaceWordErase(control_state: windows.DWORD) bool {
    const ctrl_pressed = (control_state &
        (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;
    const alt_pressed = (control_state &
        (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED)) != 0;
    const shift_pressed = (control_state & windows.SHIFT_PRESSED) != 0;

    // OpenConsole cooked-read semantics treat Ctrl+Backspace as word erase
    // (DEL / 0x7F), but do not apply that behavior when Shift is also held.
    return ctrl_pressed and !alt_pressed and !shift_pressed;
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
