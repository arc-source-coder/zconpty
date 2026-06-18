const std = @import("std");
const builtin = @import("builtin");
const windows_new = @import("windows/windows.zig");

pub const WORD = windows_new.WORD;
pub const DWORD = std.os.windows.DWORD;
pub const ULONG = std.os.windows.ULONG;
pub const ULONGLONG = std.os.windows.ULONGLONG;
pub const SIZE_T = std.os.windows.SIZE_T;
pub const GUID = windows_new.GUID;

pub const USHORT = windows_new.USHORT;
pub const MAX_PATH = windows_new.MAX_PATH;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;

pub const AFD = windows_new.AFD;
pub const SOCK = std.os.windows.ws2_32.SOCK;
pub const SOL = std.os.windows.ws2_32.SOL;
pub const SO = std.os.windows.ws2_32.SO;
pub const AF = std.os.windows.ws2_32.AF;
pub const ADDRESS_FAMILY = std.os.windows.ws2_32.ADDRESS_FAMILY;
pub const HV_PROTOCOL_RAW = 1;

pub const SOCKADDR_HV = extern struct {
    Family: ADDRESS_FAMILY = AF.HYPERV,
    Reserved: USHORT,
    /// The target VM
    VmId: GUID,
    /// HV_GUID_VSOCK_TEMPLATE with Data1 = port
    ServiceId: GUID,
};

pub const HV_BIND_STORAGE = extern struct {
    info: AFD.BIND_INFO,
    addr: SOCKADDR_HV,
};

pub const HV_CONNECT_STORAGE = extern struct {
    reserved: [3]usize = @splat(0),
    addr: SOCKADDR_HV,
};

/// 00000000-facb-11e6-bd58-64006a7986d3
pub const HV_GUID_VSOCK_TEMPLATE: GUID = .{
    // Data1 is set to the port to connect to.
    .Data1 = 0x00000000,
    .Data2 = 0xFACB,
    .Data3 = 0x11E6,
    .Data4 = .{ 0xBD, 0x58, 0x64, 0x00, 0x6A, 0x79, 0x86, 0xD3 },
};

/// 00000000-0000-0000-0000-000000000000
pub const HV_GUID_WILDCARD: GUID = .{
    .Data1 = 0x00000000,
    .Data2 = 0x0000,
    .Data3 = 0x0000,
    .Data4 = .{ 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 },
};

pub const E_NOTIMPL = 0x80004001;
pub const STATUS_NOT_IMPLEMENTED = 0x00000001;

pub const COLORREF = windows_new.COLORREF;
pub const LANGID = windows_new.LANGID;

pub const CHAR = windows_new.CHAR;
pub const WCHAR = std.os.windows.WCHAR;
pub const PWSTR = std.os.windows.PWSTR;
pub const LPSTR = std.os.windows.LPSTR;
pub const LPCSTR = std.os.windows.LPCSTR;
pub const LPWSTR = std.os.windows.LPWSTR;
pub const LPCWSTR = std.os.windows.LPCWSTR;

pub const COORD = std.os.windows.COORD;
pub const UNICODE_STRING = windows_new.UNICODE_STRING;

pub const HRESULT = std.os.windows.HRESULT;
pub const NTSTATUS = windows_new.NTSTATUS;
pub const Win32Error = std.os.windows.Win32Error;

pub const PVOID = windows_new.PVOID;

pub const SHORT = windows_new.SHORT;

pub const HANDLE = std.os.windows.HANDLE;
pub const HMODULE = windows_new.HMODULE;
pub const FARPROC = windows_new.FARPROC;
pub const ACCESS_MASK = windows_new.ACCESS_MASK;
pub const IO_STATUS_BLOCK = windows_new.IO_STATUS_BLOCK;
pub const LARGE_INTEGER = windows_new.LARGE_INTEGER;
pub const OBJECT = windows_new.OBJECT;
pub const FILE = windows_new.FILE;

pub const INVALID_HANDLE_VALUE = std.os.windows.INVALID_HANDLE_VALUE;
pub const E_FAIL = std.os.windows.E_FAIL;
pub const E_INVALIDARG = std.os.windows.E_INVALIDARG;
pub const E_OUTOFMEMORY = std.os.windows.E_OUTOFMEMORY;
pub const S_OK = std.os.windows.S_OK;
pub const S_FALSE = std.os.windows.S_FALSE;

pub const TRUE = std.os.windows.TRUE;
pub const FALSE = std.os.windows.FALSE;

pub const OBJ_INHERIT = std.os.windows.OBJ_INHERIT;
pub const OBJ_CASE_INSENSITIVE = std.os.windows.OBJ_CASE_INSENSITIVE;

pub const FILE_SHARE_DELETE = std.os.windows.FILE_SHARE_DELETE;
pub const FILE_SHARE_READ = std.os.windows.FILE_SHARE_READ;
pub const FILE_SHARE_WRITE = std.os.windows.FILE_SHARE_WRITE;
pub const FILE_SYNCHRONOUS_IO_NONALERT = std.os.windows.FILE_SYNCHRONOUS_IO_NONALERT;

pub const PseudoConsole = struct {
    hSignal: HANDLE,
    hPtyReference: HANDLE,
    hConPtyProcess: HANDLE,
};

// NTDLL / Windows API Declarations
// Copied from the Zig 0.16 standard library
// TODO: Replace with standard library declarations after Zig 0.16.0
const ntdll = @import("windows/ntdll.zig");

pub const getSystemDirectoryWtf16Le = windows_new.getSystemDirectoryWtf16Le;

pub const GENERIC_ALL = std.os.windows.GENERIC_ALL;
pub const GENERIC_WRITE = std.os.windows.GENERIC_WRITE;
pub const GENERIC_READ = std.os.windows.GENERIC_READ;
pub const MAXIMUM_ALLOWED = std.os.windows.MAXIMUM_ALLOWED;
pub const SYNCHRONIZE = std.os.windows.SYNCHRONIZE;
pub const WAIT_OBJECT_0 = std.os.windows.WAIT_OBJECT_0;
pub const WAIT_TIMEOUT = std.os.windows.WAIT_TIMEOUT;
pub const INFINITE = std.os.windows.INFINITE;
pub const CTRL_C_EVENT = std.os.windows.CTRL_C_EVENT;
pub const CTRL_BREAK_EVENT = std.os.windows.CTRL_BREAK_EVENT;
pub const CTRL_CLOSE_EVENT = std.os.windows.CTRL_CLOSE_EVENT;
pub const CTRL_LOGOFF_EVENT = std.os.windows.CTRL_LOGOFF_EVENT;
pub const CTRL_SHUTDOWN_EVENT = std.os.windows.CTRL_SHUTDOWN_EVENT;
pub const ENABLE_VIRTUAL_TERMINAL_PROCESSING = std.os.windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING;
pub const DISABLE_NEWLINE_AUTO_RETURN = std.os.windows.DISABLE_NEWLINE_AUTO_RETURN;
pub const BOOLEAN = windows_new.BOOLEAN;
pub const BOOL = windows_new.BOOL;

