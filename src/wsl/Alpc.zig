//! ALPC handle-transfer helpers for the private zconpty <-> wslz handshake.

const std = @import("std");
const windows = @import("../windows.zig");

const ALPC = windows.ALPC;

pub const Attributes = struct {
    allocator: std.mem.Allocator,
    bytes: []u8,
    attrs: *ALPC.MESSAGE_ATTRIBUTES,

    pub fn init(allocator: std.mem.Allocator) !Attributes {
        var required: usize = 0;
        _ = windows.AlpcInitializeMessageAttribute(.{ .HANDLE_ATTRIBUTE = true }, null, 0, &required);

        const bytes = try allocator.alignedAlloc(
            u8,
            std.mem.Alignment.of(ALPC.HANDLE_ATTR),
            required,
        );
        errdefer allocator.free(bytes);

        const attrs: *ALPC.MESSAGE_ATTRIBUTES = @ptrCast(@alignCast(bytes.ptr));
        const status = windows.AlpcInitializeMessageAttribute(
            .{ .HANDLE_ATTRIBUTE = true },
            attrs,
            required,
            &required,
        );
        if (status != .SUCCESS) return error.AlpcInitializationFailed;

        return .{ .allocator = allocator, .bytes = bytes, .attrs = attrs };
    }

    pub fn deinit(self: *Attributes) void {
        self.allocator.free(self.bytes);
        self.* = undefined;
    }

    pub fn handle(self: *Attributes) *ALPC.HANDLE_ATTR {
        const attr_ptr = windows.AlpcGetMessageAttribute(self.attrs, .{ .HANDLE_ATTRIBUTE = true });
        return @ptrCast(@alignCast(attr_ptr.?));
    }
};

pub const AcceptedHandles = struct {
    stdin: windows.HANDLE,
    stdout: windows.HANDLE,
    control: windows.HANDLE,
};

pub const TrustPolicy = struct {
    process: *const fn (windows.HANDLE) bool,
    handle: *const fn (windows.HANDLE) bool,
};

pub fn createPort(port_name_utf16: []const u16) !windows.HANDLE {
    var port_name: windows.UNICODE_STRING = .init(port_name_utf16);
    var object_attributes: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = &port_name };
    var port_attributes = handleTransferPortAttributes();

    var port: windows.HANDLE = undefined;
    const status = windows.NtAlpcCreatePort(&port, &object_attributes, &port_attributes);
    if (status != .SUCCESS) return error.AlpcCreationFailed;

    return port;
}

pub fn sendSockets(
    allocator: std.mem.Allocator,
    port_name_utf16: []const u16,
    sockets: struct {
        stdin: windows.HANDLE,
        stdout: windows.HANDLE,
        control: windows.HANDLE,
    },
) !windows.HANDLE {
    var handle_attrs: [3]ALPC.HANDLE_ATTR32 = undefined;
    const ordered_handles = [_]windows.HANDLE{ sockets.stdin, sockets.stdout, sockets.control };

    for (ordered_handles, &handle_attrs) |handle, *attr| {
        attr.* = .{
            .Flags = .{ .DUPLICATE_SAME_ACCESS = true },
            .Handle = @truncate(@intFromPtr(handle)),
            .ObjectType = .{ .FILE = true },
        };
    }

    var attrs: Attributes = try .init(allocator);
    defer attrs.deinit();

    var handle_attr = attrs.handle();
    handle_attr.* = std.mem.zeroes(ALPC.HANDLE_ATTR);
    handle_attr.Flags = .{ .INDIRECT = true };
    handle_attr.u2.HandleAttrArray = &handle_attrs;
    handle_attr.u3.HandleCount = @intCast(handle_attrs.len);
    attrs.attrs.ValidAttributes = .{ .HANDLE_ATTRIBUTE = true };

    const port = try connect(port_name_utf16);

    _ = try receive(port, null);
    try send(port, emptyPortMessage(), attrs.attrs);

    return port;
}

