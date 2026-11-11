# Spec 7: System: reset, boot ROM and start-up

Status: **draft for review**

This spec covers how the computer starts: what resets it and what a reset does, the boot ROM and its overlay at address 0, what the boot ROM does first, how the design is installed on the ZX Spectrum Next KS3 board, and the leftover system pieces: the board's buttons and connections, the I2C bus (real-time clock and HDMI DDC), and identification registers.

The other system-area devices have their own specs: timers (12), interrupt controller (13), USB serial (14), SD card (15) and keyboard (16).

## 1. Summary

| Item | Value |
|------|-------|
| Board | ZX Spectrum Next KS3 (issue 5): Artix-7 XC7A35T, 4 MB SRAM (design plan D1) |
| Reset sources | Power-on, reset button, watchdog, software, USB serial RESET/UPLOAD, Ctrl + Alt + Delete, CPU halted |
| What survives a reset | Chip RAM contents (except at power-on), the boot ROM contents, the USB link |
| Boot ROM | 32 KB of block RAM at `0xF80000`, loaded with the FPGA bitstream; can be made writable for development |
| Overlay | After every reset the ROM also appears at address 0 for reads, so the 68000 finds its start-up vectors; writes there go to Chip RAM. Software turns it off |
| 68000 RESET instruction | Resets the custom hardware and devices, not the CPU or the overlay |
| Start-up | A few microseconds from the end of FPGA configuration to the first 68000 instruction |
| Start-up progress | Shown as the screen's background colour (Amiga-style) and on the serial console. The board has no user LEDs or switches |
| Start-up options | Keys held during reset, and the DivMMC button |
| Buttons | Reset button = reset (a long press is the same as a short one: an upload comes only from the PC); Multiface button = NMI; DivMMC button = "monitor" button |
| I2C | A small I2C master for the battery-backed real-time clock and the HDMI DDC |
| Installing | Development: JTAG straight into the FPGA. Everyday use: an extra Next core in a free flash slot |

## 2. Reset

### 2.1 Reset sources

| Source | How | RESETWHY bit |
|--------|-----|--------------|
| Power-on | The FPGA finishes loading our configuration | POWER (0) |
| Watchdog | Not kicked in time (spec 12, section 5) | WATCHDOG (1) |
| Reset button | The KS3's reset button, debounced (10 ms) | BUTTON (2) |
| Software | Writing `0xA55A` to SYSRESET | SOFTWARE (3) |
| USB RESET | Control command from the PC (spec 14, section 3) | USB (4) |
| USB UPLOAD | Control command from the PC: reset, then wait for a program | UPLOAD (5) |
| Keyboard | Ctrl + Alt + Delete (spec 16, section 3.5) | KEYBOARD (6) |
| CPU halted | A double bus fault, if SYSCON.HALTRESET is set (spec 1, section 8) | HALTED (7) |

RESETWHY shows the cause of the last reset. It is kept in the system control registers (section 9); earlier specs that mention RESETWHY refer to this register.

### 2.2 What a reset does

All the sources above give the same **full reset**:

- The 68000 is reset and starts again from the vectors at address 0 (section 3).
- Every custom register and system device goes back to its reset value: video off, sprites, copper, DMA engine and audio stopped, all interrupts off, timers stopped, watchdog off, keyboard settings back to default.
- The ROM overlay is turned on.
- **Chip RAM keeps its contents.** Chip RAM is static RAM (SRAM), which holds its data for as long as the board is powered, with no refresh. So after anything except power-on, memory holds what it held before. Debug tools can look at what a crashed program left behind, and software can choose to keep data across resets (as some Amiga programs did).
- **The boot ROM keeps its contents,** including any changes made while it was writable (section 3.3). Only reloading the FPGA restores the original.
- **The USB serial link stays up.** Its buffers are cleared, but the FT232H module and the PC's serial port are not disturbed, so a terminal stays connected across resets.

### 2.3 Power-on sequence

1. The FPGA loads our design: from its Next core slot in the board's flash, or over JTAG during development (section 7). Loading from flash takes a fraction of a second, depending on the flash read mode and the image size (open point SY1).
2. The master clock (MMCM) locks (spec 4, section 3.1).
3. The 68000 is released from reset.

