//! Helper executable to hash the compiled wslz.exe for embedding into zconpty
const std = @import("std");

pub fn main() !void {
    var args_buffer: [16 * 1024]u8 = undefined;
    var args_allocator: std.heap.FixedBufferAllocator = .init(&args_buffer);
    var args = try std.process.argsWithAllocator(args_allocator.allocator());
    defer args.deinit();

    const exe_name = args.next() orelse "wslz-hasher";
    const input_path = args.next() orelse return usage(exe_name);
    const output_path = args.next() orelse return usage(exe_name);

    if (args.next() != null) return usage(exe_name);

    const exe = try std.fs.cwd().openFile(input_path, .{});
    defer exe.close();

    var hasher: std.crypto.hash.Blake3 = .init(.{});

    // Use a 512kb buffer - wslz.exe is ~300kb
    var buffer: [512 * 1024]u8 = undefined;

    while (true) {
        const bytes_read = try exe.read(&buffer);
        if (bytes_read == 0) break;
        hasher.update(buffer[0..bytes_read]);
    }

    var hash: [32]u8 = undefined;
    hasher.final(&hash);

    const hash_file = try std.fs.cwd().createFile(output_path, .{});
    defer hash_file.close();
    var output_buffer: [4096]u8 = undefined;
    var writer = hash_file.writer(&output_buffer);
    try writer.interface.print("pub const wslz_hash: [32]u8 = .{any};\n", .{hash});
    try writer.interface.flush();
}

fn usage(exe_name: []const u8) !void {
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stderr().writer(&buf);
    try writer.interface.print("usage: {s} <input-exe> <output-hash>\n", .{exe_name});
    try writer.interface.flush();
}
