const std = @import("std");
const condrv = @import("Condrv.zig");
const windows = @import("../windows.zig");
const cdHandler = @import("ConDrvHandler.zig");
const ioCompletion = @import("IoCompletion.zig");
const sessionState = @import("SessionState.zig");
const process = @import("Process.zig");

const apiMsg = @import("ApiMsg.zig");
const consoleMsg = @import("ConsoleMsg.zig");
const apiHandler = @import("ApiHandler.zig");
const Input = @import("Input.zig");
const utils = @import("../utils.zig");
const ConDrvHandler = cdHandler.ConDrvHandler;
const CONSOLE_DATA_PACKET = apiMsg.CONSOLE_DATA_PACKET;
const CONSOLE_MSG_HEADER = consoleMsg.CONSOLE_MSG_HEADER;
const State = sessionState.State;
const Handle = process.Process.Handle;
const ntSuccess = utils.ntSuccess;

pub const DispatchResult = apiHandler.DispatchResult;

pub const Context = struct {
    state: *State,
    io: *ConDrvHandler,
    input: *Input,
};

pub fn handleRead(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    var handler = apiHandler.ApiHandler.init(context.state, context.io, context.input);
    return handler.handleRawRead(message, completion);
}

pub fn handleWrite(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    message.Body.api_msg.msgBody.consoleMsgL1.WriteConsole = std.mem.zeroes(consoleMsg.L1.CONSOLE_WRITECONSOLE_MSG);

    var handler = apiHandler.ApiHandler.init(context.state, context.io, context.input);
    return handler.handleWrite(message, completion);
}

pub fn handleConnect(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    const pid: windows.DWORD = @truncate(message.Descriptor.Process);
    const tid: windows.DWORD = @truncate(message.Descriptor.Object);

    var connect_msg: consoleMsg.CONSOLE_SERVER_MSG = undefined;
    const connect_status = parseConnectInfo(message, context.io, &connect_msg);
    if (!ntSuccess(connect_status)) {
        ioCompletion.setStatus(completion, connect_status);
        return .complete;
    }

    const process_handle = windows.OpenProcess(windows.MAXIMUM_ALLOWED, .FALSE, pid);

    const process_entry = context.state.registerProcess(
        pid,
        tid,
        connect_msg.ProcessGroupId,
        process_handle,
    ) catch |err| {
        ioCompletion.setStatus(completion, switch (err) {
            error.OutOfMemory => .NO_MEMORY,
            error.SessionClosing => .UNSUCCESSFUL,
        });
        return .complete;
    };

    if (process_entry.input_handle == null) {
        const access_mask: windows.ACCESS_MASK = @bitCast(@as(
            windows.DWORD,
            windows.GENERIC_READ | windows.GENERIC_WRITE,
        ));
        const share_access: windows.FILE.SHARE = @bitCast(@as(
            windows.DWORD,
            windows.FILE_SHARE_READ | windows.FILE_SHARE_WRITE,
        ));

        process_entry.input_handle = context.state.createHandle(
            access_mask,
            share_access,
            .Input,
            null,
        ) catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };

        process_entry.output_handle = context.state.createHandle(
            access_mask,
            share_access,
            .Output,
            null,
        ) catch {
            context.state.destroyHandle(process_entry.input_handle.?);
            process_entry.input_handle = null;
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
    }

    process_entry.connection_info = .{
        .Process = @intFromPtr(process_entry),
        .Input = @intFromPtr(process_entry.input_handle.?),
        .Output = @intFromPtr(process_entry.output_handle.?),
    };

    ioCompletion.setWriteBuffer(
        completion,
        @ptrCast(&process_entry.connection_info),
        @sizeOf(condrv.CD_CONNECTION_INFORMATION),
    );
    ioCompletion.setSuccessWithInformation(completion, @sizeOf(condrv.CD_CONNECTION_INFORMATION));
    return .complete;
}

