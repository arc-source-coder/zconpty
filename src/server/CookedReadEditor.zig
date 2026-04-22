const std = @import("std");
const uucode = @import("uucode");
const windows = @import("../windows.zig");

const console_msg = @import("ConsoleMsg.zig");
const history_mod = @import("CookedReadHistory.zig");
const input_types = @import("InputTypes.zig");
const render = @import("CookedReadRender.zig");
const session_state = @import("SessionState.zig");
const terminal_mod = @import("Terminal.zig");
const utf = @import("utf.zig");

const InputMode = session_state.InputMode;
const KeyEvent = input_types.KeyEvent;
const Terminal = terminal_mod;

pub const History = history_mod.History;

pub const PendingRead = struct {
    identifier: windows.LUID,
    write_offset: windows.ULONG,
    capacity: windows.ULONG,
    reply: console_msg.L1.CONSOLE_READCONSOLE_MSG,
};

pub const Active = struct {
    pending: PendingRead,
    history: ?*History,
    history_nav: HistoryNavigation,
    line: std.ArrayList(u8),
    cursor_byte: usize,
    popup: render.PopupState,
    popup_cursor_hidden: bool,
    origin: ?render.Origin,
    rows_drawn_prev: u16,

    pub fn init(
        allocator: std.mem.Allocator,
        pending: PendingRead,
        history: ?*History,
        initial_text: []const u8,
    ) !Active {
        var line: std.ArrayList(u8) = .empty;
        errdefer line.deinit(allocator);
        try line.appendSlice(allocator, initial_text);

        return .{
            .pending = pending,
            .history = history,
            .history_nav = .{},
            .line = line,
            .cursor_byte = initial_text.len,
            .popup = .none,
            .popup_cursor_hidden = false,
            .origin = null,
            .rows_drawn_prev = 1,
        };
    }

    pub fn deinit(self: *Active, allocator: std.mem.Allocator) void {
        self.line.deinit(allocator);
        self.history_nav.deinit(allocator);
        self.* = undefined;
    }
};

pub const Outcome = union(enum) {
    pending,
    complete: Completion,
};

pub const Completion = struct {
    kind: CompletionKind,
    status: windows.NTSTATUS,
    control_key_state: windows.ULONG,
    payload: []u8,
};

pub const CompletionKind = enum {
    enter,
    wakeup,
    eof,
    cancel,
};

const CursorTarget = union(enum) {
    end,
    byte_offset: usize,
};

const NavigationResult = union(enum) {
    none,
    redraw,
    complete: CompletionKind,
};

const PopupCharMode = enum {
    copy_to_char,
    copy_from_char,
};

const HistoryDirection = enum {
    up,
    down,
};

const command_list_page_size = 10;

const HistoryNavigation = struct {
    browsing_index: ?usize = null,
    pending_line: std.ArrayList(u8) = .empty,
    has_pending_line: bool = false,
    f8_match_index: ?usize = null,

    fn deinit(self: *HistoryNavigation, allocator: std.mem.Allocator) void {
        self.pending_line.deinit(allocator);
        self.* = undefined;
    }
};

pub fn initActive(
    allocator: std.mem.Allocator,
    pending: PendingRead,
    history: ?*History,
    initial_text: []const u8,
) !Active {
    return Active.init(allocator, pending, history, initial_text);
}