The SRAM needs no start-up sequence, so steps 2 and 3 take a few microseconds. At every later reset only step 3 happens.

### 2.4 The 68000's RESET instruction

The 68000's RESET instruction resets external hardware without resetting the CPU. Here it resets:

- the custom hardware (video, sprites, copper, DMA engine, audio) and its registers,
- the interrupt controller, timers (except the watchdog and the 64-bit time counter), SD card controller, keyboard controller and I2C master.

It does **not** change the overlay, memory, the watchdog, the time counter, RESETWHY, or the USB link. An operating system can use it to put all the hardware into a known state without restarting.

## 3. Boot ROM and overlay

### 3.1 The boot ROM

- 32 KB of block RAM at `0xF80000`–`0xF87FFF` (design plan D11), like the Amiga's Kickstart at `0xF80000`.
- Its contents are part of the FPGA bitstream. The build puts the assembled boot ROM into the bitstream, so the ROM can be changed without changing the FPGA design itself.
- Reading it costs no memory slots and no wait states.

### 3.2 The overlay

After any reset, the 68000 reads its first two long words (stack pointer and start address) from address 0. Chip RAM (the 4 MB SRAM) is at address 0, so the **overlay** makes the ROM appear there too:

| While the overlay is on | Effect |
|-------------------------|--------|
| CPU reads from `0x000000`–`0x007FFF` | Come from the boot ROM |
| CPU writes to `0x000000`–`0x007FFF` | Go to Chip RAM underneath |
| DMA and video | Always see Chip RAM; the overlay is for the CPU only |

So the boot ROM can:

1. start (its start address points into `0xF80000`, its real address),
2. build the 68000's vector table in Chip RAM at address 0 (writes already go to RAM),
3. turn the overlay off by clearing SYSCON.OVERLAY.

From then on, address 0 is Chip RAM for reading and writing. The overlay comes back at every reset, but not after the RESET instruction.

### 3.3 Writable boot ROM, for development

Rebuilding the FPGA with Vivado takes minutes. To try new boot ROM code quickly:

- Setting **SYSCON.ROMWE** makes the boot ROM writable.
- A program (or the USB upload loader) copies a new ROM image to `0xF80000`, then resets.
- The new ROM runs from the next reset onwards, until the FPGA is reloaded.
- **SYSCON.ROMLOCK** makes ROMWE impossible to set until the next power-on, for when the system should not be changed by accident. The boot ROM decides it at power-on only (RESETWHY.POWER): it sets it unless the development key (D) is held (section 5). Later resets leave it as it is, so a development session can still take a new ROM image after an UPLOAD reset (the shared monitor spec, section 9).

## 4. What the boot ROM does

The boot ROM's own spec will define this in detail; the monitor, the upload protocol, the image header and the boot file (`BOOT.68K`) are in the shared spec `monitor.md`, the same file in retro68k and retro-z80. In outline:

1. Show progress as the screen's background colour, and on the serial console, at each step (section 5).
2. Read RESETWHY, the keys held down and the DivMMC button.
3. On power-on only: test Chip RAM.
4. Set up the vector table in RAM, turn the overlay off, set up interrupts and a 1000 Hz timer tick.
5. Start the default screen: an 80×30 text console, drawn with the ROM font into a 1-plane 640×480 bitmap layer, in a window centred in the 720×576 (576p) screen at (40, 48), with the background colour as a border. There is no text layer.
6. **If RESETWHY.UPLOAD, or U is held:** wait for a program over the USB serial link and run it.
7. **Otherwise:** start the SD card. If it holds a boot file, load and run it.
8. **If there is no boot file, or M or the DivMMC button is held:** start the monitor, on the screen and the USB serial console at once. BASIC comes later (phase 7).

## 5. Start-up progress, start-up options and identification

The KS3 has no user LEDs or switches, so:

- **Start-up progress and errors** are shown as the screen's **background colour** (BGCOLOR, spec 4), as the Amiga did: a colour for each start-up step, and a distinct colour for each error (for example "Chip RAM test failed"). The background shows on HDMI and VGA even before any layer is set up. The same messages go to the USB serial console.
- **Start-up options** come from keys held during reset, read from the keyboard's key map (spec 16), and from the DivMMC button:

