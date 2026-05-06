const std = @import("std");
const windows = @import("../windows.zig");
const condrv = @import("Condrv.zig");
const apiMsg = @import("ApiMsg.zig");
const conMsg = @import("ConsoleMsg.zig");
const cdHandler = @import("ConDrvHandler.zig");
const ioCompletion = @import("IoCompletion.zig");
const Input = @import("Input.zig");
const process = @import("Process.zig");
const sessionState = @import("SessionState.zig");
const utf = @import("utf.zig");
const utils = @import("../utils.zig");

const ntSuccess = utils.ntSuccess;
const ConDrvHandler = cdHandler.ConDrvHandler;
const State = sessionState.State;
const Terminal = sessionState.Terminal;
const TextAttributes = sessionState.TextAttributes;
const Handle = process.Process.Handle;
const CONSOLE_DATA_PACKET = apiMsg.CONSOLE_DATA_PACKET;

var empty_write_byte: u8 = 0;

pub const DispatchResult = enum {
    complete,
    pending,
};

pub const ApiHandler = struct {
    state: *State,
    io: *ConDrvHandler,
    input: *Input,

    pub fn init(state: *State, io: *ConDrvHandler, input: *Input) ApiHandler {
        return .{ .state = state, .io = io, .input = input };
    }

    pub fn handleDeprecated(
        _: *ApiHandler,
        _: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        ioCompletion.setStatus(completion, .NOT_IMPLEMENTED);
        return .complete;
    }

    pub fn handleWrite(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const write_message = &message.Body.api_msg.msgBody.consoleMsgL1.WriteConsole;
        ioCompletion.setWriteBuffer(
            completion,
            @ptrCast(write_message),
            @sizeOf(conMsg.L1.CONSOLE_WRITECONSOLE_MSG),
        );

        const payload = self.readInputPayload(message) catch |err| {
            ioCompletion.setStatus(completion, utils.mapError(err));
            return .complete;
        };
        defer self.state.allocator.free(payload);

        if (write_message.Unicode != .FALSE) {
            const utf8 = utf.utf16BytesToUtf8Alloc(self.state.allocator, payload) catch |err| {
                ioCompletion.setStatus(completion, utils.mapError(err));
                return .complete;
            };
            defer self.state.allocator.free(utf8);

            self.feedWriteConsolePayload(utf8) catch |err| {
                ioCompletion.setStatus(completion, utils.mapError(err));
                return .complete;
            };
        } else {
            self.feedWriteConsolePayload(payload) catch |err| {
                ioCompletion.setStatus(completion, utils.mapError(err));
                return .complete;
            };
        }

        self.input.redrawCookedAfterHostOutput();

        write_message.NumBytes = @intCast(payload.len);
        ioCompletion.setSuccessWithInformation(completion, payload.len);
        return .complete;
    }

    pub fn handleGetConsoleMode(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleMode.Mode = self.state.getMode(handle.type);
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleInput(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (handle.type != .Input or !hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const msg = &message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleInput;
        if ((msg.Flags & ~windows.CONSOLE_READ_VALID) != 0) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        return switch (self.input.beginGetConsoleInput(message, completion)) {
            .completed => .complete,
            .pending => .pending,
            .failed => |status| blk: {
                ioCompletion.setStatus(completion, status);
                break :blk .complete;
            },
        };
    }

    pub fn handleGetNumberOfInputEvents(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (handle.type != .Input or !hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        message.Body.api_msg.msgBody.consoleMsgL1.GetNumberOfConsoleInputEvents.ReadyEvents =
            self.input.getNumberOfInputEvents();

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleReadConsole(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (handle.type != .Input or !hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        return switch (self.input.beginReadConsole(message, completion)) {
            .completed => .complete,
            .pending => .pending,
            .failed => |status| blk: {
                ioCompletion.setStatus(completion, status);
                break :blk .complete;
            },
        };
    }

    pub fn handleRawRead(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (handle.type != .Input or !hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        return switch (self.input.beginRawRead(message, completion)) {
            .completed => .complete,
            .pending => .pending,
            .failed => |status| blk: {
                ioCompletion.setStatus(completion, status);
                break :blk .complete;
            },
        };
    }

    pub fn handleGetConsoleCP(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const get_cp_message = &message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleCP;
        get_cp_message.CodePage = self.state.getCodePage(get_cp_message.Output != .FALSE);
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleLangId(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        if (!isEastAsianCodePage(self.state.getCodePage(false))) {
            ioCompletion.setStatus(completion, .NOT_SUPPORTED);
            return .complete;
        }

        message.Body.api_msg.msgBody.consoleMsgL1.GetConsoleLangId.LangId =
            langIdForCodePage(self.state.getCodePage(true));
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleScreenBufferInfo(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        var cols: u16 = undefined;
        var rows: u16 = undefined;
        self.state.terminal.getSize(&cols, &rows);

        var cursor_col: u16 = undefined;
        var cursor_row: u16 = undefined;
        self.state.terminal.getCursorPosition(&cursor_col, &cursor_row);

        const msg = &message.Body.api_msg.msgBody.consoleMsgL2.GetConsoleScreenBufferInfo;
        var palette: [16]Terminal.RGB = undefined;
        self.state.terminal.getBase16Palette(&palette);

        // Buffer size == viewport size (our model has no scrollback for console APIs).
        msg.Size = .{ .X = @intCast(cols), .Y = @intCast(rows) };

        msg.CursorPosition = .{ .X = @intCast(cursor_col), .Y = @intCast(cursor_row) };

        // Viewport window covers the entire buffer (0-indexed, exclusive right/bottom
        // per WT convention — the driver adjusts for GetConsoleScreenBufferInfoEx).
        msg.ScrollPosition = .{ .X = 0, .Y = 0 };
        msg.CurrentWindowSize = .{ .X = @intCast(cols), .Y = @intCast(rows) };
        msg.MaximumWindowSize = .{ .X = @intCast(cols), .Y = @intCast(rows) };

        msg.Attributes = self.state.console.attributes.current.toWord();
        msg.PopupAttributes = self.state.console.attributes.popup.toWord();
        msg.FullscreenSupported = .FALSE;
        for (palette, 0..) |entry, i| {
            msg.ColorTable[i] = entry.toColorRef();
        }

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetConsoleTextAttribute(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const word = message.Body.api_msg.msgBody.consoleMsgL2.SetConsoleTextAttribute.Attributes;
        if ((word & ~windows.VALID_TEXT_ATTRIBUTES) != 0) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        const attributes = TextAttributes.fromWord(word);
        self.state.console.attributes.current = attributes;

        var vt_buf: [32]u8 = undefined;
        const vt = attributes.writeSgr(&vt_buf) catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
        self.feedVt(vt);
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleFillConsoleOutput(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const request = &message.Body.api_msg.msgBody.consoleMsgL2.FillConsoleOutput;
        const requested_len = request.Length;
        request.Length = 0;

        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const start = pointFromCoord(request.WriteCoord) orelse {
            ioCompletion.setSuccess(completion);
            return .complete;
        };

        const enable_powershell_shim = self.state.isPowershellClient(message.Descriptor.Process);

        const written = switch (request.ElementType) {
            0x1 => self.fillConsoleOutputCharacterA(
                completion,
                request.Element,
                requested_len,
                start,
                enable_powershell_shim,
            ) orelse return .complete,
            0x2, 0x4 => self.fillConsoleOutputCharacterW(
                request.Element,
                requested_len,
                start,
                enable_powershell_shim,
            ),
            0x3 => self.fillConsoleOutputAttribute(
                completion,
                request.Element,
                requested_len,
                start,
                enable_powershell_shim,
            ) orelse return .complete,
            else => {
                ioCompletion.setStatus(completion, .INVALID_PARAMETER);
                return .complete;
            },
        };

        request.Length = written;
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleCursorInfo(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        var visible = false;
        self.state.terminal.getCursorVisible(&visible);

        const msg = &message.Body.api_msg.msgBody.consoleMsgL2.GetConsoleCursorInfo;
        msg.CursorSize = self.state.console.cursor.size_percent;
        msg.Visible = if (visible) .TRUE else .FALSE;

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetConsoleCursorPosition(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const cursor = message.Body.api_msg.msgBody.consoleMsgL2.SetConsoleCursorPosition.CursorPosition;
        if (cursor.X < 0 or cursor.Y < 0) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        var cols: u16 = undefined;
        var rows: u16 = undefined;
        self.state.terminal.getSize(&cols, &rows);

        const col: u16 = @intCast(cursor.X);
        const row: u16 = @intCast(cursor.Y);
        if (col >= cols or row >= rows) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        var vt_buf: [32]u8 = undefined;
        const vt = std.fmt.bufPrint(&vt_buf, "\x1b[{d};{d}H", .{ row + 1, col + 1 }) catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
        self.feedVt(vt);
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleScrollConsoleScreenBuffer(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const request = &message.Body.api_msg.msgBody.consoleMsgL2.ScrollConsoleScreenBuffer;
        const enable_cmd_shim = isCmdClient(self, message);
        if (scrollRequestClearsViewport(self, request, enable_cmd_shim)) {
            self.feedVtClear();
        }

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetConsoleCursorInfo(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const cursor_info = message.Body.api_msg.msgBody.consoleMsgL2.SetConsoleCursorInfo;
        if (cursor_info.CursorSize == 0 or cursor_info.CursorSize > 100) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        const visible = cursor_info.Visible != .FALSE;
        self.state.console.cursor.size_percent = cursor_info.CursorSize;

        var current_visible = false;
        self.state.terminal.getCursorVisible(&current_visible);
        if (current_visible != visible) {
            const vt = if (visible) "\x1b[?25h" else "\x1b[?25l";
            self.feedVt(vt);
        }

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetCurrentConsoleFont(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_READ)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        // Return placeholder values to maintain compatiblity with legacy console programs.
        var width_px: u16 = 0;
        var height_px: u16 = 0;
        self.state.terminal.getCellSize(&width_px, &height_px);

        const msg = &message.Body.api_msg.msgBody.consoleMsgL3.GetCurrentConsoleFont;
        msg.FontIndex = 0;
        msg.FontSize = .{
            .X = @intCast(width_px),
            .Y = @intCast(height_px),
        };
        msg.FontFamily = 0x0030;
        msg.FontWeight = 400;
        @memset(msg.FaceName[0..], 0);
        writeFaceName("Consolas", &msg.FaceName);

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetCurrentConsoleFont(
        _: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        // Return placeholder values to maintain compatiblity with legacy console programs.
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetConsoleMode(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (!hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        const requested_mode = message.Body.api_msg.msgBody.consoleMsgL1.SetConsoleMode.Mode;

        const mode_status = consoleModeStatus(handle.type, requested_mode);
        const previous = self.state.console.output_mode;

        // OpenConsole applies the requested input mode before reporting
        // INVALID_PARAMETER. PowerShell/PSReadLine depends on this quirk
        // for its non-line-input prompt behavior, so we mirror it here.
        // Without this, Ctrl+C rendering breaks in Powershell 5.
        if (handle.type == .Input) {
            self.state.setMode(handle.type, requested_mode);
            if (mode_status != .SUCCESS) {
                ioCompletion.setStatus(completion, mode_status);
                return .complete;
            }
        } else {
            if (mode_status != .SUCCESS) {
                ioCompletion.setStatus(completion, mode_status);
                return .complete;
            }
            self.state.setMode(handle.type, requested_mode);
        }

        if (handle.type == .Output) {
            const current = self.state.console.output_mode;
            if (previous.enable_wrap_at_eol_output != current.enable_wrap_at_eol_output) {
                const vt = if (current.enable_wrap_at_eol_output) "\x1b[?7h" else "\x1b[?7l";
                self.feedVt(vt);
            }
        }

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleSetConsoleCP(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const set_cp_message = &message.Body.api_msg.msgBody.consoleMsgL2.SetConsoleCP;
        if (windows.IsValidCodePage(set_cp_message.CodePage) == .FALSE) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        }

        self.state.setCodePage(set_cp_message.Output != .FALSE, set_cp_message.CodePage);
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleFlushConsoleInputBuffer(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const handle = getHandle(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_HANDLE);
            return .complete;
        };

        if (handle.type != .Input or !hasRequiredAccess(handle, windows.GENERIC_WRITE)) {
            ioCompletion.setStatus(completion, .ACCESS_DENIED);
            return .complete;
        }

        self.input.flushInputBuffer();
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleTitle(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const request = &message.Body.api_msg.msgBody.consoleMsgL2.GetConsoleTitle;
        var title_allocator = std.heap.stackFallback(256, self.state.allocator);
        const allocator = title_allocator.get();

        const title = if (request.Original != .FALSE)
            self.state.getOriginalTitle()
        else
            self.copyCurrentTitle(allocator) catch {
                ioCompletion.setStatus(completion, .NO_MEMORY);
                return .complete;
            };
        defer if (request.Original == .FALSE) allocator.free(title);

        const output_capacity = getOutputPayloadCapacity(message) orelse {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return .complete;
        };

        if (request.Unicode != .FALSE) {
            const utf16 = utf.utf8ToUtf16LeAllocZ(self.state.allocator, title) catch {
                ioCompletion.setStatus(completion, .NO_MEMORY);
                return .complete;
            };
            defer self.state.allocator.free(utf16);

            const utf16_no_nul = utf16[0 .. utf16.len - 1];
            request.TitleLength = @intCast(utf16_no_nul.len);

            const copy_len = @min(output_capacity / @sizeOf(windows.WCHAR), utf16_no_nul.len);
            const payload = std.mem.sliceAsBytes(utf16_no_nul[0..copy_len]);
            if (payload.len > 0) {
                self.writeOutput(message, payload) catch {
                    ioCompletion.setStatus(completion, .UNSUCCESSFUL);
                    return .complete;
                };
            }

            ioCompletion.setSuccessWithInformation(completion, payload.len);
            return .complete;
        }

        request.TitleLength = @intCast(title.len);
        const copy_len = @min(output_capacity, title.len);
        if (copy_len > 0) {
            self.writeOutput(message, title[0..copy_len]) catch {
                ioCompletion.setStatus(completion, .UNSUCCESSFUL);
                return .complete;
            };
        }

        ioCompletion.setSuccessWithInformation(completion, copy_len);
        return .complete;
    }

    pub fn handleSetConsoleTitle(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        const request = &message.Body.api_msg.msgBody.consoleMsgL2.SetConsoleTitle;
        const payload = self.readApiPayload(message, @sizeOf(conMsg.L2.CONSOLE_SETTITLE_MSG)) catch |err| {
            ioCompletion.setStatus(completion, utils.mapError(err));
            return .complete;
        };
        defer self.state.allocator.free(payload);

        const title = if (request.Unicode != .FALSE)
            utf.utf16BytesToUtf8Alloc(self.state.allocator, payload) catch |err| {
                ioCompletion.setStatus(completion, utils.mapError(err));
                return .complete;
            }
        else
            self.state.allocator.dupe(u8, payload) catch {
                ioCompletion.setStatus(completion, .NO_MEMORY);
                return .complete;
            };
        defer self.state.allocator.free(title);

        self.state.setOriginalTitleIfUnset(title) catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };

        var writer: std.Io.Writer.Allocating = .init(self.state.allocator);
        defer writer.deinit();
        writer.writer.writeAll("\x1b]0;") catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
        writer.writer.writeAll(title) catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
        writer.writer.writeAll("\x1b\\") catch {
            ioCompletion.setStatus(completion, .NO_MEMORY);
            return .complete;
        };
        self.feedVt(writer.written());
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGetConsoleWindow(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        _ = self;
        // OpenConsole returns a real or pseudo HWND here. We do not have a
        // pseudo-window identity strategy yet, so return null cleanly until
        // that compatibility layer exists.
        message.Body.api_msg.msgBody.consoleMsgL3.GetConsoleWindow.hwnd = null;
        ioCompletion.setSuccess(completion);
        return .complete;
    }

    pub fn handleGenerateConsoleCtrlEvent(
        self: *ApiHandler,
        message: *CONSOLE_DATA_PACKET,
        completion: *condrv.CD_IO_COMPLETE,
    ) DispatchResult {
        _ = self.input;

        const ctrl_event = &message.Body.api_msg.msgBody.consoleMsgL2.GenerateConsoleCtrlEvent;
        switch (ctrl_event.CtrlEvent) {
            windows.CTRL_C_EVENT, windows.CTRL_BREAK_EVENT => {},
            else => {
                ioCompletion.setStatus(completion, .INVALID_PARAMETER);
                return .complete;
            },
        }

        self.state.dispatchControlEvent(
            ctrl_event.CtrlEvent,
            ctrl_event.ProcessGroupId,
        ) catch |err| {
            ioCompletion.setStatus(completion, utils.mapError(err));
            return .complete;
        };

        ioCompletion.setSuccess(completion);
        return .complete;
    }

    fn readInputPayload(self: *ApiHandler, message: *const CONSOLE_DATA_PACKET) ![]u8 {
        const payload_offset: usize = switch (message.Descriptor.Function) {
            condrv.CONSOLE_IO_RAW_WRITE => 0,
            // ziglint-ignore: Z024
            condrv.CONSOLE_IO_USER_DEFINED => @sizeOf(conMsg.CONSOLE_MSG_HEADER) + @sizeOf(conMsg.L1.CONSOLE_WRITECONSOLE_MSG),
            else => return error.InvalidParameter,
        };
        return self.readPayloadAtOffset(message, payload_offset);
    }

    fn readApiPayload(self: *ApiHandler, message: *const CONSOLE_DATA_PACKET, descriptor_size: usize) ![]u8 {
        const payload_offset = @sizeOf(conMsg.CONSOLE_MSG_HEADER) + descriptor_size;
        return self.readPayloadAtOffset(message, payload_offset);
    }

    fn readPayloadAtOffset(self: *ApiHandler, message: *const CONSOLE_DATA_PACKET, payload_offset: usize) ![]u8 {
        const input_size: usize = message.Descriptor.InputSize;
        if (input_size < payload_offset) return error.InvalidParameter;

        const payload_size = input_size - payload_offset;
        const payload = try self.state.allocator.alloc(u8, payload_size);
        errdefer self.state.allocator.free(payload);

        if (payload.len == 0) return payload;

        var operation: condrv.CD_IO_OPERATION = .{
            .Identifier = message.Descriptor.Identifier,
            .Buffer = .{
                .Data = payload.ptr,
                .Size = @intCast(payload.len),
                .Offset = @intCast(payload_offset),
            },
        };
        const status = self.io.readInput(&operation);
        if (!ntSuccess(status)) return error.ReadInputFailed;

        return payload;
    }

    fn getOutputPayloadCapacity(message: *const CONSOLE_DATA_PACKET) ?usize {
        const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
        if (message.Descriptor.OutputSize < write_offset) return null;
        return message.Descriptor.OutputSize - write_offset;
    }

    fn writeOutput(self: *ApiHandler, message: *const CONSOLE_DATA_PACKET, bytes: []const u8) !void {
        const write_offset = message.Body.api_msg.msgHeader.ApiDescriptorSize;
        var operation: condrv.CD_IO_OPERATION = .{
            .Identifier = message.Descriptor.Identifier,
            .Buffer = .{
                .Data = if (bytes.len == 0) &empty_write_byte else @constCast(bytes.ptr),
                .Size = @intCast(bytes.len),
                .Offset = write_offset,
            },
        };
        const status = self.io.writeOutput(&operation);
        if (!ntSuccess(status)) return error.WriteOutputFailed;
    }

    fn copyCurrentTitle(self: *ApiHandler, allocator: std.mem.Allocator) ![]u8 {
        var stack_buf: [256]u8 = undefined;
        const needed = self.state.terminal.getTitle(&stack_buf);
        const buffer = try allocator.alloc(u8, needed);
        const written = self.state.terminal.getTitle(buffer);
        std.debug.assert(written == needed);
        return buffer;
    }

    fn feedVt(self: *ApiHandler, bytes: []const u8) void {
        self.state.terminal.feed(bytes);
    }

    fn feedWriteConsolePayload(
        self: *ApiHandler,
        payload: []const u8,
    ) !void {
        const mode = self.state.console.output_mode;

        // Legacy WriteConsole text uses stored console attributes.
        // VT-processed WriteConsole payloads are fed as a terminal stream, but
        // still need LF->CRLF translation when auto-return is enabled.
        if (mode.enable_virtual_terminal_processing and mode.enable_processed_output) {
            var normalized_vt: std.ArrayList(u8) = .empty;
            defer normalized_vt.deinit(self.state.allocator);

            const vt_bytes = normalizeAutoReturnLineFeeds(
                self.state.allocator,
                payload,
                mode,
                &normalized_vt,
            ) catch return error.OutOfMemory;

            self.feedVt(vt_bytes);
            return;
        }

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(self.state.allocator);

        const bytes = self.normalizeLegacyConsoleWrite(payload, &normalized) catch return error.OutOfMemory;

        var sgr_buf: [32]u8 = undefined;
        const sgr = self.state.console.attributes.current.writeSgr(&sgr_buf) catch return error.OutOfMemory;

        var combined_buf: [256]u8 = undefined;
        if (sgr.len + bytes.len <= combined_buf.len) {
            @memcpy(combined_buf[0..sgr.len], sgr);
            @memcpy(combined_buf[sgr.len .. sgr.len + bytes.len], bytes);
            return self.feedVt(combined_buf[0 .. sgr.len + bytes.len]);
        }

        var fallback = std.heap.stackFallback(256, self.state.allocator);
        const allocator = fallback.get();
        const combined = allocator.alloc(u8, sgr.len + bytes.len) catch return error.OutOfMemory;
        defer allocator.free(combined);

        @memcpy(combined[0..sgr.len], sgr);
        @memcpy(combined[sgr.len..], bytes);
        return self.feedVt(combined);
    }

    fn normalizeLegacyConsoleWrite(
        self: *ApiHandler,
        payload: []const u8,
        normalized: *std.ArrayList(u8),
    ) ![]const u8 {
        const mode = self.state.console.output_mode;
        if (!legacyWriteNeedsNormalization(mode, payload)) {
            return payload;
        }

        std.debug.assert(normalized.items.len == 0);

        try normalized.ensureTotalCapacity(
            self.state.allocator,
            payload.len + countInsertedCarriageReturns(mode, payload),
        );

        if (mode.enable_processed_output) {
            try normalizeProcessedLegacyConsoleWrite(
                self.state.allocator,
                normalized,
                payload,
                mode,
                self.state.getCodePage(true),
            );
        } else {
            try normalizeRawLegacyConsoleWrite(self.state.allocator, normalized, payload);
        }

        return normalized.items;
    }

    fn normalizeAutoReturnLineFeeds(
        allocator: std.mem.Allocator,
        payload: []const u8,
        mode: sessionState.OutputMode,
        normalized: *std.ArrayList(u8),
    ) ![]const u8 {
        if (mode.disable_newline_auto_return) {
            return payload;
        }

        const inserted_carriage_returns = countInsertedCarriageReturns(mode, payload);
        if (inserted_carriage_returns == 0) {
            return payload;
        }

        std.debug.assert(normalized.items.len == 0);

        try normalized.ensureTotalCapacity(allocator, payload.len + inserted_carriage_returns);

        for (payload, 0..) |byte, index| {
            if (byte == '\n') {
                try appendTranslatedLineFeed(allocator, normalized, payload, index, mode);
                continue;
            }

            try normalized.append(allocator, byte);
        }

        return normalized.items;
    }

    fn legacyWriteNeedsNormalization(mode: sessionState.OutputMode, payload: []const u8) bool {
        if (mode.enable_processed_output) {
            for (payload, 0..) |byte, index| {
                if (!isLegacyControlByte(byte)) {
                    continue;
                }

                switch (byte) {
                    0x07, 0x08, 0x09, 0x0D => {},
                    0x0A => {
                        if (mode.disable_newline_auto_return) {
                            continue;
                        }
                        if (index != 0 and payload[index - 1] == '\r') {
                            continue;
                        }
                    },
                    else => {},
                }
                return true;
            }
            return false;
        }

        for (payload) |byte| {
            if (isLegacyControlByte(byte)) {
                return true;
            }
        }
        return false;
    }

    fn countInsertedCarriageReturns(mode: sessionState.OutputMode, payload: []const u8) usize {
        if (mode.disable_newline_auto_return) {
            return 0;
        }

        var count: usize = 0;
        for (payload, 0..) |byte, index| {
            if (byte != '\n') {
                continue;
            }
            if (index != 0 and payload[index - 1] == '\r') {
                continue;
            }
            count += 1;
        }
        return count;
    }

    fn normalizeProcessedLegacyConsoleWrite(
        allocator: std.mem.Allocator,
        normalized: *std.ArrayList(u8),
        payload: []const u8,
        mode: sessionState.OutputMode,
        code_page: windows.UINT,
    ) !void {
        for (payload, 0..) |byte, index| {
            if (!isLegacyControlByte(byte)) {
                try normalized.append(allocator, byte);
                continue;
            }

            switch (byte) {
                0x00 => try normalized.append(allocator, ' '),
                0x07, 0x08, 0x09, 0x0D => try normalized.append(allocator, byte),
                0x0A => {
                    try appendTranslatedLineFeed(allocator, normalized, payload, index, mode);
                },
                else => try appendLegacyControlGlyph(allocator, normalized, code_page, byte),
            }
        }
    }

    fn appendTranslatedLineFeed(
        allocator: std.mem.Allocator,
        normalized: *std.ArrayList(u8),
        payload: []const u8,
        index: usize,
        mode: sessionState.OutputMode,
    ) !void {
        if (mode.disable_newline_auto_return) {
            try normalized.append(allocator, '\n');
            return;
        }
        if (index != 0 and payload[index - 1] == '\r') {
            try normalized.append(allocator, '\n');
            return;
        }

        try normalized.append(allocator, '\r');
        try normalized.append(allocator, '\n');
    }

    fn normalizeRawLegacyConsoleWrite(
        allocator: std.mem.Allocator,
        normalized: *std.ArrayList(u8),
        payload: []const u8,
    ) !void {
        for (payload) |byte| {
            if (isLegacyControlByte(byte)) {
                try normalized.append(allocator, ' ');
                continue;
            }

            try normalized.append(allocator, byte);
        }
    }

    fn appendLegacyControlGlyph(allocator: std.mem.Allocator, normalized: *std.ArrayList(u8), code_page: windows.UINT, byte: u8) !void {
        const code_unit = utf.glyphCharFromControlByte(code_page, byte) orelse return;
        if (code_unit == 0) return;

        var utf8_buf: [4]u8 = undefined;
        const len = utf.encodeCodepointUtf8(code_unit, &utf8_buf) catch return;
        try normalized.appendSlice(allocator, utf8_buf[0..len]);
    }

    fn isLegacyControlByte(byte: u8) bool {
        return byte < 0x20 or byte == 0x7F;
    }

    fn fillConsoleOutputCharacterA(
        self: *ApiHandler,
        completion: *condrv.CD_IO_COMPLETE,
        character: windows.USHORT,
        len: windows.ULONG,
        start: Terminal.Point,
        enable_powershell_shim: bool,
    ) ?windows.ULONG {
        const codepoint = utf.decodeSingleByteCodePageChar(
            self.state.getCodePage(true),
            @truncate(character),
        ) orelse {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return null;
        };
        return self.fillConsoleOutputCharacterCodepoint(
            codepoint,
            len,
            start,
            enable_powershell_shim,
        );
    }

    fn fillConsoleOutputCharacterW(
        self: *ApiHandler,
        character: windows.WCHAR,
        len: windows.ULONG,
        start: Terminal.Point,
        enable_powershell_shim: bool,
    ) windows.ULONG {
        return self.fillConsoleOutputCharacterCodepoint(
            character,
            len,
            start,
            enable_powershell_shim,
        );
    }

    fn fillConsoleOutputCharacterCodepoint(
        self: *ApiHandler,
        codepoint: windows.WCHAR,
        len: windows.ULONG,
        start: Terminal.Point,
        enable_powershell_shim: bool,
    ) windows.ULONG {
        const fill_cell: Terminal.Cell = .{
            .codepoint = codepoint,
            .style = self.state.console.attributes.current.toSurfaceStyle(),
            .width = .narrow,
            ._padding = 0,
        };
        return self.completeFillSpan(
            start,
            len,
            enable_powershell_shim,
            if (codepoint == ' ') .character_space else .none,
            .character,
            fill_cell,
        );
    }

    fn fillConsoleOutputAttribute(
        self: *ApiHandler,
        completion: *condrv.CD_IO_COMPLETE,
        attributes_word: windows.USHORT,
        len: windows.ULONG,
        start: Terminal.Point,
        enable_powershell_shim: bool,
    ) ?windows.ULONG {
        if ((attributes_word & ~windows.VALID_TEXT_ATTRIBUTES) != 0) {
            ioCompletion.setStatus(completion, .INVALID_PARAMETER);
            return null;
        }

        const attributes = TextAttributes.fromWord(attributes_word);
        const fill_cell: Terminal.Cell = .{
            .codepoint = 0,
            .style = attributes.toSurfaceStyle(),
            .width = .narrow,
            ._padding = 0,
        };
        return self.completeFillSpan(
            start,
            len,
            enable_powershell_shim,
            if (attributes_word == windows.DEFAULT_TEXT_ATTRIBUTES) .default_attribute else .none,
            .style,
            fill_cell,
        );
    }

    fn completeFillSpan(
        self: *ApiHandler,
        start: Terminal.Point,
        len: windows.ULONG,
        enable_powershell_shim: bool,
        clear_kind: FillClearKind,
        fill_kind: Terminal.FillKind,
        fill_cell: Terminal.Cell,
    ) windows.ULONG {
        if (enable_powershell_shim and isViewportClear(self, start, len, clear_kind)) {
            if (clear_kind == .character_space) self.feedVtClear();
            return len;
        }

        return @intCast(self.state.terminal.fillSpan(start, len, fill_kind, fill_cell));
    }

    fn feedVtClear(self: *ApiHandler) void {
        self.feedVt("\x1b[H\x1b[2J\x1b[3J");
    }

    fn getHandle(message: *const CONSOLE_DATA_PACKET) ?*Handle {
        const raw = message.Descriptor.Object;
        if (raw == 0) return null;
        return @ptrFromInt(raw);
    }

    fn hasRequiredAccess(handle: *const Handle, required: windows.DWORD) bool {
        const granted: windows.DWORD = @bitCast(handle.access_mask);
        return (granted & required) == required;
    }

    fn consoleModeStatus(handle_type: Handle.HandleType, mode: windows.ULONG) windows.NTSTATUS {
        return switch (handle_type) {
            .Input => inputModeStatus(mode),
            .Output => outputModeStatus(mode),
            .NotReady => .INVALID_PARAMETER,
        };
    }

    fn inputModeStatus(mode: windows.ULONG) windows.NTSTATUS {
        if ((mode & ~(windows.INPUT_MODES | windows.PRIVATE_MODES)) != 0) return .INVALID_PARAMETER;

        if ((mode & windows.ENABLE_ECHO_INPUT) != 0 and (mode & windows.ENABLE_LINE_INPUT) == 0) {
            return .INVALID_PARAMETER;
        }
        return .SUCCESS;
    }

    fn outputModeStatus(mode: windows.ULONG) windows.NTSTATUS {
        if ((mode & ~windows.OUTPUT_MODES) != 0) return .INVALID_PARAMETER;
        return .SUCCESS;
    }

    fn isEastAsianCodePage(code_page: windows.UINT) bool {
        return switch (code_page) {
            windows.CP_JAPANESE,
            windows.CP_CHINESE_SIMPLIFIED,
            windows.CP_KOREAN,
            windows.CP_CHINESE_TRADITIONAL,
            => true,
            else => false,
        };
    }

    fn langIdForCodePage(code_page: windows.UINT) windows.LANGID {
        return switch (code_page) {
            windows.CP_JAPANESE => makeLangId(windows.LANG.JAPANESE, windows.SUBLANG.DEFAULT),
            windows.CP_KOREAN => makeLangId(windows.LANG.KOREAN, windows.SUBLANG.KOREAN),
            windows.CP_CHINESE_SIMPLIFIED => makeLangId(windows.LANG.CHINESE, windows.SUBLANG.CHINESE_SIMPLIFIED),
            windows.CP_CHINESE_TRADITIONAL => makeLangId(windows.LANG.CHINESE, windows.SUBLANG.CHINESE_TRADITIONAL),
            else => makeLangId(windows.LANG.ENGLISH, windows.SUBLANG.ENGLISH_US),
        };
    }

    fn makeLangId(primary: u16, sub: u16) windows.LANGID {
        return (sub << 10) | primary;
    }

    fn pointFromCoord(coord: windows.COORD) ?Terminal.Point {
        if (coord.X < 0 or coord.Y < 0) return null;
        return .{ .x = @intCast(coord.X), .y = @intCast(coord.Y) };
    }

    const FillClearKind = enum {
        none,
        character_space,
        default_attribute,
    };

    fn isViewportClear(
        self: *ApiHandler,
        start: Terminal.Point,
        len: windows.ULONG,
        clear_kind: FillClearKind,
    ) bool {
        if (clear_kind == .none) return false;
        if (start.x != 0 or start.y != 0) return false;

        var cols: u16 = 0;
        var rows: u16 = 0;
        self.state.terminal.getSize(&cols, &rows);
        const viewport_area = @as(windows.ULONG, cols) * @as(windows.ULONG, rows);
        if (len != viewport_area) return false;

        return true;
    }

    fn scrollRequestClearsViewport(
        self: *ApiHandler,
        request: *const conMsg.L2.CONSOLE_SCROLLSCREENBUFFER_MSG,
        enable_cmd_shim: bool,
    ) bool {
        if (!enable_cmd_shim) return false;
        if (request.Clip != .FALSE) return false;
        if (request.DestinationOrigin.X != 0) return false;

        const scroll = request.ScrollRectangle;
        if (scroll.Left != 0 or scroll.Top != 0) return false;

        var cols: u16 = 0;
        var rows: u16 = 0;
        self.state.terminal.getSize(&cols, &rows);
        if (cols == 0 or rows == 0) return false;

        if (scroll.Right < cols - 1 or scroll.Bottom < rows - 1) return false;
        if (request.DestinationOrigin.Y > -@as(windows.SHORT, @intCast(rows))) return false;

        const fill_char, const fill_attributes = normalizedScrollFill(request, self.state.console.attributes.current.toWord());
        if (fill_char != ' ') return false;
        if (fill_attributes != self.state.console.attributes.current.toWord()) return false;

        return true;
    }

    fn normalizedScrollFill(
        request: *const conMsg.L2.CONSOLE_SCROLLSCREENBUFFER_MSG,
        current_attributes: windows.WORD,
    ) struct { windows.WCHAR, windows.WORD } {
        var fill_char: windows.WCHAR = if (request.Unicode != .FALSE)
            request.Fill.Char.UnicodeChar
        else
            request.Fill.Char.AsciiChar;
        var fill_attributes = request.Fill.Attributes;

        if (fill_char == 0 and fill_attributes == 0) {
            fill_attributes = current_attributes;
        }

        if (fill_char == 0) {
            fill_char = ' ';
        }

        return .{ fill_char, fill_attributes };
    }

    fn isCmdClient(self: *ApiHandler, message: *const CONSOLE_DATA_PACKET) bool {
        return self.state.isCmdClient(message.Descriptor.Process);
    }

    fn writeFaceName(comptime text: []const u8, buffer: *[windows.LF_FACESIZE]windows.WCHAR) void {
        const utf16 = utf.utf8ToUtf16LeStringLiteral(text);
        const len = @min(std.mem.len(utf16), buffer.len - 1);
        @memcpy(buffer[0..len], utf16[0..len]);
    }

    test "input mode status preserves the PowerShell compatibility quirk" {
        try std.testing.expectEqual(windows.NTSTATUS.INVALID_PARAMETER, inputModeStatus(0x1e4));
    }

    test "legacy processed write converts lf to crlf" {
        const mode: sessionState.OutputMode = .{
            .enable_processed_output = true,
            .enable_wrap_at_eol_output = true,
            .enable_virtual_terminal_processing = false,
            .disable_newline_auto_return = false,
            .enable_lvb_grid_worldwide = false,
            ._reserved = 0,
        };

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        try normalizeProcessedLegacyConsoleWrite(
            std.testing.allocator,
            &normalized,
            "a\nb\r\nc",
            mode,
            windows.GetOEMCP(),
        );

        try std.testing.expectEqualStrings("a\r\nb\r\nc", normalized.items);
    }

    test "legacy processed write keeps lf when auto-return disabled" {
        const mode: sessionState.OutputMode = .{
            .enable_processed_output = true,
            .enable_wrap_at_eol_output = true,
            .enable_virtual_terminal_processing = false,
            .disable_newline_auto_return = true,
            .enable_lvb_grid_worldwide = false,
            ._reserved = 0,
        };

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        try normalizeProcessedLegacyConsoleWrite(
            std.testing.allocator,
            &normalized,
            "a\nb",
            mode,
            windows.GetOEMCP(),
        );

        try std.testing.expectEqualStrings("a\nb", normalized.items);
    }

    test "legacy processed write preserves console control bytes" {
        const mode: sessionState.OutputMode = .{
            .enable_processed_output = true,
            .enable_wrap_at_eol_output = true,
            .enable_virtual_terminal_processing = false,
            .disable_newline_auto_return = false,
            .enable_lvb_grid_worldwide = false,
            ._reserved = 0,
        };

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        try normalizeProcessedLegacyConsoleWrite(
            std.testing.allocator,
            &normalized,
            "\x07\x08\t\r",
            mode,
            windows.GetOEMCP(),
        );

        try std.testing.expectEqualStrings("\x07\x08\t\r", normalized.items);
    }

    test "legacy raw write replaces controls with spaces" {
        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        try normalizeRawLegacyConsoleWrite(std.testing.allocator, &normalized, "a\n\t\x08\x00b");

        try std.testing.expectEqualStrings("a    b", normalized.items);
    }

    test "vt processed write converts lf to crlf" {
        const mode: sessionState.OutputMode = .{
            .enable_processed_output = true,
            .enable_wrap_at_eol_output = true,
            .enable_virtual_terminal_processing = true,
            .disable_newline_auto_return = false,
            .enable_lvb_grid_worldwide = false,
            ._reserved = 0,
        };

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        const output = try normalizeAutoReturnLineFeeds(
            std.testing.allocator,
            "a\nb\r\nc",
            mode,
            &normalized,
        );

        try std.testing.expectEqualStrings("a\r\nb\r\nc", output);
    }

    test "vt processed write keeps lf when auto-return disabled" {
        const mode: sessionState.OutputMode = .{
            .enable_processed_output = true,
            .enable_wrap_at_eol_output = true,
            .enable_virtual_terminal_processing = true,
            .disable_newline_auto_return = true,
            .enable_lvb_grid_worldwide = false,
            ._reserved = 0,
        };

        var normalized: std.ArrayList(u8) = .empty;
        defer normalized.deinit(std.testing.allocator);

        const output = try normalizeAutoReturnLineFeeds(
            std.testing.allocator,
            "a\nb",
            mode,
            &normalized,
        );

        try std.testing.expectEqualStrings("a\nb", output);
    }
};
