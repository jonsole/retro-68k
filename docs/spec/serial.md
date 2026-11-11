# Spec 14: USB serial

Status: **draft for review**

The USB serial link connects the computer to a PC through a small FT232H USB module plugged onto the KS3's accelerator port. It carries the console (text in and out), program and file uploads, and debug commands. On the PC it appears as an ordinary serial port, so any terminal program works.

## 1. Summary

| Item | Value |
|------|-------|
| Hardware | An **FT232H USB module** (e.g. FTDI UM232H-B or an FT232H breakout board) on the KS3's accelerator port (`accel_io`, 3.3 V), wired to the FPGA as an 8-bit parallel FIFO. The module is powered from its own USB cable |
| On the PC | A normal serial port (e.g. `/dev/ttyUSB1` or `COM5`). The baud rate setting is ignored |
| Speed | Several MB/s each way (the FT232H's asynchronous FIFO mode allows up to about 8 MB/s; the PC side usually sets the real limit) |
| Flow control | Automatic in hardware, both ways: no data is ever lost and no XON/XOFF or RTS/CTS is needed |
| Buffers | 2 KB receive and 2 KB transmit FIFOs in the FPGA, plus the FT232H's own 1 KB each way |
| CPU access | A data register for bytes, status with counts, interrupts on thresholds and a timeout |
| DMA | DMA engine port 1 (spec 11): bulk transfers with no CPU work |
| Low delay | The FPGA tells the FT232H to send at once when the transmit FIFO empties, so console text appears without the usual 16 ms USB delay |
| Control commands | A 3-byte command from the PC (`C0 c ~c`, with the PC's other bytes SLIP-escaped) triggers NMI (break into the debugger), reset, or reset into the upload loader, even when the 68000 has hung |

## 2. How the FIFO link works

The FT232H runs in **asynchronous 245 FIFO mode**. Its EEPROM must be set for this once, with FTDI's free FT_Prog tool (open point U1). The module plugs onto the accelerator port (the Raspberry Pi header, 28 GPIO pins at 3.3 V); which `accel_io` pins carry which signal is still to be decided (open point U6). It uses 13 signals plus ground:

| Signal | Direction | Meaning |
|--------|-----------|---------|
| D7–D0 | Both | Data byte |
| RXF# | FTDI → FPGA | Low: the FT232H has a byte from the PC waiting |
| RD# | FPGA → FTDI | Pulse low to read that byte |
| TXE# | FTDI → FPGA | Low: the FT232H has room for a byte to the PC |
| WR# | FPGA → FTDI | Pulse high-to-low to write a byte |
| SIWU# | FPGA → FTDI | "Send immediate": send what it holds to the PC now |

**Flow control comes for free:**

- **PC to computer:** the FPGA only reads from the FT232H while its receive FIFO has room. When the FIFO is full, the FT232H's buffer fills, and USB then holds the PC back. Nothing is dropped, however fast the PC sends or however slowly software reads.
- **Computer to PC:** the FPGA only writes when TXE# says there is room. If the PC isn't reading, the FT232H's buffer and then the transmit FIFO fill up (section 4.3).

**Low delay:** the FT232H normally waits up to 16 ms (its latency timer) before sending a small amount of data. When the FPGA's transmit FIFO becomes empty after sending, it pulses SIWU#, so short console messages reach the PC straight away.

**Later, faster:** the FT232H also has a **synchronous 245 FIFO mode**, up to about 40 MB/s. It needs two more signals, the module's 60 MHz clock output (CLKOUT) and OE#. The accelerator port has pins to spare, so this can be added later without new hardware (open point U5).

**Without the module:** the KS3's ESP8266 WiFi module is wired to the FPGA by a UART. It could carry a slow console (a few hundred KB/s at most) if no FT232H is fitted. Not planned for version 1.

## 3. Control commands from the PC

The link has no separate "break" signal in FIFO mode, so the PC sends commands in the data stream. While recognition is on (CTLEN or CTLLOCK set), the bytes from the PC are SLIP-style. Two byte values are kept for the link:

| Bytes from the PC | Reach the FIFO as | Meaning |
|-------------------|-------------------|---------|
| `C0 c ~c` | Nothing | A control command (table below) |
| `DB DC` | `C0` | An escaped data byte |
| `DB DD` | `DB` | An escaped data byte |
| `DB` then any other byte | That byte | Not sent by the PC tools; passed on |
| Any other byte | Itself, at once | Data |

| c | ~c | Command | Effect |
|---|----|---------|--------|
| `0x01` | `0xFE` | BREAK | NMI (spec 13, NMISTAT.USB), to enter a debug monitor. Only while CTLEN is set |
| `0x02` | `0xFD` | RESET | Reset the computer (RESETWHY.USB) |
| `0x03` | `0xFC` | UPLOAD | Reset the computer with RESETWHY.UPLOAD set, so the boot ROM's loader waits for a program over the link (the shared spec "Monitor and upload protocol", [`monitor.md`](monitor.md), section 6). This is the only way into UPLOAD: a long press of the reset button is a plain reset |

- The commands and escapes are handled in hardware, so commands work even when the 68000 has crashed or runs with interrupts off.
- The command's 3 bytes and the escape bytes are removed from the stream; software and the DMA engine (port 1) see only the data, in order.
- **No data byte waits for the next one.** Only a `DB` or a command's bytes are held, and the PC always sends what completes them at once: a `C0` with nothing after it would wait, but the PC tools never send one. (An earlier 16-byte sequence, `00 FF "R68K-CTL" FF 00 A5 5A c ~c`, held back any bytes that might start it, so a message ending in `0x00`, such as a frame whose CRC ends in `0x00`, was seen only when the next byte came. The retro-z80 session found it on its board; this design is shared with it.)
- The decoder's state (in an escape, in a command) is cleared at power-on only, like the FT232H interface, so the link survives other resets. A reset cannot come in the middle of a command: the command itself causes it.
- **Terminals:** a plain terminal program sends its bytes unescaped. That is fine for ASCII. In UTF-8, `C0` never appears, but `DB` is a lead byte (U+06C0–U+06FF), so such a character would be decoded wrongly. For binary or non-ASCII text use `rlink.py term`, which escapes.
- A broken command (a wrong inverse, or a code other than 1–3) is dropped. A `C0` always starts a command again, even inside another one.
- The PC tools escape every byte they send except the commands. Random data grows by about 0.8 %.
- With CTLEN and CTLLOCK both clear, every byte goes to the FIFO as it is, `C0` and `DB` too: a program can then run its own protocol on the link, and the PC must not escape.
- **SERCON.CTLEN** turns recognition off (it is on after reset, so a hung machine can always be reached). With **SERCON.CTLLOCK** set, RESET and UPLOAD still work when CTLEN is off. Once set, CTLLOCK cannot be cleared by software; a reset clears it.

The PC tool `tools/rlink.py`, shared with retro-z80, sends the commands and uploads programs with the upload protocol of [`monitor.md`](monitor.md) (sections 6 and 8).

## 4. Using the link from the CPU

### 4.1 Reading and writing bytes

- **Receive:** reading the low byte of SERDATA takes the next byte from the receive FIFO. SERSTAT.RXCOUNT says how many are waiting. Reading when the FIFO is empty returns SERDATA.EMPTY set and no byte.
- **Send:** writing the low byte of SERDATA puts a byte in the transmit FIFO. SERSTAT.TXSPACE says how much room there is.
- The CPU never waits on a full or empty FIFO; it checks the counts or uses interrupts.

### 4.2 Interrupts

The link is source SERIAL (15) in the interrupt controller (spec 13). It can interrupt when:

| Flag | When |
|------|------|
| RXREADY | At least RXLEVEL bytes are waiting |
| RXTIMEOUT | At least one byte has waited longer than RXTIME microseconds without reaching RXLEVEL. This catches the end of a message without polling |
| TXREADY | At least TXLEVEL bytes of room are free |
| TXOVF | A byte was written while the transmit FIFO was full, and was lost |

A typical console driver sets RXLEVEL = 1 (interrupt on every key) or a larger level plus a short timeout for bulk data.

### 4.3 When nothing is reading on the PC

If no program on the PC has the port open, sent data piles up: first in the FT232H, then in the transmit FIFO. Software can treat a full FIFO as "nobody listening". With **SERCON.TXDROP** set, the oldest bytes are dropped to make room instead, so debug output never holds a program up. Dropped bytes are counted in SERDROP.

### 4.4 Bulk transfers with the DMA engine

The DMA engine's **port 1** is this link (spec 11, section 4). A channel can copy a whole file to or from Chip RAM at full speed, paced automatically by the FIFOs, while the CPU does other work. Control-command recognition still works during DMA.

## 5. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rule (spec 3, section 2).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x200` | SERCON | EN (0), CTLEN (1), CTLLOCK (2), TXDROP (3) | Link on; recognise control commands (on after reset); keep RESET and UPLOAD working when CTLEN is off; drop old data instead of filling up |
| `0x204` | SERSTAT | RXCOUNT 27–16, TXSPACE 11–0 | Bytes waiting; room to send (0–2048) |
| `0x208` | SERDATA | Read: EMPTY (8), byte 7–0. Write: byte 7–0 | Reading the low half takes one byte (a MOVE.L, high half then low, takes one; the high half alone takes nothing); writing the low byte sends one byte |
| `0x20C` | SERLEVEL | RXLEVEL 27–16, TXLEVEL 11–0 | Interrupt thresholds |
| `0x210` | SERTIME | 15–0 | RXTIMEOUT time, in microseconds |
| `0x214` | SERIRQ | RXREADY (0), RXTIMEOUT (1), TXREADY (2), TXOVF (3) | Flags. RXREADY and TXREADY follow the FIFO levels; RXTIMEOUT and TXOVF are sticky, write 1 to clear |
| `0x218` | SERIRQEN | Same layout as SERIRQ | Interrupt enables |
| `0x21C` | SERDROP | 15–0 | Read: bytes dropped by TXDROP since last read (reading the low half clears it) |

## 6. FPGA resources

| Item | Resource |
|------|----------|
| Receive and transmit FIFOs, 2 KB each | 2 block RAMs (in the design plan's budget) |
| FIFO interface, control-sequence matcher, timers, registers | Estimate 250–400 LUTs |
| Pins | 13 on the accelerator port (15 with synchronous mode later) |

## 7. Open points

| # | Item |
|---|------|
| U1 | Set the FT232H module's EEPROM to 245 FIFO mode with FT_Prog (once, before first use) |
| U2 | Measure real throughput with Linux and Windows drivers |
| U3 | Settled: the upload protocol is in the shared spec `monitor.md`, and the control commands and escapes (section 3) are agreed with retro-z80 |
| U4 | Should the link offer several logical channels (e.g. console and debugger at once)? For now software can share the one stream |
| U5 | Synchronous 245 FIFO mode (up to about 40 MB/s): needs the FT232H's 60 MHz CLKOUT and OE# on two more accelerator-port pins |
| U6 | Which `accel_io` pins carry the 13 signals, and which FT232H module to recommend (pin order, how it plugs onto the Pi header). Provisional in the KS3 build: `accel_io[7:0]` D7–D0, `[8]` RXF#, `[9]` TXE#, `[10]` RD#, `[11]` WR#, `[12]` SIWU# |

## 8. Tests

- **Loopback:** a PC test sends megabytes of random data; the computer echoes it back; check it arrives complete and in order, with software reading slowly and quickly.
- **Flow control:** stop reading on the computer for seconds while the PC sends; nothing is lost.
- **No listener:** with the PC port closed, sends fill up; with TXDROP, old bytes drop and are counted.
- **Control commands and escapes** (`make serial`, and the `+serial` boot test): a frame ending in `0x00` reaches the FIFO at once; `DB DC` and `DB DD` give `C0` and `DB`; BREAK gives one NMI; RESET and UPLOAD reset with the right RESETWHY; none of a command's bytes reach the FIFO; broken commands are dropped; CTLLOCK alone keeps RESET and UPLOAD; with CTLEN and CTLLOCK clear every byte goes on raw.
- **Interrupts:** RXREADY, RXTIMEOUT, TXREADY and TXOVF at their thresholds.
- **DMA:** port 1 transfers in both directions at full speed.
- **Latency:** a single byte sent by the computer reaches the PC in well under 16 ms.