pub fn acceptSockets(
    allocator: std.mem.Allocator,
    port: windows.HANDLE,
    trust: TrustPolicy,
) !AcceptedHandles {
    var attrs: Attributes = try .init(allocator);
    defer attrs.deinit();

    var connection_message = try receive(port, attrs.attrs);
    const process_validated = try validateSenderProcess(port, &connection_message, trust.process);
    const server_port = try acceptConnection(port, &connection_message, process_validated);
    defer _ = windows.NtClose(server_port);

    if (!process_validated) return error.UntrustedPeer;

    attrs.attrs.ValidAttributes = .{};
    // The connection-specific server port should work here, but it does not
    // receive indirect handles from wslz. Keep all transfer traffic on the
    // named port, matching the observed WSL handshake behavior.
    const handle_message = try receive(port, attrs.attrs);
    if (!attrs.attrs.ValidAttributes.HANDLE_ATTRIBUTE) return error.MissingHandleAttributes;

    const handle_attr = attrs.handle();
    if (handle_attr.u3.HandleCount != 3) return error.InvalidHandleCount;

    var sockets: [3]windows.HANDLE = undefined;
    for (&sockets, 0..) |*socket, index| {
        var info: ALPC.MESSAGE_HANDLE_INFORMATION = .{ .Index = @intCast(index) };
        const status = windows.NtAlpcQueryInformationMessage(
            port,
            @constCast(&handle_message),
            .HandleInformation,
            &info,
            @sizeOf(@TypeOf(info)),
            null,
        );
        if (status != .SUCCESS) return windows.unexpectedStatus(status);

        socket.* = @ptrFromInt(info.Handle);
        if (!trust.handle(socket.*)) return error.InvalidHandle;
    }

    return .{
        .stdin = sockets[0],
        .stdout = sockets[1],
        .control = sockets[2],
    };
}

fn handleTransferPortAttributes() ALPC.PORT_ATTRIBUTES {
    return .{
        .Flags = .{
            .ACCEPT_REQUESTS = true,
            .ACCEPT_DUP_HANDLES = true,
            .ACCEPT_INDIRECT_HANDLES = true,
        },
        .DupObjectTypes = .{ .FILE = true },
    };
}

fn emptyPortMessage() windows.PORT_MESSAGE {
    var message = std.mem.zeroes(windows.PORT_MESSAGE);
    message.u1.s1.DataLength = 0;
    message.u1.s1.TotalLength = @sizeOf(windows.PORT_MESSAGE);
    return message;
}

fn connect(port_name_utf16: []const u16) !windows.HANDLE {
    var port_name: windows.UNICODE_STRING = .init(port_name_utf16);
    var connection_oa: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = &port_name };
    var client_oa: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = null };
    var port_attrs = handleTransferPortAttributes();
    var connect_msg = emptyPortMessage();
    var connect_msg_len: usize = @sizeOf(windows.PORT_MESSAGE);

    var port: windows.HANDLE = undefined;
    const status = windows.NtAlpcConnectPortEx(
        &port,
        &connection_oa,
        &client_oa,
        &port_attrs,
        .{},
        null,
        &connect_msg,
        &connect_msg_len,
        null,
        null,
        null,
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);

    return port;
}

fn send(
    port: windows.HANDLE,
    message: windows.PORT_MESSAGE,
    attrs: ?*ALPC.MESSAGE_ATTRIBUTES,
) !void {
    var mutable_message = message;
    const status = windows.NtAlpcSendWaitReceivePort(
        port,
        .{},
        &mutable_message,
        attrs,
        null,
        null,
        null,
        null,
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);
}

fn receive(
    port: windows.HANDLE,
    attrs: ?*ALPC.MESSAGE_ATTRIBUTES,
) !windows.PORT_MESSAGE {
    var message = std.mem.zeroes(windows.PORT_MESSAGE);
    var message_len: usize = @sizeOf(windows.PORT_MESSAGE);

    const status = windows.NtAlpcSendWaitReceivePort(
        port,
        .{},
        null,
        null,
        &message,
        &message_len,
        attrs,
        null,
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);

    return message;
}

fn validateSenderProcess(
    port: windows.HANDLE,
    message: *windows.PORT_MESSAGE,
    process_valid: *const fn (windows.HANDLE) bool,
) !bool {
    var process_handle: windows.HANDLE = undefined;
    var query_oa: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = null };

    const status = windows.NtAlpcOpenSenderProcess(
        &process_handle,
        port,
        message,
        .{},
        .{ .SPECIFIC = .{ .PROCESS = .{ .QUERY_LIMITED_INFORMATION = true } } },
        &query_oa,
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);
    defer _ = windows.NtClose(process_handle);

    return process_valid(process_handle);
}

fn acceptConnection(
    port: windows.HANDLE,
    message: *const windows.PORT_MESSAGE,
    accepted: bool,
) !windows.HANDLE {
    var server_port: windows.HANDLE = undefined;
    const object_attributes: windows.OBJECT.ATTRIBUTES = .{};
    var port_attributes = handleTransferPortAttributes();
    const accept: windows.BOOLEAN = if (accepted) .TRUE else .FALSE;

    const status = windows.NtAlpcAcceptConnectPort(
        &server_port,
        port,
        0,
        &object_attributes,
        &port_attributes,
        null,
        message,
        null,
        accept,
    );
    if (status != .SUCCESS) return windows.unexpectedStatus(status);

    return server_port;
}
