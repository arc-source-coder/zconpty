const std = @import("std");
const windows = @import("../windows.zig");

pub const KeyAction = enum(c_int) {
    release,
    press,
    repeat,
};

/// W3C-based physical key vocabulary mirrored from Ghostty's key enum.
/// Keeping the numeric order aligned lets the terminal adapter convert to
/// Ghostty's key enum without a second mapping table.
/// See: https://www.w3.org/TR/uievents-code
pub const W3CCode = enum(u16) {
    unidentified,
    backquote,
    backslash,
    bracket_left,
    bracket_right,
    comma,
    digit_0,
    digit_1,
    digit_2,
    digit_3,
    digit_4,
    digit_5,
    digit_6,
    digit_7,
    digit_8,
    digit_9,
    equal,
    intl_backslash,
    intl_ro,
    intl_yen,
    key_a,
    key_b,
    key_c,
    key_d,
    key_e,
    key_f,
    key_g,
    key_h,
    key_i,
    key_j,
    key_k,
    key_l,
    key_m,
    key_n,
    key_o,
    key_p,
    key_q,
    key_r,
    key_s,
    key_t,
    key_u,
    key_v,
    key_w,
    key_x,
    key_y,
    key_z,
    minus,
    period,
    quote,
    semicolon,
    slash,
    alt_left,
    alt_right,
    backspace,
    caps_lock,
    context_menu,
    control_left,
    control_right,
    enter,
    meta_left,
    meta_right,
    shift_left,
    shift_right,
    space,
    tab,
    convert,
    kana_mode,
    non_convert,
    delete,
    end,
    help,
    home,
    insert,
    page_down,
    page_up,
    arrow_down,
    arrow_left,
    arrow_right,
    arrow_up,
    num_lock,
    numpad_0,
    numpad_1,
    numpad_2,
    numpad_3,
    numpad_4,
    numpad_5,
    numpad_6,
    numpad_7,
    numpad_8,
    numpad_9,
    numpad_add,
    numpad_backspace,
    numpad_clear,
    numpad_clear_entry,
    numpad_comma,
    numpad_decimal,
    numpad_divide,
    numpad_enter,
    numpad_equal,
    numpad_memory_add,
    numpad_memory_clear,
    numpad_memory_recall,
    numpad_memory_store,
    numpad_memory_subtract,
    numpad_multiply,
    numpad_paren_left,
    numpad_paren_right,
    numpad_subtract,
    numpad_separator,
    numpad_up,
    numpad_down,
    numpad_right,
    numpad_left,
    numpad_begin,
    numpad_home,
    numpad_end,
    numpad_insert,
    numpad_delete,
    numpad_page_up,
    numpad_page_down,
    escape,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
    f13,
    f14,
    f15,
    f16,
    f17,
    f18,
    f19,
    f20,
    f21,
    f22,
    f23,
    f24,
    f25,
    @"fn",
    fn_lock,
    print_screen,
    scroll_lock,
    pause,
    browser_back,
    browser_favorites,
    browser_forward,
    browser_home,
    browser_refresh,
    browser_search,
    browser_stop,
    eject,
    launch_app_1,
    launch_app_2,
    launch_mail,
    media_play_pause,
    media_select,
    media_stop,
    media_track_next,
    media_track_previous,
    power,
    sleep,
    audio_volume_down,
    audio_volume_mute,
    audio_volume_up,
    wake_up,
    copy,
    cut,
    paste,

    pub fn fromW3C(code: []const u8) ?W3CCode {
        var normalized: [128]u8 = undefined;

        if (code.len == 0) return null;
        if (code.len > normalized.len) return null;

        if (std.meta.stringToEnum(
            W3CCode,
            std.ascii.lowerString(&normalized, code),
        )) |resolved| {
            return resolved;
        }

        var stream = std.io.fixedBufferStream(&normalized);
        const writer = stream.writer();

        for (code, 0..) |ch, index| switch (ch) {
            'a'...'z' => writer.writeByte(ch) catch return null,
            'A'...'Z', '0'...'9' => {
                if (index > 0) writer.writeByte('_') catch return null;
                writer.writeByte(std.ascii.toLower(ch)) catch return null;
            },
            else => return null,
        };

        return std.meta.stringToEnum(W3CCode, stream.getWritten());
    }
};

pub const Mods = packed struct(u16) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    caps_lock: bool = false,
    num_lock: bool = false,
    reserved: u10 = 0,
};

