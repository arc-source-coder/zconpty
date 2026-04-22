const std = @import("std");
const uucode = @import("uucode");

const session_state = @import("SessionState.zig");
const terminal_mod = @import("Terminal.zig");

const InputMode = session_state.InputMode;
const Terminal = terminal_mod;

pub const Origin = struct {
    col: u16,
    row: u16,
};

pub const CommandNumberMaxInputLength: usize = 5;

pub const CommandNumberPopup = struct {
    input: [CommandNumberMaxInputLength]u8 = std.mem.zeroes([CommandNumberMaxInputLength]u8),
    len: u8 = 0,
};

pub const CommandListPopup = struct {
    selected: usize = 0,
    number_overlay: ?CommandNumberPopup = null,
};

pub const PopupState = union(enum) {
    none,
    copy_to_char,
    copy_from_char,
    command_number: CommandNumberPopup,
    command_list: CommandListPopup,
};

const Layout = struct {
    rows_used: u16,
    cursor_col: u16,
    cursor_row: u16,
};

const prompt_copy_to_char = "Enter char to copy up to: ";
const prompt_copy_from_char = "Enter char to delete up to: ";
const prompt_command_number = "Enter command number: ";

pub fn redraw(
    allocator: std.mem.Allocator,
    terminal: Terminal,
    input_mode: InputMode,
    active: anytype,
) !void {
    if (!input_mode.enable_echo_input) return;

    if (active.origin == null) {
        var col: u16 = undefined;
        var row: u16 = undefined;
        terminal.getCursorPosition(&col, &row);
        active.origin = .{ .col = col, .row = row };
    }

    var cols: u16 = undefined;
    var rows: u16 = undefined;
    terminal.getSize(&cols, &rows);

    const origin = active.origin.?;
    const layout = layoutLine(cols, origin.col, active.line.items, active.cursor_byte);
    const popup_rows = popupRowsUsed(rows, active);
    const total_rows = layout.rows_used + popup_rows;

    var vt: std.ArrayList(u8) = .empty;
    defer vt.deinit(allocator);

    var draw_origin = origin;
    if (rows > 0) {
        const row_after_content = @as(u32, draw_origin.row) + @as(u32, total_rows);
        if (row_after_content > rows) {
            const scroll_rows: u16 = @intCast(@min(row_after_content - rows, @as(u32, draw_origin.row)));

            if (scroll_rows > 0) {
                try appendScrollUp(allocator, &vt, scroll_rows);
                draw_origin.row -= scroll_rows;
                active.origin = draw_origin;
            }
        }
    }

    const rows_clear_max = if (rows > draw_origin.row) rows - draw_origin.row else 1;
    const rows_clear = @min(@max(active.rows_drawn_prev, total_rows), rows_clear_max);

    const has_popup = active.popup != .none;
    if (has_popup and !active.popup_cursor_hidden) {
        try vt.appendSlice(allocator, "\x1b[?25l");
        active.popup_cursor_hidden = true;
    } else if (!has_popup and active.popup_cursor_hidden) {
        try vt.appendSlice(allocator, "\x1b[?25h");
        active.popup_cursor_hidden = false;
    }

    try clearRows(allocator, &vt, draw_origin, rows_clear);
    try appendCup(allocator, &vt, draw_origin.row, draw_origin.col);
    try vt.appendSlice(allocator, active.line.items);

    var cursor_row = draw_origin.row + layout.cursor_row;
    var cursor_col = layout.cursor_col;
    if (popup_rows > 0) {
        const popup_origin_row = draw_origin.row + layout.rows_used;
        try drawPopup(
            allocator,
            &vt,
            cols,
            rows,
            popup_origin_row,
            active,
            &cursor_row,
            &cursor_col,
        );
    }

    try appendCup(allocator, &vt, cursor_row, cursor_col);

    terminal.feed(vt.items);
    active.rows_drawn_prev = @min(total_rows, rows_clear_max);
}