fn parseConnectInfo(
    message: *const CONSOLE_DATA_PACKET,
    io: *ConDrvHandler,
    connect_msg: *consoleMsg.CONSOLE_SERVER_MSG,
) windows.NTSTATUS {
    if (message.Descriptor.InputSize < @sizeOf(consoleMsg.CONSOLE_SERVER_MSG)) {
        return .INVALID_PARAMETER;
    }

    var operation: condrv.CD_IO_OPERATION = .{
        .Identifier = message.Descriptor.Identifier,
        .Buffer = .{
            .Data = @ptrCast(connect_msg),
            .Size = @intCast(@sizeOf(consoleMsg.CONSOLE_SERVER_MSG)),
            .Offset = 0,
        },
    };
    const status = io.readInput(&operation);
    if (!ntSuccess(status)) {
        return status;
    }

    if (!isValidConnectString(connect_msg.ApplicationNameLength, &connect_msg.ApplicationName) or
        !isValidConnectString(connect_msg.TitleLength, &connect_msg.Title) or
        !isValidConnectString(connect_msg.CurrentDirectoryLength, &connect_msg.CurrentDirectory))
    {
        return .INVALID_PARAMETER;
    }

    return .SUCCESS;
}

fn isValidConnectString(length_bytes: windows.USHORT, buffer: []const windows.WCHAR) bool {
    if (length_bytes % @sizeOf(windows.WCHAR) != 0) return false;

    const max_length_bytes = @sizeOf(windows.WCHAR) * (buffer.len - 1);
    if (length_bytes > max_length_bytes) return false;

    const terminator_index = @as(usize, length_bytes) / @sizeOf(windows.WCHAR);
    return buffer[terminator_index] == 0;
}

pub fn handleDisconnect(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    _ = context.state.unregisterProcessByClientPointer(message.Descriptor.Process);

    ioCompletion.setSuccess(completion);
    return .complete;
}

pub fn handleFlush(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) DispatchResult {
    _ = message;
    ioCompletion.setUnsupported(completion);
    return .complete;
}

pub fn handleCreateObject(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    const create_info = &message.Body.object_msg.CreateObject;

    var object_type = create_info.ObjectType;
    if (object_type == condrv.CD_IO_OBJECT_TYPE_GENERIC) {
        const desired_access: windows.DWORD = @bitCast(create_info.DesiredAccess);
        const read_write_mask = windows.GENERIC_READ | windows.GENERIC_WRITE;
        switch (desired_access & read_write_mask) {
            windows.GENERIC_READ => object_type = condrv.CD_IO_OBJECT_TYPE_CURRENT_INPUT,
            windows.GENERIC_WRITE => object_type = condrv.CD_IO_OBJECT_TYPE_CURRENT_OUTPUT,
            else => {},
        }
    }

    const handle_type = switch (object_type) {
        condrv.CD_IO_OBJECT_TYPE_CURRENT_INPUT => Handle.HandleType.Input,
        condrv.CD_IO_OBJECT_TYPE_CURRENT_OUTPUT => Handle.HandleType.Output,
        else => {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        },
    };

    const share_access: windows.FILE.SHARE = @bitCast(create_info.ShareMode);
    const handle = context.state.createHandle(
        create_info.DesiredAccess,
        share_access,
        handle_type,
        null,
    ) catch {
        ioCompletion.setStatus(completion, .NO_MEMORY);
        return .complete;
    };

    ioCompletion.setSuccessWithInformation(completion, @intFromPtr(handle));
    return .complete;
}

pub fn handleCloseObject(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    const handle_ptr: windows.ULONG_PTR = message.Descriptor.Object;
    if (handle_ptr != 0) {
        const handle: *Handle = @ptrFromInt(handle_ptr);
        context.state.destroyHandle(handle);
    }

    ioCompletion.setSuccess(completion);
    return .complete;
}

pub fn handleUnknown(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
) DispatchResult {
    _ = message;
    ioCompletion.setUnsupported(completion);
    return .complete;
}

