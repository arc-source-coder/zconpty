const std = @import("std");
const condrv = @import("Condrv.zig");
const ApiNumber = @import("Dispatcher.zig").ApiNumber;

pub const FunctionStat = struct {
    count: u64,
    first_seen_order: u32,
};

pub const Stats = struct {
    read_attempts: u64 = 0,
    read_pending: u64 = 0,
    read_success: u64 = 0,
    read_errors: u64 = 0,
    complete_success: u64 = 0,
    complete_errors: u64 = 0,
    disconnects: u64 = 0,
    raw_write: u64 = 0,
    raw_read: u64 = 0,
    user_defined: u64 = 0,

    pub fn onFunction(self: *Stats, function_id: u32) void {
        switch (function_id) {
            condrv.CONSOLE_IO_RAW_WRITE => self.raw_write += 1,
            condrv.CONSOLE_IO_RAW_READ => self.raw_read += 1,
            condrv.CONSOLE_IO_USER_DEFINED => self.user_defined += 1,
            condrv.CONSOLE_IO_DISCONNECT => self.disconnects += 1,
            else => {},
        }
    }
};

pub const RequestLogger = struct {
    allocator: std.mem.Allocator,
    next_order: u32 = 0,
    descriptor_stats: std.AutoArrayHashMapUnmanaged(u32, FunctionStat) = .empty,
    user_api_stats: std.AutoArrayHashMapUnmanaged(u32, FunctionStat) = .empty,

    pub fn init(allocator: std.mem.Allocator) RequestLogger {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RequestLogger) void {
        self.descriptor_stats.deinit(self.allocator);
        self.user_api_stats.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn recordDescriptor(self: *RequestLogger, function_id: u32) !void {
        try self.recordInto(&self.descriptor_stats, function_id);
    }

    pub fn recordUserApi(self: *RequestLogger, api_number: u32) !void {
        try self.recordInto(&self.user_api_stats, api_number);
    }

    fn recordInto(
        self: *RequestLogger,
        map: *std.AutoArrayHashMapUnmanaged(u32, FunctionStat),
        key: u32,
    ) !void {
        const gop = try map.getOrPut(self.allocator, key);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .count = 0, .first_seen_order = self.next_order };
            self.next_order += 1;
        }
        gop.value_ptr.count += 1;
    }

    fn descriptorName(function_id: u32) []const u8 {
        return switch (function_id) {
            condrv.CONSOLE_IO_CONNECT => "CONSOLE_IO_CONNECT",
            condrv.CONSOLE_IO_DISCONNECT => "CONSOLE_IO_DISCONNECT",
            condrv.CONSOLE_IO_CREATE_OBJECT => "CONSOLE_IO_CREATE_OBJECT",
            condrv.CONSOLE_IO_CLOSE_OBJECT => "CONSOLE_IO_CLOSE_OBJECT",
            condrv.CONSOLE_IO_RAW_WRITE => "CONSOLE_IO_RAW_WRITE",
            condrv.CONSOLE_IO_RAW_READ => "CONSOLE_IO_RAW_READ",
            condrv.CONSOLE_IO_USER_DEFINED => "CONSOLE_IO_USER_DEFINED",
            condrv.CONSOLE_IO_RAW_FLUSH => "CONSOLE_IO_RAW_FLUSH",
            else => "UNKNOWN_DESCRIPTOR_FUNCTION",
        };
    }

    pub fn dumpPriorityList(self: *RequestLogger, writer: anytype) !void {
        const Item = struct {
            key: u32,
            stat: FunctionStat,
        };

        var descriptor_items: std.ArrayList(Item) = .empty;
        defer descriptor_items.deinit(self.allocator);
        try descriptor_items.ensureTotalCapacity(self.allocator, self.descriptor_stats.count());

        var i: usize = 0;
        while (i < self.descriptor_stats.count()) : (i += 1) {
            const key: u32 = self.descriptor_stats.keys()[i];
            const stat: FunctionStat = self.descriptor_stats.values()[i];
            descriptor_items.appendAssumeCapacity(.{ .key = key, .stat = stat });
        }

        std.mem.sort(Item, descriptor_items.items, {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                if (a.stat.count != b.stat.count) return a.stat.count > b.stat.count;
                return a.stat.first_seen_order < b.stat.first_seen_order;
            }
        }.lessThan);

        var user_api_items: std.ArrayList(Item) = .empty;
        defer user_api_items.deinit(self.allocator);
        try user_api_items.ensureTotalCapacity(self.allocator, self.user_api_stats.count());

        i = 0;
        while (i < self.user_api_stats.count()) : (i += 1) {
            const key: u32 = self.user_api_stats.keys()[i];
            const stat: FunctionStat = self.user_api_stats.values()[i];
            user_api_items.appendAssumeCapacity(.{ .key = key, .stat = stat });
        }

        std.mem.sort(Item, user_api_items.items, {}, struct {
            fn lessThan(_: void, a: Item, b: Item) bool {
                if (a.stat.first_seen_order != b.stat.first_seen_order) {
                    return a.stat.first_seen_order < b.stat.first_seen_order;
                }
                return a.stat.count > b.stat.count;
            }
        }.lessThan);

        try writer.print("\n=== InProc request priority summary ===\n", .{});
        try writer.print("Descriptor functions (count desc):\n", .{});
        if (descriptor_items.items.len == 0) {
            try writer.print("  (none)\n", .{});
        } else {
            for (descriptor_items.items) |entry| {
                try writer.print(
                    "  - {s: <24} id=0x{x:0>8}  count={d: >4}  first_seen={d}\n",
                    .{
                        descriptorName(entry.key),
                        entry.key,
                        entry.stat.count,
                        entry.stat.first_seen_order,
                    },
                );
            }
        }

        try writer.print("USER_DEFINED API calls (first-seen order):\n", .{});
        if (user_api_items.items.len == 0) {
            try writer.print("  (none)\n", .{});
        } else {
            for (user_api_items.items) |entry| {
                const tag: ApiNumber = @enumFromInt(entry.key);
                try writer.print(
                    "  - name={s} api=0x{x:0>8}  count={d: >4}  first_seen={d}\n",
                    .{ @tagName(tag), entry.key, entry.stat.count, entry.stat.first_seen_order },
                );
            }
        }
    }
};