pub fn handleKey(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    input_mode: InputMode,
    active: *Active,
    event: KeyEvent,
) !Outcome {
    if (event.action == .release) return .pending;

    const control_key_state = input_types.effectiveControlKeyState(event, false);

    if (input_mode.enable_processed_input and input_types.isCtrlC(event, control_key_state)) {
        return .{
            .complete = .{
                .kind = .cancel,
                .status = .ALERTED,
                .control_key_state = 0,
                .payload = try allocator.alloc(u8, 0),
            },
        };
    }

    switch (try handleNavigationKey(allocator, active, event, control_key_state)) {
        .none => {},
        .redraw => {
            try render.redraw(allocator, terminal, input_mode, active);
            return .pending;
        },
        .complete => |kind| {
            return .{ .complete = try buildCompletion(
                allocator,
                terminal,
                input_mode,
                active,
                kind,
                0,
            ) };
        },
    }

    const char = deriveInputChar(event, control_key_state);
    if (char == 0) return .pending;

    if (shouldWake(active.pending.reply.CtrlWakeupMask, char)) {
        try insertCodeUnit(allocator, active, char, input_mode.enable_insert_mode);
        return .{ .complete = try buildCompletion(
            allocator,
            terminal,
            input_mode,
            active,
            .wakeup,
            control_key_state,
        ) };
    }

    if (char == '\r') {
        return .{ .complete = try buildCompletion(
            allocator,
            terminal,
            input_mode,
            active,
            .enter,
            0,
        ) };
    }

    if (input_mode.enable_processed_input and char == 0x1A and active.pending.reply.ProcessControlZ != .FALSE) {
        return .{ .complete = try buildCompletion(allocator, terminal, input_mode, active, .eof, 0) };
    }

    if (input_mode.enable_processed_input and char == 0x08) {
        if (previousGrapheme(active.line.items, active.cursor_byte)) |grapheme| {
            try applyLineMutation(
                allocator,
                active,
                grapheme.start,
                grapheme.end - grapheme.start,
                "",
                .{ .byte_offset = grapheme.start },
                true,
            );
            try render.redraw(allocator, terminal, input_mode, active);
        }
        return .pending;
    }

    return handleCodeUnit(
        allocator,
        terminal,
        input_mode,
        active,
        char,
        control_key_state,
    );
}

pub fn handleText(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    input_mode: InputMode,
    active: *Active,
    text: []const u8,
) !Outcome {
    if (text.len == 0) return .pending;

    var mutated = false;
    var index: usize = 0;
    while (index < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[index]) catch break;
        if (index + len > text.len) break;

        const chunk = text[index .. index + len];
        var iterator = uucode.utf8.Iterator.init(chunk);
        const codepoint = iterator.next() orelse {
            index += len;
            continue;
        };

        if (codepoint <= std.math.maxInt(u16)) {
            if (completionKind(input_mode, active, @intCast(codepoint))) |kind| {
                if (kind != .eof) {
                    try insertText(allocator, active, chunk, input_mode.enable_insert_mode);
                }
                return .{ .complete = try buildCompletion(
                    allocator,
                    terminal,
                    input_mode,
                    active,
                    kind,
                    0,
                ) };
            }
        }

        try insertText(allocator, active, chunk, input_mode.enable_insert_mode);
        mutated = true;
        index += len;
    }

    if (mutated) {
        try render.redraw(allocator, terminal, input_mode, active);
    }

    return .pending;
}

fn applyLineMutation(
    allocator: std.mem.Allocator,
    active: *Active,
    index: usize,
    remove_len: usize,
    replacement: []const u8,
    cursor: CursorTarget,
    reset_history_nav: bool,
) !void {
    try active.line.replaceRange(allocator, index, remove_len, replacement);

    switch (cursor) {
        .end => active.cursor_byte = active.line.items.len,
        .byte_offset => |offset| {
            active.cursor_byte = clampCursorByte(active.line.items, offset);
        },
    }

    if (reset_history_nav) {
        clearHistoryNavigation(active);
    }
}

fn handleCodeUnit(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    input_mode: InputMode,
    active: *Active,
    code_unit: u16,
    control_key_state: windows.ULONG,
) !Outcome {
    if (completionKind(input_mode, active, code_unit)) |kind| {
        if (kind != .eof) {
            try insertCodeUnit(allocator, active, code_unit, input_mode.enable_insert_mode);
        }
        return .{ .complete = try buildCompletion(
            allocator,
            terminal,
            input_mode,
            active,
            kind,
            control_key_state,
        ) };
    }

    try insertCodeUnit(allocator, active, code_unit, input_mode.enable_insert_mode);
    try render.redraw(allocator, terminal, input_mode, active);
    return .pending;
}

