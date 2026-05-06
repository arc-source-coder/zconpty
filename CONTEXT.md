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

## Relationships

- **zconpty** implements **ConPTY** as an in-process **console server**.
- The **console server** talks to **ConDrv** directly instead of relying on OpenConsole/conhost.
- The **server thread** runs the **console server** loop and handles console activity for attached clients.
- **zconpty** relies on the host's **Vtable** for authoritative terminal state rather than owning a separate screen buffer or VT parser.
- The **Input subsystem** receives host key, mouse, paste, focus, and resize events and uses them to satisfy pending console input operations.
- **Cooked read** belongs to the **Input subsystem** and is distinct from raw input event delivery.

## Example dialogue

> **Dev:** "Is zconpty just a wrapper around `CreatePseudoConsole`?"
> **Domain expert:** "No. **zconpty** is an in-process **console server**. It talks to the **ConDrv** directly and does not create an `HPCON`."

> **Dev:** "Where does zconpty store the screen buffer?"
> **Domain expert:** "It does not own a second authoritative buffer. zconpty uses the host **Vtable** to query or update the backing terminal."

> **Dev:** "Why is `ReadConsole` logic separate from key events?"
> **Domain expert:** "Because **cooked read** is a Windows console behavior: line editing, history, echo, and Unicode-aware cursor movement have to be emulated above raw input events."

## Flagged ambiguities

- **PTY** is too generic for zconpty internals. Prefer **ConPTY**, **ConDrv**, **console server**, or **Vtable** depending on the boundary being discussed.
- **Terminal** should not imply ownership of terminal state inside zconpty. Use **Vtable** for the host-provided interface and backing terminal for the external authoritative state.
