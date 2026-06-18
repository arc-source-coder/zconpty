const std = @import("std");
const windows = @import("windows.zig");

const CP_UTF8: windows.UINT = 65001;
const CP_US_ASCII: windows.UINT = 20127;
const MB_USEGLYPHCHARS: windows.DWORD = 0x00000004;

pub const CodePageKind = enum {
    utf8,
    ascii,
    legacy,
};

extern "kernel32" fn MultiByteToWideChar(
    code_page: windows.UINT,
    dwFlags: windows.DWORD,
    lpMultiByteStr: [*]const u8,
    cbMultiByte: c_int,
    lpWideCharStr: ?[*]windows.WCHAR,
    cchWideChar: c_int,
) callconv(.winapi) c_int;

pub inline fn utf8ToUtf16LeStringLiteral(comptime text: []const u8) [*:0]const windows.WCHAR {
    return std.unicode.utf8ToUtf16LeStringLiteral(text);
}

pub inline fn utf8ToUtf16LeAllocZ(allocator: std.mem.Allocator, text: []const u8) ![:0]u16 {
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, text);
}

pub inline fn utf8ToUtf16LeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u16 {
    return std.unicode.utf8ToUtf16LeAlloc(allocator, text);
}

pub inline fn utf16LeToUtf8Alloc(allocator: std.mem.Allocator, text: []const u16) ![]u8 {
    return std.unicode.utf16LeToUtf8Alloc(allocator, text);
}

pub fn utf8ToUtf16BytesAlloc(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    const utf16 = try utf8ToUtf16LeAllocZ(allocator, text);
    defer allocator.free(utf16);

    return allocator.dupe(u8, std.mem.sliceAsBytes(utf16[0..utf16.len]));
}

pub fn encodeCodepointUtf8(codepoint: u21, out: []u8) !u3 {
    return std.unicode.utf8Encode(codepoint, out);
}

pub fn utf16BytesToUtf8Alloc(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if ((bytes.len & 1) != 0) return error.InvalidParameter;

    const code_units = bytes.len / @sizeOf(u16);
    const utf16 = try allocator.alloc(u16, code_units);
    defer allocator.free(utf16);

    for (utf16, 0..) |*code_unit, index| {
        const byte_index = index * 2;
        code_unit.* = std.mem.readInt(u16, bytes[byte_index..][0..2], .little);
    }

    return utf16LeToUtf8Alloc(allocator, utf16) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ExpectedSecondSurrogateHalf,
        error.DanglingSurrogateHalf,
        error.UnexpectedSecondSurrogateHalf,
        => error.InvalidUtf16,
    };
}

pub fn appendUtf8Text(
    allocator: std.mem.Allocator,
    list: *std.ArrayList(windows.INPUT_RECORD),
    text: []const u8,
) !void {
    const view = std.unicode.Utf8View.init(text) catch {
        for (text) |byte| {
            try list.append(allocator, makeUnicodeKeyRecord(byte));
        }
        return;
    };

    var it = view.iterator();
    while (it.nextCodepoint()) |codepoint| {
        try list.append(allocator, makeUnicodeKeyRecord(@truncate(codepoint)));
    }
}

pub fn utf16CodeUnit(text: []const u8) windows.WCHAR {
    const view = std.unicode.Utf8View.init(text) catch return 0;
    var it = view.iterator();
    const codepoint = it.nextCodepoint() orelse return 0;
    if (codepoint > std.math.maxInt(u16)) return 0;
    return @intCast(codepoint);
}

pub fn decodeSingleByteCodePageChar(code_page: windows.UINT, byte: u8) ?windows.WCHAR {
    return switch (classifyCodePage(code_page)) {
        .utf8, .ascii => decodeUtfBackedSingleByteChar(byte),
        .legacy => decodeLegacySingleByteCodePageChar(code_page, byte),
    };
}

pub fn glyphCharFromControlByte(code_page: windows.UINT, byte: u8) ?windows.WCHAR {
    if (classifyCodePage(code_page) != .legacy) return null;

    var utf16: windows.WCHAR = 0;
    const bytes = [_]u8{byte};
    const written = MultiByteToWideChar(code_page, MB_USEGLYPHCHARS, &bytes, 1, @ptrCast(&utf16), 1);
    if (written != 1) return null;
    return utf16;
}

pub fn classifyCodePage(code_page: windows.UINT) CodePageKind {
    return switch (code_page) {
        CP_UTF8 => .utf8,
        CP_US_ASCII => .ascii,
        else => .legacy,
    };
}

fn decodeUtfBackedSingleByteChar(byte: u8) ?windows.WCHAR {
    if (byte > 0x7F) return null;
    return byte;
}

fn decodeLegacySingleByteCodePageChar(code_page: windows.UINT, byte: u8) ?windows.WCHAR {
    var utf16: windows.WCHAR = 0;
    const bytes = [_]u8{byte};
    const written = MultiByteToWideChar(code_page, 0, &bytes, 1, @ptrCast(&utf16), 1);
    if (written != 1) return null;
    return utf16;
}

pub fn makeUnicodeKeyRecord(codepoint: u21) windows.INPUT_RECORD {
    const value: windows.WCHAR = if (codepoint <= std.math.maxInt(u16)) @intCast(codepoint) else 0;
    return .{
        .EventType = windows.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = .TRUE,
            .wRepeatCount = 1,
            .wVirtualKeyCode = 0,
            .wVirtualScanCode = 0,
            .uChar = .{ .UnicodeChar = value },
            .dwControlKeyState = 0,
        } },
    };
}

pub fn makeByteKeyRecord(byte: u8) windows.INPUT_RECORD {
    return .{
        .EventType = windows.KEY_EVENT,
        .Event = .{ .KeyEvent = .{
            .bKeyDown = .TRUE,
            .wRepeatCount = 1,
            .wVirtualKeyCode = 0,
            .wVirtualScanCode = 0,
            .uChar = .{ .UnicodeChar = byte },
            .dwControlKeyState = 0,
        } },
    };
}

test "appendVtBytes wraps each byte as a key record" {
    var list: std.ArrayList(windows.INPUT_RECORD) = .empty;
    defer list.deinit(std.testing.allocator);

    try list.ensureUnusedCapacity(std.testing.allocator, 3);
    list.appendAssumeCapacity(makeByteKeyRecord(0x1b));
    list.appendAssumeCapacity(makeByteKeyRecord('['));
    list.appendAssumeCapacity(makeByteKeyRecord('A'));

    try std.testing.expectEqual(@as(usize, 3), list.items.len);
    try std.testing.expectEqual(windows.KEY_EVENT, list.items[0].EventType);
    try std.testing.expectEqual(@as(windows.WCHAR, 0x1b), list.items[0].Event.KeyEvent.uChar.UnicodeChar);
    try std.testing.expectEqual(@as(windows.WCHAR, '['), list.items[1].Event.KeyEvent.uChar.UnicodeChar);
    try std.testing.expectEqual(@as(windows.WCHAR, 'A'), list.items[2].Event.KeyEvent.uChar.UnicodeChar);
}