fn buildCompletion(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    input_mode: InputMode,
    active: *Active,
    kind: CompletionKind,
    control_key_state: windows.ULONG,
) !Completion {
    if (active.popup_cursor_hidden) {
        terminal.feed("\x1b[?25h");
        active.popup_cursor_hidden = false;
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);

    if (kind != .eof) {
        try text.appendSlice(allocator, active.line.items);
    }

    if (completionSuffix(input_mode, kind)) |suffix| {
        try text.appendSlice(allocator, suffix);

        if (input_mode.enable_echo_input) {
            terminal.feed(suffix);
        }
    }

    const payload = if (active.pending.reply.Unicode != .FALSE)
        try utf.utf8ToUtf16BytesAlloc(allocator, text.items)
    else
        try allocator.dupe(u8, text.items);

    return .{
        .kind = kind,
        .status = .SUCCESS,
        .control_key_state = control_key_state,
        .payload = payload,
    };
}

fn completionKind(input_mode: InputMode, active: *const Active, code_unit: u16) ?CompletionKind {
    if (shouldWake(active.pending.reply.CtrlWakeupMask, @intCast(code_unit))) {
        return .wakeup;
    }

    if (code_unit == '\r' or code_unit == '\n') {
        return .enter;
    }

    if (input_mode.enable_processed_input and code_unit == 0x1A and active.pending.reply.ProcessControlZ != .FALSE) {
        return .eof;
    }

    return null;
}

fn completionSuffix(input_mode: InputMode, kind: CompletionKind) ?[]const u8 {
    return switch (kind) {
        .enter => if (input_mode.enable_processed_input) "\r\n" else "\r",
        .wakeup, .eof, .cancel => null,
    };
}

fn handleNavigationKey(
    allocator: std.mem.Allocator,
    active: *Active,
    event: KeyEvent,
    control_key_state: windows.DWORD,
) !NavigationResult {
    if (active.popup != .none) {
        return handlePopupKey(allocator, active, event, control_key_state);
    }

    const ctrl_pressed = (control_key_state &
        (windows.LEFT_CTRL_PRESSED | windows.RIGHT_CTRL_PRESSED)) != 0;
    const alt_pressed = (control_key_state &
        (windows.LEFT_ALT_PRESSED | windows.RIGHT_ALT_PRESSED)) != 0;
    const shift_pressed = (control_key_state & windows.SHIFT_PRESSED) != 0;

    if (event.code != .f8) {
        active.history_nav.f8_match_index = null;
    }

    switch (event.code) {
        .backspace => {
            if (input_types.shouldUseCtrlBackspaceWordErase(control_key_state)) {
                if (try erasePreviousWord(allocator, active)) {
                    return .redraw;
                }
                return .none;
            }
        },
        .arrow_left => {
            if (previousGrapheme(active.line.items, active.cursor_byte)) |grapheme| {
                active.cursor_byte = grapheme.start;
                return .redraw;
            }
        },
        .arrow_right => {
            if (nextGrapheme(active.line.items, active.cursor_byte)) |grapheme| {
                active.cursor_byte = grapheme.end;
                return .redraw;
            }
        },
        .home => {
            if (active.cursor_byte != 0) {
                active.cursor_byte = 0;
                return .redraw;
            }
        },
        .end => {
            if (active.cursor_byte != active.line.items.len) {
                active.cursor_byte = active.line.items.len;
                return .redraw;
            }
        },
        .delete => {
            if (nextGrapheme(active.line.items, active.cursor_byte)) |grapheme| {
                try applyLineMutation(
                    allocator,
                    active,
                    grapheme.start,
                    grapheme.end - grapheme.start,
                    "",
                    .{ .byte_offset = grapheme.start },
                    true,
                );
                return .redraw;
            }
        },
        .arrow_up => {
            if (try historyNavigate(allocator, active, .up)) {
                return .redraw;
            }
        },
        .arrow_down => {
            if (try historyNavigate(allocator, active, .down)) {
                return .redraw;
            }
        },
        .f3 => {
            if (try historyCopyFromReference(allocator, active)) {
                return .redraw;
            }
        },
        .f2 => {
            if (!ctrl_pressed and !alt_pressed) {
                active.popup = .copy_to_char;
                return .redraw;
            }
        },
        .f4 => {
            if (!ctrl_pressed and !alt_pressed) {
                active.popup = .copy_from_char;
                return .redraw;
            }
        },
        .f7 => {
            if (alt_pressed and !ctrl_pressed and !shift_pressed) {
                if (active.history) |history| {
                    history.clear(allocator);
                    clearHistoryNavigation(active);
                    return .redraw;
                }
            }

            if (!ctrl_pressed and !alt_pressed and !shift_pressed) {
                if (beginCommandListPopup(active)) {
                    return .redraw;
                }
            }
        },
        .f8 => {
            if (!ctrl_pressed and !alt_pressed and !shift_pressed) {
                if (try historyCopyByPrefixF8(allocator, active)) {
                    return .redraw;
                }
            }
        },
        .f9 => {
            if (!ctrl_pressed and !alt_pressed and !shift_pressed) {
                if (beginCommandNumberPopup(active)) {
                    return .redraw;
                }
            }
        },
        else => {},
    }

    return .none;
}