pub const ApiNumber = enum(u32) {
    // Layer 1
    get_cp = 0x01000000,
    get_mode = 0x01000001,
    set_mode = 0x01000002,
    get_number_of_input_events = 0x01000003,
    get_console_input = 0x01000004,
    read_console = 0x01000005,
    write_console = 0x01000006,
    // Deprecated.
    notify_last_close = 0x01000007,
    get_lang_id = 0x01000008,
    // Deprecated.
    map_bitmap = 0x01000009,
    // Layer 2
    fill_console_output = 0x02000000,
    generate_ctrl_event = 0x02000001,
    set_active_screen_buffer = 0x02000002,
    flush_input_buffer = 0x02000003,
    set_cp = 0x02000004,
    get_cursor_info = 0x02000005,
    set_cursor_info = 0x02000006,
    get_screen_buffer_info = 0x02000007,
    set_screen_buffer_info = 0x02000008,
    set_screen_buffer_size = 0x02000009,
    set_cursor_position = 0x0200000a,
    get_largest_window_size = 0x0200000b,
    scroll_screen_buffer = 0x0200000c,
    set_text_attribute = 0x0200000d,
    set_window_info = 0x0200000e,
    read_console_output_string = 0x0200000f,
    write_console_input = 0x02000010,
    write_console_output = 0x02000011,
    write_console_output_string = 0x02000012,
    read_console_output = 0x02000013,
    get_title = 0x02000014,
    set_title = 0x02000015,
    // Layer 3
    // Deprecated.
    get_number_of_fonts = 0x03000000,
    get_mouse_info = 0x03000001,
    // Deprecated.
    get_font_info = 0x03000002,
    get_font_size = 0x03000003,
    get_current_font = 0x03000004,
    // Deprecated.
    set_font = 0x03000005,
    // Deprecated.
    set_icon = 0x03000006,
    // Deprecated.
    invalidate_bitmap_rect = 0x03000007,
    // Deprecated.
    vdm_operation = 0x03000008,
    // Deprecated.
    set_cursor = 0x03000009,
    // Deprecated.
    show_cursor = 0x0300000a,
    // Deprecated.
    menu_control = 0x0300000b,
    // Deprecated.
    set_palette = 0x0300000c,
    set_display_mode = 0x0300000d,
    // Deprecated.
    register_vdm = 0x0300000e,
    // Deprecated.
    get_hardware_state = 0x0300000f,
    // Deprecated.
    set_hardware_state = 0x03000010,
    get_display_mode = 0x03000011,
    add_alias = 0x03000012,
    get_alias = 0x03000013,
    get_aliases_length = 0x03000014,
    get_aliasExes_length = 0x03000015,
    get_aliases = 0x03000016,
    get_aliasExes = 0x03000017,
    expunge_command_history = 0x03000018,
    set_number_of_commands = 0x03000019,
    get_command_history_length = 0x0300001a,
    get_command_history = 0x0300001b,
    // Deprecated.
    set_key_shortcuts = 0x0300001c,
    // Deprecated.
    set_menu_close = 0x0300001d,
    // Deprecated.
    get_keyboard_layout_name = 0x0300001e,
    get_console_window = 0x0300001f,
    // Deprecated.
    char_type = 0x03000020,
    // Deprecated.
    set_local_eudc = 0x03000021,
    // Deprecated.
    set_cursor_mode = 0x03000022,
    // Deprecated.
    get_cursor_mode = 0x03000023,
    // Deprecated.
    register_OS2 = 0x03000024,
    // Deprecated.
    set_oS2_oem_format = 0x03000025,
    // Deprecated.
    get_nls_mode = 0x03000026,
    // Deprecated.
    set_nls_mode = 0x03000027,
    get_selection_info = 0x03000028,
    get_console_process_list = 0x03000029,
    get_history = 0x0300002a,
    set_history = 0x0300002b,
    set_current_font = 0x0300002c,
};

