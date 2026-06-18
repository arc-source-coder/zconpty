const std = @import("std");
const windows = @import("../windows.zig");
const utf = @import("../utf.zig");

/// Returns the number of UTF-16 code units in a Windows environment block,
/// including the final NUL that terminates the block.
pub fn windowsBlockLength(block: [*:0]const windows.WCHAR) usize {
    var offset: usize = 0;
    while (block[offset] != 0) {
        offset += std.mem.len(block + offset) + 1;
    }
    return offset + 1;
}

pub fn buildInteropBlock(
    allocator: std.mem.Allocator,
    current_environment: [*:0]const windows.WCHAR,
    linux_environment: []const u8,
) ![]u16 {
    var entries: std.ArrayList([]u16) = .empty;
    defer entries.deinit(allocator);
    defer for (entries.items) |entry| allocator.free(entry);

    var current_offset: usize = 0;
    while (current_environment[current_offset] != 0) {
        const entry = std.mem.span(current_environment + current_offset);
        current_offset += entry.len + 1;

        try entries.ensureUnusedCapacity(allocator, 1);
        entries.appendAssumeCapacity(try allocator.dupe(u16, entry));
    }

    var found_environment_end = false;
    var environment_entries = std.mem.splitScalar(u8, linux_environment, 0);
    while (environment_entries.next()) |environment_entry_utf8| {
        if (environment_entry_utf8.len == 0) {
            found_environment_end = true;
            break;
        }

        const key_end = std.mem.indexOfScalar(u8, environment_entry_utf8, '=') orelse {
            return error.InvalidEnvironment;
        };
        const new_entry = try utf.utf8ToUtf16LeAlloc(allocator, environment_entry_utf8);
        errdefer allocator.free(new_entry);
        const new_key_end = std.mem.indexOfScalar(u16, new_entry, '=') orelse {
            return error.InvalidEnvironment;
        };

        const entry_index = try findEntry(entries.items, new_entry[0..new_key_end]);

        if (key_end + 1 == environment_entry_utf8.len) {
            allocator.free(new_entry);
            if (entry_index) |index| {
                allocator.free(entries.items[index]);
                _ = entries.orderedRemove(index);
            }
            continue;
        }

        if (entry_index) |index| {
            allocator.free(entries.items[index]);
            entries.items[index] = new_entry;
        } else {
            try entries.ensureUnusedCapacity(allocator, 1);
            entries.appendAssumeCapacity(new_entry);
        }
    }
    if (!found_environment_end) return error.InvalidEnvironment;

    try setEntry(allocator, &entries, "WSLZ_SESSION=1");

    std.mem.sortUnstable([]u16, entries.items, {}, lessThanEnvEntry);

    var environment_block: std.ArrayList(u16) = .empty;
    errdefer environment_block.deinit(allocator);

    if (entries.items.len == 0) {
        try environment_block.append(allocator, 0);
    }

    for (entries.items) |entry| {
        try environment_block.appendSlice(allocator, entry);
        try environment_block.append(allocator, 0);
    }
    try environment_block.append(allocator, 0);

    return environment_block.toOwnedSlice(allocator);
}

fn setEntry(allocator: std.mem.Allocator, entries: *std.ArrayList([]u16), entry_utf8: []const u8) !void {
    const entry = try utf.utf8ToUtf16LeAlloc(allocator, entry_utf8);
    errdefer allocator.free(entry);

    const key_end = std.mem.indexOfScalar(u16, entry, '=') orelse return error.InvalidEnvironment;
    const entry_index = try findEntry(entries.items, entry[0..key_end]);
    if (entry_index) |index| {
        allocator.free(entries.items[index]);
        entries.items[index] = entry;
        return;
    }

    try entries.append(allocator, entry);
}

fn findEntry(entries: []const []u16, key: []const u16) !?usize {
    for (entries, 0..) |entry, index| {
        const current_key_end = std.mem.indexOfScalar(u16, entry, '=') orelse {
            return error.InvalidEnvironment;
        };
        if (std.mem.eql(u16, entry[0..current_key_end], key)) return index;
    }
    return null;
}

fn lessThanEnvEntry(_: void, lhs: []u16, rhs: []u16) bool {
    return std.mem.lessThan(u16, lhs, rhs);
}

test "windowsBlockLength includes final environment terminator" {
    const block = [_]windows.WCHAR{ 'A', '=', '1', 0, 'P', 'A', 'T', 'H', '=', 'x', 0, 0 };
    const slice = block[0 .. block.len - 1 :0];

    try std.testing.expectEqual(block.len, windowsBlockLength(slice.ptr));
}

test "buildInteropBlock rejects unterminated Linux environment" {
    const current_environment = [_]windows.WCHAR{0};

    try std.testing.expectError(
        error.InvalidEnvironment,
        buildInteropBlock(std.testing.allocator, current_environment[0..0 :0].ptr, "A=2"),
    );
}

test "buildInteropBlock applies WSL interop environment updates" {
    const current_environment = utf.utf8ToUtf16LeStringLiteral(
        "KEEP=1\x00REMOVE=1\x00UPDATE=1\x00\x00",
    );

    const block = try buildInteropBlock(
        std.testing.allocator,
        current_environment,
        "UPDATE=2\x00ADD=3\x00REMOVE=\x00\x00",
    );
    defer std.testing.allocator.free(block);

    const expected = utf.utf8ToUtf16LeStringLiteral("ADD=3\x00KEEP=1\x00UPDATE=2\x00WSLZ_SESSION=1\x00\x00");
    try std.testing.expectEqualSlices(u16, expected[0..block.len], block);
}