| Held during reset | Effect at start-up |
|-------------------|--------------------|
| M, or the DivMMC button | Go straight to the monitor |
| U | Wait for a program over USB |
| D | Development: leave the boot ROM writable (don't set ROMLOCK) |

Keys can be held on the PS/2 keyboard or the Spectrum keyboard (spec 16).

- **Buttons:** the Multiface button is the NMI button (spec 13). The DivMMC button can be read at any time in SYSBTN; the boot ROM uses it as the "monitor" button. The reset button resets (section 2.1).
- **Identification:** SYSID reads `0x5236384B` ("R68K"). SYSVER gives the FPGA build version. SYSCFG describes the hardware, so one boot ROM and one operating system can run on different builds:

| SYSCFG field | Meaning |
|--------------|---------|
| CPU (1–0) | Always 0: fx68k inside the FPGA |
| CPUMHZ (9–2) | CPU clock in MHz (20) |
| CHIPMB (15–10) | Chip RAM size in MB: 4 (2 on boards with 2 MB) |
| FASTMB (21–16) | Always 0: no Fast RAM on the KS3 |

## 6. I2C: real-time clock and HDMI DDC

The KS3 has one I2C bus to a **battery-backed real-time clock** and to the HDMI connector's DDC lines (which carry the monitor's description, EDID). A small I2C master in the system block lets software use both:

- **Real-time clock:** software reads and sets the date and time over I2C. It keeps time while the board is off, so the boot ROM and operating system know the date (timers spec 12, open point T1).
- **HDMI DDC:** software can read the monitor's EDID to see which video modes it supports.

The master works one byte at a time. Software:

1. sets the clock speed in I2CCON (100 or 400 kHz),
2. writes a byte to I2CDATA (for writes),
3. writes I2CCMD with any of START, WRITE or READ, STOP and ACK,
4. waits for I2CSTAT.BUSY to clear (or polls), then checks NACK and reads I2CDATA (for reads).

A transfer of a few bytes to the clock takes well under a millisecond, so no interrupt or DMA is needed.

| Register | Bits | Meaning |
|----------|------|---------|
| I2CCON | EN (0), CLKDIV (15–8) | On; SCL = 100 MHz ÷ (4 × (CLKDIV + 1)): CLKDIV = 249 gives 100 kHz, 61 gives about 400 kHz |
| I2CDATA | 7–0 | Byte to send, or the byte received |
| I2CCMD | START (0), STOP (1), WRITE (2), READ (3), ACK (4) | Writing starts the steps set, in order: START, then WRITE or READ, then STOP. With READ, ACK = 1 sends an acknowledge (more bytes to come), ACK = 0 sends none (last byte) |
| I2CSTAT | BUSY (0), NACK (1), ARBLOST (2) | Read: a command is running; the last byte written was not acknowledged; another master took the bus. NACK and ARBLOST are cleared by the next command |

## 7. Installing on the KS3

The Next keeps several FPGA designs ("cores") in its configuration flash, in slots. Slot 0 holds the anti-brick core and slot 1 the Next itself. **Those two slots are never touched.**

- **Development:** the design is loaded straight into the FPGA over the board's JTAG header, with Vivado (or openFPGALoader) and a JTAG cable. Nothing is written to the flash; turning the power off brings back the normal Next.
- **Everyday use:** the design is installed as an extra Next core in a free flash slot, and started from the Next's core menu. The exact KS3 core file format and slot size are to be confirmed (open point SY5): an XC7A35T image is about 2.2 MB, bigger than the 512 KB slots documented for the older Spartan-6 boards.

## 8. Board connections

