const windows = @import("windows.zig");

pub fn mapError(err: anyerror) windows.NTSTATUS {
    return switch (err) {
        error.InvalidHandle => .INVALID_HANDLE,
        error.OutOfMemory => .NO_MEMORY,
        error.InvalidParameter => .INVALID_PARAMETER,
        error.InvalidUtf16 => .INVALID_PARAMETER,
        error.ReadInputFailed => .UNSUCCESSFUL,
        else => .UNSUCCESSFUL,
    };
}

pub inline fn handleIsValid(h: windows.HANDLE) bool {
    return (h != windows.INVALID_HANDLE_VALUE) and (@intFromPtr(h) != 0);
}

pub inline fn ntSuccess(status: windows.NTSTATUS) bool {
    return @as(i32, @bitCast(@intFromEnum(status))) >= 0;
}

pub fn hresultFromWin32(err: windows.Win32Error) windows.HRESULT {
    const code: u32 = @intFromEnum(err) & 0x0000_FFFF;
    return @bitCast(0x8007_0000 | code);
}

pub fn hresultFromNt(status: windows.NTSTATUS) windows.HRESULT {
    const raw: u32 = @intFromEnum(status);
    return @bitCast(raw | 0x1000_0000);
}
