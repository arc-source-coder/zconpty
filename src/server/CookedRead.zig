const std = @import("std");

const editor = @import("CookedReadEditor.zig");
const history = @import("CookedReadHistory.zig");
const render = @import("CookedReadRender.zig");

pub const PendingRead = editor.PendingRead;
pub const Active = editor.Active;
pub const Outcome = editor.Outcome;
pub const Completion = editor.Completion;
pub const CompletionKind = editor.CompletionKind;
pub const History = history.History;
pub const HistoryPool = history.HistoryPool;

pub const Slot = struct {
    mutex: std.Thread.Mutex = .{},
    active: ?Active = null,

    pub fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        if (self.active) |*active| {
            active.deinit(allocator);
        }

        self.* = undefined;
    }
};

pub const initActive = editor.initActive;
pub const handleKey = editor.handleKey;
pub const handleText = editor.handleText;
pub const redraw = render.redraw;

test {
    _ = @import("CookedReadEditor.zig");
    _ = @import("CookedReadHistory.zig");
    _ = @import("CookedReadRender.zig");
}
