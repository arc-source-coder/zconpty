const std = @import("std");
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

pub fn duplicateHandle(handle: windows.HANDLE, attributes: windows.ULONG) !windows.HANDLE {
    var duplicate: windows.HANDLE = undefined;
    const process = windows.GetCurrentProcess();
    const status = windows.NtDuplicateObject(
        process,
        handle,
        process,
        &duplicate,
        0,
        attributes,
        windows.DUPLICATE_SAME_ACCESS,
    );
    if (!ntSuccess(status)) return windows.unexpectedStatus(status);
    return duplicate;
}

pub const ProcThreadAttributes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    list: ?*anyopaque,

    pub fn init(allocator: std.mem.Allocator, count: windows.DWORD) !ProcThreadAttributes {
        var bytes_len: windows.SIZE_T = 0;
        _ = windows.InitializeProcThreadAttributeList(null, count, 0, &bytes_len);

        const bytes = try allocator.alloc(u8, bytes_len);
        errdefer allocator.free(bytes);

        const list: ?*anyopaque = @ptrCast(bytes.ptr);
        if (windows.InitializeProcThreadAttributeList(list, count, 0, &bytes_len) == .FALSE) {
            return error.AttributeInitializationFailed;
        }

        return .{ .allocator = allocator, .bytes = bytes, .list = list };
    }

    pub fn deinit(self: *ProcThreadAttributes) void {
        windows.DeleteProcThreadAttributeList(self.list);
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn update(
        self: *ProcThreadAttributes,
        attribute: usize,
        value: *anyopaque,
        size: windows.SIZE_T,
    ) !void {
        if (windows.UpdateProcThreadAttribute(
            self.list,
            0,
            attribute,
            value,
            size,
            null,
            null,
        ) == .FALSE) {
            return error.AttributeUpdateFailed;
        }
    }
};

pub fn hresultFromWin32(err: windows.Win32Error) windows.HRESULT {
    const code: u32 = @intFromEnum(err) & 0x0000_FFFF;
    return @bitCast(0x8007_0000 | code);
}

pub fn hresultFromNt(status: windows.NTSTATUS) windows.HRESULT {
    const raw: u32 = @intFromEnum(status);
    return @bitCast(raw | 0x1000_0000);
}