fn erasePreviousWord(allocator: std.mem.Allocator, active: *Active) !bool {
    if (active.cursor_byte == 0) return false;

    const cursor_byte = active.cursor_byte;
    var start_byte = cursor_byte;

    while (previousGrapheme(active.line.items, start_byte)) |grapheme| {
        if (!graphemeIsWhitespace(active.line.items[grapheme.start..grapheme.end])) break;
        start_byte = grapheme.start;
    }
    while (previousGrapheme(active.line.items, start_byte)) |grapheme| {
        if (graphemeIsWhitespace(active.line.items[grapheme.start..grapheme.end])) break;
        start_byte = grapheme.start;
    }

    if (start_byte == cursor_byte) return false;

    try applyLineMutation(
        allocator,
        active,
        start_byte,
        cursor_byte - start_byte,
        "",
        .{ .byte_offset = start_byte },
        true,
    );
    return true;
}

fn graphemeIsWhitespace(text: []const u8) bool {
    var it = uucode.utf8.Iterator.init(text);
    const codepoint = it.next() orelse return false;
    if (it.next() != null) return false;
    if (codepoint > 0x7F) return false;
    return std.ascii.isWhitespace(@intCast(codepoint));
}

fn handlePopupKey(
    allocator: std.mem.Allocator,
    active: *Active,
    event: KeyEvent,
    control_key_state: windows.DWORD,
) !NavigationResult {
    const shift_pressed = (control_key_state & windows.SHIFT_PRESSED) != 0;

    return switch (active.popup) {
        .copy_to_char => handleCharPopupInput(allocator, active, event, .copy_to_char),
        .copy_from_char => handleCharPopupInput(allocator, active, event, .copy_from_char),
        .command_number => handleCommandNumberPopupInput(allocator, active, event),
        .command_list => handleCommandListPopupInput(allocator, active, event, shift_pressed),
        .none => .none,
    };
}

fn handleCharPopupInput(
    allocator: std.mem.Allocator,
    active: *Active,
    event: KeyEvent,
    mode: PopupCharMode,
) !NavigationResult {
    if (event.code == .escape) {
        closeAllPopups(active);
        return .redraw;
    }

    const input_char = popupInputChar(event);
    if (input_char == 0) return .none;

    const command = popupReferenceCommand(active) orelse {
        closeAllPopups(active);
        return .redraw;
    };
    const cursor_byte = cursorByteOffset(active);
    switch (mode) {
        .copy_to_char => {
            if (cursor_byte < command.len) {
                if (std.mem.indexOfScalarPos(u8, command, cursor_byte, input_char)) |index| {
                    const copy_len = index - cursor_byte;
                    const remove_len = @min(copy_len, active.line.items.len - cursor_byte);
                    try applyLineMutation(
                        allocator,
                        active,
                        cursor_byte,
                        remove_len,
                        command[cursor_byte..index],
                        .{ .byte_offset = cursor_byte + copy_len },
                        true,
                    );
                }
            }
        },
        .copy_from_char => {
            const index = std.mem.indexOfScalarPos(u8, active.line.items, cursor_byte, input_char) orelse active.line.items.len;
            try applyLineMutation(
                allocator,
                active,
                cursor_byte,
                index - cursor_byte,
                "",
                .{ .byte_offset = cursor_byte },
                true,
            );
        },
    }

    closeAllPopups(active);
    return .redraw;
}

