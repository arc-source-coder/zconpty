const std = @import("std");

const session_state = @import("SessionState.zig");

pub const History = struct {
    commands: std.ArrayList([]u8) = .empty,

    pub fn deinit(self: *History, allocator: std.mem.Allocator) void {
        for (self.commands.items) |command| {
            allocator.free(command);
        }
        self.commands.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(
        self: *History,
        allocator: std.mem.Allocator,
        settings: session_state.HistorySettings,
        line: []const u8,
    ) !void {
        if (line.len == 0) return;

        if (settings.history_no_dup and self.commands.items.len > 0) {
            const last = self.commands.items[self.commands.items.len - 1];
            if (std.mem.eql(u8, last, line)) {
                return;
            }
        }

        const command = try allocator.dupe(u8, line);
        errdefer allocator.free(command);

        const max_commands = @max(@as(usize, settings.history_buffer_size), 1);
        if (self.commands.items.len >= max_commands) {
            const first = self.commands.orderedRemove(0);
            allocator.free(first);
        }

        try self.commands.append(allocator, command);
    }

    pub fn clear(self: *History, allocator: std.mem.Allocator) void {
        for (self.commands.items) |command| {
            allocator.free(command);
        }
        self.commands.items.len = 0;
    }

    pub fn remove(self: *History, allocator: std.mem.Allocator, index: usize) bool {
        if (index >= self.commands.items.len) return false;
        const removed = self.commands.orderedRemove(index);
        allocator.free(removed);
        return true;
    }

    pub fn swap(self: *History, index_a: usize, index_b: usize) bool {
        if (index_a >= self.commands.items.len or index_b >= self.commands.items.len) {
            return false;
        }
        if (index_a == index_b) return true;

        std.mem.swap([]u8, &self.commands.items[index_a], &self.commands.items[index_b]);
        return true;
    }
};

pub const HistoryPool = struct {
    entries: std.ArrayList(*HistoryEntry) = .empty,

    const HistoryEntry = struct {
        exe_name: []u8,
        history: History,
    };

    pub fn deinit(self: *HistoryPool, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.exe_name);
            entry.history.deinit(allocator);
            allocator.destroy(entry);
        }
        self.entries.deinit(allocator);
        self.* = undefined;
    }

    pub fn acquire(
        self: *HistoryPool,
        allocator: std.mem.Allocator,
        settings: session_state.HistorySettings,
        exe_name: []const u8,
    ) !*History {
        const index_existing = findEntryIndex(self.entries.items, exe_name);
        if (index_existing) |index| {
            if (index != 0) {
                const entry = self.entries.orderedRemove(index);
                try self.entries.insert(allocator, 0, entry);
            }
            return &self.entries.items[0].history;
        }

        const max_buffers = @max(@as(usize, settings.number_of_history_buffers), 1);
        if (self.entries.items.len >= max_buffers) {
            var evicted = self.entries.pop().?;
            allocator.free(evicted.exe_name);
            evicted.history.deinit(allocator);
        }

        const entry = try allocator.create(HistoryEntry);
        errdefer allocator.destroy(entry);

        const exe_name_owned = try allocator.dupe(u8, exe_name);
        errdefer allocator.free(exe_name_owned);

        entry.* = .{
            .exe_name = exe_name_owned,
            .history = .{},
        };

        try self.entries.insert(allocator, 0, entry);

        return &self.entries.items[0].history;
    }
};

fn findEntryIndex(entries: []const *HistoryPool.HistoryEntry, exe_name: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.ascii.eqlIgnoreCase(entry.exe_name, exe_name)) {
            return index;
        }
    }
    return null;
}

test "history append respects adjacent dedup" {
    var history: History = .{};
    defer history.deinit(std.testing.allocator);

    try history.append(std.testing.allocator, .{
        .history_buffer_size = 5,
        .number_of_history_buffers = 2,
        .history_no_dup = true,
    }, "dir");
    try history.append(std.testing.allocator, .{
        .history_buffer_size = 5,
        .number_of_history_buffers = 2,
        .history_no_dup = true,
    }, "dir");

    try std.testing.expectEqual(@as(usize, 1), history.commands.items.len);
    try std.testing.expectEqualStrings("dir", history.commands.items[0]);
}

test "history pool matches exe name case insensitive" {
    var pool: HistoryPool = .{};
    defer pool.deinit(std.testing.allocator);

    const settings: session_state.HistorySettings = .{
        .history_buffer_size = 5,
        .number_of_history_buffers = 2,
        .history_no_dup = false,
    };

    const cmd_history = try pool.acquire(std.testing.allocator, settings, "CMD.EXE");
    const cmd_history_again = try pool.acquire(std.testing.allocator, settings, "cmd.exe");
    try std.testing.expect(cmd_history == cmd_history_again);
}

test "history pool keeps pointers stable across MRU moves" {
    var pool: HistoryPool = .{};
    defer pool.deinit(std.testing.allocator);

    const settings: session_state.HistorySettings = .{
        .history_buffer_size = 5,
        .number_of_history_buffers = 3,
        .history_no_dup = false,
    };

    const cmd_history = try pool.acquire(std.testing.allocator, settings, "cmd.exe");
    const pwsh_history = try pool.acquire(std.testing.allocator, settings, "pwsh.exe");
    const cmd_history_again = try pool.acquire(std.testing.allocator, settings, "CMD.EXE");

    try std.testing.expect(cmd_history == cmd_history_again);
    try std.testing.expect(cmd_history != pwsh_history);
}
