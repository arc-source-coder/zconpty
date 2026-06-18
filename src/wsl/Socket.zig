//! Functions for interacting with Hyper-V sockets
const std = @import("std");
const windows = @import("../windows.zig");
const io = @import("Io.zig");

pub fn openHvSocket(vm_id: windows.GUID, port: u32) !windows.HANDLE {
    var handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    errdefer _ = windows.NtClose(handle);

    try openAfdHvEndpoint(&handle);
    try bindHvSocket(handle);
    try connectHvSocket(handle, vm_id, port);

    return handle;
}

/// Creates an AFD endpoint for a Hyper-V socket
fn openAfdHvEndpoint(handle: *windows.HANDLE) !void {
    var extended_attributes: windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION = .{
        .Value = .{
            .EndpointType = .{
                .CONNECTIONLESS = false,
                .MESSAGEMODE = false,
                .RAW = false,
            },
            .GroupID = 0,
            .AddressFamily = windows.AF.HYPERV,
            .SocketType = windows.SOCK.STREAM,
            .Protocol = windows.HV_PROTOCOL_RAW,
            .TransportDeviceNameLength = 0,
            .TransportDeviceName = undefined,
        },
    };

    var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);

    const desired_access: windows.ACCESS_MASK = .{
        .GENERIC = .{ .READ = true, .WRITE = true },
        .STANDARD = .{ .SYNCHRONIZE = true },
    };

    // "\\Device\\Afd\\Endpoint"
    const endpoint: []const u16 = windows.AFD.DEVICE_NAME ++ .{ '\\', 'E', 'n', 'd', 'p', 'o', 'i', 'n', 't' };
    var object_name = windows.UNICODE_STRING.init(endpoint);
    var oa: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = &object_name };

    const status = windows.NtCreateFile(
        handle,
        desired_access,
        &oa,
        &iosb,
        null,
        .{},
        .{ .READ = true, .WRITE = true },
        .OPEN_IF,
        .{ .IO = .ASYNCHRONOUS },
        &extended_attributes,
        @sizeOf(windows.AFD.OPEN_PACKET.FULL_EA_INFORMATION),
    );

    try io.wait(handle.*, status, &iosb);
}

fn bindHvSocket(handle: windows.HANDLE) !void {
    const local_addr: windows.SOCKADDR_HV = .{
        .Family = windows.AF.HYPERV,
        .Reserved = 0,
        .VmId = windows.HV_GUID_WILDCARD,
        .ServiceId = windows.HV_GUID_WILDCARD,
    };

    var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);

    var storage: windows.HV_BIND_STORAGE = .{
        .info = .{ .Mode = .Active },
        .addr = local_addr,
    };

    const bind_status = windows.NtDeviceIoControlFile(
        handle,
        null, // event
        null, // APC routine
        null, // APC context
        &iosb,
        windows.IOCTL.AFD.BIND,
        &storage,
        @offsetOf(@TypeOf(storage), "addr") + @sizeOf(windows.SOCKADDR_HV),
        &storage.addr,
        @sizeOf(windows.SOCKADDR_HV),
    );
    try io.wait(handle, bind_status, &iosb);
}

fn connectHvSocket(handle: windows.HANDLE, vm_id: windows.GUID, port: u32) !void {
    var service_id = windows.HV_GUID_VSOCK_TEMPLATE;
    service_id.Data1 = port;

    const remote_addr: windows.SOCKADDR_HV = .{
        .Family = windows.AF.HYPERV,
        .Reserved = 0,
        .VmId = vm_id,
        .ServiceId = service_id,
    };

    var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);

    var storage: windows.HV_CONNECT_STORAGE = .{
        // AFD connect requires 3 reserved usize
        .reserved = @splat(0),
        .addr = remote_addr,
    };

    const connect_status = windows.NtDeviceIoControlFile(
        handle,
        null, // event
        null, // apc routine
        null, // apc context
        &iosb,
        windows.IOCTL.AFD.CONNECT,
        @ptrCast(&storage),
        @offsetOf(@TypeOf(storage), "addr") + @sizeOf(windows.SOCKADDR_HV),
        null, // output buffer
        0,
    );

    try io.wait(handle, connect_status, &iosb);
}

pub fn recvMessage(allocator: std.mem.Allocator, socket: windows.HANDLE) !?[]u8 {
    var header: windows.LX.MESSAGE_HEADER = undefined;

    const header_buffer = std.mem.asBytes(&header);
    const bytes_read = try io.read(socket, header_buffer);
    if (bytes_read == 0) return null;
    try io.readExact(socket, header_buffer[bytes_read..]);

    if (header.MessageSize < @sizeOf(windows.LX.MESSAGE_HEADER)) {
        return error.InvalidMessage;
    }
    if (header.MessageSize > windows.LX.MAXIMUM_MESSAGE_SIZE) {
        return error.MessageTooLarge;
    }

    const message = try allocator.alloc(u8, header.MessageSize);
    errdefer allocator.free(message);

    @memcpy(message[0..@sizeOf(windows.LX.MESSAGE_HEADER)], std.mem.asBytes(&header));

    const body = message[@sizeOf(windows.LX.MESSAGE_HEADER)..];
    try io.readExact(socket, body);

    return message;
}
