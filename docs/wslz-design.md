# wslz

The **wslz subsystem** is zconpty's direct integration with WSL. It
runs interactive WSL shells without the relay processes that wsl.exe
puts on the data path. Linux output flows straight from the WSL stdout
socket into zconpty's backing terminal.

It still does everything wsl.exe does for an interactive shell - launches
the session through the Windows WSL service, wires up the stdin/stdout/
control/interop sockets, and handles interop spawns - but the terminal
bytes never pass through a separate Windows process.

The difference is that wslz cuts the terminal-relay part out of `wsl.exe`
entirely. The bytes that `wsl.exe` normally shuttles between WSL's sockets
and the console host go straight into zconpty instead, because zconpty already
owns the terminal.

Doing this needs two cooperating pieces:

- The **wslz session** — An in-server component that lives inside zconpty,
  holds the WSL sockets, and drives the terminal.
- The **wslz.exe** broker process that talks to the WSL COM service and
  handles interop spawns.

Neither piece can do the job alone: the COM/interop work needs a real
process, and the terminal work needs to be inside zconpty.

wslz is not a full `wsl.exe` replacement. It does not handle localhost
forwarding, debugging, or network relays. It owns one thing — the interactive
terminal session — and tries to do it with as few hops as possible.

## Why wslz exists

For an interactive Linux shell, the stock `wsl.exe` path crosses every boundary
Windows has to offer before a byte ever lands on the user's screen. Three
things in particular add up:

1. **Every byte of Linux output is moved through two extra processes.**
   `wsl.exe` itself reads from the WSL stdout socket and writes to a ConPTY
   pipe, and `OpenConsole.exe` reads from the other end of that pipe and
   writes to the terminal. Both processes are pure transports — neither one
   needs to look at the bytes, but both copy them.

