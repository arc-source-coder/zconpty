const std = @import("std");
const windows_new = @import("windows/windows.zig");

pub const WORD = windows_new.WORD;
pub const DWORD = std.os.windows.DWORD;
pub const ULONG = std.os.windows.ULONG;
pub const SIZE_T = std.os.windows.SIZE_T;

pub const USHORT = windows_new.USHORT;
pub const MAX_PATH = windows_new.MAX_PATH;
pub const ULONG_PTR = std.os.windows.ULONG_PTR;

pub const E_NOTIMPL = 0x80004001;
pub const STATUS_NOT_IMPLEMENTED = 0x00000001;

pub const COLORREF = windows_new.COLORREF;
pub const LANGID = windows_new.LANGID;

pub const CHAR = windows_new.CHAR;
pub const WCHAR = std.os.windows.WCHAR;
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

pub const NtWriteFile = ntdll.NtWriteFile;
pub const NtOpenFile = ntdll.NtOpenFile;
pub const NtClose = ntdll.NtClose;
pub const NtDeviceIoControlFile = ntdll.NtDeviceIoControlFile;
pub const NtWaitForSingleObject = ntdll.NtWaitForSingleObject;
pub const NtTerminateProcess = ntdll.NtTerminateProcess;
pub const NtCancelSynchronousIoFile = ntdll.NtCancelSynchronousIoFile;
pub const NtCreateEvent = ntdll.NtCreateEvent;
pub const NtSetEvent = ntdll.NtSetEvent;
pub const RtlWaitOnAddress = ntdll.RtlWaitOnAddress;
pub const RtlWakeAddressSingle = ntdll.RtlWakeAddressSingle;

pub extern "kernel32" fn ResetEvent(hEvent: HANDLE) callconv(.winapi) BOOL;

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

pub const PROCESS_INFORMATION = std.os.windows.PROCESS_INFORMATION;
pub const SECURITY_ATTRIBUTES = std.os.windows.SECURITY_ATTRIBUTES;
pub const STARTUPINFOW = std.os.windows.STARTUPINFOW;
pub const UINT = std.os.windows.UINT;
pub const LANG = std.os.windows.LANG;
pub const SUBLANG = std.os.windows.SUBLANG;

pub const STARTUPINFOEXW = extern struct {
    StartupInfo: STARTUPINFOW,
    lpAttributeList: ?*anyopaque,
};

pub const PROC_THREAD_ATTRIBUTE_HANDLE_LIST: usize = 0x00020002;
pub const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
/// This is an undocumented API used by OpenConsole.exe
// Defined in src\server\winbasep.h (inside the WT repo) as:
// ProcThreadAttributeValue(10, FALSE, TRUE, FALSE)
// Where the macro is:
// ProcThreadAttributeValue (Number, Thread, Input, Additive) =
//   ((Number) & PROC_THREAD_ATTRIBUTE_NUMBER)                      // PTAN = 0x0000FFFF
//   | ((Thread != FALSE) ? PROC_THREAD_ATTRIBUTE_THREAD : 0)       // PTAT = 0x00010000
//   | ((Input != FALSE) ? PROC_THREAD_ATTRIBUTE_INPUT : 0)         // PTAI = 0x00020000
//   | ((Additive != FALSE) ? PROC_THREAD_ATTRIBUTE_ADDITIVE : 0))) // PTAA = 0x00040000
pub const PROC_THREAD_ATTRIBUTE_CONSOLE_REFERENCE: usize = 0x0002000A;

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
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) BOOL;

pub extern "kernel32" fn OpenProcess(
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwProcessId: DWORD,
) callconv(.winapi) ?HANDLE;

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
    lpProcessInformation: *PROCESS_INFORMATION,
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

pub extern "kernel32" fn DuplicateHandle(
    hSourceProcessHandle: HANDLE,
    hSourceHandle: HANDLE,
    hTargetProcessHandle: HANDLE,
    lpTargetHandle: *HANDLE,
    dwDesiredAccess: DWORD,
    bInheritHandle: BOOL,
    dwOptions: DWORD,
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
