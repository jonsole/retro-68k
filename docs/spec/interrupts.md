# Spec 13: Interrupt controller

Status: **draft for review**

The interrupt controller gathers every interrupt request in the machine and passes them to the 68000. Each source gets **its own vector**, so the CPU jumps straight to the right handler with no need to work out who interrupted. Each source's **priority level** can be changed. The controller lives in the **system area** at `0xF00000`, so the copper cannot change it.

## 1. Summary

| Item | Value |
|------|-------|
| Sources | 24, plus NMI |
| Vectors | One per source: vector = VECBASE + source number (default VECBASE = 64, the first 68000 user vector) |
| Levels | Each source can be set to level 1–6, or 0 (off). Defaults follow the design plan |
| NMI (level 7) | The KS3's NMI (Multiface) button, and a "break" request from the USB host |
| Within a level | Lower source number goes first |
| Software interrupt | The CPU can raise one for itself, to do work later at a lower priority |
| Spurious requests | Handled with the 68000's spurious-interrupt vector (24) |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Sources | 14 | 24 + NMI |
| Vectors | Autovectored: one vector per level; the handler reads INTREQR to find the source | One vector per source |
| Levels | Fixed per source | Programmable per source |
| Masking | INTENA (set/clear, bit 15), with a master bit | INTENA (two set/clear halves, bits 15 and 31), with a master bit |
| Software interrupt | SOFTINT | SOFTINT |
| NMI | Level 7, rarely used | Button and USB "break", for a debug monitor |

## 3. How an interrupt reaches the CPU