pub const KeyEvent = extern struct {
    action: KeyAction,
    mods: Mods,
    consumed_mods: Mods,
    repeat_count: u16,
    code: W3CCode,
    text_len: u8,
    text: [32]u8,
    unshifted_codepoint: u32,
    composing: u8,
    has_win_vk: u8,
    win_vk: u16,
    has_win_scan: u8,
    win_scan: u16,
    has_win_control_key_state: u8,
    win_control_key_state: u32,
};

pub fn codeFromWindowsNative(
    virtual_key: u16,
    scan_code: u16,
    control_key_state: windows.DWORD,
) ?W3CCode {
    const enhanced = (control_key_state & windows.ENHANCED_KEY) != 0;

    return switch (virtual_key) {
        0x10 => if (scan_code == 0x36) .shift_right else .shift_left,
        0x11 => if (enhanced) .control_right else .control_left,
        0x12 => if (enhanced) .alt_right else .alt_left,
        0x5B => .meta_left,
        0x5C => .meta_right,
        0x14 => .caps_lock,
        else => null,
    };
}

pub const MouseButton = enum(i8) {
    none = -1,
    unknown = 0,
    left = 1,
    right = 2,
    middle = 3,
    /// Scroll up is Button 4 for encoding
    four = 4,
    /// Scroll down is Button 5 for encoding
    five = 5,
    /// Horizontal scroll left
    six = 6,
    /// Horizontal scroll right
    seven = 7,
    eight = 8,
    nine = 9,
    ten = 10,
    eleven = 11,
};

pub const MouseAction = enum(c_int) { press, release, motion };

pub const MousePosition = extern struct {
    // Mouse position in cells
    x: u32,
    y: u32,
    // Mouse position in screen pixels
    x_px: f32,
    y_px: f32,
};

pub const MouseEvent = extern struct {
    button: MouseButton,
    action: MouseAction,
    mods: Mods,
    position: MousePosition,
};

pub fn controlKeyStateFromMods(mods: Mods) windows.DWORD {
    var state: windows.DWORD = 0;

    if (mods.shift) state |= windows.SHIFT_PRESSED;
    if (mods.ctrl) state |= windows.LEFT_CTRL_PRESSED;
    if (mods.alt) state |= windows.LEFT_ALT_PRESSED;
    if (mods.caps_lock) state |= windows.CAPSLOCK_ON;
    if (mods.num_lock) state |= windows.NUMLOCK_ON;

    return state;
}

test "W3CCode.fromW3C resolves supported names" {
    // Letters
    try std.testing.expectEqual(W3CCode.key_a, W3CCode.fromW3C("KeyA").?);
    try std.testing.expectEqual(W3CCode.key_z, W3CCode.fromW3C("KeyZ").?);
    // Named keys
    try std.testing.expectEqual(W3CCode.enter, W3CCode.fromW3C("Enter").?);
    try std.testing.expectEqual(W3CCode.escape, W3CCode.fromW3C("Escape").?);
    try std.testing.expectEqual(W3CCode.f1, W3CCode.fromW3C("F1").?);
    try std.testing.expectEqual(W3CCode.arrow_left, W3CCode.fromW3C("ArrowLeft").?);
    try std.testing.expectEqual(W3CCode.page_up, W3CCode.fromW3C("PageUp").?);
    try std.testing.expectEqual(W3CCode.space, W3CCode.fromW3C("Space").?);
}

test "W3CCode.fromW3C rejects unsupported names" {
    try std.testing.expect(W3CCode.fromW3C("") == null);
    try std.testing.expect(W3CCode.fromW3C("FooBar") == null);
    try std.testing.expect(W3CCode.fromW3C("Arrow-Left") == null);
}

test "codeFromWindowsNative resolves sided modifier keys" {
    try std.testing.expectEqual(
        W3CCode.shift_left,
        codeFromWindowsNative(0x10, 0x2A, 0).?,
    );
    try std.testing.expectEqual(
        W3CCode.shift_right,
        codeFromWindowsNative(0x10, 0x36, 0).?,
    );
    try std.testing.expectEqual(
        W3CCode.control_right,
        codeFromWindowsNative(0x11, 0x1D, windows.ENHANCED_KEY).?,
    );
    try std.testing.expectEqual(
        W3CCode.alt_left,
        codeFromWindowsNative(0x12, 0x38, 0).?,
    );
}