pub const PROCESS = windows_new.PROCESS;
pub const PEB = windows_new.PEB;

pub const PHANDLER_ROUTINE = ?*const fn (DWORD) callconv(.winapi) BOOL;

pub const NtReadFile = ntdll.NtReadFile;
pub const NtWriteFile = ntdll.NtWriteFile;
pub const NtOpenFile = ntdll.NtOpenFile;
pub const NtCreateFile = ntdll.NtCreateFile;
pub const NtClose = ntdll.NtClose;
pub const NtDeviceIoControlFile = ntdll.NtDeviceIoControlFile;
pub const NtWaitForSingleObject = ntdll.NtWaitForSingleObject;
pub const NtTerminateProcess = ntdll.NtTerminateProcess;
pub const NtCancelSynchronousIoFile = ntdll.NtCancelSynchronousIoFile;
pub const NtCancelIoFileEx = ntdll.NtCancelIoFileEx;
pub const NtQueryInformationProcess = ntdll.NtQueryInformationProcess;
pub const NtQueryInformationFile = ntdll.NtQueryInformationFile;
pub const NtCreateEvent = ntdll.NtCreateEvent;
pub const NtSetEvent = ntdll.NtSetEvent;
pub const NtAlertThread = ntdll.NtAlertThread;
pub const NtQueryObject = ntdll.NtQueryObject;
pub const NtReadVirtualMemory = ntdll.NtReadVirtualMemory;
pub const RtlWaitOnAddress = ntdll.RtlWaitOnAddress;
pub const RtlWakeAddressSingle = ntdll.RtlWakeAddressSingle;
pub const RtlExitUserProcess = ntdll.RtlExitUserProcess;
pub const NtCreateSection = ntdll.NtCreateSection;
pub const NtMapViewOfSection = ntdll.NtMapViewOfSection;
pub const NtUnmapViewOfSection = ntdll.NtUnmapViewOfSection;

pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

pub extern "kernel32" fn SetConsoleCtrlHandler(
    HandlerRoutine: PHANDLER_ROUTINE,
    Add: BOOL,
) callconv(.winapi) BOOL;

pub const ENABLE_PROCESSED_INPUT: ULONG = 0x0001;
pub const ENABLE_LINE_INPUT: ULONG = 0x0002;
pub const ENABLE_ECHO_INPUT: ULONG = 0x0004;
pub const ENABLE_WINDOW_INPUT: ULONG = 0x0008;
pub const ENABLE_MOUSE_INPUT: ULONG = 0x0010;
pub const ENABLE_INSERT_MODE: ULONG = 0x0020;
pub const ENABLE_QUICK_EDIT_MODE: ULONG = 0x0040;
pub const ENABLE_EXTENDED_FLAGS: ULONG = 0x0080;
pub const ENABLE_AUTO_POSITION: ULONG = 0x0100;
pub const ENABLE_VIRTUAL_TERMINAL_INPUT: ULONG = 0x0200;

pub const CONSOLE_CTRL_C_FLAG: ULONG = 0x00000001;
pub const CONSOLE_CTRL_BREAK_FLAG: ULONG = 0x00000002;
pub const CONSOLE_CTRL_CLOSE_FLAG: ULONG = 0x00000004;
pub const CONSOLE_CTRL_LOGOFF_FLAG: ULONG = 0x00000010;
pub const CONSOLE_CTRL_SHUTDOWN_FLAG: ULONG = 0x00000020;

pub const RIGHT_ALT_PRESSED: ULONG = 0x0001;
pub const LEFT_ALT_PRESSED: ULONG = 0x0002;
pub const RIGHT_CTRL_PRESSED: ULONG = 0x0004;
pub const LEFT_CTRL_PRESSED: ULONG = 0x0008;
pub const SHIFT_PRESSED: ULONG = 0x0010;
pub const NUMLOCK_ON: ULONG = 0x0020;
pub const SCROLLLOCK_ON: ULONG = 0x0040;
pub const CAPSLOCK_ON: ULONG = 0x0080;
pub const ENHANCED_KEY: ULONG = 0x0100;

pub const KEY_EVENT: USHORT = 0x0001;
pub const MOUSE_EVENT: USHORT = 0x0002;
pub const WINDOW_BUFFER_SIZE_EVENT: USHORT = 0x0004;
pub const MENU_EVENT: USHORT = 0x0008;
pub const FOCUS_EVENT: USHORT = 0x0010;

pub const FROM_LEFT_1ST_BUTTON_PRESSED: ULONG = 0x0001;
pub const RIGHTMOST_BUTTON_PRESSED: ULONG = 0x0002;
pub const FROM_LEFT_2ND_BUTTON_PRESSED: ULONG = 0x0004;
pub const FROM_LEFT_3RD_BUTTON_PRESSED: ULONG = 0x0008;
pub const FROM_LEFT_4TH_BUTTON_PRESSED: ULONG = 0x0010;
pub const SCROLL_DELTA_BACKWARD: ULONG = 0xFF800000;
pub const SCROLL_DELTA_FORWARD: ULONG = 0x00800000;
pub const DOUBLE_CLICK: ULONG = 0x0002;
pub const MOUSE_MOVED: ULONG = 0x0001;
pub const MOUSE_WHEELED: ULONG = 0x0004;
pub const MOUSE_HWHEELED: ULONG = 0x0008;

pub const INPUT_RECORD = extern struct {
    EventType: USHORT,
    Event: extern union {
        KeyEvent: KEY_EVENT_RECORD,
        MouseEvent: MOUSE_EVENT_RECORD,
        WindowBufferSizeEvent: WINDOW_BUFFER_SIZE_RECORD,
        MenuEvent: MENU_EVENT_RECORD,
        FocusEvent: FOCUS_EVENT_RECORD,
    },
};

