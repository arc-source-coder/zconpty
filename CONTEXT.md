# zconpty

zconpty is an in-process Windows ConPTY server implementation that translates Windows-specific console behavior against a host-provided terminal interface.

## Language

**zconpty**:
An in-process console server library that implements the ConPTY translation layer without spawning OpenConsole/conhost as a separate process.

**ConPTY**:
The Windows pseudo-terminal translation concept that bridges console applications and terminal hosts.

**ConDrv**:
The Windows kernel console driver interface that zconpty serves directly.

**Console server**:
The in-process zconpty component that handles ConDrv operations and Windows console API behavior for attached console clients.

**Server thread**:
The zconpty-owned thread that runs the console server loop for one host integration.

**Vtable**:
The host-provided terminal interface zconpty uses to feed output, encode terminal input, query terminal properties, and read or update terminal cells.

**Input subsystem**:
The zconpty component that accepts host input events and satisfies console input reads.

**Cooked read**:
Line-oriented `ReadConsole` behavior, including editing, history, echo, and completion; zconpty's implementation is grapheme-aware and uses uucode for Unicode behavior.

**wslz subsystem**:
zconpty's direct integration with WSL for running an interactive Linux session without routing terminal traffic through the ConDrv or wsl.exe's relay path. The umbrella term covering **wslz.exe**, the private ConDrv APIs, the ALPC handle-transfer channel, the **wslz session** in the server, and the **WSL output relay thread**. Distinct from "WSL" (Microsoft's Windows Subsystem for Linux).

**wslz.exe**:
The broker process that establishes a wslz session. It calls `ILxssUserSession::CreateLxProcess` to start the Linux side, transfers the stdin/stdout/control sockets to zconpty over ALPC, and stays alive to service interop requests on the WSL interop socket. It does not relay terminal data; once the handshake completes, Linux output flows directly into zconpty.

**wslz session**:
The in-server object owned by `SessionState` for the lifetime of one wslz.exe client. It holds the transferred sockets, the session token, the owning client's process descriptor, and the WSL output relay thread. Begins when `handleWslzBootstrap` succeeds and ends when `handleDisconnect` observes the matching client going away.

**WSL output relay thread**:
The dedicated thread spawned per wslz session that runs the double-buffered `NtReadFile` loop against the WSL stdout socket and calls `Terminal.feed()`. Distinct from the **server thread**. Cancelled via `NtAlertThread` + `NtCancelIoFileEx` during teardown.

**Windows interop mode**:
The temporary wslz-session state where a foreground interactive Windows console process launched from Linux receives input through ConDrv instead of the WSL stdin socket. Switched on and off by wslz.exe via `wslz_set_interop_mode` IOCTLs authenticated with the session token.

## Relationships

- **zconpty** implements **ConPTY** as an in-process **console server**.
- The **console server** talks to **ConDrv** directly instead of relying on OpenConsole/conhost.
- The **server thread** runs the **console server** loop and handles console activity for attached clients.
- **zconpty** relies on the host's **Vtable** for authoritative terminal state rather than owning a separate screen buffer or VT parser.
- The **Input subsystem** receives host key, mouse, paste, focus, and resize events and uses them to satisfy pending console input operations.
- **Cooked read** belongs to the **Input subsystem** and is distinct from raw input event delivery.
- The **wslz subsystem** is the integration; **wslz.exe** is the broker process that establishes one; the **wslz session** is the in-server object that the **bootstrap handshake** creates and that the **WSL output relay thread** belongs to.
- The **bootstrap handshake** authenticates **wslz.exe** by BLAKE3 hash and returns a **session token** that gates every subsequent `wslz_set_interop_mode` call.
- The **interop socket** stays in **wslz.exe** and never crosses into zconpty; the other three sockets (stdin, stdout, control) are transferred over ALPC and owned by the **wslz session**.
- **Windows interop mode** belongs to the **wslz session** and applies only to interactive Windows console processes — not GUI Windows applications or redirected non-interactive launches.

## Example dialogue

> **Dev:** "Is zconpty just a wrapper around `CreatePseudoConsole`?"
> **Domain expert:** "No. **zconpty** is an in-process **console server**. It talks to the **ConDrv** directly and does not create an `HPCON`."

> **Dev:** "Where does zconpty store the screen buffer?"
> **Domain expert:** "It does not own a second authoritative buffer. zconpty uses the host **Vtable** to query or update the backing terminal."

> **Dev:** "Why is `ReadConsole` logic separate from key events?"
> **Domain expert:** "Because **cooked read** is a Windows console behavior: line editing, history, echo, and Unicode-aware cursor movement have to be emulated above raw input events."

> **Dev:** "When a Linux command launches `cmd.exe`, does host input still go to the WSL stdin socket?"
> **Domain expert:** "No. During **Windows interop mode**, input routes through **ConDrv** so the foreground Windows console process receives normal console input."

## Flagged ambiguities

- **PTY** is too generic for zconpty internals. Prefer **ConPTY**, **ConDrv**, **console server**, or **Vtable** depending on the boundary being discussed.
- **Terminal** should not imply ownership of terminal state inside zconpty. Use **Vtable** for the host-provided interface and backing terminal for the external authoritative state.
- **Interop** is too broad by itself. Use **Windows interop mode** for the temporary input-routing state inside a **wslz session**.
- **wslz** alone is ambiguous. Prefer **wslz subsystem** (the integration as a whole), **wslz.exe** (the broker process), or **wslz session** (the in-server object).
- **Token** alone is ambiguous in Windows contexts (access token, impersonation token). Use **session token** for the wslz bootstrap secret.
- **WSL** refers to Microsoft's Windows Subsystem for Linux. Do not abbreviate the **wslz subsystem** to "WSL".