fn handleCommandNumberPopupInput(
    allocator: std.mem.Allocator,
    active: *Active,
    event: KeyEvent,
) !NavigationResult {
    const popup = currentCommandNumberPopupMut(active) orelse return .none;

    if (event.code == .escape) {
        dismissCommandNumberPopup(active);
        return .redraw;
    }

    if (event.code == .backspace) {
        if (popup.len == 0) return .none;
        popup.len -= 1;
        popup.input[popup.len] = 0;
        return .redraw;
    }

    if (event.code == .enter) {
        _ = try applyCommandNumberSelection(allocator, active);
        dismissCommandNumberPopup(active);
        return .redraw;
    }

    const input_char = popupInputChar(event);
    if (input_char < '0' or input_char > '9') return .none;
    if (popup.len >= render.CommandNumberMaxInputLength) return .none;

    popup.input[popup.len] = input_char;
    popup.len += 1;
    return .redraw;
}

fn currentCommandNumberPopupMut(active: *Active) ?*render.CommandNumberPopup {
    return switch (active.popup) {
        .command_number => |*top| top,
        .command_list => |*list| {
            if (list.number_overlay) |*overlay| {
                return overlay;
            }
            return null;
        },
        else => null,
    };
}

fn currentCommandNumberPopup(active: *const Active) ?render.CommandNumberPopup {
    return switch (active.popup) {
        .command_number => |top| top,
        .command_list => |list| list.number_overlay,
        else => null,
    };
}

fn dismissCommandNumberPopup(active: *Active) void {
    switch (active.popup) {
        .command_number => active.popup = .none,
        .command_list => |*popup| popup.number_overlay = null,
        else => {},
    }
}

fn handleCommandListPopupInput(
    allocator: std.mem.Allocator,
    active: *Active,
    event: KeyEvent,
    shift_pressed: bool,
) !NavigationResult {
    const history = active.history orelse {
        closeAllPopups(active);
        return .redraw;
    };
    if (history.commands.items.len == 0) {
        closeAllPopups(active);
        return .redraw;
    }

    const popup = switch (active.popup) {
        .command_list => |*list| list,
        else => return .none,
    };

    if (popup.number_overlay != null) {
        return handleCommandNumberPopupInput(allocator, active, event);
    }

    switch (event.code) {
        .escape => {
            closeAllPopups(active);
            return .redraw;
        },
        .f9 => {
            if (popup.number_overlay == null) {
                popup.number_overlay = .{};
                return .redraw;
            }
            return .none;
        },
        .delete => return deleteCommandListSelection(allocator, active, history, popup),
        .arrow_left, .arrow_right => {
            try replaceLineFromCommandListSelection(allocator, active);
            closeAllPopups(active);
            return .redraw;
        },
        .enter => {
            try replaceLineFromCommandListSelection(allocator, active);
            closeAllPopups(active);
            return .{ .complete = .enter };
        },
        .arrow_up => return moveCommandListSelection(history, popup, -1, shift_pressed),
        .arrow_down => return moveCommandListSelection(history, popup, 1, shift_pressed),
        .home => {
            popup.selected = 0;
            return .redraw;
        },
        .end => {
            popup.selected = history.commands.items.len - 1;
            return .redraw;
        },
        .page_up => {
            popup.selected -|= command_list_page_size;
            return .redraw;
        },
        .page_down => {
            popup.selected += command_list_page_size;
            return .redraw;
        },
        else => return .none,
    }
}

fn beginCommandListPopup(active: *Active) bool {
    const history = active.history orelse return false;
    if (history.commands.items.len == 0) return false;

    active.popup = .{ .command_list = .{
        .selected = history.commands.items.len - 1,
        .number_overlay = null,
    } };
    return true;
}

fn beginCommandNumberPopup(active: *Active) bool {
    const history = active.history orelse return false;
    if (history.commands.items.len == 0) return false;

    switch (active.popup) {
        .command_list => |*popup| popup.number_overlay = .{},
        else => active.popup = .{ .command_number = .{} },
    }
    return true;
}