fn clearRows(
    allocator: std.mem.Allocator,
    vt: *std.ArrayList(u8),
    origin: Origin,
    rows_clear: u16,
) !void {
    var row_index: u16 = 0;
    while (row_index < rows_clear) : (row_index += 1) {
        const col: u16 = if (row_index == 0) origin.col else 0;
        try appendCup(allocator, vt, origin.row + row_index, col);
        if (row_index == 0) {
            try vt.appendSlice(allocator, "\x1b[K");
        } else {
            try vt.appendSlice(allocator, "\x1b[2K");
        }
    }
}

fn appendCup(allocator: std.mem.Allocator, vt: *std.ArrayList(u8), row: u16, col: u16) !void {
    var buf: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 });
    try vt.appendSlice(allocator, text);
}

fn appendScrollUp(allocator: std.mem.Allocator, vt: *std.ArrayList(u8), rows: u16) !void {
    if (rows == 0) return;

    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "\x1b[{d}S", .{rows});
    try vt.appendSlice(allocator, text);
}

fn popupRowsUsed(rows: u16, active: anytype) u16 {
    return switch (active.popup) {
        .none => 0,
        .copy_to_char, .copy_from_char, .command_number => 1,
        .command_list => |popup| commandListHeight(rows) + @as(u16, if (popup.number_overlay != null) 1 else 0),
    };
}

fn commandListHeight(rows: u16) u16 {
    if (rows <= 2) return 1;

    const half = rows / 2;
    const capped = @min(half - 1, @as(u16, 20));
    return @max(capped, 1);
}

fn drawPopup(
    allocator: std.mem.Allocator,
    vt: *std.ArrayList(u8),
    cols: u16,
    rows: u16,
    popup_origin_row: u16,
    active: anytype,
    cursor_row: *u16,
    cursor_col: *u16,
) !void {
    switch (active.popup) {
        .none => return,
        .copy_to_char => {
            try drawPopupLine(allocator, vt, popup_origin_row, cols, prompt_copy_to_char);
            cursor_row.* = popup_origin_row;
            cursor_col.* = @intCast(@min(displayWidth(prompt_copy_to_char), cols));
        },
        .copy_from_char => {
            try drawPopupLine(allocator, vt, popup_origin_row, cols, prompt_copy_from_char);
            cursor_row.* = popup_origin_row;
            cursor_col.* = @intCast(@min(displayWidth(prompt_copy_from_char), cols));
        },
        .command_number => |popup| {
            try drawCommandNumberPrompt(allocator, vt, popup_origin_row, cols, popup, false);
            cursor_row.* = popup_origin_row;
            cursor_col.* = @intCast(@min(commandNumberPromptWidth(popup, false), cols));
        },
        .command_list => |popup| {
            const consumed = try drawCommandListPopup(allocator, vt, cols, rows, popup_origin_row, active, popup);
            if (popup.number_overlay) |overlay| {
                const overlay_row = popup_origin_row + consumed;
                try drawCommandNumberPrompt(allocator, vt, overlay_row, cols, overlay, true);
                cursor_row.* = overlay_row;
                cursor_col.* = @intCast(@min(commandNumberPromptWidth(overlay, true), cols));
            } else {
                const view = computeCommandListView(rows, active, popup);
                cursor_row.* = popup_origin_row + @as(u16, @intCast(view.selected - view.top));
                cursor_col.* = 0;
            }
        },
    }
}

fn drawPopupLine(
    allocator: std.mem.Allocator,
    vt: *std.ArrayList(u8),
    row: u16,
    cols: u16,
    text: []const u8,
) !void {
    try appendCup(allocator, vt, row, 0);
    try vt.appendSlice(allocator, "\x1b[2K");
    try appendDisplayClipped(allocator, vt, text, cols);
}

