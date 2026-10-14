# CAN and RS485 diagnostics

Open **Equipment → RS485 1 / 2** or **CAN 1 / 2** for that bus's configuration and
explicit, bounded diagnostics. RS485 1/2 map to `ttyS3`/`ttyS4`; CAN 1/2 map to
`can0`/`can1`. Each page acts only on its selected port. Visiting sends no bus traffic. Only one
bus operation runs at a time, independently of LAN trials, USB recovery and VPN.
Host mode simulates everything in memory; other non-EC100 firmware targets are
unsupported. No workstation CAN sockets or serial ports are opened in host mode.

## CAN

Only `can0` and `can1` are eligible. Status reports the detected kernel interface,
up/down, bitrate, listen-only flag, controller state, error counters and packet
counters. These are observations, not proof of wiring, termination or health.
Connector/controller mapping and physical traffic still require EC100 qualification.

Enable explicitly with the peer's bitrate: 10000, 20000, 50000, 100000, 125000,
250000, 500000 or 1000000 bit/s. Configuration takes the interface down, sets the
bitrate and **listen-only** mode, then brings it up. Disable takes it down. This
can interrupt another local user of that interface. There is no atomic rollback;
a failed or interrupted change can leave it down or partially configured. Review
observations before retrying. Kernel state is not persisted or replayed at boot.
A service restart observes existing kernel state; it does not silently disable CAN.

Capture requires up + listen-only, rechecked before opening its receive socket.
It receives at most **200 classic frames or five seconds**, whichever comes first.
No CAN transmit API, normal-mode enable, automatic restart, CAN FD or remote bus
bridge is exposed. Normal/unknown mode configured externally is refused for capture.
Listen-only does not acknowledge frames; a lone transmitter may therefore error.
External writers can change kernel state after the check; the app cannot enforce
exclusive ownership against other privileged processes.

## RS485

Only `/dev/ttyS3` and `/dev/ttyS4` are used. UART0 stays the boot console. Presence
means a character device was detected, not that a peer is wired or the port is free.
Enable only permits this application to open the port for an explicit operation;
it opens nothing by itself and resets to disabled on service restart.

Only **9600 baud, 8 data bits, no parity, 1 stop bit, no flow control** is offered.
The BSP has qualified this profile with automatic transceiver direction handling;
other speeds and bus loads are unqualified. No GPIO, DE/RTS polarity or software
RS485 ioctl mode is guessed. Each operation opens a short-lived passive UART,
closes it afterward, and leaves no persistent reader. Opening configures termios;
there is no promise to restore another application's previous serial settings.

Passive capture transmits nothing and returns at most **4096 raw bytes or five
seconds**, displayed as hex without guessing protocol boundaries.

### Modbus RTU

The operator must authorize **each** request and ensure there is no other master.
A 50 ms quiet-bus check rejects observed traffic before sending, but is not bus
arbitration and cannot ensure exclusivity. Consult the device register map:
even read functions can have device-specific side effects.

- One request, with no retries or unit discovery.
- Functions **3 (holding registers)** or **4 (input registers)** only.
- Unit **1–247**, never broadcast 0.
- Zero-based start address **0–65535**, **1–32 registers**, end within 65535.
- One-second response deadline after a write bounded to 500 ms.
- Exact unit, function, length, byte count and CRC validation; exceptions reported.
- Fragmented responses are assembled; unrelated traffic/echo/corrupt frames are
  rejected, not searched for a convenient match.
- Results are unsigned 16-bit integers, without scaling, float or word-order guesses.

There are no write functions, continuous polling, arbitrary bytes or automatic
protocol probes. Lost replies/timeouts do not prove the device did nothing.

## Lifetime and verification

A linked worker owns each socket/UART. A 6.5-second outer deadline stops stalled
work; shutdown stops the worker. Results are bounded, memory-only and shared with
current UI sessions, not a retained log. The next operation clears the prior result.
Idle availability polling every five seconds is read-only. UI drafts do not overwrite
live observations; an explicit apply uses the submitted values without revision locks.

`mix ci` runs static checks and the QEMU device integration suite. The former
host-fake and standalone PTY/vcan tests have been removed. Bus protocol integration
coverage on the QEMU device remains to be added; QEMU does not reproduce EC100
transceivers or wiring. Actual EC100 bus traffic still requires hardware qualification.
The trusted-network, unauthenticated HTTP deployment assumption is unchanged.