fn requiredDescriptorSize(api_number: windows.ULONG) ?windows.ULONG {
    // Keep this validator in sync with handleDispatch(). It runs before the
    // handler switch, so any API omitted here is rejected as ILLEGAL_FUNCTION
    // even if the handler exists below.
    return switch (api_number) {
        // Layer 1
        @intFromEnum(ApiNumber.get_cp) => @sizeOf(consoleMsg.L1.CONSOLE_GETCP_MSG),
        @intFromEnum(ApiNumber.get_mode) => @sizeOf(consoleMsg.L1.CONSOLE_MODE_MSG),
        @intFromEnum(ApiNumber.set_mode) => @sizeOf(consoleMsg.L1.CONSOLE_MODE_MSG),
        @intFromEnum(ApiNumber.get_number_of_input_events) => @sizeOf(consoleMsg.L1.CONSOLE_GETNUMBEROFINPUTEVENTS_MSG),
        @intFromEnum(ApiNumber.get_console_input) => @sizeOf(consoleMsg.L1.CONSOLE_GETCONSOLEINPUT_MSG),
        @intFromEnum(ApiNumber.read_console) => @sizeOf(consoleMsg.L1.CONSOLE_READCONSOLE_MSG),
        @intFromEnum(ApiNumber.write_console) => @sizeOf(consoleMsg.L1.CONSOLE_WRITECONSOLE_MSG),
        @intFromEnum(ApiNumber.notify_last_close) => 0,
        @intFromEnum(ApiNumber.get_lang_id) => @sizeOf(consoleMsg.L1.CONSOLE_LANGID_MSG),
        @intFromEnum(ApiNumber.map_bitmap) => @sizeOf(consoleMsg.L1.CONSOLE_MAPBITMAP_MSG),

        // Layer 2
        @intFromEnum(ApiNumber.fill_console_output) => @sizeOf(consoleMsg.L2.CONSOLE_FILLCONSOLEOUTPUT_MSG),
        @intFromEnum(ApiNumber.generate_ctrl_event) => @sizeOf(consoleMsg.L2.CONSOLE_CTRLEVENT_MSG),
        @intFromEnum(ApiNumber.set_active_screen_buffer) => 0,
        @intFromEnum(ApiNumber.flush_input_buffer) => 0,
        @intFromEnum(ApiNumber.set_cp) => @sizeOf(consoleMsg.L2.CONSOLE_SETCP_MSG),
        @intFromEnum(ApiNumber.get_cursor_info) => @sizeOf(consoleMsg.L2.CONSOLE_GETCURSORINFO_MSG),
        @intFromEnum(ApiNumber.set_cursor_info) => @sizeOf(consoleMsg.L2.CONSOLE_SETCURSORINFO_MSG),
        @intFromEnum(ApiNumber.get_screen_buffer_info) => @sizeOf(consoleMsg.L2.CONSOLE_SCREENBUFFERINFO_MSG),
        @intFromEnum(ApiNumber.set_screen_buffer_info) => @sizeOf(consoleMsg.L2.CONSOLE_SCREENBUFFERINFO_MSG),
        @intFromEnum(ApiNumber.set_screen_buffer_size) => @sizeOf(consoleMsg.L2.CONSOLE_SETSCREENBUFFERSIZE_MSG),
        @intFromEnum(ApiNumber.set_cursor_position) => @sizeOf(consoleMsg.L2.CONSOLE_SETCURSORPOSITION_MSG),
        @intFromEnum(ApiNumber.get_largest_window_size) => @sizeOf(consoleMsg.L2.CONSOLE_GETLARGESTWINDOWSIZE_MSG),
        @intFromEnum(ApiNumber.scroll_screen_buffer) => @sizeOf(consoleMsg.L2.CONSOLE_SCROLLSCREENBUFFER_MSG),
        @intFromEnum(ApiNumber.set_text_attribute) => @sizeOf(consoleMsg.L2.CONSOLE_SETTEXTATTRIBUTE_MSG),
        @intFromEnum(ApiNumber.set_window_info) => @sizeOf(consoleMsg.L2.CONSOLE_SETWINDOWINFO_MSG),
        @intFromEnum(ApiNumber.read_console_output_string) => @sizeOf(consoleMsg.L2.CONSOLE_READCONSOLEOUTPUTSTRING_MSG),
        @intFromEnum(ApiNumber.write_console_input) => @sizeOf(consoleMsg.L2.CONSOLE_WRITECONSOLEINPUT_MSG),
        @intFromEnum(ApiNumber.write_console_output) => @sizeOf(consoleMsg.L2.CONSOLE_WRITECONSOLEOUTPUT_MSG),
        @intFromEnum(ApiNumber.write_console_output_string) => @sizeOf(consoleMsg.L2.CONSOLE_WRITECONSOLEOUTPUTSTRING_MSG),
        @intFromEnum(ApiNumber.read_console_output) => @sizeOf(consoleMsg.L2.CONSOLE_READCONSOLEOUTPUT_MSG),
        @intFromEnum(ApiNumber.get_title) => @sizeOf(consoleMsg.L2.CONSOLE_GETTITLE_MSG),
        @intFromEnum(ApiNumber.set_title) => @sizeOf(consoleMsg.L2.CONSOLE_SETTITLE_MSG),

        // Layer 3
        @intFromEnum(ApiNumber.get_number_of_fonts) => @sizeOf(consoleMsg.L3.CONSOLE_GETNUMBEROFFONTS_MSG),
        @intFromEnum(ApiNumber.get_mouse_info) => @sizeOf(consoleMsg.L3.CONSOLE_GETMOUSEINFO_MSG),
        @intFromEnum(ApiNumber.get_font_info) => @sizeOf(consoleMsg.L3.CONSOLE_GETFONTINFO_MSG),
        @intFromEnum(ApiNumber.get_font_size) => @sizeOf(consoleMsg.L3.CONSOLE_GETFONTSIZE_MSG),
        @intFromEnum(ApiNumber.get_current_font) => @sizeOf(consoleMsg.L3.CONSOLE_CURRENTFONT_MSG),
        @intFromEnum(ApiNumber.set_font) => @sizeOf(consoleMsg.L3.CONSOLE_SETFONT_MSG),
        @intFromEnum(ApiNumber.set_icon) => @sizeOf(consoleMsg.L3.CONSOLE_SETICON_MSG),
        @intFromEnum(ApiNumber.invalidate_bitmap_rect) => @sizeOf(consoleMsg.L3.CONSOLE_INVALIDATERECT_MSG),
        @intFromEnum(ApiNumber.vdm_operation) => @sizeOf(consoleMsg.L3.CONSOLE_VDM_MSG),
        @intFromEnum(ApiNumber.set_cursor) => @sizeOf(consoleMsg.L3.CONSOLE_SETCURSOR_MSG),
        @intFromEnum(ApiNumber.show_cursor) => @sizeOf(consoleMsg.L3.CONSOLE_SHOWCURSOR_MSG),
        @intFromEnum(ApiNumber.menu_control) => @sizeOf(consoleMsg.L3.CONSOLE_MENUCONTROL_MSG),
        @intFromEnum(ApiNumber.set_palette) => @sizeOf(consoleMsg.L3.CONSOLE_SETPALETTE_MSG),
        @intFromEnum(ApiNumber.set_display_mode) => @sizeOf(consoleMsg.L3.CONSOLE_SETDISPLAYMODE_MSG),
        @intFromEnum(ApiNumber.register_vdm) => @sizeOf(consoleMsg.L3.CONSOLE_REGISTERVDM_MSG),
        @intFromEnum(ApiNumber.get_hardware_state) => @sizeOf(consoleMsg.L3.CONSOLE_GETHARDWARESTATE_MSG),
        @intFromEnum(ApiNumber.set_hardware_state) => @sizeOf(consoleMsg.L3.CONSOLE_SETHARDWARESTATE_MSG),
        @intFromEnum(ApiNumber.get_display_mode) => @sizeOf(consoleMsg.L3.CONSOLE_GETDISPLAYMODE_MSG),
        @intFromEnum(ApiNumber.add_alias) => @sizeOf(consoleMsg.L3.CONSOLE_ADDALIAS_MSG),
        @intFromEnum(ApiNumber.get_alias) => @sizeOf(consoleMsg.L3.CONSOLE_GETALIAS_MSG),
        @intFromEnum(ApiNumber.get_aliases_length) => @sizeOf(consoleMsg.L3.CONSOLE_GETALIASESLENGTH_MSG),
        @intFromEnum(ApiNumber.get_aliasExes_length) => @sizeOf(consoleMsg.L3.CONSOLE_GETALIASEXESLENGTH_MSG),
        @intFromEnum(ApiNumber.get_aliases) => @sizeOf(consoleMsg.L3.CONSOLE_GETALIASES_MSG),
        @intFromEnum(ApiNumber.get_aliasExes) => @sizeOf(consoleMsg.L3.CONSOLE_GETALIASEXES_MSG),
        @intFromEnum(ApiNumber.expunge_command_history) => @sizeOf(consoleMsg.L3.CONSOLE_EXPUNGECOMMANDHISTORY_MSG),
        @intFromEnum(ApiNumber.set_number_of_commands) => @sizeOf(consoleMsg.L3.CONSOLE_SETNUMBEROFCOMMANDS_MSG),
        @intFromEnum(ApiNumber.get_command_history_length) => @sizeOf(consoleMsg.L3.CONSOLE_GETCOMMANDHISTORYLENGTH_MSG),
        @intFromEnum(ApiNumber.get_command_history) => @sizeOf(consoleMsg.L3.CONSOLE_GETCOMMANDHISTORY_MSG),
        @intFromEnum(ApiNumber.set_key_shortcuts) => @sizeOf(consoleMsg.L3.CONSOLE_SETKEYSHORTCUTS_MSG),
        @intFromEnum(ApiNumber.set_menu_close) => @sizeOf(consoleMsg.L3.CONSOLE_SETMENUCLOSE_MSG),
        @intFromEnum(ApiNumber.get_keyboard_layout_name) => @sizeOf(consoleMsg.L3.CONSOLE_GETKEYBOARDLAYOUTNAME_MSG),
        @intFromEnum(ApiNumber.get_console_window) => @sizeOf(consoleMsg.L3.CONSOLE_GETCONSOLEWINDOW_MSG),
        @intFromEnum(ApiNumber.char_type) => @sizeOf(consoleMsg.L3.CONSOLE_CHAR_TYPE_MSG),
        @intFromEnum(ApiNumber.set_local_eudc) => @sizeOf(consoleMsg.L3.CONSOLE_LOCAL_EUDC_MSG),
        @intFromEnum(ApiNumber.set_cursor_mode) => @sizeOf(consoleMsg.L3.CONSOLE_CURSOR_MODE_MSG),
        @intFromEnum(ApiNumber.get_cursor_mode) => @sizeOf(consoleMsg.L3.CONSOLE_CURSOR_MODE_MSG),
        @intFromEnum(ApiNumber.register_OS2) => @sizeOf(consoleMsg.L3.CONSOLE_REGISTEROS2_MSG),
        @intFromEnum(ApiNumber.set_oS2_oem_format) => @sizeOf(consoleMsg.L3.CONSOLE_SETOS2OEMFORMAT_MSG),
        @intFromEnum(ApiNumber.get_nls_mode) => @sizeOf(consoleMsg.L3.CONSOLE_NLS_MODE_MSG),
        @intFromEnum(ApiNumber.set_nls_mode) => @sizeOf(consoleMsg.L3.CONSOLE_NLS_MODE_MSG),
        @intFromEnum(ApiNumber.get_selection_info) => @sizeOf(consoleMsg.L3.CONSOLE_GETSELECTIONINFO_MSG),
        @intFromEnum(ApiNumber.get_console_process_list) => @sizeOf(consoleMsg.L3.CONSOLE_GETCONSOLEPROCESSLIST_MSG),
        @intFromEnum(ApiNumber.get_history) => @sizeOf(consoleMsg.L3.CONSOLE_HISTORY_MSG),
        @intFromEnum(ApiNumber.set_history) => @sizeOf(consoleMsg.L3.CONSOLE_HISTORY_MSG),
        @intFromEnum(ApiNumber.set_current_font) => @sizeOf(consoleMsg.L3.CONSOLE_CURRENTFONT_MSG),

        else => null,
    };
}