fn closeAllPopups(active: *Active) void {
    active.popup = .none;
}

fn popupInputChar(event: KeyEvent) u8 {
    const input_char = deriveInputChar(event, input_types.effectiveControlKeyState(event, false));
    return switch (input_char) {
        0, '\r', '\n', 0x08 => 0,
        else => input_char,
    };
}

fn popupReferenceCommand(active: *const Active) ?[]const u8 {
    const history = active.history orelse return null;
    if (history.commands.items.len == 0) return null;
    return history.commands.items[history.commands.items.len - 1];
}

fn selectedCommandListIndex(popup: *render.CommandListPopup, history_len: usize) usize {
    if (popup.selected >= history_len) {
        popup.selected = history_len - 1;
    }
    return popup.selected;
}

fn deleteCommandListSelection(
    allocator: std.mem.Allocator,
    active: *Active,
    history: *History,
    popup: *render.CommandListPopup,
) NavigationResult {
    const selected = selectedCommandListIndex(popup, history.commands.items.len);
    if (!history.remove(allocator, selected)) return .none;

    if (history.commands.items.len == 0) {
        closeAllPopups(active);
        clearHistoryNavigation(active);
        return .redraw;
    }

    if (popup.selected >= history.commands.items.len) {
        popup.selected = history.commands.items.len - 1;
    }
    return .redraw;
}

fn moveCommandListSelection(
    history: *History,
    popup: *render.CommandListPopup,
    delta: i32,
    reorder: bool,
) NavigationResult {
    if (reorder) {
        const selected = selectedCommandListIndex(popup, history.commands.items.len);
        if (delta < 0) {
            if (selected > 0 and history.swap(selected, selected - 1)) {
                popup.selected -= 1;
                return .redraw;
            }
        } else {
            if (selected + 1 < history.commands.items.len and history.swap(selected, selected + 1)) {
                popup.selected += 1;
                return .redraw;
            }
        }
    }

    if (delta < 0) {
        popup.selected -|= @intCast(-delta);
    } else {
        popup.selected += @intCast(delta);
    }
    return .redraw;
}

fn replaceLineFromCommandListSelection(allocator: std.mem.Allocator, active: *Active) !void {
    const history = active.history orelse return;
    const len = history.commands.items.len;
    if (len == 0) return;

    const popup = switch (active.popup) {
        .command_list => |*list| list,
        else => return,
    };

    const selected = selectedCommandListIndex(popup, len);
    const command = history.commands.items[selected];
    try replaceLine(allocator, active, command);
    clearHistoryNavigation(active);
}

fn applyCommandNumberSelection(allocator: std.mem.Allocator, active: *Active) !bool {
    const history = active.history orelse return false;
    if (history.commands.items.len == 0) return false;
    const popup = currentCommandNumberPopup(active) orelse return false;
    if (popup.len == 0) return false;

    const value = std.fmt.parseInt(usize, popup.input[0..popup.len], 10) catch return false;
    if (value >= history.commands.items.len) return false;
    try replaceLine(allocator, active, history.commands.items[value]);
    clearHistoryNavigation(active);
    return true;
}

fn clearHistoryNavigation(active: *Active) void {
    active.history_nav.browsing_index = null;
    active.history_nav.has_pending_line = false;
    active.history_nav.pending_line.items.len = 0;
    active.history_nav.f8_match_index = null;
}

fn historyNavigate(
    allocator: std.mem.Allocator,
    active: *Active,
    direction: HistoryDirection,
) !bool {
    const history = active.history orelse return false;
    if (history.commands.items.len == 0) return false;

    const nav = &active.history_nav;
    nav.f8_match_index = null;
    switch (direction) {
        .up => {
            if (!nav.has_pending_line) {
                nav.pending_line.items.len = 0;
                try nav.pending_line.appendSlice(allocator, active.line.items);
                nav.has_pending_line = true;
            }

            if (nav.browsing_index) |index| {
                if (index == 0) return false;
                nav.browsing_index = index - 1;
            } else {
                nav.browsing_index = history.commands.items.len - 1;
            }

            try replaceLine(allocator, active, history.commands.items[nav.browsing_index.?]);
            return true;
        },
        .down => {
            const index = nav.browsing_index orelse return false;
            if (index + 1 < history.commands.items.len) {
                nav.browsing_index = index + 1;
                try replaceLine(allocator, active, history.commands.items[nav.browsing_index.?]);
                return true;
            }

            nav.browsing_index = null;
            if (nav.has_pending_line) {
                try replaceLine(allocator, active, nav.pending_line.items);
                nav.has_pending_line = false;
                nav.pending_line.items.len = 0;
            } else {
                try replaceLine(allocator, active, "");
            }
            return true;
        },
    }
}