fn drawCommandNumberPrompt(
    allocator: std.mem.Allocator,
    vt: *std.ArrayList(u8),
    row: u16,
    cols: u16,
    popup: CommandNumberPopup,
    stacked: bool,
) !void {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(allocator);

    if (stacked) {
        try line.appendSlice(allocator, "↳ ");
    }

    try line.appendSlice(allocator, prompt_command_number);
    try line.appendSlice(allocator, popup.input[0..popup.len]);
    try drawPopupLine(allocator, vt, row, cols, line.items);
}

fn commandNumberPromptWidth(popup: CommandNumberPopup, stacked: bool) usize {
    var width: usize = prompt_command_number.len + popup.len;
    if (stacked) width += displayWidth("↳ ");
    return width;
}

const CommandListView = struct {
    top: usize,
    height: usize,
    selected: usize,
    index_width: usize,
    has_above: bool,
    has_below: bool,
};

fn computeCommandListView(rows: u16, active: anytype, popup: CommandListPopup) CommandListView {
    const history = active.history orelse {
        return .{
            .top = 0,
            .height = 1,
            .selected = 0,
            .index_width = 1,
            .has_above = false,
            .has_below = false,
        };
    };

    const history_len = history.commands.items.len;
    const max_rows = commandListHeight(rows);
    const height: usize = @max(@as(usize, 1), @min(history_len, max_rows));
    const selected = @min(popup.selected, history_len - 1);

    var top = selected;
    if (height > 1) {
        top = top -| height / 2;
        if (top + height > history_len) {
            top = history_len - height;
        }
    }

    return .{
        .top = top,
        .height = height,
        .selected = selected,
        .index_width = decimalDigits(history_len),
        .has_above = top > 0,
        .has_below = top + height < history_len,
    };
}

fn drawCommandListPopup(
    allocator: std.mem.Allocator,
    vt: *std.ArrayList(u8),
    cols: u16,
    rows: u16,
    row_begin: u16,
    active: anytype,
    popup: CommandListPopup,
) !u16 {
    const history = active.history orelse return 0;
    const history_len = history.commands.items.len;
    if (history_len == 0) return 0;

    const view = computeCommandListView(rows, active, popup);
    var off: usize = 0;
    while (off < view.height) : (off += 1) {
        const index = view.top + off;
        const selected = index == view.selected;
        const marker: []const u8 = if (selected)
            "▶"
        else if (view.has_above and off == 0)
            "▲"
        else if (view.has_below and off + 1 == view.height)
            "▼"
        else
            " ";

        try appendCup(allocator, vt, row_begin + @as(u16, @intCast(off)), 0);
        try vt.appendSlice(allocator, "\x1b[2K");

        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(allocator);
        try line.appendSlice(allocator, marker);
        try line.appendSlice(allocator, " ");
        try appendPaddedNumber(allocator, &line, index, view.index_width);
        try line.appendSlice(allocator, ": ");
        try line.appendSlice(allocator, history.commands.items[index]);
        try appendDisplayClipped(allocator, vt, line.items, cols);
    }

    return @intCast(view.height);
}

fn decimalDigits(value: usize) usize {
    var n = value;
    var digits: usize = 1;
    while (n >= 10) : (digits += 1) {
        n /= 10;
    }
    return digits;
}

fn appendPaddedNumber(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    number: usize,
    width: usize,
) !void {
    var buffer: [32]u8 = undefined;
    const text = try std.fmt.bufPrint(&buffer, "{d}", .{number});
    if (text.len < width) {
        try out.appendNTimes(allocator, ' ', width - text.len);
    }
    try out.appendSlice(allocator, text);
}

fn appendDisplayClipped(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
    max_width: u16,
) !void {
    const prefix_len = displayPrefixLen(text, max_width);
    try out.appendSlice(allocator, text[0..prefix_len]);
}