2. **The relay reads one 4 KiB buffer at a time and waits for each completion
   before issuing the next read** (`LX_RELAY_BUFFER_SIZE = 0x1000`, single
   `ReadFile` per loop iteration in WSL's `InterruptableRelay`). Output
   bursts from Linux can't keep the pipeline full: the socket sits idle while
   the previous buffer is still being processed, and a single chunky write on
   the Linux side fragments into many round trips.

3. **Input is walked back through the console input queue.** The host already
   produced VT bytes, but the relay calls `ReadConsoleInputExW` and smuggles
   one byte per `INPUT_RECORD.Event.KeyEvent.uChar.UnicodeChar`, then
   reassembles the byte stream on the other side. The encoded bytes never
   needed to become `INPUT_RECORD`s in the first place; the round trip
   through the console queue is pure ceremony.

The socket between init and Windows is a fact of WSL's architecture and can't
be removed. Everything else in the chain can. Comparing the three deployment
shapes for the same Linux process makes the saving obvious:

```diagram
Stock wsl.exe + Windows Terminal (or any other terminal using OpenConsole.exe):

╭───────╮  ╭──────╮  ╭────────╮  ╭─────────╮  ╭─────────────────╮  ╭──────────╮
│ linux │─►│ init │─►│ socket │─►│ wsl.exe │─►│ OpenConsole.exe │─►│ terminal │
╰───────╯  ╰──────╯  ╰────────╯  ╰─────────╯  ╰─────────────────╯  ╰──────────╯

Kairo + zconpty, no wslz (wsl.exe is still in the loop):

╭───────╮  ╭──────╮  ╭────────╮  ╭─────────╮  ╭───────╮
│ linux │─►│ init │─►│ socket │─►│ wsl.exe │─►│ Kairo │
╰───────╯  ╰──────╯  ╰────────╯  ╰─────────╯  ╰───────╯

Kairo + zconpty with wslz:

╭───────╮  ╭──────╮  ╭────────╮  ╭───────╮
│ linux │─►│ init │─►│ socket │─►│ Kairo │
╰───────╯  ╰──────╯  ╰────────╯  ╰───────╯
```

The third path is what wslz delivers: the WSL stdout socket is handed
directly to zconpty during the bootstrap handshake, and Linux output goes
into `Terminal.feed()` without ever passing through a separate Windows
process. The wsl.exe relay process and the OpenConsole.exe console host are
both gone.

The rest of the wsl.exe job — picking a distribution, calling
`ILxssUserSession::CreateLxProcess`, handling interop spawns still has
to happen, so wslz keeps a small broker process (`wslz.exe`) to do
it. wslz.exe just doesn't carry data after the handshake.

## Architecture

The wslz subsystem is split across two trust domains that live in the same
Windows session: the **wslz.exe** broker that holds the COM/WSL session, and
the **zconpty server** that owns the terminal. A private ALPC port carries the
WSL socket handles between them during setup; once the handshake is done, it
isn't used again.

```diagram
╭────────────────────────╮            ╭───────────────────────────╮
│        wslz.exe        │            │    zconpty (in-process)   │
│                        │            │                           │
│  ╭──────────────────╮  │  ConDrv    │  ╭──────────────────────╮ │
│  │     Cli.run      │──┼── IOCTL ──►│  │      ApiHandler      │ │
│  │  CreateLxProcess │  │ bootstrap  │  │  handleWslzBootstrap │ │
│  ╰────────┬─────────╯  │            │  ╰──────────┬───────────╯ │
│           │            │            │             │             │
│           ▼            │            │             ▼             │
│  ╭──────────────────╮  │    ALPC    │  ╭─────────────────────╮  │
│  │ alpc.sendSockets │──┼─ handles ─►│  │  alpc.acceptSockets │  │
│  ╰──────────────────╯  │            │  ╰──────────┬──────────╯  │
│                        │            │             │             │
│  ╭──────────────────╮  │            │             ▼             │
│  │ Interop loop on  │  │            │  ╭─────────────────────╮  │
│  │  interop_socket  │  │            │  │    WslReadThread    │  │
│  ╰────────┬─────────╯  │            │  │   stdout → feed()   │  │
│           │            │            │  ╰─────────────────────╯  │
│  Windows  │ ConDrv     │            │                           │
│  console  │ IOCTL      │            │                           │
│  child    │ set_interop│            │  ╭─────────────────────╮  │
│  spawn    │ ───────────┼───────────►│  │   Input subsystem   │  │
│           │            │            │  │  (host VT → stdin   │  │
│           │            │            │  │  socket / control)  │  │
│           │            │            │  ╰─────────────────────╯  │
╰────────────────────────╯            ╰───────────────────────────╯
```

zconpty already owns the host terminal boundary, so wslz treats the WSL
session as a transport problem rather than a console-client compatibility
problem:

- Linux output is read straight off WSL's stdout socket and handed to the host
  terminal with `Terminal.feed()`.
- Host VT input is written straight to WSL's stdin socket without ever passing
  through `INPUT_RECORD`.
- Resize is a single `LX_INIT_WINDOW_SIZE_CHANGED` message on the control
  socket, mirroring WSL's existing `SIGWINCH` plumbing.

## Bootstrap handshake

The bootstrap handshake is small but deliberately paranoid: zconpty has to be
sure the process on the other side really is the wslz.exe shipped with this
build, and wslz.exe has to be sure it's talking to a real zconpty server. Two
private L3 console API numbers, only known to the wslz subsystem, do the talking:

| API number   | Name                    | Direction          |
| ------------ | ----------------------- | ------------------ |
| `0x0300002d` | `wslz_bootstrap`        | wslz.exe → zconpty |
| `0x0300002e` | `wslz_set_interop_mode` | wslz.exe → zconpty |

The full handshake:

1. **CreateLxProcess.** wslz.exe goes through the WSL COM session
   (`ILxssUserSession::CreateLxProcess`) with the terminal's `ConsoleHandle`
   from the PEB as the reference handle. WSL hands back four sockets: stdin,
   stdout, control, and interop.

2. **wslz_bootstrap IOCTL.** wslz.exe issues `CONDRV.ISSUE_USER_IO` against the
   console handle with `ApiNumber = wslz_bootstrap`.

3. **Identity check.** zconpty resolves the calling process (via the IO
   descriptor's `Process` field), maps the on-disk wslz.exe image into its own
   address space, hashes it with BLAKE3, and compares against a hash baked
   into the build (`build/hasher.zig` → `wslz_hash` module). A name match is
   not enough; the bytes have to match.

4. **Channel setup.** zconpty creates a private ALPC port at
   `\RPC Control\zconpty-<pid>-<random128>`, generates a 128-bit secret
   (the **session token**), and returns both in the IOCTL response.

5. **Handle transfer.** wslz.exe connects to the ALPC port and sends the
   stdin, stdout, and control socket handles as `INDIRECT` `HANDLE_ATTRIBUTE`
   entries with `ObjectType = FILE` and `DUPLICATE_SAME_ACCESS`. zconpty
   queries each handle's object name and refuses anything that isn't an AFD
   socket (`\Device\Afd`).

6. **Activation.** zconpty stores the handles on `SessionState.wslz_session`,
   flips `Input.target` from `Condrv` to `Wsl`, and spawns the
   **WSL output relay thread**.

The interop socket stays in wslz.exe. zconpty deliberately does not touch it —
interop is wslz.exe's job, and keeping that boundary clean is what lets the
two processes cooperate without sharing state.

## Steady-state data flow

Once activated, three independent paths carry traffic between the terminal and
the Linux session.

### Output: WSL stdout → `Terminal.feed`

The WSL output relay thread runs a double-buffered `NtReadFile` loop against
the stdout socket:

- Two 128 KiB buffers, swapped each iteration.
- `NtReadFile` is issued asynchronously into the **read** buffer; while it is
  pending, the previous iteration's **feed** buffer is handed to
  `Terminal.feed()`.
- On `STATUS_PENDING`, the thread waits on the event with `NtWaitForSingleObject`
  in alertable mode so shutdown can wake it.

Buffers are 128 KiB and there is exactly one in-flight read at a time, but the
_processing_ of the previous read overlaps with the next read, so the socket
is never idle waiting on `feed()`. The relay runs on a dedicated thread rather
than sharing the server thread, because `feed()` calls can stall on the host
terminal and the server thread must stay responsive to ConDrv traffic.

### Input: host VT bytes → WSL stdin

The zconpty input subsystem already routes host events through a target
selector (`Input.target`). While a wslz session is active and Windows interop
mode is off, encoded VT bytes from the host go directly to
`WslzSession.writeInput`, which calls `io.writeAll` on the stdin socket. No
`INPUT_RECORD`, no `ReadConsole`, no console queue.

### Resize: host → WSL control socket

Host resize events become a single `LX_INIT_WINDOW_SIZE_CHANGED` message on
the control socket. The same path is used to send the _initial_ resize right
after the handshake, so the Linux side observes the correct geometry before
the first prompt is drawn.

## Windows interop mode

Linux processes can launch Windows processes through WSL's binfmt interop. The
interop socket carries one of two relevant messages:

- `LxInitMessageCreateProcessUtilityVm` — Linux is asking wslz.exe to spawn
  an NT process on its behalf.
- `LxInitMessageExitStatus` — the Linux session itself has exited.

wslz.exe spawns a detached thread per interop request (`Interop.handleInterop`)
and then waits for the next message. The handler does three things: pick the
right spawn shape, route I/O accordingly, and tell zconpty when to change input
routing.

### Spawn shapes

WSL classifies each interop launch with a `CreatePseudoconsole` flag in the
common header of the request:

| `CreatePseudoconsole` | Shape                                               | I/O                                                                        |
| --------------------- | --------------------------------------------------- | -------------------------------------------------------------------------- |
| `false`               | Redirected (pipes only) or GUI (`CREATE_NO_WINDOW`) | Pipes are stitched to the four WSL stdio sockets by detached relay threads |
| `true`                | Interactive console child                           | wslz.exe's `hStdInput/Output/Error` are duplicated into the child          |

The CPC=true case is the reason wslz.exe is a process rather than a library.
For an interactive console child, wslz.exe behaves like a shell launching a
child process: it uses its own stdin/stdout/stderr — which are already
attached to the zconpty console server — and hands those same handles to the
child. The child becomes a console client of the _same_ zconpty, sharing the
terminal with wslz.exe and the Linux session.

The naive alternative is to let the WSL service do what `wsl.exe` does today:
call `CreatePseudoConsole` for every interop child. That goes through the
system DLL, which spawns `conhost.exe` (not OpenConsole), and then forces a
relay chain on every byte of output. The two paths, side by side, for the
same `cmd.exe` launched from Linux:

```diagram
Stock interop (CreatePseudoConsole path):

╭───────────────╮   ╭─────────────╮   ╭────────╮   ╭─────────────────╮
│ Windows child │──►│ conhost.exe │──►│ pipe   │──►│   WSL interop   │
╰───────────────╯   ╰─────────────╯   ╰────────╯   │   socket set    │
                                                   ╰────────┬────────╯
                                                            ▼
╭────────────────╮   ╭──────────────────╮   ╭───────────────────╮
│ terminal       │◄──│ OpenConsole.exe  │◄──│ wsl.exe relay     │
╰────────────────╯   ╰──────────────────╯   ╰───────────────────╯

wslz interop (console-client child):

╭───────────────╮   ╭───────────────────────╮   ╭────────────╮
│ Windows child │──►│ zconpty - in-process  │──►│  Terminal  │
│    process    │   │    with terminal      │   │            │
╰───────────────╯   ╰─────────────────────-─╯   ╰────────────╯
```

That collapse is what wslz.exe's process identity buys. For reference, the
DOOM-fire benchmark runs at ~8 FPS in `conhost.exe`, ~250 FPS in
`OpenConsole.exe`, and ~450 FPS in zconpty — so every layer the CPC path
forces in matters.

GUI launches are detected by reading the child PEB's `ImageSubSystem` via
`NtReadVirtualMemory` after `CreateProcessW` returns. GUI apps run with
`CREATE_NO_WINDOW` so they don't pop a console, and they never trigger an
input-routing change.

### Input routing

For an interactive console child, host input has to go to _that child_ — not
to the WSL stdin socket. wslz.exe issues `wslz_set_interop_mode` with
`windowsInterop = TRUE` _before_ writing the create-process response back to
Linux. zconpty switches `Input.target` from `Wsl` to `Condrv`, so host keys
land in the console input queue where the Windows child can find them. When
the child exits, wslz.exe calls the same IOCTL with `windowsInterop = FALSE`
and input flips back. The session token from the bootstrap response
authenticates the call; an attacker who guesses the API number still needs
the 128-bit token to flip anything.

### Ctrl+C while a console child runs

Keyboard Ctrl+C is broadcast to every process attached to the console,
including wslz.exe. wslz.exe installs a console control handler that
acknowledges `CTRL_C_EVENT` and `CTRL_BREAK_EVENT` as handled, so the
foreground Windows child sees the signal and wslz.exe does not get torn down
in the middle of an interop session.

## Nested wslz

wslz.exe sets `WSLZ_SESSION=1` in the environment of every process it spawns.
On startup, if a child sees that variable already set, it prints a notice and
re-execs `wsl.exe` instead; when `wsl.exe` exits, the nested wslz exits with
the same status. This avoids two wslz sessions fighting over the same console
handle from inside a single shell tree.

## Lifetime and cleanup

A wslz session is bounded by the lifetime of the wslz.exe console client.
`Dispatcher.handleDisconnect` is the single owner of teardown:

1. When wslz.exe's console client disconnects (process exit, ConDrv close,
   etc.), ConDrv issues a disconnect to the server.
2. The dispatcher checks whether the disconnecting client's `Process`
   descriptor matches `WslzSession.client`. If so, it flips
   `Input.target` back to `Condrv` and calls `WslzSession.deinit`.
3. `deinit` sets a `closing` flag, calls `NtAlertThread` on the read thread to
   wake any pending wait, closes the stdin/control/connection-port handles,
   and joins the thread. The read thread observes the alert, cancels its
   in-flight `NtReadFile` with `NtCancelIoFileEx`, drains the IOSB, and
   returns. The stdout socket is closed in the read thread's `defer`.

The connection port handle is tracked separately because the read thread may
be parked in `acceptSockets` (waiting for ALPC) rather than `NtReadFile` when
shutdown hits; closing it from `deinit` unblocks that case.
