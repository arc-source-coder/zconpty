//! Wrapper around `wsl/Cli.zig` to fix "error: import of file outside module path".
//! `wsl/Cli.zig` imports `windows.zig` for windows declarations.

const cli = @import("wsl/Cli.zig");

pub fn main() !void {
    try cli.run();
}
