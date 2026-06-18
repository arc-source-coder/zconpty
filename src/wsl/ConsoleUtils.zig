//! Functions for interacting with the ConDrv
const std = @import("std");
const windows = @import("../windows.zig");
const dispatcher = @import("../server/Dispatcher.zig");
const console_msg = @import("../server/ConsoleMsg.zig");
const io = @import("Io.zig");

pub fn bootstrapWslz(stdout: windows.HANDLE, out: *console_msg.L3.CONSOLE_WSLZ_BOOTSTRAP_MSG) !void {
    var info: console_msg.L3.CONSOLE_WSLZ_BOOTSTRAP_MSG = undefined;

    const header: windows.CONSOLE.USER_IO.Header.With(console_msg.L3.CONSOLE_WSLZ_BOOTSTRAP_MSG) =
        .init(@enumFromInt(@intFromEnum(dispatcher.ApiNumber.wslz_bootstrap)), undefined);

    const inputBuf: [1]windows.CONSOLE.USER_IO.InputBuffer = .{.{
        .Size = @sizeOf(@TypeOf(header)),
        .Pointer = &header,
    }};
    const outputBuf: [1]windows.CONSOLE.USER_IO.OutputBuffer = .{.{
        .Size = @sizeOf(console_msg.L3.CONSOLE_WSLZ_BOOTSTRAP_MSG),
        .Pointer = &info,
    }};

    var request: windows.CONSOLE.USER_IO.Request(1, 1) = .init(stdout, inputBuf, outputBuf);
    try issueIoctl(&request, @sizeOf(@TypeOf(request)));

    out.* = info;
}

pub fn setInteropMode(stdout: windows.HANDLE, token: [16]u8, enabled: windows.BOOLEAN) !void {
    const message: console_msg.L3.CONSOLE_WSLZ_SET_INTEROP_MODE_MSG = .{
        .token = token,
        .windowsInterop = enabled,
    };

    const header: windows.CONSOLE.USER_IO.Header.With(console_msg.L3.CONSOLE_WSLZ_SET_INTEROP_MODE_MSG) =
        .init(@enumFromInt(@intFromEnum(dispatcher.ApiNumber.wslz_set_interop_mode)), message);

    const inputBuf: [1]windows.CONSOLE.USER_IO.InputBuffer = .{.{
        .Size = @sizeOf(@TypeOf(header)),
        .Pointer = &header,
    }};
    const outputBuf: [0]windows.CONSOLE.USER_IO.OutputBuffer = .{};

    var request: windows.CONSOLE.USER_IO.Request(1, 0) = .init(stdout, inputBuf, outputBuf);
    try issueIoctl(&request, @sizeOf(@TypeOf(request)));
}

pub fn getTerminalSize(stdout: windows.HANDLE, cols: *u16, rows: *u16) !void {
    var info: windows.CONSOLE.USER_IO.INFO.SCREEN_BUFFER = undefined;

    const inputBuf: [1]windows.CONSOLE.USER_IO.InputBuffer = .{.{
        .Size = @sizeOf(@TypeOf(windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO)),
        .Pointer = &windows.CONSOLE.USER_IO.GET_SCREEN_BUFFER_INFO,
    }};
    const outputBuf: [1]windows.CONSOLE.USER_IO.OutputBuffer = .{.{
        .Size = @sizeOf(windows.CONSOLE.USER_IO.INFO.SCREEN_BUFFER),
        .Pointer = &info,
    }};

    var request: windows.CONSOLE.USER_IO.Request(1, 1) = .init(stdout, inputBuf, outputBuf);
    try issueIoctl(&request, @sizeOf(@TypeOf(request)));

    cols.* = @intCast(info.dwSize.X);
    rows.* = @intCast(info.dwSize.Y);
}

pub fn issueIoctl(request_ptr: *anyopaque, request_len: windows.ULONG) !void {
    var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);
    const console_handle = std.os.windows.peb().ProcessParameters.ConsoleHandle;
    const status = windows.NtDeviceIoControlFile(
        console_handle,
        null,
        null,
        null,
        &iosb,
        windows.IOCTL.CONDRV.ISSUE_USER_IO,
        request_ptr,
        request_len,
        null,
        0,
    );
    try io.wait(console_handle, status, &iosb);
}
