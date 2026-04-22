const Self = @This();

const input_types = @import("InputTypes.zig");
const windows = @import("../windows.zig");

pub const RGB = extern struct {
    r: u8,
    g: u8,
    b: u8,

    pub fn toColorRef(self: RGB) windows.COLORREF {
        return @as(windows.COLORREF, self.r) |
            (@as(windows.COLORREF, self.g) << 8) |
            (@as(windows.COLORREF, self.b) << 16);
    }
};

pub const Point = extern struct {
    x: u16,
    y: u16,
};

pub const Rect = extern struct {
    x: u16,
    y: u16,
    width: u16,
    height: u16,
};

pub const Style = packed struct(u16) {
    fg: u4,
    bg: u4,
    underline: bool,
    inverse: bool,
    _reserved: u6 = 0,
};

pub const Width = enum(u8) {
    narrow,
    wide_lead,
    wide_trail,
};

pub const Cell = extern struct {
    codepoint: u32,
    style: Style,
    width: Width,
    _padding: u8 = 0,
};

pub const FillKind = enum(u8) {
    character,
    style,
    cell,
};

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    feed: *const fn (ptr: *anyopaque, bytes: []const u8) void,
    // Encoding APIs
    vt_encode_key: *const fn (ptr: *anyopaque, event: *const input_types.KeyEvent, out: [*]u8, out_len: usize) usize,
    vt_encode_mouse: *const fn (ptr: *anyopaque, event: *const input_types.MouseEvent, out: [*]u8, out_len: usize) usize,
    vt_encode_focus: *const fn (ptr: *anyopaque, focused: bool, out: [*]u8, out_len: usize) usize,
    vt_encode_paste: *const fn (ptr: *anyopaque, out: [*]u8, text: [*]const u8, text_len: usize, out_len: usize) usize,
    // Queries
    get_size: *const fn (ptr: *anyopaque, cols: *u16, rows: *u16) void,
    get_cursor_position: *const fn (ptr: *anyopaque, col: *u16, row: *u16) void,
    get_cursor_visible: *const fn (ptr: *anyopaque, visible: *bool) void,
    get_cell_size: *const fn (ptr: *anyopaque, width_px: *u16, height_px: *u16) void,
    get_title: *const fn (ptr: *anyopaque, out: [*]u8, out_len: usize) usize,
    get_base16_palette: *const fn (ptr: *anyopaque, out: *[16]RGB) void,
    read_rect: *const fn (ptr: *anyopaque, rect: Rect, out: [*]Cell) Rect,
    write_rect: *const fn (ptr: *anyopaque, rect: Rect, cells: [*]const Cell) Rect,
    fill_span: *const fn (ptr: *anyopaque, start: Point, len: u32, kind: FillKind, cell: Cell) u32,
};

pub fn init(ptr: *anyopaque, vtable: *const VTable) Self {
    return .{
        .ptr = ptr,
        .vtable = vtable,
    };
}

pub inline fn feed(self: *const Self, bytes: []const u8) void {
    return self.vtable.feed(self.ptr, bytes);
}

pub inline fn vtEncodeKey(self: *const Self, event: *const input_types.KeyEvent, out: []u8) usize {
    return self.vtable.vt_encode_key(self.ptr, event, out.ptr, out.len);
}

pub inline fn vtEncodeMouse(self: *const Self, event: *const input_types.MouseEvent, out: []u8) usize {
    return self.vtable.vt_encode_mouse(self.ptr, event, out.ptr, out.len);
}

pub inline fn vtEncodeFocus(self: *const Self, focused: bool, out: []u8) usize {
    return self.vtable.vt_encode_focus(self.ptr, focused, out.ptr, out.len);
}

pub inline fn vtEncodePaste(self: *const Self, out: [*]u8, text: [*]const u8, text_len: usize, out_len: usize) usize {
    return self.vtable.vt_encode_paste(self.ptr, out, text, text_len, out_len);
}

pub inline fn getSize(self: *const Self, cols: *u16, rows: *u16) void {
    self.vtable.get_size(self.ptr, cols, rows);
}

pub inline fn getCursorPosition(self: *const Self, col: *u16, row: *u16) void {
    self.vtable.get_cursor_position(self.ptr, col, row);
}

pub inline fn getCursorVisible(self: *const Self, visible: *bool) void {
    self.vtable.get_cursor_visible(self.ptr, visible);
}

pub inline fn getCellSize(self: *const Self, width_px: *u16, height_px: *u16) void {
    self.vtable.get_cell_size(self.ptr, width_px, height_px);
}

pub inline fn getTitle(self: *const Self, out: []u8) usize {
    return self.vtable.get_title(self.ptr, out.ptr, out.len);
}

pub inline fn getBase16Palette(self: *const Self, out: *[16]RGB) void {
    self.vtable.get_base16_palette(self.ptr, out);
}

pub inline fn readRect(self: *const Self, rect: Rect, out: []Cell) Rect {
    return self.vtable.read_rect(self.ptr, rect, out.ptr);
}

pub inline fn writeRect(self: *const Self, rect: Rect, cells: []const Cell) Rect {
    return self.vtable.write_rect(self.ptr, rect, cells.ptr);
}

pub inline fn fillSpan(self: *const Self, start: Point, len: u32, kind: FillKind, cell: Cell) u32 {
    return self.vtable.fill_span(self.ptr, start, len, kind, cell);
}