fn historyCopyFromReference(allocator: std.mem.Allocator, active: *Active) !bool {
    const command = historyCommandForF3(active) orelse return false;
    const cursor_byte = cursorByteOffset(active);
    if (cursor_byte >= command.len) return false;

    const replace_len = active.line.items.len - cursor_byte;
    const suffix = command[cursor_byte..];
    try applyLineMutation(
        allocator,
        active,
        cursor_byte,
        replace_len,
        suffix,
        .end,
        false,
    );
    return true;
}

fn historyCopyByPrefixF8(allocator: std.mem.Allocator, active: *Active) !bool {
    const history = active.history orelse return false;
    if (history.commands.items.len == 0) return false;

    const cursor_byte = cursorByteOffset(active);
    const prefix = active.line.items[0..@min(cursor_byte, active.line.items.len)];
    const start_exclusive = active.history_nav.f8_match_index orelse history.commands.items.len;

    const index = findMatchingHistoryIndex(history.commands.items, prefix, start_exclusive) orelse return false;
    active.history_nav.f8_match_index = index;
    try replaceLineAtByteOffset(allocator, active, history.commands.items[index], cursor_byte);
    return true;
}

fn findMatchingHistoryIndex(
    commands: []const []u8,
    prefix: []const u8,
    start_exclusive: usize,
) ?usize {
    if (commands.len == 0) return null;

    var scanned: usize = 0;
    var index = @min(start_exclusive, commands.len);
    while (scanned < commands.len) : (scanned += 1) {
        if (index == 0) index = commands.len;
        index -= 1;

        if (std.mem.startsWith(u8, commands[index], prefix)) {
            return index;
        }
    }

    return null;
}

fn historyCommandForF3(active: *const Active) ?[]const u8 {
    const history = active.history orelse return null;
    if (history.commands.items.len == 0) return null;

    if (active.history_nav.browsing_index) |index| {
        return history.commands.items[index];
    }

    return history.commands.items[history.commands.items.len - 1];
}

fn replaceLine(allocator: std.mem.Allocator, active: *Active, text: []const u8) !void {
    try applyLineMutation(
        allocator,
        active,
        0,
        active.line.items.len,
        text,
        .end,
        false,
    );
}

fn replaceLineAtByteOffset(
    allocator: std.mem.Allocator,
    active: *Active,
    text: []const u8,
    byte_offset: usize,
) !void {
    try applyLineMutation(
        allocator,
        active,
        0,
        active.line.items.len,
        text,
        .{ .byte_offset = byte_offset },
        false,
    );
}

fn insertCodeUnit(
    allocator: std.mem.Allocator,
    active: *Active,
    code_unit: u16,
    insert_mode: bool,
) !void {
    var buf: [4]u8 = undefined;
    const utf8_len = try std.unicode.utf8Encode(@intCast(code_unit), &buf);
    try insertText(allocator, active, buf[0..utf8_len], insert_mode);
}

fn insertText(
    allocator: std.mem.Allocator,
    active: *Active,
    text: []const u8,
    insert_mode: bool,
) !void {
    const cursor_byte = cursorByteOffset(active);
    const cursor_byte_after_insert = cursor_byte + text.len;

    var remove: usize = 0;
    if (!insert_mode) {
        if (nextGrapheme(active.line.items, cursor_byte)) |grapheme| {
            remove = grapheme.end - grapheme.start;
        }
    }

    try applyLineMutation(
        allocator,
        active,
        cursor_byte,
        remove,
        text,
        .{ .byte_offset = cursor_byte_after_insert },
        true,
    );
}