pub fn handleDispatch(
    message: *CONSOLE_DATA_PACKET,
    completion: *condrv.CD_IO_COMPLETE,
    context: *const Context,
) DispatchResult {
    const raw_api_number = message.Body.api_msg.msgHeader.ApiNumber;
    const required_size = requiredDescriptorSize(raw_api_number) orelse {
        ioCompletion.setStatus(completion, .ILLEGAL_FUNCTION);
        return .complete;
    };
    const api_number: ApiNumber = @enumFromInt(raw_api_number);

    const descriptor_size = message.Body.api_msg.msgHeader.ApiDescriptorSize;
    if (message.Descriptor.InputSize < @sizeOf(CONSOLE_MSG_HEADER) or
        descriptor_size > @sizeOf(@TypeOf(message.Body)) or
        descriptor_size > (message.Descriptor.InputSize - @sizeOf(CONSOLE_MSG_HEADER)) or
        descriptor_size < required_size)
    {
        ioCompletion.setStatus(completion, .ILLEGAL_FUNCTION);
        return .complete;
    }

    ioCompletion.setWriteBuffer(
        completion,
        @ptrCast(&message.Body.api_msg.msgBody),
        descriptor_size,
    );
    ioCompletion.setUnsupported(completion);

    var handler = apiHandler.ApiHandler.init(context.state, context.io, context.input);

    return switch (api_number) {
        // Layer 1
        .get_cp => handler.handleGetConsoleCP(message, completion),
        .get_mode => handler.handleGetConsoleMode(message, completion),
        .set_mode => handler.handleSetConsoleMode(message, completion),
        .get_number_of_input_events => handler.handleGetNumberOfInputEvents(message, completion),
        .get_console_input => handler.handleGetConsoleInput(message, completion),
        .read_console => handler.handleReadConsole(message, completion),
        .write_console => handler.handleWrite(message, completion),
        .notify_last_close => handler.handleDeprecated(message, completion),
        .get_lang_id => handler.handleGetConsoleLangId(message, completion),
        .map_bitmap => handler.handleDeprecated(message, completion),
        // Layer 2
        .fill_console_output => handler.handleFillConsoleOutput(message, completion),
        .generate_ctrl_event => handler.handleGenerateConsoleCtrlEvent(message, completion),
        .set_active_screen_buffer => .complete,
        .flush_input_buffer => handler.handleFlushConsoleInputBuffer(message, completion),
        .set_cp => handler.handleSetConsoleCP(message, completion),
        .get_cursor_info => handler.handleGetConsoleCursorInfo(message, completion),
        .set_cursor_info => handler.handleSetConsoleCursorInfo(message, completion),
        .get_screen_buffer_info => handler.handleGetConsoleScreenBufferInfo(message, completion),
        .set_screen_buffer_info => .complete,
        .set_screen_buffer_size => .complete,
        .set_cursor_position => handler.handleSetConsoleCursorPosition(message, completion),
        .get_largest_window_size => .complete,
        .scroll_screen_buffer => handler.handleScrollConsoleScreenBuffer(message, completion),
        .set_text_attribute => handler.handleSetConsoleTextAttribute(message, completion),
        .set_window_info => .complete,
        .read_console_output_string => .complete,
        .write_console_input => .complete,
        .write_console_output => .complete,
        .write_console_output_string => .complete,
        .read_console_output => .complete,
        .get_title => handler.handleGetConsoleTitle(message, completion),
        .set_title => handler.handleSetConsoleTitle(message, completion),
        // Layer 3
        .get_number_of_fonts => handler.handleDeprecated(message, completion),
        .get_mouse_info => .complete,
        .get_font_info => handler.handleDeprecated(message, completion),
        .get_font_size => .complete,
        .get_current_font => handler.handleGetCurrentConsoleFont(message, completion),
        .set_font => handler.handleDeprecated(message, completion),
        .set_icon => handler.handleDeprecated(message, completion),
        .invalidate_bitmap_rect => handler.handleDeprecated(message, completion),
        .vdm_operation => handler.handleDeprecated(message, completion),
        .set_cursor => handler.handleDeprecated(message, completion),
        .show_cursor => handler.handleDeprecated(message, completion),
        .menu_control => handler.handleDeprecated(message, completion),
        .set_palette => handler.handleDeprecated(message, completion),
        .set_display_mode => .complete,
        .register_vdm => handler.handleDeprecated(message, completion),
        .get_hardware_state => handler.handleDeprecated(message, completion),
        .set_hardware_state => handler.handleDeprecated(message, completion),
        .get_display_mode => .complete,
        .add_alias => .complete,
        .get_alias => .complete,
        .get_aliases_length => .complete,
        .get_aliasExes_length => .complete,
        .get_aliases => .complete,
        .get_aliasExes => .complete,
        .expunge_command_history => .complete,
        .set_number_of_commands => .complete,
        .get_command_history_length => .complete,
        .get_command_history => .complete,
        .set_key_shortcuts => handler.handleDeprecated(message, completion),
        .set_menu_close => handler.handleDeprecated(message, completion),
        .get_keyboard_layout_name => handler.handleDeprecated(message, completion),
        .get_console_window => handler.handleGetConsoleWindow(message, completion),
        .char_type => handler.handleDeprecated(message, completion),
        .set_local_eudc => handler.handleDeprecated(message, completion),
        .set_cursor_mode => handler.handleDeprecated(message, completion),
        .get_cursor_mode => handler.handleDeprecated(message, completion),
        .register_OS2 => handler.handleDeprecated(message, completion),
        .set_oS2_oem_format => handler.handleDeprecated(message, completion),
        .get_nls_mode => handler.handleDeprecated(message, completion),
        .set_nls_mode => handler.handleDeprecated(message, completion),
        .get_selection_info => .complete,
        .get_console_process_list => .complete,
        .get_history => .complete,
        .set_history => .complete,
        .set_current_font => .complete,
    };
}
