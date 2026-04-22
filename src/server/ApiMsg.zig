const condrv = @import("Condrv.zig");
const conmsg = @import("ConsoleMsg.zig");

pub const CONSOLE_DATA_PACKET = extern struct {
    Descriptor: condrv.CD_IO_DESCRIPTOR,
    Body: extern union {
        object_msg: CONSOLE_OBJECT_MSG,
        api_msg: CONSOLE_API_MSG,
    },
};

pub const CONSOLE_OBJECT_MSG = extern struct {
    CreateObject: condrv.CD_CREATE_OBJECT_INFORMATION,
    CreateScreenBuffer: conmsg.CONSOLE_CREATESCREENBUFFER_MSG,
};

pub const CONSOLE_API_MSG = extern struct {
    msgHeader: conmsg.CONSOLE_MSG_HEADER,
    msgBody: extern union {
        consoleMsgL1: conmsg.L1.MSG_BODY,
        consoleMsgL2: conmsg.L2.MSG_BODY,
        consoleMsgL3: conmsg.L3.MSG_BODY,
    },
};
