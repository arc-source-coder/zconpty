const std = @import("std");
const windows = @import("../windows.zig");

const Terminal = @import("../server/Terminal.zig");
const alpc = @import("Alpc.zig");
const utils = @import("../utils.zig");
const io = @import("Io.zig");

const WSLZ_HASH = @import("wslz_hash").wslz_hash;

pub const WslReadThread = struct {
    os_thread: std.Thread,

    pub fn init(
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        port: windows.HANDLE,
        sockets: *WslzSession.Sockets,
        closing: *std.atomic.Value(bool),
    ) !WslReadThread {
        const thread = std.Thread.spawn(.{}, handleInitialization, .{
            allocator,
            terminal,
            port,
            sockets,
            closing,
        }) catch {
            return error.SpawnFailed;
        };
        thread.setName("WSL output relay") catch |err| {
            std.log.warn("failed to set WSL output relay thread name: {}", .{err});
        };

        return .{ .os_thread = thread };
    }

    pub fn deinit(self: *WslReadThread) void {
        self.os_thread.join();
        self.* = undefined;
    }

    pub fn close(self: *WslReadThread) void {
        _ = windows.NtAlertThread(self.os_thread.getHandle());
    }

    /// Waits for a connection on the ALPC port, validates it, and starts the read loop.
    fn handleInitialization(
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        port: windows.HANDLE,
        sockets: *WslzSession.Sockets,
        closing: *std.atomic.Value(bool),
    ) !void {
        @atomicStore(windows.HANDLE, &sockets.connection_port, port, .monotonic);

        const transfer = try alpc.acceptSockets(allocator, port, .{
            .process = verifyWslz,
            .handle = verifySocket,
        });

        @atomicStore(windows.HANDLE, &sockets.stdin, transfer.stdin, .monotonic);
        @atomicStore(windows.HANDLE, &sockets.control, transfer.control, .monotonic);

        var rows: u16 = undefined;
        var columns: u16 = undefined;
        terminal.getSize(&columns, &rows);
        // Notify the linux side about the current terminal size
        notifyTerminalResize(transfer.control, sockets.nextControlMessageId(), rows, columns) catch return;

        readLoop(closing, transfer.stdout, terminal);
    }

    fn readLoop(
        closing: *std.atomic.Value(bool),
        stdout: windows.HANDLE,
        terminal: *Terminal,
    ) void {
        defer _ = windows.NtClose(stdout);

        const allocator = std.heap.smp_allocator;
        const buffer_size = 128 * 1024;
        const storage = allocator.alloc(u8, buffer_size * 2) catch return;
        defer allocator.free(storage);

        const buffers: [2][]u8 = .{
            storage[0..buffer_size],
            storage[buffer_size..],
        };

        var event: windows.HANDLE = undefined;
        const desired_access: windows.ACCESS_MASK = @bitCast(@as(windows.DWORD, windows.GENERIC_ALL));
        const event_status = windows.NtCreateEvent(&event, desired_access, null, .Notification, .FALSE);
        if (event_status != .SUCCESS) return;
        defer _ = windows.NtClose(event);

        var read_index: usize = 0;
        var feed_index: usize = 1;
        var feed_len: ?usize = null;

        while (true) {
            var iosb: windows.IO_STATUS_BLOCK = std.mem.zeroes(windows.IO_STATUS_BLOCK);
            const read_buf = buffers[read_index];

            const status = windows.NtReadFile(
                @constCast(stdout),
                event,
                null,
                null,
                &iosb,
                read_buf.ptr,
                @intCast(read_buf.len),
                null,
                null,
            );

            if (feed_len) |len| {
                terminal.feed(buffers[feed_index][0..len]);
                feed_len = null;
            }

            if (status == .PENDING) {
                while (true) {
                    const wait_status = windows.NtWaitForSingleObject(event, .TRUE, null);

                    if (wait_status == .ALERTED) {
                        if (closing.load(.monotonic)) {
                            var cancel_iosb: windows.IO_STATUS_BLOCK = undefined;
                            _ = windows.NtCancelIoFileEx(stdout, &iosb, &cancel_iosb);
                            // The read IOSB and target buffer live on this thread's stack.
                            _ = windows.NtWaitForSingleObject(event, .FALSE, null);
                            return;
                        }
                        continue;
                    }

                    if (wait_status != .SUCCESS) return;
                    break;
                }

                if (iosb.u.Status != .SUCCESS) return;
            } else if (status != .SUCCESS) {
                return;
            }

            if (closing.load(.monotonic)) return;

            const bytes_read = iosb.Information;

            feed_len = bytes_read;
            std.mem.swap(usize, &read_index, &feed_index);

            if (bytes_read == 0) return;
        }
    }
};

