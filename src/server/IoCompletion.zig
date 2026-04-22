const windows = @import("../windows.zig");
const condrv = @import("Condrv.zig");

var write_placeholder_byte: u8 = 0;

fn writePlaceholderPtr() windows.PVOID {
    return @ptrCast(&write_placeholder_byte);
}

pub fn setWritePlaceholder(completion: *condrv.CD_IO_COMPLETE) void {
    completion.Write = .{ .Data = writePlaceholderPtr(), .Size = 0, .Offset = 0 };
}

pub fn setWriteBuffer(
    completion: *condrv.CD_IO_COMPLETE,
    data: *anyopaque,
    size: windows.ULONG,
) void {
    completion.Write = .{ .Data = data, .Size = size, .Offset = 0 };
}

pub fn setCompletion(
    completion: *condrv.CD_IO_COMPLETE,
    status: windows.NTSTATUS,
    information: windows.ULONG_PTR,
) void {
    completion.IoStatus.u.Status = status;
    completion.IoStatus.Information = information;
}

pub fn setStatus(completion: *condrv.CD_IO_COMPLETE, status: windows.NTSTATUS) void {
    setCompletion(completion, status, 0);
}

pub fn setUnsupported(completion: *condrv.CD_IO_COMPLETE) void {
    setStatus(completion, .NOT_IMPLEMENTED);
}

pub fn setSuccess(completion: *condrv.CD_IO_COMPLETE) void {
    setStatus(completion, .SUCCESS);
}

pub fn setSuccessWithInformation(
    completion: *condrv.CD_IO_COMPLETE,
    information: windows.ULONG_PTR,
) void {
    setCompletion(completion, .SUCCESS, information);
}