fn shouldWake(mask: windows.ULONG, char: u8) bool {
    if (mask == 0) return false;
    if (char >= 32) return false;
    return (mask & (@as(windows.ULONG, 1) << @intCast(char))) != 0;
}

fn deriveInputChar(event: KeyEvent, control_key_state: windows.DWORD) u8 {
    if (event.text_len > 0) {
        if (event.text[0] <= 0x7F) {
            return event.text[0];
        }

        var it = uucode.utf8.Iterator.init(event.text[0..event.text_len]);
        const codepoint = it.next() orelse return 0;
        if (codepoint <= 0xFF) return @intCast(codepoint);
        return 0;
    }

    return switch (event.code) {
        .enter => '\r',
        .backspace => if (input_types.shouldUseCtrlBackspaceWordErase(control_key_state)) 0 else 0x08,
        .tab => '\t',
        else => 0,
    };
}

fn cursorByteOffset(active: *const Active) usize {
    return active.cursor_byte;
}

fn clampCursorByte(text: []const u8, byte_offset: usize) usize {
    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(text);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        if (byte_offset <= grapheme.start) return grapheme.start;
        if (byte_offset < grapheme.end) return grapheme.end;
    }

    return text.len;
}

fn previousGrapheme(text: []const u8, cursor_byte: usize) ?uucode.grapheme.Grapheme {
    var previous: ?uucode.grapheme.Grapheme = null;
    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(text);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        if (grapheme.end == cursor_byte) return grapheme;
        if (grapheme.end > cursor_byte) return previous;
        previous = grapheme;
    }
    return previous;
}

fn nextGrapheme(text: []const u8, cursor_byte: usize) ?uucode.grapheme.Grapheme {
    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(text);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        if (grapheme.start >= cursor_byte) return grapheme;
        if (cursor_byte < grapheme.end) return grapheme;
    }
    return null;
}

test "wakeup mask matches tab" {
    try std.testing.expect(shouldWake(@as(windows.ULONG, 1) << 9, '\t'));
}

const TestTerminal = struct {
    feed_calls: usize = 0,

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

    fn feed(ptr: *anyopaque, _: []const u8) void {
        const self: *TestTerminal = @ptrCast(@alignCast(ptr));
        self.feed_calls += 1;
    }

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

test "handleText keeps supplementary-plane codepoints" {
    var terminal_state: TestTerminal = .{};
    const pending: PendingRead = .{
        .identifier = std.mem.zeroes(windows.LUID),
        .write_offset = 0,
        .capacity = 256,
        .reply = std.mem.zeroes(console_msg.L1.CONSOLE_READCONSOLE_MSG),
    };

    var active = try Active.init(std.testing.allocator, pending, null, "");
    defer active.deinit(std.testing.allocator);

    const outcome = try handleText(
        std.testing.allocator,
        terminal_state.terminal(),
        .{},
        &active,
        "🙂",
    );

    try std.testing.expect(outcome == .pending);
    try std.testing.expectEqualStrings("🙂", active.line.items);
    try std.testing.expectEqual(@as(usize, "🙂".len), active.cursor_byte);
    try std.testing.expectEqual(@as(usize, 1), terminal_state.feed_calls);
}

test "F3 copies suffix from most recent history command" {
    var history: History = .{};
    defer history.deinit(std.testing.allocator);

    try history.append(std.testing.allocator, .{
        .history_buffer_size = 10,
        .number_of_history_buffers = 4,
        .history_no_dup = false,
    }, "echo hello");

    const pending: PendingRead = .{
        .identifier = std.mem.zeroes(windows.LUID),
        .write_offset = 0,
        .capacity = 256,
        .reply = std.mem.zeroes(console_msg.L1.CONSOLE_READCONSOLE_MSG),
    };

    var active = try Active.init(std.testing.allocator, pending, &history, "echo h");
    defer active.deinit(std.testing.allocator);
    active.cursor_byte = active.line.items.len;

    try std.testing.expect(try historyCopyFromReference(std.testing.allocator, &active));
    try std.testing.expectEqualStrings("echo hello", active.line.items);
}
