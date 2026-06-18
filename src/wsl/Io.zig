//! Shared blocking NT I/O helpers for WSL pipe and socket handles.
//!
//! wsl.exe writes to the Linux sockets through WSASend, which maps to AFD send
//! IOCTLs. All Linux sockets involved are byte-stream file handles, and callers
//! have already serialized LX messages into contiguous bytes, so NtWriteFile
//! is equivalent to IOCTL.AFD.SEND for sending those bytes.

const std = @import("std");
const windows = @import("../windows.zig");

pub fn wait(handle: windows.HANDLE, status: windows.NTSTATUS, iosb: *windows.IO_STATUS_BLOCK) !void {
    if (status == .PENDING) {
        const wait_status = windows.NtWaitForSingleObject(handle, .FALSE, null);
        if (wait_status != .SUCCESS) return windows.unexpectedStatus(wait_status);
    } else if (status != .SUCCESS) {
        return windows.unexpectedStatus(status);
    }

    switch (iosb.u.Status) {
        .SUCCESS => {},
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        else => |io_status| return windows.unexpectedStatus(io_status),
    }
}

pub fn read(handle: windows.HANDLE, buffer: []u8) !usize {
    if (buffer.len == 0) return 0;

    const read_len = @min(buffer.len, std.math.maxInt(windows.ULONG));

    var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);
    const status = windows.NtReadFile(
        handle,
        null,
        null,
        null,
        &iosb,
        buffer.ptr,
        @intCast(read_len),
        null,
        null,
    );

    try wait(handle, status, &iosb);
    return iosb.Information;
}

pub fn readExact(handle: windows.HANDLE, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        const bytes_read = try read(handle, buffer[offset..]);
        if (bytes_read == 0) return error.UnexpectedEof;
        offset += bytes_read;
    }
}

pub fn writeAll(handle: windows.HANDLE, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const remaining = bytes[offset..];
        const write_len = @min(remaining.len, std.math.maxInt(windows.ULONG));
        const chunk = remaining[0..write_len];

        var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);
        const status = windows.NtWriteFile(
            handle,
            null,
            null,
            null,
            &iosb,
            chunk.ptr,
            @intCast(chunk.len),
            null,
            null,
        );

        try wait(handle, status, &iosb);

        if (iosb.Information == 0) return error.ShortWrite;
        if (iosb.Information > chunk.len) return error.InvalidIoCompletion;
        offset += iosb.Information;
    }
}
