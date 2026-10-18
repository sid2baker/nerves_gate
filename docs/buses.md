# CAN and RS485 diagnostics

**Equipment → RS485 1 / 2** (`ttyS3`/`ttyS4`) and **CAN 1 / 2** (`can0`/`can1`)
configure one bus each and run explicit, bounded diagnostics. Visiting a page sends
no traffic. One bus operation runs at a time, independently of LAN trials, USB and
VPN. Buses require EC100: QEMU reports them unsupported, and workstation UIs never
open local CAN sockets or serial ports.

## CAN

Status reports the kernel interface, up/down, bitrate, listen-only flag, controller
state and error and packet counters. These are observations, not proof of wiring,
termination or health.

Enable with the peer's bitrate: 10000, 20000, 50000, 100000, 125000, 250000, 500000
or 1000000 bit/s. Configuration takes the interface down, sets the bitrate and
**listen-only** mode, then brings it up; disable takes it down. This can interrupt
other local users, and a failed change can leave the interface down or partially
configured, so review observations before retrying. Kernel state is neither
persisted nor replayed at boot, and a service restart does not disable CAN.

Capture requires up and listen-only, rechecked before opening the receive socket,
and receives at most **200 classic frames or five seconds**. There is no transmit,
normal mode, automatic restart, CAN FD or bus bridge. Listen-only does not
acknowledge frames, so a lone transmitter may report errors. Other privileged
processes can still change the interface.

## RS485

Only `/dev/ttyS3` and `/dev/ttyS4` are used; UART0 stays the boot console. Presence
means a character device exists, not that a peer is wired or the port is free.
Enabling only permits explicit operations; it opens nothing and resets to disabled
when the service restarts.

The only profile is **9600 baud, 8N1, no flow control**, which the BSP qualified with
automatic transceiver direction. No GPIO, DE/RTS polarity or RS485 ioctl mode is
guessed. Each operation opens the UART briefly and closes it; opening configures
termios without restoring another application's settings.

Passive capture transmits nothing and returns at most **4096 raw bytes or five
seconds** as hex.

### Modbus RTU

The operator must authorize **each** request and ensure there is no other master.
A 50 ms quiet-bus check rejects observed traffic before sending, but it is not
arbitration. Check the device's register map: even reads can have side effects.

- One request, no retries or unit discovery.
- Functions **3 (holding registers)** or **4 (input registers)** only.
- Unit **1–247**, never broadcast 0.
- Zero-based start address **0–65535**, **1–32 registers**, ending within 65535.
- Write bounded to 500 ms, then a one-second response deadline.
- Exact unit, function, length, byte count and CRC validation; exceptions reported.
- Fragmented responses are assembled; unrelated, echoed or corrupt frames are rejected.
- Results are unsigned 16-bit integers without scaling or word-order guesses.

There are no write functions, polling, arbitrary bytes or protocol probes. A lost
reply does not prove the device did nothing.

## Lifetime

A linked worker owns each socket or UART, stopped by a 6.5-second outer deadline or
shutdown. Results are bounded, memory-only and shared with current UI sessions; the
next operation clears them. Availability polling every five seconds is read-only.
UI drafts never overwrite observations, and apply uses the submitted values. The
UI has no sign-in; see [HTTP exposure](networking.md#local-recovery-and-http-exposure).