| Connection | Use |
|------------|-----|
| Accelerator port (28 pins, Raspberry Pi header) | The FT232H USB serial module (spec 14). Remaining pins free |
| HDMI and VGA | Video (spec 4) |
| Audio jack and internal speaker | Audio (spec 6) |
| SD card slot | Storage (spec 15) |
| PS/2 keyboard and the Spectrum keyboard | Keyboard (spec 16) |
| Reset, Multiface and DivMMC buttons | Section 5 |
| I2C (real-time clock, HDMI DDC) | Section 6 |
| PS/2 mouse, joystick ports | Not used yet |
| ESP8266 WiFi module | Not used yet |
| Spectrum expansion connector | Not used |

## 9. Registers

System control registers, in the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x800` | SYSID | 31–0 | Read: `0x5236384B` ("R68K") |
| `0x804` | SYSVER | 31–0 | Read: FPGA build version |
| `0x808` | SYSCFG | see section 5 | Read: hardware description |
| `0x80C` | RESETWHY | POWER (0), WATCHDOG (1), BUTTON (2), SOFTWARE (3), USB (4), UPLOAD (5), KEYBOARD (6), HALTED (7) | Read: cause of the last reset |
| `0x810` | SYSCON | OVERLAY (0), ROMWE (1), ROMLOCK (2), PROTECT (3), HALTRESET (4) | Overlay on (set at every reset); boot ROM writable; lock ROMWE off until power-on; user-mode hardware accesses give bus errors; reset when the CPU halts (spec 1) |
| `0x814` | SYSRESET | 15–0 | Write `0xA55A` to reset the computer; other values are ignored |
| `0x818` | SYSBTN | MULTIFACE (0), DIVMMC (1) | Read: 1 = button pressed (debounced) |
| `0x820` | SYSSTAT | HALTED (0) | Read: the CPU is halted (spec 1, section 8) |
| `0x824` | BUSERRADDR | 23–0 | Read: address of the last bus error (spec 1, section 6) |
| `0x828` | BUSERRWHY | UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3) | Read: cause of the last bus error |
| `0x840` | I2CCON | EN (0), CLKDIV (15–8) | I2C master on; clock divider (section 6) |
| `0x844` | I2CDATA | 7–0 | Byte to send, or byte received |
| `0x848` | I2CCMD | START (0), STOP (1), WRITE (2), READ (3), ACK (4) | Write: run these steps |
| `0x84C` | I2CSTAT | BUSY (0), NACK (1), ARBLOST (2) | Read: status |

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Boot ROM, 32 KB | 16 block RAMs (already in the design plan's budget) |
| Reset control, overlay decode, button debounce, system registers | Estimate 100–200 LUTs |
| I2C master | Estimate 80–150 LUTs |

## 11. Open points

| # | Item |
|---|------|
| SY1 | Measure the FPGA configuration time from the KS3's flash, and whether a faster flash read mode can be set in the bitstream |
| SY2 | The boot ROM spec: the monitor commands, upload protocol, image header and boot file are settled in the shared spec `monitor.md` (agreed with retro-z80). Left for retro68k's own boot ROM spec: its break instruction (planned ILLEGAL, `0x4AFC`), ROM calls (planned TRAP #15, function number in D0), traps, address limits, registers whose reads have side effects, what a program inherits, and the background colour codes (the shared spec's open point M2) |
| SY4 | Which real-time clock chip the KS3 uses, and its I2C address and register layout |
| SY5 | The KS3 core file format and flash slot size, and how a core is installed from the SD card |

## 12. Tests

- **Each reset source** resets the CPU and hardware and sets the right RESETWHY bit.
- **Memory survives:** write a pattern to Chip RAM, reset by each non-power source, check the pattern is still there.
- **Overlay:** after reset, reads at 0 come from ROM and writes go to RAM; clearing OVERLAY shows the written RAM; DMA always sees RAM.
- **RESET instruction:** resets the hardware but not the CPU, overlay, watchdog or time counter.
- **Writable ROM:** with ROMWE, a new image runs after reset; with ROMLOCK, ROMWE can't be set until power-on.
- **USB link across reset:** a terminal stays connected and keeps working after every kind of reset except power-on.
- **Start-up time:** from configuration done to the first instruction within a few microseconds.
- **Buttons:** SYSBTN follows the Multiface and DivMMC buttons, debounced.
- **I2C:** read and set the real-time clock; read the monitor's EDID; a missing device gives NACK.
