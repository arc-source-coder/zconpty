const windows = @import("windows.zig");

pub const Windows = windows;
pub const Server = @import("server/Server.zig");
pub const InputTypes = @import("server/InputTypes.zig");

pub const Session = Server.Session;
pub const Terminal = Session.Terminal;

pub const KeyAction = InputTypes.KeyAction;
pub const W3CCode = InputTypes.W3CCode;
pub const Mods = InputTypes.Mods;
pub const KeyEvent = InputTypes.KeyEvent;
pub const MouseEvent = InputTypes.MouseEvent;

test {
    _ = @import("server/ApiHandler.zig");
    _ = @import("server/ApiMsg.zig");
    _ = @import("server/Condrv.zig");
    _ = @import("server/ConDrvHandler.zig");
    _ = @import("server/CookedRead.zig");
    _ = @import("server/Dispatcher.zig");
    _ = @import("server/Input.zig");
    _ = @import("server/InputTypes.zig");
    _ = @import("server/IoCompletion.zig");
    _ = @import("server/Process.zig");
    _ = @import("server/ProcessPolicies.zig");
    _ = @import("server/Server.zig");
    _ = @import("server/SessionState.zig");
    _ = @import("server/Terminal.zig");
    _ = @import("utf.zig");
    _ = @import("wsl/Alpc.zig");
    _ = @import("wsl/Cli.zig");
    _ = @import("wsl/Environment.zig");
    _ = @import("wsl/Wsl.zig");
    _ = @import("wsl/Interop.zig");
    _ = @import("wsl/Io.zig");
}