fn displayPrefixLen(text: []const u8, max_width: u16) usize {
    if (max_width == 0 or text.len == 0) return 0;

    var width_used: u16 = 0;
    var prefix_len: usize = 0;
    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(text);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        var width_it = uucode.grapheme.utf8IteratorNoControl(text[grapheme.start..grapheme.end]);
        const cell_width: u16 = @intCast(uucode.grapheme.wcwidthNext(&width_it));
        if (cell_width > 0 and width_used + cell_width > max_width) break;
        width_used += cell_width;
        prefix_len = grapheme.end;
    }

    return prefix_len;
}

fn displayWidth(text: []const u8) usize {
    var width: usize = 0;
    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(text);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        var width_it = uucode.grapheme.utf8IteratorNoControl(text[grapheme.start..grapheme.end]);
        width += uucode.grapheme.wcwidthNext(&width_it);
    }
    return width;
}

fn layoutLine(width: u16, origin_col: u16, line: []const u8, cursor_byte: usize) Layout {
    if (width == 0) {
        return .{ .rows_used = 1, .cursor_col = 0, .cursor_row = 0 };
    }

    var rows_used: u16 = 1;
    var col = origin_col;
    var row: u16 = 0;
    var cursor_col: u16 = origin_col;
    var cursor_row: u16 = 0;
    var cursor_set = false;

    var grapheme_it = uucode.grapheme.utf8IteratorNoControl(line);
    while (grapheme_it.nextGrapheme()) |grapheme| {
        if (!cursor_set and grapheme.start >= cursor_byte) {
            cursor_col = col;
            cursor_row = row;
            cursor_set = true;
        }

        var width_it = uucode.grapheme.utf8IteratorNoControl(line[grapheme.start..grapheme.end]);
        const cell_width: u16 = @intCast(uucode.grapheme.wcwidthNext(&width_it));

        if (cell_width > 0 and col + cell_width > width) {
            col = 0;
            row += 1;
            rows_used = row + 1;
        }

        col += cell_width;
    }

    if (!cursor_set) {
        if (col >= width) {
            col = 0;
            row += 1;
            rows_used = row + 1;
        }
        cursor_col = col;
        cursor_row = row;
    }

    return .{
        .rows_used = rows_used,
        .cursor_col = cursor_col,
        .cursor_row = cursor_row,
    };
}

test "layout wraps and tracks cursor" {
    const layout = layoutLine(5, 3, "abcd", 4);
    try std.testing.expectEqual(@as(u16, 2), layout.rows_used);
    try std.testing.expectEqual(@as(u16, 2), layout.cursor_col);
    try std.testing.expectEqual(@as(u16, 1), layout.cursor_row);
}

test "layout treats CJK as double width" {
    const layout = layoutLine(4, 0, "ab界d", "ab界".len);
    try std.testing.expectEqual(@as(u16, 2), layout.rows_used);
    try std.testing.expectEqual(@as(u16, 4), layout.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), layout.cursor_row);
}

test "layout keeps combining marks zero width" {
    const layout = layoutLine(8, 0, "e\u{0301}x", "e\u{0301}".len);
    try std.testing.expectEqual(@as(u16, 1), layout.rows_used);
    try std.testing.expectEqual(@as(u16, 1), layout.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), layout.cursor_row);
}

test "layout keeps emoji zwj sequence in one cell span" {
    const text = "A👨🏻‍❤️‍👨🏿B";
    const layout = layoutLine(10, 0, text, "A👨🏻‍❤️‍👨🏿".len);
    try std.testing.expectEqual(@as(u16, 1), layout.rows_used);
    try std.testing.expectEqual(@as(u16, 3), layout.cursor_col);
    try std.testing.expectEqual(@as(u16, 0), layout.cursor_row);
}

test "display prefix len clips on grapheme boundaries" {
    try std.testing.expectEqual(@as(usize, "A".len), displayPrefixLen("A界B", 1));
    try std.testing.expectEqual(@as(usize, "A界".len), displayPrefixLen("A界B", 3));
    try std.testing.expectEqual(@as(usize, 0), displayPrefixLen("界", 1));
}