pub const KEY_EVENT_RECORD = extern struct {
    bKeyDown: BOOL,
    wRepeatCount: WORD,
    wVirtualKeyCode: WORD,
    wVirtualScanCode: WORD,
    uChar: extern union {
        UnicodeChar: WCHAR,
        AsciiChar: CHAR,
    },
    dwControlKeyState: DWORD,
};

pub const MOUSE_EVENT_RECORD = extern struct {
    dwMousePosition: COORD,
    dwButtonState: DWORD,
    dwControlKeyState: DWORD,
    dwEventFlags: DWORD,
};

pub const WINDOW_BUFFER_SIZE_RECORD = extern struct {
    dwSize: COORD,
};

pub const MENU_EVENT_RECORD = extern struct {
    dwCommandId: UINT,
};

pub const FOCUS_EVENT_RECORD = extern struct {
    bSetFocus: BOOL,
};

pub const ENABLE_PROCESSED_OUTPUT: ULONG = 0x0001;
pub const ENABLE_WRAP_AT_EOL_OUTPUT: ULONG = 0x0002;
pub const ENABLE_LVB_GRID_WORLDWIDE: ULONG = 0x0010;

pub const FOREGROUND_ATTRIBUTES: WORD = 0x000F;
pub const BACKGROUND_ATTRIBUTES: WORD = 0x00F0;
pub const DEFAULT_FOREGROUND_ATTRIBUTES: WORD = 0x0007;
pub const DEFAULT_BACKGROUND_ATTRIBUTES: WORD = 0x0000;
pub const DEFAULT_TEXT_ATTRIBUTES: WORD = DEFAULT_FOREGROUND_ATTRIBUTES | DEFAULT_BACKGROUND_ATTRIBUTES;
pub const DEFAULT_POPUP_ATTRIBUTES: WORD = 0x0005;

pub const LVB = struct {
    pub const LEADING_BYTE: WORD = 0x0100;
    pub const TRAILING_BYTE: WORD = 0x0200;
    pub const GRID_HORIZONTAL: WORD = 0x0400;
    pub const GRID_LEFT_VERTICAL: WORD = 0x0800;
    pub const GRID_RIGHT_VERTICAL: WORD = 0x1000;
    pub const REVERSE_VIDEO: WORD = 0x4000;
    pub const UNDERSCORE: WORD = 0x8000;
};

pub const META_ATTRIBUTES: WORD = LVB.LEADING_BYTE |
    LVB.TRAILING_BYTE |
    LVB.GRID_HORIZONTAL |
    LVB.GRID_LEFT_VERTICAL |
    LVB.GRID_RIGHT_VERTICAL |
    LVB.REVERSE_VIDEO |
    LVB.UNDERSCORE;

pub const VALID_TEXT_ATTRIBUTES: WORD =
    FOREGROUND_ATTRIBUTES | BACKGROUND_ATTRIBUTES | META_ATTRIBUTES;

pub const CONSOLE_READ_NOREMOVE: USHORT = 0x0001;
pub const CONSOLE_READ_NOWAIT: USHORT = 0x0002;
pub const CONSOLE_READ_VALID: USHORT = CONSOLE_READ_NOREMOVE | CONSOLE_READ_NOWAIT;

pub const INPUT_MODES: ULONG = ENABLE_LINE_INPUT |
    ENABLE_PROCESSED_INPUT |
    ENABLE_ECHO_INPUT |
    ENABLE_WINDOW_INPUT |
    ENABLE_MOUSE_INPUT |
    ENABLE_VIRTUAL_TERMINAL_INPUT;

pub const PRIVATE_MODES: ULONG = ENABLE_INSERT_MODE |
    ENABLE_QUICK_EDIT_MODE |
    ENABLE_AUTO_POSITION |
    ENABLE_EXTENDED_FLAGS;

pub const OUTPUT_MODES: ULONG = ENABLE_PROCESSED_OUTPUT |
    ENABLE_WRAP_AT_EOL_OUTPUT |
    ENABLE_VIRTUAL_TERMINAL_PROCESSING |
    DISABLE_NEWLINE_AUTO_RETURN |
    ENABLE_LVB_GRID_WORLDWIDE;

pub const DEFAULT_CONSOLE_INPUT_MODE: ULONG = ENABLE_PROCESSED_INPUT |
    ENABLE_LINE_INPUT |
    ENABLE_ECHO_INPUT |
    ENABLE_MOUSE_INPUT;

pub const DEFAULT_CONSOLE_OUTPUT_MODE: ULONG = ENABLE_PROCESSED_OUTPUT |
    ENABLE_WRAP_AT_EOL_OUTPUT;

pub const CP_JAPANESE: UINT = 932;
pub const CP_CHINESE_SIMPLIFIED: UINT = 936;
pub const CP_KOREAN: UINT = 949;
pub const CP_CHINESE_TRADITIONAL: UINT = 950;

pub const SECURITY_ATTRIBUTES = windows_new.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = windows_new.STARTUPINFOW;
pub const UINT = std.os.windows.UINT;
pub const LANG = std.os.windows.LANG;
pub const SUBLANG = std.os.windows.SUBLANG;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const CONSOLE = windows_new.CONSOLE;

pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
/// This is an undocumented API used by OpenConsole.exe to spawn child processes.
/// Defined in src\server\winbasep.h (inside the WT repo) as:
/// ProcThreadAttributeValue(10, FALSE, TRUE, FALSE)
// Where the macro is:
// ProcThreadAttributeValue (Number, Thread, Input, Additive) =
//   ((Number) & PROC_THREAD_ATTRIBUTE_NUMBER)                      // PTAN = 0x0000FFFF
//   | ((Thread != FALSE) ? PROC_THREAD_ATTRIBUTE_THREAD : 0)       // PTAT = 0x00010000
//   | ((Input != FALSE) ? PROC_THREAD_ATTRIBUTE_INPUT : 0)         // PTAI = 0x00020000
//   | ((Additive != FALSE) ? PROC_THREAD_ATTRIBUTE_ADDITIVE : 0))) // PTAA = 0x00040000
pub const PROC_THREAD_ATTRIBUTE_CONSOLE_REFERENCE: usize = 0x0002000A;
pub const PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY: usize = 0x00020012;

/// Used with PROC_THREAD_ATTRIBUTE_DESKTOP_APP_POLICY
pub const PROCESS_CREATION_DESKTOP_APP_BREAKAWAY_OVERRIDE: usize = 0x04;

