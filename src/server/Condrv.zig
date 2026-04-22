const windows = @import("../windows.zig");

pub const CONSOLE_IO_CONNECT = 0x01;
pub const CONSOLE_IO_DISCONNECT = 0x02;
pub const CONSOLE_IO_CREATE_OBJECT = 0x03;
pub const CONSOLE_IO_CLOSE_OBJECT = 0x04;
pub const CONSOLE_IO_RAW_WRITE = 0x05;
pub const CONSOLE_IO_RAW_READ = 0x06;
pub const CONSOLE_IO_USER_DEFINED = 0x07;
pub const CONSOLE_IO_RAW_FLUSH = 0x08;

pub const CD_IO_OBJECT_TYPE_CURRENT_INPUT: windows.ULONG = 0x01;
pub const CD_IO_OBJECT_TYPE_CURRENT_OUTPUT: windows.ULONG = 0x02;
pub const CD_IO_OBJECT_TYPE_NEW_OUTPUT: windows.ULONG = 0x03;
pub const CD_IO_OBJECT_TYPE_GENERIC: windows.ULONG = 0x04;

pub const CD_IO_DESCRIPTOR = extern struct {
    Identifier: windows.LUID,
    Process: windows.ULONG_PTR,
    Object: windows.ULONG_PTR,
    Function: windows.ULONG,
    InputSize: windows.ULONG,
    OutputSize: windows.ULONG,
    Reserved: windows.ULONG,
};

pub const CD_IO_COMPLETE = extern struct {
    Identifier: windows.LUID,
    IoStatus: windows.IO_STATUS_BLOCK,
    Write: CD_IO_BUFFER_DESCRIPTOR,
};

pub const CD_IO_BUFFER_DESCRIPTOR = extern struct {
    Data: windows.PVOID,
    Size: windows.ULONG,
    Offset: windows.ULONG,
};

pub const CD_CREATE_OBJECT_INFORMATION = extern struct {
    ObjectType: windows.ULONG,
    ShareMode: windows.ULONG,
    DesiredAccess: windows.ACCESS_MASK,
};

pub const CD_IO_SERVER_INFORMATION = extern struct {
    InputAvailableEvent: windows.HANDLE,
};

pub const CD_CONNECTION_INFORMATION = extern struct {
    Process: windows.ULONG_PTR,
    Input: windows.ULONG_PTR,
    Output: windows.ULONG_PTR,
};

pub const CD_IO_OPERATION = extern struct {
    Identifier: windows.LUID,
    Buffer: CD_IO_BUFFER_DESCRIPTOR,
};