1. A unit (video, audio, blitter, timer…) sets a status flag. If that flag's enable is on in the unit, the unit raises its **request line** to the controller. Each unit keeps its own flags and enables, as described in its spec.
2. If the source is enabled in **INTENA** and the master enable is on, the request is **pending**.
3. The controller finds the highest level with a pending source and drives the 68000's IPL lines with that level.
4. When the CPU's interrupt mask allows it, the 68000 runs an **interrupt-acknowledge cycle** for that level. The controller answers with the vector of the pending source at that level with the lowest source number, and asserts /DTACK. This is a normal internal bus cycle, with no memory cycle and no wait states (spec 5, section 5).
5. The handler clears the cause in the unit (usually by writing 1 to the unit's sticky flag). The request drops. If another source at the same level is still pending, the CPU is interrupted again straight after the handler returns.

Requests are **level-sensitive**: a source stays pending until its unit's flag is cleared, so no interrupt is ever lost.

**Spurious interrupt:** if a request disappears between steps 3 and 4 (for example, the CPU cleared the flag itself), the controller answers with vector 24, the 68000's spurious-interrupt vector. Its handler can simply return.

**Response time:** the 68000 checks for interrupts between instructions, then takes 44 clocks to start the handler. At 20 MHz that is 2.2 µs plus the rest of the current instruction (at most about 8 µs, for a long divide).

## 4. Sources

| Source | Vector (default) | Name | From | Default level |
|--------|------------------|------|------|---------------|
| 0 | 64 | VBLANK | Video: start of vertical blanking (VIDSTAT.VBLANK) | 5 |
| 1 | 65 | LINE | Video: line compare (VIDSTAT.LINE) | 5 |
| 2 | 66 | COPPER | The copper: COPSTAT.IRQ (raised by a write to COPINT) with COPCON.IRQEN; cleared by writing 1 to COPSTAT.IRQ (spec 10) | 5 |
| 3 | 67 | VIDERR | Video: a layer ran short (VIDSTAT.OVERRUN, spec 4, section 5.3) | 5 |
| 4 | 68 | BLT | The blitter: a job with IRQ ended, or the blitter stopped (DMXINT with DMXINTEN, spec 11) | 4 |
| 5–7 | 69–71 | – | Not used (were DMA engine channels 1–3) | 4 |
| 8 | 72 | – | Not used in version 1 (was AUDSTR; there is no audio stream) | 0 (off) |
| 9 | 73 | AUDIO | Audio: a channel took its registers, at its start or the end of a block (AUDSTAT with AUDINTEN, spec 6) | 4 |
| 10 | 74 | – | Not used in version 1 (was AUDERR) | 0 (off) |
| 11 | 75 | TIMER0 | Timer 0 underflow | 6 |
| 12 | 76 | TIMER1 | Timer 1 underflow | 6 |
| 13 | 77 | TIMER2 | Timer 2 underflow | 6 |
| 14 | 78 | TIMER3 | Timer 3 underflow | 6 |
| 15 | 79 | SERIAL | USB serial: data received, timeout, room to send, overflow (spec 14) | 3 |
| 16 | 80 | – | Not used in version 1 (was SD; the v1 SD card is a plain SPI byte master that software polls, spec 15) | 0 (off) |
| 17 | 81 | KEYB | PS/2 keyboard: byte received (spec 16) | 2 |
| 18 | 82 | SOFT | Software interrupt (SOFTINT) | 1 |
| 19–23 | 83–87 | – | Reserved (e.g. mouse, joysticks, accelerator-port pins) | 0 (off) |

The audio channel flags that share one source (AUDIO) are told apart by reading the unit's status register in the handler. Unused sources keep their numbers, so later versions can bring them back without moving the others.

**Choosing levels:** the defaults put timers highest (an operating system tick should not be held up by graphics), then video (VBLANK and LINE handlers have to run on time for smooth animation), then audio and DMA, serial, and the slow devices. Software can change any of them, for example raising LINE to level 6 for precise raster effects.

## 5. NMI (level 7)

Level 7 cannot be masked by the 68000. It is kept for getting control back from a hung or misbehaving program:

- **NMI button:** the KS3's NMI button (the one the Next uses for its Multiface), debounced in the FPGA.

The KS3's third button, DivMMC, is not an interrupt source: software reads it in a system register, and the boot ROM uses it as the "monitor" button (spec 7).
- **USB break:** a BREAK command from the PC over the USB link (spec 14, section 3), so a debugger on the PC can stop the 68000 at any moment.

Both use vector 31, the 68000's usual level 7 vector; the controller supplies it during the acknowledge like any other vector. NMISTAT says which one it was. NMICON can turn each off, for example so the USB break only works while debugging. NMI is edge-triggered on the 68000, so each press or break gives exactly one interrupt.

## 6. Software interrupt

Writing SOFTINT.SET raises source 18; writing SOFTINT.CLR clears it. A typical use: a high-priority handler (e.g. VBLANK) does the urgent part and raises the software interrupt to do the rest at level 1, once nothing more important is waiting. This is the Amiga's SOFTINT idea.

## 7. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rule (spec 3, section 2).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | INTCON | MASTER (0) | All interrupts (except NMI) on/off. Off after reset |
| `0x004` | INTENA | SETCLRH (31), sources 15–23 (24–16), SETCLRL (15), sources 0–14 (14–0) | Enables. Two set/clear halves, as the Amiga's INTENA: in each 16-bit half, writing with the top bit = 1 sets the bits written as 1, with it = 0 clears them; bits written as 0 are left alone. Each half can be written on its own with `MOVE.W`, or both with `MOVE.L`. Reads give the enables (bits 31 and 15 read 0). All off after reset |
| `0x008` | INTPEND | As INTENA | Read: sources pending (requesting and enabled) |
| `0x00C` | INTRAW | As INTENA | Read: sources requesting, before INTENA |
| `0x010` | INTPRI0 | 8 × 4 bits | Levels of sources 0–7: source n in bits 4n+2 … 4n (0 = off, 1–6) |
| `0x014` | INTPRI1 | 8 × 4 bits | Sources 8–15 |
| `0x018` | INTPRI2 | 8 × 4 bits | Sources 16–23 |
| `0x01C` | VECBASE | 7–0 | First vector (64–232, default 64). Source n uses VECBASE + n |
| `0x020` | SOFTINT | SET (0), CLR (1) | Write 1 to raise or clear the software interrupt |
| `0x024` | INTID | 4–0 | Read: the source given at the last interrupt acknowledge, for debugging |
| `0x028` | NMICON | BUTTONEN (0), USBEN (1) | Enable each NMI source. Both on after reset |
| `0x02C` | NMISTAT | BUTTON (0), USB (1) | Which caused the last NMI; sticky, write 1 to clear |

**Bit positions:** in INTENA, INTPEND and INTRAW, source n is bit n for sources 0–14, and bit n + 1 for sources 15–23 (bit 15 is the low half's SET/CLR bit). `hw.inc` names each position: `INTB_VBLANK` … `INTB_SOFT`.

After reset everything except NMI is off, so the boot ROM can set up its vector table (in RAM, once the ROM overlay is off) before enabling anything.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| 24-source priority encoder, level table, vector logic, NMI debounce | Estimate 200–300 LUTs |
| Block RAM, DSP | None |

## 9. Open points

| # | Item |
|---|------|
| I1 | Whether any accelerator-port pins should be able to raise interrupts (sources 19–23) |
| I3 | Use of the reserved sources 19–23 |

## 10. Tests

- **Vectors and levels:** every source gives VECBASE + n at its set level; changing a level takes effect at once. (The controller registers the pending requests, so a request reaches the CPU one system clock, 10 ns, after it is raised.)
- **Priority:** several sources at one level are served lowest number first; a higher level interrupts a running lower-level handler.
- **Masking:** INTENA, the master bit, and the 68000's own mask each block interrupts as expected; nothing is lost while blocked.
- **Spurious:** a request withdrawn before the acknowledge gives vector 24.
- **NMI:** button and USB break each give exactly one interrupt per event, set NMISTAT, and can be turned off.
- **SOFTINT:** set, clear, and runs only after higher-level handlers finish.
- **Alignment:** interrupt-acknowledge cycles never add wait states or knock the CPU off its slot grid.
