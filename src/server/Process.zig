const std = @import("std");
const windows = @import("../windows.zig");
const condrv = @import("Condrv.zig");
const processPolicies = @import("ProcessPolicies.zig");

pub const Process = struct {
    pid: windows.DWORD,
    tid: windows.DWORD,
    process_group_id: windows.ULONG,
    process_handle: windows.HANDLE,
    policy: Policy,
    shim_policy: ShimPolicy,
    input_handle: ?*Handle,
    output_handle: ?*Handle,
    connection_info: condrv.CD_CONNECTION_INFORMATION,

    pub fn init(
        pid: windows.DWORD,
        tid: windows.DWORD,
        process_group_id: windows.ULONG,
        process_handle: windows.HANDLE,
    ) Process {
        return .{
            .pid = pid,
            .tid = tid,
            .process_group_id = process_group_id,
            .process_handle = process_handle,
            .policy = Policy.init(process_handle),
            .shim_policy = ShimPolicy.init(process_handle),
            .input_handle = null,
            .output_handle = null,
            .connection_info = std.mem.zeroes(condrv.CD_CONNECTION_INFORMATION),
        };
    }

    pub const Handle = struct {
        access_mask: windows.ACCESS_MASK,
        share_access: windows.FILE.SHARE,
        type: HandleType,
        client_pointer: ?*anyopaque,

        pub const HandleType = enum(u8) {
            NotReady = 0,
            Input = 1,
            Output = 2,
        };
    };

    pub const Policy = struct {
        can_read_output_buffer: bool,
        can_write_input_buffer: bool,

        fn init(process_handle: windows.HANDLE) Policy {
            var can_read_output_buffer = false;
            var can_write_input_buffer = false;
            processPolicies.applyConsoleAccessPolicy(
                process_handle,
                &can_read_output_buffer,
                &can_write_input_buffer,
            );
            return .{
                .can_read_output_buffer = can_read_output_buffer,
                .can_write_input_buffer = can_write_input_buffer,
            };
        }
    };

    pub const ShimPolicy = struct {
        is_cmd_exe: bool,
        is_powershell_exe: bool,

        fn init(process_handle: windows.HANDLE) ShimPolicy {
            var is_cmd_exe = false;
            var is_powershell_exe = false;

            processPolicies.applyConsoleShimPolicy(
                process_handle,
                &is_cmd_exe,
                &is_powershell_exe,
            );
            return .{
                .is_cmd_exe = is_cmd_exe,
                .is_powershell_exe = is_powershell_exe,
            };
        }
    };
};