pub const CreatePipe = std.os.windows.CreatePipe;
pub const SetHandleInformation = std.os.windows.SetHandleInformation;
pub const GetLastError = std.os.windows.GetLastError;

pub const HANDLE_FLAG_INHERIT = std.os.windows.HANDLE_FLAG_INHERIT;
pub const STARTF_USESTDHANDLES = std.os.windows.STARTF_USESTDHANDLES;
pub const CreateProcessFlags = std.os.windows.CreateProcessFlags;
pub const CREATE_UNICODE_ENVIRONMENT = std.os.windows.CREATE_UNICODE_ENVIRONMENT;
pub const INVALID_FILE_ATTRIBUTES = std.os.windows.INVALID_FILE_ATTRIBUTES;
pub const DUPLICATE_SAME_ACCESS = std.os.windows.DUPLICATE_SAME_ACCESS;
pub const GetCurrentProcess = std.os.windows.GetCurrentProcess;
pub const TOKEN_READ: DWORD = 0x00020008;

pub const TOKEN_INFORMATION_CLASS = enum(u32) {
    TokenIntegrityLevel = 25,
    TokenIsAppContainer = 29,
    _,
};

pub const SID_AND_ATTRIBUTES = extern struct {
    Sid: ?*anyopaque,
    Attributes: DWORD,
};

pub const TOKEN_MANDATORY_LABEL = extern struct {
    Label: SID_AND_ATTRIBUTES,
};

pub const SYSTEM_CONSOLE_INFORMATION_CLASS: u32 = 132;
pub const SYSTEM_CONSOLE_INFORMATION = packed struct(u32) {
    DriverLoaded: u1 = 0,
    Spare: u31 = 0,
};

pub const ULONG64 = windows_new.ULONG64;
pub const LONG = windows_new.LONG;
pub const EVENT_TYPE = windows_new.EVENT_TYPE;

// Locally Unique Identifier
// Defined in winnt.h
pub const LUID = extern struct {
    LowPart: DWORD,
    HighPart: LONG,
};

// Defined in wincon.h
pub const CHAR_INFO = extern struct {
    Char: extern union {
        UnicodeChar: WCHAR,
        AsciiChar: CHAR,
    },
    Attributes: WORD,
};

pub const POINT = std.os.windows.POINT;
pub const RECT = std.os.windows.RECT;

// Defined in wincon.h
pub const SMALL_RECT = extern struct {
    Left: SHORT,
    Top: SHORT,
    Right: SHORT,
    Bottom: SHORT,
};

// Defined in wingdi.h
pub const LF_FACESIZE = 32;

// Defined in wincon.h
pub const CONSOLE_SELECTION_INFO = extern struct {
    dwFlags: DWORD,
    dwSelectionAnchor: COORD,
    srSelection: SMALL_RECT,
};

pub const HICON = windows_new.HICON;
pub const HCURSOR = windows_new.HCURSOR;
// TODO: verify this is correct
pub const HPALETTE = windows_new.HANDLE;

pub const HWND = windows_new.HWND;
pub const BYTE = windows_new.BYTE;
pub const HMENU = windows_new.HMENU;

pub const CTL_CODE = windows_new.CTL_CODE;
pub const IOCTL = windows_new.IOCTL;
pub const CLIENT_ID = windows_new.CLIENT_ID;

pub const IMAGE_SUBSYSTEM = enum(ULONG) {
    UNKNOWN = 0,
    WINDOWS_GUI = 2,
    WINDOWS_CUI = 3,
};

pub const CONSOLEENDTASK = extern struct {
    ProcessId: HANDLE,
    hwnd: ?HWND,
    ConsoleEventCode: ULONG,
    ConsoleFlags: ULONG,
};

pub const CONSOLE_CONTROL_END_TASK: DWORD = 7;

