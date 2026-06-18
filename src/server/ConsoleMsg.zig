const windows = @import("../windows.zig");

pub const CONSOLE_SERVER_MSG = extern struct {
    IconId: windows.ULONG,
    HotKey: windows.ULONG,
    StartupFlags: windows.ULONG,
    FillAttribute: windows.USHORT,
    ShowWindow: windows.USHORT,
    ScreenBufferSize: windows.COORD,
    WindowSize: windows.COORD,
    WindowOrigin: windows.COORD,
    ProcessGroupId: windows.ULONG,
    ConsoleApp: windows.BOOLEAN,
    WindowVisible: windows.BOOLEAN,
    TitleLength: windows.USHORT,
    Title: [windows.MAX_PATH + 1]windows.WCHAR,
    ApplicationNameLength: windows.USHORT,
    ApplicationName: [128]windows.WCHAR,
    CurrentDirectoryLength: windows.USHORT,
    CurrentDirectory: [windows.MAX_PATH + 1]windows.WCHAR,
};

pub const CONSOLE_MSG_HEADER = extern struct {
    ApiNumber: windows.ULONG,
    ApiDescriptorSize: windows.ULONG,
};

// Level 1 APIs
pub const L1 = struct {
    pub const MSG_BODY = extern union {
        GetConsoleCP: CONSOLE_GETCP_MSG,
        GetConsoleMode: CONSOLE_MODE_MSG,
        SetConsoleMode: CONSOLE_MODE_MSG,
        GetNumberOfConsoleInputEvents: CONSOLE_GETNUMBEROFINPUTEVENTS_MSG,
        GetConsoleInput: CONSOLE_GETCONSOLEINPUT_MSG,
        ReadConsole: CONSOLE_READCONSOLE_MSG,
        WriteConsole: CONSOLE_WRITECONSOLE_MSG,
        GetConsoleLangId: CONSOLE_LANGID_MSG,
        // Deprecated.
        MapBitmap: CONSOLE_MAPBITMAP_MSG,
    };

    pub const CONSOLE_GETCP_MSG = extern struct {
        CodePage: windows.ULONG,
        Output: windows.BOOLEAN,
    };
    pub const CONSOLE_MODE_MSG = extern struct {
        Mode: windows.ULONG,
    };
    pub const CONSOLE_GETNUMBEROFINPUTEVENTS_MSG = extern struct {
        ReadyEvents: windows.ULONG,
    };
    pub const CONSOLE_GETCONSOLEINPUT_MSG = extern struct {
        NumRecords: windows.ULONG,
        Flags: windows.USHORT,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_READCONSOLE_MSG = extern struct {
        Unicode: windows.BOOLEAN,
        ProcessControlZ: windows.BOOLEAN,
        ExeNameLength: windows.USHORT,
        InitialNumBytes: windows.ULONG,
        CtrlWakeupMask: windows.ULONG,
        ControlKeyState: windows.ULONG,
        NumBytes: windows.ULONG,
    };
    pub const CONSOLE_WRITECONSOLE_MSG = extern struct {
        NumBytes: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_LANGID_MSG = extern struct {
        LangId: windows.LANGID,
    };
    pub const CONSOLE_MAPBITMAP_MSG = extern struct {
        Mutex: windows.HANDLE,
        Bitmap: windows.PVOID,
    };
};

// Level 2 APIs

pub const L2 = extern struct {
    pub const MSG_BODY = extern union {
        GenerateConsoleCtrlEvent: CONSOLE_CTRLEVENT_MSG,
        FillConsoleOutput: CONSOLE_FILLCONSOLEOUTPUT_MSG,
        SetConsoleCP: CONSOLE_SETCP_MSG,
        GetConsoleCursorInfo: CONSOLE_GETCURSORINFO_MSG,
        SetConsoleCursorInfo: CONSOLE_SETCURSORINFO_MSG,
        GetConsoleScreenBufferInfo: CONSOLE_SCREENBUFFERINFO_MSG,
        SetConsoleScreenBufferInfo: CONSOLE_SCREENBUFFERINFO_MSG,
        SetConsoleScreenBufferSize: CONSOLE_SETSCREENBUFFERSIZE_MSG,
        SetConsoleCursorPosition: CONSOLE_SETCURSORPOSITION_MSG,
        GetLargestConsoleWindowSize: CONSOLE_GETLARGESTWINDOWSIZE_MSG,
        ScrollConsoleScreenBuffer: CONSOLE_SCROLLSCREENBUFFER_MSG,
        SetConsoleTextAttribute: CONSOLE_SETTEXTATTRIBUTE_MSG,
        SetConsoleWindowInfo: CONSOLE_SETWINDOWINFO_MSG,
        ReadConsoleOutputString: CONSOLE_READCONSOLEOUTPUTSTRING_MSG,
        WriteConsoleInput: CONSOLE_WRITECONSOLEINPUT_MSG,
        WriteConsoleOutputString: CONSOLE_WRITECONSOLEOUTPUTSTRING_MSG,
        WriteConsoleOutput: CONSOLE_WRITECONSOLEOUTPUT_MSG,
        ReadConsoleOutput: CONSOLE_READCONSOLEOUTPUT_MSG,
        SetConsoleTitle: CONSOLE_SETTITLE_MSG,
        GetConsoleTitle: CONSOLE_GETTITLE_MSG,
    };

    pub const CONSOLE_CTRLEVENT_MSG = extern struct {
        CtrlEvent: windows.ULONG,
        ProcessGroupId: windows.ULONG,
    };
    pub const CONSOLE_FILLCONSOLEOUTPUT_MSG = extern struct {
        WriteCoord: windows.COORD,
        ElementType: windows.ULONG,
        Element: windows.USHORT,
        Length: windows.ULONG,
    };
    pub const CONSOLE_SETCP_MSG = extern struct {
        CodePage: windows.ULONG,
        Output: windows.BOOLEAN,
    };
    pub const CONSOLE_GETCURSORINFO_MSG = extern struct {
        CursorSize: windows.ULONG,
        Visible: windows.BOOLEAN,
    };
    pub const CONSOLE_SETCURSORINFO_MSG = extern struct {
        CursorSize: windows.ULONG,
        Visible: windows.BOOLEAN,
    };
    pub const CONSOLE_SCREENBUFFERINFO_MSG = extern struct {
        Size: windows.COORD,
        CursorPosition: windows.COORD,
        ScrollPosition: windows.COORD,
        Attributes: windows.USHORT,
        CurrentWindowSize: windows.COORD,
        MaximumWindowSize: windows.COORD,
        PopupAttributes: windows.USHORT,
        FullscreenSupported: windows.BOOLEAN,
        ColorTable: [16]windows.COLORREF,
    };
    pub const CONSOLE_SETSCREENBUFFERSIZE_MSG = extern struct {
        Size: windows.COORD,
    };
    pub const CONSOLE_SETCURSORPOSITION_MSG = extern struct {
        CursorPosition: windows.COORD,
    };
    pub const CONSOLE_GETLARGESTWINDOWSIZE_MSG = extern struct {
        Size: windows.COORD,
    };
    pub const CONSOLE_SCROLLSCREENBUFFER_MSG = extern struct {
        ScrollRectangle: windows.SMALL_RECT,
        ClipRectangle: windows.SMALL_RECT,
        Clip: windows.BOOLEAN,
        Unicode: windows.BOOLEAN,
        DestinationOrigin: windows.COORD,
        Fill: windows.CHAR_INFO,
    };
    pub const CONSOLE_SETTEXTATTRIBUTE_MSG = extern struct {
        Attributes: windows.USHORT,
    };
    pub const CONSOLE_SETWINDOWINFO_MSG = extern struct {
        Absolute: windows.BOOLEAN,
        Window: windows.SMALL_RECT,
    };
    pub const CONSOLE_READCONSOLEOUTPUTSTRING_MSG = extern struct {
        ReadCoord: windows.COORD,
        StringType: windows.ULONG,
        NumRecords: windows.ULONG,
    };
    pub const CONSOLE_WRITECONSOLEINPUT_MSG = extern struct {
        NumRecords: windows.ULONG,
        Unicode: windows.BOOLEAN,
        Append: windows.BOOLEAN,
    };
    pub const CONSOLE_WRITECONSOLEOUTPUTSTRING_MSG = extern struct {
        WriteCoord: windows.COORD,
        StringType: windows.ULONG,
        NumRecords: windows.ULONG,
    };
    pub const CONSOLE_WRITECONSOLEOUTPUT_MSG = extern struct {
        CharRegion: windows.SMALL_RECT,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_READCONSOLEOUTPUT_MSG = extern struct {
        CharRegion: windows.SMALL_RECT,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_SETTITLE_MSG = extern struct {
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETTITLE_MSG = extern struct {
        TitleLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
        Original: windows.BOOLEAN,
    };
};

pub const L3 = struct {
    pub const MSG_BODY = extern union {
        // Deprecated.
        GetNumberOfConsoleFonts: CONSOLE_GETNUMBEROFFONTS_MSG,
        GetConsoleMouseInfo: CONSOLE_GETMOUSEINFO_MSG,
        // Deprecated.
        GetConsoleFontInfo: CONSOLE_GETFONTINFO_MSG,
        GetConsoleFontSize: CONSOLE_GETFONTSIZE_MSG,
        GetCurrentConsoleFont: CONSOLE_CURRENTFONT_MSG,
        // Deprecated.
        SetConsoleFont: CONSOLE_SETFONT_MSG,
        // Deprecated.
        InvalidateConsoleBitmapRect: CONSOLE_INVALIDATERECT_MSG,
        // Deprecated.
        VDMConsoleOperation: CONSOLE_VDM_MSG,
        // Deprecated.
        ShowConsoleCursor: CONSOLE_SHOWCURSOR_MSG,
        SetConsoleDisplayMode: CONSOLE_SETDISPLAYMODE_MSG,
        // Deprecated.
        RegisterConsoleVDM: CONSOLE_REGISTERVDM_MSG,
        // Deprecated.
        SetConsoleCursor: CONSOLE_SETCURSOR_MSG,
        // Deprecated.
        SetConsoleIcon: CONSOLE_SETICON_MSG,
        // Deprecated.
        ConsoleMenuControl: CONSOLE_MENUCONTROL_MSG,
        // Deprecated.
        SetConsolePalette: CONSOLE_SETPALETTE_MSG,
        GetConsoleWindow: CONSOLE_GETCONSOLEWINDOW_MSG,
        // Deprecated.
        GetConsoleHardwareState: CONSOLE_GETHARDWARESTATE_MSG,
        // Deprecated.
        SetConsoleHardwareState: CONSOLE_SETHARDWARESTATE_MSG,
        GetConsoleDisplayMode: CONSOLE_GETDISPLAYMODE_MSG,
        AddConsoleAliasW: CONSOLE_ADDALIAS_MSG,
        GetConsoleAliasW: CONSOLE_GETALIAS_MSG,
        GetConsoleAliasesLengthW: CONSOLE_GETALIASESLENGTH_MSG,
        GetConsoleAliasExesLengthW: CONSOLE_GETALIASEXESLENGTH_MSG,
        GetConsoleAliasesW: CONSOLE_GETALIASES_MSG,
        GetConsoleAliasExesW: CONSOLE_GETALIASEXES_MSG,
        ExpungeConsoleCommandHistoryW: CONSOLE_EXPUNGECOMMANDHISTORY_MSG,
        SetConsoleNumberOfCommandsW: CONSOLE_SETNUMBEROFCOMMANDS_MSG,
        GetConsoleCommandHistoryLengthW: CONSOLE_GETCOMMANDHISTORYLENGTH_MSG,
        GetConsoleCommandHistoryW: CONSOLE_GETCOMMANDHISTORY_MSG,
        // Deprecated.
        SetConsoleKeyShortcuts: CONSOLE_SETKEYSHORTCUTS_MSG,
        // Deprecated.
        SetConsoleMenuClose: CONSOLE_SETMENUCLOSE_MSG,
        // Deprecated.
        GetKeyboardLayoutName: CONSOLE_GETKEYBOARDLAYOUTNAME_MSG,
        // Deprecated.
        GetConsoleCharType: CONSOLE_CHAR_TYPE_MSG,
        // Deprecated.
        SetConsoleLocalEUDC: CONSOLE_LOCAL_EUDC_MSG,
        // Deprecated.
        SetConsoleCursorMode: CONSOLE_CURSOR_MODE_MSG,
        // Deprecated.
        GetConsoleCursorMode: CONSOLE_CURSOR_MODE_MSG,
        // Deprecated.
        RegisterConsoleOS2: CONSOLE_REGISTEROS2_MSG,
        // Deprecated.
        SetConsoleOS2OemFormat: CONSOLE_SETOS2OEMFORMAT_MSG,
        // Deprecated.
        GetConsoleNlsMode: CONSOLE_NLS_MODE_MSG,
        // Deprecated.
        SetConsoleNlsMode: CONSOLE_NLS_MODE_MSG,
        GetConsoleSelectionInfo: CONSOLE_GETSELECTIONINFO_MSG,
        GetConsoleProcessList: CONSOLE_GETCONSOLEPROCESSLIST_MSG,
        SetCurrentConsoleFont: CONSOLE_CURRENTFONT_MSG,
        SetConsoleHistory: CONSOLE_HISTORY_MSG,
        GetConsoleHistory: CONSOLE_HISTORY_MSG,
        WslzBootstrap: CONSOLE_WSLZ_BOOTSTRAP_MSG,
        WslzSetInteropMode: CONSOLE_WSLZ_SET_INTEROP_MODE_MSG,
    };

    pub const CONSOLE_GETNUMBEROFFONTS_MSG = extern struct {
        NumberOfFonts: windows.ULONG,
    };
    pub const CONSOLE_GETMOUSEINFO_MSG = extern struct {
        NumButtons: windows.ULONG,
    };
    pub const CONSOLE_GETFONTINFO_MSG = extern struct {
        MaximumWindow: windows.BOOLEAN,
        NumFonts: windows.ULONG,
    };
    pub const CONSOLE_GETFONTSIZE_MSG = extern struct {
        FontIndex: windows.ULONG,
        FontSize: windows.COORD,
    };
    pub const CONSOLE_CURRENTFONT_MSG = extern struct {
        MaximumWindow: windows.BOOLEAN,
        FontIndex: windows.ULONG,
        FontSize: windows.COORD,
        FontFamily: windows.ULONG,
        FontWeight: windows.ULONG,
        FaceName: [windows.LF_FACESIZE]windows.WCHAR,
    };
    pub const CONSOLE_SETFONT_MSG = extern struct {
        FontIndex: windows.ULONG,
    };
    pub const CONSOLE_SETICON_MSG = extern struct {
        hIcon: windows.HICON,
    };
    pub const CONSOLE_ADDALIAS_MSG = extern struct {
        SourceLength: windows.USHORT,
        TargetLength: windows.USHORT,
        ExeLength: windows.USHORT,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETALIAS_MSG = extern struct {
        SourceLength: windows.USHORT,
        TargetLength: windows.USHORT,
        ExeLength: windows.USHORT,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETALIASESLENGTH_MSG = extern struct {
        AliasesLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETALIASEXESLENGTH_MSG = extern struct {
        AliasExesLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETALIASES_MSG = extern struct {
        Unicode: windows.BOOLEAN,
        AliasesBufferLength: windows.ULONG,
    };
    pub const CONSOLE_GETALIASEXES_MSG = extern struct {
        AliasExesBufferLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_EXPUNGECOMMANDHISTORY_MSG = extern struct {
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_SETNUMBEROFCOMMANDS_MSG = extern struct {
        NumCommands: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETCOMMANDHISTORYLENGTH_MSG = extern struct {
        CommandHistoryLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_GETCOMMANDHISTORY_MSG = extern struct {
        CommandBufferLength: windows.ULONG,
        Unicode: windows.BOOLEAN,
    };
    pub const CONSOLE_INVALIDATERECT_MSG = extern struct {
        Rect: windows.SMALL_RECT,
    };
    pub const CONSOLE_VDM_MSG = extern struct {
        iFunction: windows.ULONG,
        Bool: windows.BOOLEAN,
        Point: windows.POINT,
        Rect: windows.RECT,
    };
    pub const CONSOLE_SETCURSOR_MSG = extern struct {
        CursorHandle: windows.HCURSOR,
    };
    pub const CONSOLE_SHOWCURSOR_MSG = extern struct {
        bShow: windows.BOOLEAN,
        DisplayCount: windows.ULONG,
    };
    pub const CONSOLE_MENUCONTROL_MSG = extern struct {
        CommandIdLow: windows.ULONG,
        CommandIdHigh: windows.ULONG,
        hMenu: windows.HMENU,
    };
    pub const CONSOLE_SETPALETTE_MSG = extern struct {
        hPalette: windows.HPALETTE,
        dwUsage: windows.ULONG,
    };
    pub const CONSOLE_SETDISPLAYMODE_MSG = extern struct {
        dwFlags: windows.ULONG,
        ScreenBufferDimensions: windows.COORD,
    };
    pub const CONSOLE_REGISTERVDM_MSG = extern struct {
        RegisterFlags: windows.ULONG,
        StartEvent: windows.HANDLE,
        EndEvent: windows.HANDLE,
        ErrorEvent: windows.HANDLE,
        StateLength: windows.ULONG,
        StateBuffer: windows.PVOID,
        VDMBuffer: windows.PVOID,
    };
    pub const CONSOLE_GETHARDWARESTATE_MSG = extern struct {
        Resolution: windows.COORD,
        FontSize: windows.COORD,
    };
    pub const CONSOLE_SETHARDWARESTATE_MSG = extern struct {
        Resolution: windows.COORD,
        FontSize: windows.COORD,
    };
    pub const CONSOLE_GETDISPLAYMODE_MSG = extern struct {
        ModeFlags: windows.ULONG,
    };
    pub const CONSOLE_GETKEYBOARDLAYOUTNAME_MSG = extern struct {
        Layout: extern union { awchLayout: [9]windows.WCHAR, achLayout: [9]windows.CHAR },
        bAnsi: windows.BOOLEAN,
    };
    pub const CONSOLE_SETKEYSHORTCUTS_MSG = extern struct {
        Set: windows.BOOLEAN,
        ReserveKeys: windows.BYTE,
    };
    pub const CONSOLE_SETMENUCLOSE_MSG = extern struct {
        Enable: windows.BOOLEAN,
    };
    pub const CONSOLE_CHAR_TYPE_MSG = extern struct {
        coordCheck: windows.COORD,
        dwType: windows.ULONG,
    };
    pub const CONSOLE_LOCAL_EUDC_MSG = extern struct {
        CodePoint: windows.USHORT,
        FontSize: windows.COORD,
    };
    pub const CONSOLE_CURSOR_MODE_MSG = extern struct {
        Blink: windows.BOOLEAN,
        DBEnable: windows.BOOLEAN,
    };
    pub const CONSOLE_REGISTEROS2_MSG = extern struct {
        fOs2Register: windows.BOOLEAN,
    };
    pub const CONSOLE_SETOS2OEMFORMAT_MSG = extern struct {
        fOs2OemFormat: windows.BOOLEAN,
    };
    pub const CONSOLE_NLS_MODE_MSG = extern struct {
        Ready: windows.BOOLEAN,
        NlsMode: windows.ULONG,
    };
    pub const CONSOLE_GETCONSOLEWINDOW_MSG = extern struct {
        hwnd: ?windows.HWND,
    };
    pub const CONSOLE_GETSELECTIONINFO_MSG = extern struct {
        SelectionInfo: windows.CONSOLE_SELECTION_INFO,
    };
    pub const CONSOLE_GETCONSOLEPROCESSLIST_MSG = extern struct {
        dwProcessCount: windows.ULONG,
    };
    pub const CONSOLE_HISTORY_MSG = extern struct {
        HistoryBufferSize: windows.ULONG,
        NumberOfHistoryBuffers: windows.ULONG,
        dwFlags: windows.ULONG,
    };
    /// Used by wslz.exe to start the WSL integration.
    pub const CONSOLE_WSLZ_BOOTSTRAP_MSG = extern struct {
        /// Token to authenticate WSLZ_SET_INTEROP_MODE calls
        token: [16]u8,
        /// Number of bytes written to portName
        portNameLength: windows.USHORT,
        /// The ALPC port to transfer handles through.
        portName: [64]windows.WCHAR,
    };
    /// Used to wslz.exe to notify interop state changes.
    pub const CONSOLE_WSLZ_SET_INTEROP_MODE_MSG = extern struct {
        /// Token to authenticate the call
        token: [16]u8,
        /// Whether Windows interop mode is active.
        /// This is used to switch input paths to ConDrv
        /// instead of directly writing input to the WSL socket
        windowsInterop: windows.BOOLEAN,
    };
};

pub const CONSOLE_CREATESCREENBUFFER_MSG = extern struct {
    Flags: windows.ULONG,
    BitmapInfoLength: windows.ULONG,
    Usage: windows.ULONG,
};
