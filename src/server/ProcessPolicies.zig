//! Process-scoped policy helpers shared by server state.

const std = @import("std");
const windows = @import("../windows.zig");
const utils = @import("../utils.zig");

const handleIsValid = utils.handleIsValid;
const log = std.log.scoped(.conpty_process_policy);

pub fn applyConsoleAccessPolicy(
    process_handle: windows.HANDLE,
    can_read_output_buffer: *bool,
    can_write_input_buffer: *bool,
) void {
    const allows_console_buffer_access = !isWrongWayBlocked(process_handle);
    can_read_output_buffer.* = allows_console_buffer_access;
    can_write_input_buffer.* = allows_console_buffer_access;
}

pub fn applyConsoleShimPolicy(
    process_handle: windows.HANDLE,
    is_cmd_exe: *bool,
    is_powershell_exe: *bool,
) void {
    var path_buf: [1024]windows.WCHAR = undefined;
    var path_len: windows.DWORD = path_buf.len;
    if (windows.QueryFullProcessImageNameW(
        process_handle,
        0,
        @ptrCast(path_buf[0..].ptr),
        &path_len,
    ) == .FALSE) {
        return;
    }

    const exe_name = fileNameSlice(path_buf[0..path_len]);
    is_cmd_exe.* = eqlAsciiCaseInsensitiveW(exe_name, "cmd.exe");
    const is_windows_powershell = eqlAsciiCaseInsensitiveW(exe_name, "powershell.exe");
    const is_pwsh = eqlAsciiCaseInsensitiveW(exe_name, "pwsh.exe");
    is_powershell_exe.* = is_windows_powershell or is_pwsh;
}

fn isWrongWayBlocked(process_handle: windows.HANDLE) bool {
    var token_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    if (windows.OpenProcessToken(process_handle, windows.TOKEN_READ, &token_handle) == .FALSE) {
        return true;
    }
    defer {
        if (handleIsValid(token_handle)) {
            _ = windows.NtClose(token_handle);
        }
    }

    var is_wrong_way_blocked = true;
    checkAppModelPolicy(token_handle, &is_wrong_way_blocked) catch |err| {
        log.warn("checkAppModelPolicy failed: {}", .{err});
        return true;
    };

    if (!is_wrong_way_blocked) {
        checkIntegrityLevelPolicy(token_handle, &is_wrong_way_blocked) catch |err| {
            log.warn("checkIntegrityLevelPolicy failed: {}", .{err});
            return true;
        };
    }

    return is_wrong_way_blocked;
}

fn checkAppModelPolicy(
    token_handle: windows.HANDLE,
    is_wrong_way_blocked: *bool,
) !void {
    var is_app_container: windows.DWORD = 0;
    var return_len: windows.DWORD = 0;

    if (windows.GetTokenInformation(
        token_handle,
        .TokenIsAppContainer,
        &is_app_container,
        @sizeOf(windows.DWORD),
        &return_len,
    ) == .FALSE) {
        return error.GetTokenInformationFailed;
    }

    is_wrong_way_blocked.* = is_app_container != 0;
}

fn checkIntegrityLevelPolicy(
    other_token_handle: windows.HANDLE,
    is_wrong_way_blocked: *bool,
) !void {
    const our_process = windows.GetCurrentProcess();

    var our_token_handle: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    if (windows.OpenProcessToken(our_process, windows.TOKEN_READ, &our_token_handle) == .FALSE) {
        return error.OpenCurrentProcessTokenFailed;
    }
    defer {
        if (handleIsValid(our_token_handle)) {
            _ = windows.NtClose(our_token_handle);
        }
    }

    const our_integrity_rid = try queryIntegrityRid(our_token_handle);
    const other_integrity_rid = try queryIntegrityRid(other_token_handle);

    is_wrong_way_blocked.* = other_integrity_rid < our_integrity_rid;
}

fn queryIntegrityRid(token_handle: windows.HANDLE) !windows.DWORD {
    var return_len: windows.DWORD = 0;
    _ = windows.GetTokenInformation(
        token_handle,
        .TokenIntegrityLevel,
        null,
        0,
        &return_len,
    );

    const last_error_code = @intFromEnum(windows.GetLastError());
    if (last_error_code != 122) return error.GetTokenInformationSizeFailed;

    var token_info_buf: [256]u8 = undefined;
    if (return_len == 0 or return_len > token_info_buf.len) {
        return error.InvalidIntegrityLabelSize;
    }

    if (windows.GetTokenInformation(
        token_handle,
        .TokenIntegrityLevel,
        &token_info_buf,
        return_len,
        &return_len,
    ) == .FALSE) {
        return error.GetTokenInformationFailed;
    }

    const label: *const windows.TOKEN_MANDATORY_LABEL = @ptrCast(@alignCast(&token_info_buf));
    const sid = label.Label.Sid orelse return error.InvalidSid;

    if (windows.IsValidSid(sid) == .FALSE) return error.InvalidSid;

    const subauth_count = windows.GetSidSubAuthorityCount(sid) orelse return error.InvalidSid;
    if (subauth_count.* == 0) return error.InvalidSid;

    const rid_index: windows.DWORD = @as(windows.DWORD, subauth_count.* - 1);
    const rid_ptr = windows.GetSidSubAuthority(sid, rid_index) orelse return error.InvalidSid;
    return rid_ptr.*;
}

fn fileNameSlice(path: []const windows.WCHAR) []const windows.WCHAR {
    var last_sep: usize = 0;
    var found_sep = false;
    for (path, 0..) |ch, i| {
        if (ch == '\\' or ch == '/') {
            last_sep = i + 1;
            found_sep = true;
        }
    }

    if (!found_sep or last_sep >= path.len) {
        return path;
    }
    return path[last_sep..];
}

fn eqlAsciiCaseInsensitiveW(actual_w: []const windows.WCHAR, expected_ascii: []const u8) bool {
    if (actual_w.len != expected_ascii.len) {
        return false;
    }

    for (actual_w, expected_ascii) |aw, ex| {
        const actual = toLowerAsciiW(aw);
        const expected = toLowerAsciiW(@as(windows.WCHAR, ex));
        if (actual != expected) {
            return false;
        }
    }

    return true;
}

fn toLowerAsciiW(ch: windows.WCHAR) windows.WCHAR {
    if (ch >= 'A' and ch <= 'Z') {
        return ch + 32;
    }
    return ch;
}