pub extern "ntdll" fn NtSetSystemInformation(
    system_information_class: u32,
    system_information: ?*const anyopaque,
    system_information_length: u32,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtOpenProcess(
    ProcessHandle: *HANDLE,
    DesiredAccess: ACCESS_MASK,
    ObjectAttributes: *const OBJECT.ATTRIBUTES,
    ClientId: ?*const CLIENT_ID,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtAlpcOpenSenderProcess(
    ProcessHandle: *HANDLE,
    PortHandle: HANDLE,
    PortMessage: *PORT_MESSAGE,
    Flags: ALPC.MESSAGE_FLAGS,
    DesiredAccess: ACCESS_MASK,
    ObjectAttributes: *OBJECT.ATTRIBUTES,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtAlpcCreatePort(
    PortHandle: *HANDLE,
    ObjectAttributes: ?*const OBJECT.ATTRIBUTES,
    PortAttributes: ?*ALPC.PORT_ATTRIBUTES,
) callconv(.winapi) NTSTATUS;

pub const QUAD = extern struct {
    Anonymous: extern union {
        UseThisFieldToCopy: i64,
        DoNotUseThisField: f64,
    },
};

pub const unexpectedStatus = std.os.windows.unexpectedStatus;

pub const PORT_MESSAGE = extern struct {
    u1: extern union {
        s1: extern struct {
            DataLength: SHORT,
            TotalLength: SHORT,
        },
        Length: ULONG,
    },
    u2: extern union {
        s2: extern struct {
            Type: SHORT,
            DataInfoOffset: SHORT,
        },
        ZeroInit: ULONG,
    },
    u3: extern union {
        s3: extern union {
            ClientId: CLIENT_ID,
            DoNotUseThisField: QUAD,
        },
    },
    MessageId: ULONG,
    u4: extern union {
        /// Only valid for LPC_CONNECTION_REQUEST messages
        ClientViewSize: SIZE_T,
        /// Only valid for LPC_REQUEST messages
        CallbackID: ULONG,
    },
};

pub const OBJECT_TYPES = packed struct(ULONG) {
    FILE: bool = false,
    INVALID: bool = false,
    THREAD: bool = false,
    SEMAPHORE: bool = false,
    EVENT: bool = false,
    PROCESS: bool = false,
    MUTEX: bool = false,
    SECTION: bool = false,
    REGKEY: bool = false,
    TOKEN: bool = false,
    COMPOSITION: bool = false,
    JOB: bool = false,
    Reserved12: u20 = 0,
};

pub const ALPC = struct {
    /// Ref: https://github.com/microsoft/openvmm
    pub const PORT_FLAGS = packed struct(ULONG) {
        Reserved0: u16 = 0,
        // 0x10000
        ALLOW_IMPERSONATION: bool = false,
        // 0x20000
        ACCEPT_REQUESTS: bool = false,
        // 0x40000
        WAITABLE_PORT: bool = false,
        // 0x80000
        ACCEPT_DUP_HANDLES: bool = false,
        Reserved20: u5 = 0,
        // 0x2000000
        ACCEPT_INDIRECT_HANDLES: bool = false,
        Reserved26: u6 = 0,
    };

    pub const SECURITY_IMPERSONATION_LEVEL = enum(c_int) {
        Anonymous = 0,
        Identification = 1,
        Impersonation = 2,
        Delegation = 3,
    };

    pub const SECURITY_QUALITY_OF_SERVICE = extern struct {
        Length: ULONG = @sizeOf(SECURITY_QUALITY_OF_SERVICE),
        ImpersonationLevel: SECURITY_IMPERSONATION_LEVEL = .Identification,
        ContextTrackingMode: BOOLEAN = .FALSE,
        EffectiveOnly: BOOLEAN = .FALSE,
    };

    /// Defaults based on OpenVhttps://github.com/microsoft/openvmm
    pub const PORT_ATTRIBUTES = extern struct {
        Flags: PORT_FLAGS,
        SecurityQos: SECURITY_QUALITY_OF_SERVICE = .{},
        MaxMessageLength: SIZE_T = @sizeOf(PORT_MESSAGE) + 512,
        MemoryBandwidth: SIZE_T = 0,
        MaxPoolUsage: SIZE_T = std.math.maxInt(usize),
        MaxSectionSize: SIZE_T = std.math.maxInt(usize),
        MaxViewSize: SIZE_T = std.math.maxInt(usize),
        MaxTotalSectionSize: SIZE_T = std.math.maxInt(usize),
        DupObjectTypes: OBJECT_TYPES,
        Reserved: ULONG = 0,
    };

    pub const MESSAGE_ATTRIBUTE_FLAGS = packed struct(ULONG) {
        Reserved0: u28 = 0,
        // 0x10000000
        HANDLE_ATTRIBUTE: bool = false,
        // 0x20000000
        CONTEXT_ATTRIBUTE: bool = false,
        // 0x40000000
        VIEW_ATTRIBUTE: bool = false,
        // 0x80000000
        SECURITY_ATTRIBUTE: bool = false,
    };

    pub const MESSAGE_ATTRIBUTES = extern struct {
        AllocatedAttributes: MESSAGE_ATTRIBUTE_FLAGS,
        ValidAttributes: MESSAGE_ATTRIBUTE_FLAGS,
    };

    pub const MESSAGE_INFORMATION_CLASS = enum(ULONG) {
        SidInformation = 0,
        TokenModifiedIdInformation = 1,
        DirectStatusInformation = 2,
        HandleInformation = 3,
        _,
    };

    pub const MESSAGE_HANDLE_INFORMATION = extern struct {
        Index: ULONG = 0,
        Flags: ULONG = 0,
        Handle: ULONG = 0,
        ObjectType: OBJECT_TYPES = .{},
        GrantedAccess: ACCESS_MASK = .{},
    };

    pub const HANDLE_FLAGS = packed struct(ULONG) {
        Reserved0: u16 = 0,
        // 0x10000
        DUPLICATE_SAME_ACCESS: bool = false,
        // 0x20000
        DUPLICATE_SAME_ATTRIBUTES: bool = false,
        // 0x40000
        INDIRECT: bool = false,
        // 0x80000
        DUPLICATE_INHERIT: bool = false,
        Reserved20: u12 = 0,
    };

    /// Ref: https://github.com/microsoft/openvmm
    pub const HANDLE_ATTR = extern struct {
        Flags: HANDLE_FLAGS = .{},
        u2: extern union {
            Handle: HANDLE,
            HandleAttrArray: ?[*]HANDLE_ATTR32,
        } = .{ .Handle = INVALID_HANDLE_VALUE },
        u3: extern union {
            ObjectType: OBJECT_TYPES,
            HandleCount: ULONG,
        } = .{ .ObjectType = .{} },
        u4: extern union {
            DesiredAccess: ACCESS_MASK,
            GrantedAccess: ACCESS_MASK,
        } = .{ .DesiredAccess = .{} },
    };

    /// Ref: https://github.com/microsoft/openvmm
    pub const HANDLE_ATTR32 = extern struct {
        Flags: HANDLE_FLAGS = .{},
        Handle: ULONG = 0,
        ObjectType: OBJECT_TYPES = .{},
        Access: ACCESS_MASK = .{},
    };

    /// Ref: https://ntdoc.m417z.com/alpc_message_flags
    pub const MESSAGE_FLAGS = packed struct(ULONG) {
        REPLY_MESSAGE: bool = false,
        LPC_MODE: bool = false,
        Reserved2: u14 = 0,
        RELEASE_MESSAGE: bool = false,
        SYNC_REQUEST: bool = false,
        TRACK_PORT_REFERENCES: bool = false,
        Reserved19: u1 = 0,
        WAIT_USER_MODE: bool = false,
        WAIT_ALERTABLE: bool = false,
        SIGNAL_ALERTABLE: bool = false,
        Reserved23: u1 = 0,
        INTERNAL_REJECT: bool = false,
        Reserved25: u6 = 0,
        WOW64_CALL: bool = false,
    };
};

pub extern "ntdll" fn NtAlpcSendWaitReceivePort(
    PortHandle: HANDLE,
    Flags: ALPC.MESSAGE_FLAGS,
    SendMessage: ?*const PORT_MESSAGE,
    SendMessageAttributes: ?*ALPC.MESSAGE_ATTRIBUTES,
    ReceiveMessage: ?*PORT_MESSAGE,
    BufferLength: ?*SIZE_T,
    ReceiveMessageAttributes: ?*ALPC.MESSAGE_ATTRIBUTES,
    Timeout: ?*LARGE_INTEGER,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtAlpcConnectPortEx(
    PortHandle: *HANDLE,
    ConnectionPortObjectAttributes: *OBJECT.ATTRIBUTES,
    ClientPortObjectAttributes: ?*OBJECT.ATTRIBUTES,
    PortAttributes: ?*ALPC.PORT_ATTRIBUTES,
    Flags: ALPC.MESSAGE_FLAGS,
    ServerSecurityRequirements: ?PVOID,
    ConnectionMessage: ?*PORT_MESSAGE,
    BufferLength: ?*SIZE_T,
    /// 'Out' means attributes being **sent** out from client to server
    OutMessageAttributes: ?*ALPC.MESSAGE_ATTRIBUTES,
    InMessageAttributes: ?*ALPC.MESSAGE_ATTRIBUTES,
    Timeout: ?*LARGE_INTEGER,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn NtAlpcAcceptConnectPort(
    PortHandle: *HANDLE,
    ConnectionPort: HANDLE,
    Flags: ULONG,
    ObjectAttributes: ?*const OBJECT.ATTRIBUTES,
    PortAttributes: ?*ALPC.PORT_ATTRIBUTES,
    PortContext: ?PVOID,
    ConnectionRequest: *const PORT_MESSAGE,
    MessageAttributes: ?*ALPC.MESSAGE_ATTRIBUTES,
    AcceptConnection: BOOLEAN,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn AlpcInitializeMessageAttribute(
    AttributeFlags: ALPC.MESSAGE_ATTRIBUTE_FLAGS,
    Buffer: ?*ALPC.MESSAGE_ATTRIBUTES,
    BufferSize: SIZE_T,
    RequiredBufferSize: *SIZE_T,
) callconv(.winapi) NTSTATUS;

pub extern "ntdll" fn AlpcGetMessageAttribute(
    Buffer: *ALPC.MESSAGE_ATTRIBUTES,
    AttributeFlag: ALPC.MESSAGE_ATTRIBUTE_FLAGS,
) callconv(.winapi) ?*anyopaque;

pub extern "ntdll" fn NtAlpcQueryInformationMessage(
    PortHandle: HANDLE,
    PortMessage: *PORT_MESSAGE,
    MessageInformationClass: ALPC.MESSAGE_INFORMATION_CLASS,
    MessageInformation: PVOID,
    Length: ULONG,
    ReturnLength: ?*ULONG,
) callconv(.winapi) NTSTATUS;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

pub extern "ntdll" fn NtDuplicateObject(
    SourceProcessHandle: HANDLE,
    SourceHandle: HANDLE,
    TargetProcessHandle: HANDLE,
    TargetHandle: *HANDLE,
    DesiredAccess: DWORD,
    HandleAttributes: ULONG,
    Options: ULONG,
) callconv(.winapi) NTSTATUS;

pub extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: DWORD,
    dwFlags: DWORD,
    lpSize: *SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetACP() callconv(.winapi) UINT;
pub extern "kernel32" fn IsValidCodePage(code_page: UINT) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetOEMCP() callconv(.winapi) UINT;

pub extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: ?*anyopaque,
    dwFlags: DWORD,
    Attribute: usize,
    lpValue: ?*anyopaque,
    cbSize: SIZE_T,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*SIZE_T,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn DeleteProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
) callconv(.winapi) void;

pub extern "advapi32" fn CreateProcessAsUserW(
    hToken: ?HANDLE,
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS.INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?LPCWSTR,
    lpCommandLine: ?LPWSTR,
    lpProcessAttributes: ?*SECURITY_ATTRIBUTES,
    lpThreadAttributes: ?*SECURITY_ATTRIBUTES,
    bInheritHandles: BOOL,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?LPCWSTR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS.INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn GetFileAttributesW(
    lpFileName: LPCWSTR,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn QueryFullProcessImageNameW(
    hProcess: HANDLE,
    dwFlags: DWORD,
    lpExeName: LPWSTR,
    lpdwSize: *DWORD,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn WaitForSingleObject(
    hHandle: HANDLE,
    dwMilliseconds: DWORD,
) callconv(.winapi) DWORD;

pub extern "kernel32" fn GetModuleHandleW(
    lpModuleName: LPCWSTR,
) callconv(.winapi) ?HMODULE;

pub extern "kernel32" fn GetProcAddress(
    hModule: ?HMODULE,
    lpProcName: [*:0]const u8,
) callconv(.winapi) ?FARPROC;

pub extern "advapi32" fn OpenProcessToken(
    ProcessHandle: HANDLE,
    DesiredAccess: DWORD,
    TokenHandle: *HANDLE,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetTokenInformation(
    TokenHandle: HANDLE,
    TokenInformationClass: TOKEN_INFORMATION_CLASS,
    TokenInformation: ?*anyopaque,
    TokenInformationLength: DWORD,
    ReturnLength: *DWORD,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn IsValidSid(
    pSid: ?*anyopaque,
) callconv(.winapi) BOOL;

pub extern "advapi32" fn GetSidSubAuthorityCount(
    pSid: ?*anyopaque,
) callconv(.winapi) ?*u8;

pub extern "advapi32" fn GetSidSubAuthority(
    pSid: ?*anyopaque,
    nSubAuthority: DWORD,
) callconv(.winapi) ?*DWORD;

// COM APIs for WSL integration
// Based on zigwin32 and https://github.com/microsoft/WSL

pub const CLSCTX_LOCAL_SERVER = 0x00000004;
pub const COINIT_MULTITHREADED = 0x0000000;

pub extern "ole32" fn CoCreateInstance(
    rclsid: ?*const GUID,
    // This should be ?*IUnknown, but WSL integration does
    // not need this field - we only pass null.
    pUnkOuter: ?*anyopaque,
    // WSL integration only needs CLSCTX_LOCAL_SERVER.
    dwClsContext: u32,
    riid: *const GUID,
    ppv: **anyopaque,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoInitializeEx(
    pvReserved: ?*anyopaque,
    // WSL integration only needs COINIT_MULTITHREADED.
    dwCoInit: u32,
) callconv(.winapi) HRESULT;

pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;

pub const SOLE_AUTHENTICATION_SERVICE = extern struct {
    dwAuthnSvc: u32,
    dwAuthzSvc: u32,
    pPrincipalName: ?PWSTR,
    hr: HRESULT,
};

pub const RPC_C_AUTHN_LEVEL = enum(u32) {
    DEFAULT = 0,
    NONE = 1,
    CONNECT = 2,
    CALL = 3,
    PKT = 4,
    PKT_INTEGRITY = 5,
    PKT_PRIVACY = 6,
};

pub const RPC_C_IMP_LEVEL = enum(u32) {
    DEFAULT = 0,
    ANONYMOUS = 1,
    IDENTIFY = 2,
    IMPERSONATE = 3,
    DELEGATE = 4,
};

pub const EOLE_AUTHENTICATION_CAPABILITIES = enum(i32) {
    NONE = 0,
    MUTUAL_AUTH = 1,
    STATIC_CLOAKING = 32,
    DYNAMIC_CLOAKING = 64,
    ANY_AUTHORITY = 128,
    MAKE_FULLSIC = 256,
    DEFAULT = 2048,
    SECURE_REFS = 2,
    ACCESS_CONTROL = 4,
    APPID = 8,
    DYNAMIC = 16,
    REQUIRE_FULLSIC = 512,
    AUTO_IMPERSONATE = 1024,
    DISABLE_AAA = 4096,
    NO_CUSTOM_MARSHAL = 8192,
    RESERVED1 = 16384,
};

pub extern "ole32" fn CoInitializeSecurity(
    pSecDesc: ?*anyopaque,
    cAuthSvc: i32,
    asAuthSvc: ?*SOLE_AUTHENTICATION_SERVICE,
    pReserved1: ?*anyopaque,
    dwAuthnLevel: RPC_C_AUTHN_LEVEL,
    dwImpLevel: RPC_C_IMP_LEVEL,
    pAuthList: ?*anyopaque,
    dwCapabilities: EOLE_AUTHENTICATION_CAPABILITIES,
    pReserved3: ?*anyopaque,
) callconv(.winapi) HRESULT;

// Ref: wslservice.idl
pub const CLSID_LxssUserSession: GUID = .{
    .Data1 = 0xa9b7a1b9,
    .Data2 = 0x0671,
    .Data3 = 0x405c,
    .Data4 = .{ 0x95, 0xf1, 0xe0, 0x61, 0x2c, 0xb4, 0xce, 0x7e },
};

pub const LX = struct {
    pub const LX_INIT_STD_FD_COUNT = 3;
    pub const MAXIMUM_MESSAGE_SIZE = 4 * 1024 * 1024;

    pub const LX_INIT_CREATE_PROCESS_RESULT_FLAG_GUI_APPLICATION: u32 = 0x1;

    pub const STATUS = enum(i32) {
        SUCCESS = 0,
        ENOENT = 2,
        EACCESS = 13,
        EINVAL = 22,
    };

    pub const MESSAGE = struct {
        pub const LX_INIT_WINDOW_SIZE_CHANGED = extern struct {
            Header: MESSAGE_HEADER,
            Rows: u16,
            Columns: u16,
        };

        pub const LX_INIT_PROCESS_EXIT_STATUS = extern struct {
            Header: MESSAGE_HEADER,
            ExitCode: i32,
        };

        pub const LX_INIT_CREATE_NT_PROCESS_UTILITY_VM = extern struct {
            Header: MESSAGE_HEADER,
            Port: u32,
            Common: LX_INIT_CREATE_NT_PROCESS_COMMON,
        };

        pub const LX_INIT_CREATE_NT_PROCESS_COMMON = extern struct {
            StdFdIds: [LX_INIT_STD_FD_COUNT]i64,
            FilenameOffset: u32,
            CurrentWorkingDirectoryOffset: u32,
            CommandLineOffset: u32,
            CommandLineCount: u16,
            EnvironmentOffset: u32,
            Rows: u16,
            Columns: u16,
            CreatePseudoconsole: bool,
            Buffer: [0]u8,
        };

        pub const LX_INIT_CREATE_PROCESS_RESPONSE = extern struct {
            Header: MESSAGE_HEADER,
            Result: STATUS,
            /// This field is only used in WSL1 code
            SignalPipeId: i64 = 0,
            Flags: u32,
        };
    };
    pub const MESSAGE_HEADER = extern struct {
        MessageType: MESSAGE_TYPE,
        MessageSize: u32,
        TransactionId: u32 = 0,
        TransactionStep: STEP = .NONE,

        pub const STEP = enum(u32) {
            NONE = 0,
            REQUEST = 1,
            FIRST_REPLY = 2,
        };
    };

    pub const MESSAGE_TYPE = enum(u32) {
        LxMiniInitMessageAny = 0,
        /// Used by Linux to spawn a Windows process
        LxInitMessageCreateProcessUtilityVm = 8,
        /// Used by Linux to notify exitcode of the shell
        LxInitMessageExitStatus = 9,
        /// Used by Windows to send resize events
        LxInitMessageWindowSizeChanged = 10,
        /// Used to respond to `LxInitMessageCreateProcessUtilityVm`
        LxInitMessageCreateProcessResponse = 11,
    };
};

// Winsock APIs

// Use Winsock 2.2 - Equivalent to MAKEWORD(2, 2)
pub const WINSOCK_2_2 = (2 << 8 | 2);

pub const WSAData = switch (builtin.target.cpu.arch) {
    .x86_64, .arm, .armeb, .aarch64 => extern struct {
        wVersion: u16,
        wHighVersion: u16,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?LPSTR,
        szDescription: [257]CHAR,
        szSystemStatus: [129]CHAR,
    },
    .x86 => extern struct {
        wVersion: u16,
        wHighVersion: u16,
        szDescription: [257]CHAR,
        szSystemStatus: [129]CHAR,
        iMaxSockets: u16,
        iMaxUdpDg: u16,
        lpVendorInfo: ?LPSTR,
    },
    else => @compileError("unhandled arch: " ++ @tagName(builtin.target.cpu.arch)),
};

pub extern "ws2_32" fn WSAStartup(
    wVersionRequested: u16,
    lpWSAData: ?*WSAData,
) callconv(.winapi) i32;

// TODO: this type is limited to platform 'windows8.1'
pub extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;

// WSL-specifc APIs

// Ref: wslservice.idl
// UUID: 38541BDC-F54F-4CEB-85D0-37F0F3D2617E
pub const IID_ILxssUserSession: GUID = .{
    .Data1 = 0x38541BDC,
    .Data2 = 0xF54F,
    .Data3 = 0x4CEB,
    .Data4 = .{ 0x85, 0xD0, 0x37, 0xF0, 0xF3, 0xD2, 0x61, 0x7E },
};

pub const LXSS_HANDLE_USE_CONSOLE = 0;
pub const LXSS_CREATE_INSTANCE_FLAGS_ALLOW_FS_UPGRADE: ULONG = 0x1;
pub const LXSS_CREATE_INSTANCE_FLAGS_SHELL_LOGIN: ULONG = 0x10;

pub const LXSS = struct {
    pub const HANDLE = extern struct {
        Handle: ULONG,
        HandleType: LxssHandleType,

        pub const LxssHandleType = enum(c_int) {
            LxssHandleConsole = 0,
            LxssHandleInput = 1,
            LxssHandleOutput = 2,
        };
    };

    pub const STD_HANDLES = extern struct {
        StdIn: LXSS.HANDLE,
        StdOut: LXSS.HANDLE,
        StdErr: LXSS.HANDLE,
    };

    pub const ERROR_INFO = extern struct {
        Flags: ULONG,
        Context: ULONGLONG,
        Message: LPWSTR,
        Warnings: LPWSTR,
        WarningsPipe: ULONG,
    };
    pub const ENUMERATE_INFO = extern struct {
        DistroGuid: GUID,
        State: LxssDistributionState,
        Version: ULONG,
        Flags: ULONG,
        DistroName: [257]WCHAR,

        pub const LxssDistributionState = enum(c_int) {
            LxssDistributionStateInvalid = 0,
            LxssDistributionStateInstalled = 1,
            LxssDistributionStateRunning = 2,
            LxssDistributionStateInstalling = 3,
            LxssDistributionStateUninstalling = 4,
            LxssDistributionStateConverting = 5,
            LxssDistributionStateExporting = 6,
        };
    };
};

pub const ILxssUserSession = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const fn (
            self: *const ILxssUserSession,
            riid: *const GUID,
            ppvObject: **anyopaque,
        ) callconv(.winapi) HRESULT,
        AddRef: *const fn (self: *const ILxssUserSession) callconv(.winapi) u32,
        Release: *const fn (self: *const ILxssUserSession) callconv(.winapi) u32,

        // Placeholder pointers for ordering.
        CreateInstance: *const anyopaque,
        RegisterDistribution: *const anyopaque,
        RegisterDistributionPipe: *const anyopaque,

        /// Used to resolve a distribution name to its GUID.
        GetDistributionId: *const fn (
            self: *const ILxssUserSession,
            DistributionName: LPCWSTR,
            Flags: ULONG,
            Error: *LXSS.ERROR_INFO,
            pDistroGuid: *GUID,
        ) callconv(.winapi) HRESULT,

        TerminateDistribution: *const anyopaque,
        UnregisterDistribution: *const anyopaque,
        ConfigureDistribution: *const anyopaque,
        GetDistributionConfiguration: *const anyopaque,
        GetDefaultDistribution: *const anyopaque,
        ResizeDistribution: *const anyopaque,
        SetDefaultDistribution: *const anyopaque,
        SetSparse: *const anyopaque,
        EnumerateDistributions: *const anyopaque,

        /// The main function WSL integration needs.
        CreateLxProcess: *const fn (
            self: *const ILxssUserSession,
            DistroGuid: ?*const GUID,
            Filename: ?LPCSTR,
            CommandLineCount: ULONG,
            CommandLine: ?*LPCSTR,
            CurrentWorkingDirectory: LPCWSTR,
            NtPath: LPCWSTR,
            NtEnvironment: *WCHAR,
            NtEnvironmentLength: ULONG,
            Username: ?LPCWSTR,
            Columns: SHORT,
            Rows: SHORT,
            ConsoleHandle: ULONG,
            StdHandles: *LXSS.STD_HANDLES,
            Flags: ULONG,
            DistributionId: *GUID,
            InstanceId: *GUID,
            ProcessHandle: *HANDLE,
            ServerHandle: *HANDLE,
            StandardIn: *HANDLE,
            StandardOut: *HANDLE,
            StandardErr: ?*HANDLE,
            CommunicationChannel: *HANDLE,
            InteropSocket: *HANDLE,
            Error: *LXSS.ERROR_INFO,
        ) callconv(.winapi) HRESULT,
    };

    pub inline fn QueryInterface(
        self: *const ILxssUserSession,
        riid: *const GUID,
        ppvObject: **anyopaque,
    ) HRESULT {
        return self.vtable.QueryInterface(self, riid, ppvObject);
    }
    pub inline fn AddRef(self: *const ILxssUserSession) u32 {
        return self.vtable.AddRef(self);
    }
    pub inline fn Release(self: *const ILxssUserSession) u32 {
        return self.vtable.Release(self);
    }

    pub inline fn GetDistributionId(
        self: *const ILxssUserSession,
        DistributionName: LPCWSTR,
        Flags: ULONG,
        Error: *LXSS.ERROR_INFO,
        pDistroGuid: *GUID,
    ) HRESULT {
        return self.vtable.GetDistributionId(self, DistributionName, Flags, Error, pDistroGuid);
    }

    pub inline fn CreateLxProcess(
        self: *const ILxssUserSession,
        DistroGuid: ?*const GUID,
        Filename: ?LPCSTR,
        CommandLineCount: ULONG,
        CommandLine: ?*LPCSTR,
        CurrentWorkingDirectory: LPCWSTR,
        NtPath: LPCWSTR,
        NtEnvironment: *WCHAR,
        NtEnvironmentLength: ULONG,
        Username: ?LPCWSTR,
        Columns: SHORT,
        Rows: SHORT,
        ConsoleHandle: ULONG,
        StdHandles: *LXSS.STD_HANDLES,
        Flags: ULONG,
        DistributionId: *GUID,
        InstanceId: *GUID,
        ProcessHandle: *HANDLE,
        ServerHandle: *HANDLE,
        StandardIn: *HANDLE,
        StandardOut: *HANDLE,
        StandardErr: ?*HANDLE,
        CommunicationChannel: *HANDLE,
        InteropSocket: *HANDLE,
        Error: *LXSS.ERROR_INFO,
    ) HRESULT {
        return self.vtable.CreateLxProcess(
            self,
            DistroGuid,
            Filename,
            CommandLineCount,
            CommandLine,
            CurrentWorkingDirectory,
            NtPath,
            NtEnvironment,
            NtEnvironmentLength,
            Username,
            Columns,
            Rows,
            ConsoleHandle,
            StdHandles,
            Flags,
            DistributionId,
            InstanceId,
            ProcessHandle,
            ServerHandle,
            StandardIn,
            StandardOut,
            StandardErr,
            CommunicationChannel,
            InteropSocket,
            Error,
        );
    }
};
