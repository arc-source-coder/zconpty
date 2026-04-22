const windows = @import("../windows.zig");
const condrv = @import("Condrv.zig");
const apiMsg = @import("ApiMsg.zig");

pub const ConDrvHandler = struct {
    server: windows.HANDLE,

    pub fn init(server: windows.HANDLE) ConDrvHandler {
        return .{ .server = server };
    }

    pub fn readInput(
        self: *ConDrvHandler,
        operation: *const condrv.CD_IO_OPERATION,
    ) windows.NTSTATUS {
        var iosb: windows.IO_STATUS_BLOCK = undefined;

        return windows.NtDeviceIoControlFile(
            self.server,
            null,
            null,
            null,
            &iosb,
            windows.IOCTL.CONDRV.READ_INPUT,
            operation,
            @sizeOf(condrv.CD_IO_OPERATION),
            null,
            0,
        );
    }

    pub fn setServerInformation(
        self: *ConDrvHandler,
        server_info: *const condrv.CD_IO_SERVER_INFORMATION,
    ) windows.NTSTATUS {
        var iosb: windows.IO_STATUS_BLOCK = undefined;

        return windows.NtDeviceIoControlFile(
            self.server,
            null,
            null,
            null,
            &iosb,
            windows.IOCTL.CONDRV.SET_SERVER_INFORMATION,
            server_info,
            @sizeOf(condrv.CD_IO_SERVER_INFORMATION),
            null,
            0,
        );
    }

    pub fn readIo(
        self: *ConDrvHandler,
        previous_complete: ?*const condrv.CD_IO_COMPLETE,
        data_packet: *apiMsg.CONSOLE_DATA_PACKET,
    ) windows.NTSTATUS {
        var iosb: windows.IO_STATUS_BLOCK = undefined;

        const st = windows.NtDeviceIoControlFile(
            self.server,
            null,
            null,
            null,
            &iosb,
            windows.IOCTL.CONDRV.READ_IO,
            if (previous_complete) |c| c else null,
            if (previous_complete == null) 0 else @sizeOf(condrv.CD_IO_COMPLETE),
            data_packet,
            @sizeOf(apiMsg.CONSOLE_DATA_PACKET),
        );
        if (st == .PENDING) {
            _ = windows.NtWaitForSingleObject(self.server, .FALSE, null);
            return iosb.u.Status;
        }
        return st;
    }

    pub fn completeIo(
        self: *ConDrvHandler,
        completion: *const condrv.CD_IO_COMPLETE,
    ) windows.NTSTATUS {
        var iosb: windows.IO_STATUS_BLOCK = undefined;

        return windows.NtDeviceIoControlFile(
            self.server,
            null,
            null,
            null,
            &iosb,
            windows.IOCTL.CONDRV.COMPLETE_IO,
            completion,
            @sizeOf(condrv.CD_IO_COMPLETE),
            null,
            0,
        );
    }

    pub fn writeOutput(
        self: *ConDrvHandler,
        operation: *const condrv.CD_IO_OPERATION,
    ) windows.NTSTATUS {
        var iosb: windows.IO_STATUS_BLOCK = undefined;

        return windows.NtDeviceIoControlFile(
            self.server,
            null,
            null,
            null,
            &iosb,
            windows.IOCTL.CONDRV.WRITE_OUTPUT,
            operation,
            @sizeOf(condrv.CD_IO_OPERATION),
            null,
            0,
        );
    }
};