pub const WslzSession = struct {
    thread: WslReadThread,
    allocator: std.mem.Allocator,
    closing: std.atomic.Value(bool),
    /// This contains message.Descriptor.Process which is used by
    /// handleDisconnect() to detect when wslz.exe exits and close the session.
    client: usize,
    /// Used to verify the wslz.exe associated with this session
    token: [16]u8,
    sockets: Sockets,

    pub const Sockets = struct {
        stdin: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
        /// Used to send resize events to Linux.
        control: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
        /// WSL's SocketChannel validates non-transaction control messages with
        /// monotonically increasing ids, starting at 1.
        control_sequence: std.atomic.Value(u32) = .init(0),
        /// Used to unblock the read thread if the session is closed
        /// while it is waiting for ALPC connection/handle message.
        connection_port: windows.HANDLE = windows.INVALID_HANDLE_VALUE,

        fn nextControlMessageId(self: *Sockets) u32 {
            return self.control_sequence.fetchAdd(1, .monotonic) + 1;
        }
    };

    pub fn init(
        self: *WslzSession,
        allocator: std.mem.Allocator,
        terminal: *Terminal,
        client: usize,
        token: [16]u8,
        port_name_utf16: []u16,
    ) !void {
        self.* = .{
            .thread = undefined,
            .allocator = allocator,
            .closing = .init(false),
            .client = client,
            .token = token,
            .sockets = .{},
        };

        const port = try alpc.createPort(port_name_utf16);
        errdefer _ = windows.NtClose(port);

        const sockets = &self.sockets;
        const closing = &self.closing;
        const thread: WslReadThread = try .init(allocator, terminal, port, sockets, closing);
        self.thread = thread;
    }

    pub fn deinit(self: *WslzSession) void {
        self.closing.store(true, .monotonic);

        // Notify the read thread to wind up
        self.thread.close();

        const stdin = @atomicLoad(windows.HANDLE, &self.sockets.stdin, .monotonic);
        const control = @atomicLoad(windows.HANDLE, &self.sockets.control, .monotonic);
        const connection_port = @atomicLoad(windows.HANDLE, &self.sockets.connection_port, .monotonic);

        if (utils.handleIsValid(stdin)) _ = windows.NtClose(stdin);
        if (utils.handleIsValid(control)) _ = windows.NtClose(control);
        if (utils.handleIsValid(connection_port)) _ = windows.NtClose(connection_port);

        // Join the read thread
        self.thread.deinit();
        self.* = undefined;
    }

    pub fn verifyToken(self: *WslzSession, token: [16]u8) bool {
        return std.mem.eql(u8, &self.token, &token);
    }

    pub fn writeInput(self: *WslzSession, bytes: []const u8) void {
        const stdin = @atomicLoad(windows.HANDLE, &self.sockets.stdin, .monotonic);
        if (!utils.handleIsValid(stdin)) return;
        io.writeAll(stdin, bytes) catch return;
    }

    pub fn notifyResize(self: *WslzSession, rows: u16, cols: u16) void {
        const control = @atomicLoad(windows.HANDLE, &self.sockets.control, .monotonic);
        notifyTerminalResize(control, self.sockets.nextControlMessageId(), rows, cols) catch return;
    }
};

fn notifyTerminalResize(control_socket: windows.HANDLE, transaction_id: u32, rows: u16, cols: u16) !void {
    if (rows == 0 or cols == 0) return error.InvalidResize;

    const msg: windows.LX.MESSAGE.LX_INIT_WINDOW_SIZE_CHANGED = .{
        .Header = .{
            .MessageType = .LxInitMessageWindowSizeChanged,
            .MessageSize = @sizeOf(windows.LX.MESSAGE.LX_INIT_WINDOW_SIZE_CHANGED),
            .TransactionId = transaction_id,
        },
        .Rows = rows,
        .Columns = cols,
    };
    try io.writeAll(control_socket, std.mem.asBytes(&msg));
}

/// Opens the process and verifies that its hash matches.
pub fn verifyWslz(process_handle: windows.HANDLE) bool {
    var buf: [1024]u8 = undefined;
    var return_len: windows.ULONG = undefined;

    const query_status = windows.NtQueryInformationProcess(
        process_handle,
        .ImageFileName,
        &buf,
        buf.len,
        &return_len,
    );

    if (query_status != .SUCCESS) return false;

    const name: *windows.UNICODE_STRING = @ptrCast(@alignCast(&buf));

    var file_handle: windows.HANDLE = undefined;
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    const file_oa: windows.OBJECT.ATTRIBUTES = .{ .ObjectName = name };

    const file_status = windows.NtOpenFile(
        &file_handle,
        windows.ACCESS_MASK.Specific.File.GENERIC_READ,
        &file_oa,
        &iosb,
        .{ .READ = true },
        .{ .IO = .SYNCHRONOUS_NONALERT },
    );
    if (file_status != .SUCCESS) return false;
    defer _ = windows.NtClose(file_handle);

    // Mmap the executable
    var section: windows.HANDLE = undefined;

    const section_status = windows.NtCreateSection(
        &section,
        .{ .GENERIC = .{ .READ = true } },
        null,
        null,
        .{ .READONLY = true },
        .{ .COMMIT = true },
        file_handle,
    );
    if (section_status != .SUCCESS) return false;
    defer _ = windows.NtClose(section);

    // This needs to be null, not undefined so that NtMapViewOfSection
    // does not fail with .MAPPED_ALIGNMENT
    var base_ptr: ?*anyopaque = null;
    var view_len: usize = 0;

    const current_process = std.os.windows.GetCurrentProcess();
    const map_status = windows.NtMapViewOfSection(
        section,
        current_process,
        @ptrCast(&base_ptr),
        0,
        0,
        null,
        &view_len,
        .Unmap,
        .{},
        .{ .READONLY = true },
    );
    if (map_status != .SUCCESS) return false;
    defer _ = windows.NtUnmapViewOfSection(current_process, base_ptr.?);

    var query_iosb: windows.IO_STATUS_BLOCK = undefined;
    var query_info: windows.FILE.STANDARD_INFORMATION = undefined;
    const size_query_status = windows.NtQueryInformationFile(
        file_handle,
        &query_iosb,
        &query_info,
        @sizeOf(@TypeOf(query_info)),
        .Standard,
    );
    if (size_query_status != .SUCCESS) return false;
    const file_size: usize = @intCast(query_info.EndOfFile);

    var process_hash: [32]u8 = undefined;
    var hasher: std.crypto.hash.Blake3 = .init(.{});
    hasher.update(@as([*]u8, @ptrCast(base_ptr))[0..file_size]);
    hasher.final(&process_hash);

    if (!std.mem.eql(u8, &process_hash, &WSLZ_HASH)) {
        std.log.warn("wslz.exe hash mismatch, rejecting connection", .{});
        return false;
    }

    return true;
}

/// Queries the socket and verifies that it is an AFD socket
pub fn verifySocket(socket: windows.HANDLE) bool {
    var buf: [1024]u8 = undefined;
    var return_len: windows.ULONG = 0;
    const status = windows.NtQueryObject(
        socket,
        .Name,
        &buf,
        buf.len,
        &return_len,
    );
    if (status != .SUCCESS) return false;
    const info: *windows.OBJECT.NAME_INFORMATION = @ptrCast(@alignCast(&buf));
    const name = info.Name.slice();

    // "\\Device\\Afd"
    const prefix = windows.AFD.DEVICE_NAME;
    if (!std.mem.startsWith(u16, name, prefix)) return false;

    return true;
}
