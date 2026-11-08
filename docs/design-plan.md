# retro68k design plan

Status: **draft for review**. Nothing in `fpga/`, `firmware/` or `hardware/` gets built until the decisions below are agreed and each block has a written spec.

## Main path

The whole computer runs on a **ZX Spectrum Next KS3** board (issue 5). The 68000 is the fx68k core inside the board's Artix-7 FPGA, and main RAM is the board's fast SRAM. The only extra hardware is a small FT232H USB module for the serial console and uploads.

The design is installed as an extra core on the Next, next to the normal Next core, so the board keeps working as a Spectrum Next.

## 1. Requirements

| # | Requirement | Source |
|---|-------------|--------|
| R1 | CPU is a 68000: the fx68k core inside the FPGA, at 20 MHz | decided |
| R2 | Fast main memory: Chip RAM in fast SRAM, shared Amiga-style with DMA, where the CPU has its own memory cycle and waits only when the display would otherwise be late | project goal |
| R3 | Video, audio and glue logic are done by an FPGA | project goal |
| R4 | Video output is HDMI/DVI and VGA; one mode, 576p (720×576 at 50 Hz, CEA-861, 27 MHz); every line exactly 320 memory slots, so the display's DMA repeats the same way on every line | decided (version 1) |
| R5 | Audio: 4 Paula-style 8-bit sample channels | decided (version 1) |
| R6 | Usable as a home computer: boots to a monitor, then BASIC; PS/2 keyboard; SD card | decided ("both") |
| R7 | Usable as a game/demo machine: bitmap layers with scrolling, a copper, a DMA engine for copies and fills, sprites | decided ("both") |
| R8 | Hardware = the ZX Spectrum Next KS3, already owned | decided |

## 2. Key decisions

### D1. Board: ZX Spectrum Next KS3 (issue 5)

Checked against the official Next FPGA sources (`zxnext_top_issue5.vhd` and `zxnext_pins_issue5.xdc` in [gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA](https://gitlab.com/SpectrumNext/ZX_Spectrum_Next_FPGA)):

| Feature | Detail | Used for |
|---------|--------|----------|
| FPGA | Xilinx Artix-7 XC7A35T-2CSG324: 20,800 LUTs, 41,600 flip-flops, 100 × 18 Kb block RAM (225 KB), 90 DSP slices, 5 MMCMs | Everything |
| RAM | IS61WV204816BLL-10: 2M × 16 (4 MB) asynchronous SRAM, 10 ns | Chip RAM: main RAM, video memory, audio samples |
| Video | HDMI straight from the FPGA; VGA through an ADV7125 24-bit video DAC | Display, both at once |
| Audio | 2 pins to the audio jack through a filter, 1 to the internal speaker | Sound (sigma-delta) |
| SD card | One slot, wired for SPI mode only; no card detect | Storage |
| Keyboards | PS/2 keyboard and mouse sockets; the Spectrum membrane keyboard (8 × 7 matrix) | PS/2 keyboard; mouse and Spectrum keyboard later |
| Joysticks | 2 ports (Atari / Mega Drive style), multiplexed | Later |
| Buttons | Reset, Multiface, DivMMC | Reset, NMI, monitor |
| I2C | Battery-backed real-time clock; HDMI DDC | Later |
| Accelerator port | 28 GPIO pins (Raspberry Pi Zero header), 3.3 V | FT232H USB module |
| Other | ESP8266 WiFi on a UART; Spectrum edge connector | Not used for now |
| Clock | 50 MHz oscillator | MMCM input |
| Config flash | Core slots: slot 0 anti-brick, slot 1 the Next core, more for other cores | Installing the design |

What this means:
- **The SRAM is fast enough to give the CPU its own memory cycle in every 100 ns slot**, so the CPU normally never waits for the display, audio, copper or DMA engine (D5); as on the Amiga, a bitplane fetch that would otherwise be late takes the CPU's cycle. There is no Fast RAM: all RAM is Chip RAM.
- **Block RAM is 225 KB**, still too small for a 720×576×8bpp frame buffer (405 KB) plus everything else, so video memory stays in Chip RAM and is fetched just in time by DMA, as planned. The palette stays in block RAM; there is no text mode (the boot ROM's font is in the ROM).
- **No LEDs or switches.** The boot ROM shows start-up progress and errors as the screen's background colour (as the Amiga did) and on the serial console. Start-up options come from keys held during reset and the DivMMC button (spec 7).
- **Toolchain is Vivado** (the free edition covers the XC7A35T), scripted with Tcl in batch mode, on Linux or Windows.

### D2. The FPGA is the glue logic

The FPGA decodes addresses, drives `/DTACK`, encodes interrupts and generates the CPU clock and reset. Since the CPU is inside the FPGA, its bus is just signals in the chip: everything is synchronous and simple to simulate, and no glue chips are needed.

- **The boot ROM lives in FPGA block RAM** (32 KB), loaded with the bitstream, and can be made writable for development (spec 7).

### D3. Board connections

| Board part | Pins | Spec |
|------------|------|------|
| SRAM | 21 address, 16 data, /CS, /OE, /WE, /UB, /LB | 5 |
| HDMI | 4 differential pairs | 4 |
| VGA (ADV7125) | 4 pins per colour at double data rate, clock, sync | 4 |
| Audio | `audioext_l`, `audioext_r`, `audioint` | 6 |
| SD card | `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0` (`sd_cs1` unused) | 15 |
| PS/2 | Keyboard clock and data (mouse later) | 16 |
| Buttons | Reset, Multiface (NMI), DivMMC (monitor) | 7, 13 |
| Accelerator port | 13 pins for the FT232H module in 245 FIFO mode | 14 |

The full list is in spec 7, section 8.

### D4. Clocks

- **One master clock for the system, as on the Amiga.** MMCM 1, set once at power-on, makes a 200 MHz master from the 50 MHz oscillator (VCO 1000 MHz). The system clocks are the master divided by a whole number:
  - **System / SRAM controller: 100 MHz** (÷ 2)
  - **68000: 20 MHz** (fx68k clocked at 40 MHz, ÷ 5, with alternating phase enables)
  - **Memory cycle: 20 ns** (÷ 4); **slot: 100 ns = 5 memory cycles = 2 CPU clocks** (÷ 20), the Amiga's ratio
- **A second MMCM for the pixels.** MMCM 2 makes the 576p pixel clock from the same oscillator: 50 ÷ 5 × 108 = VCO 1080 MHz, ÷ 40 = **27 MHz**, and ÷ 8 = 135 MHz for the HDMI serialisers. The VGA DAC is clocked from the pixel clock.
- Both MMCMs run from one oscillator, so the frequencies are exact: every 576p line (864 pixels) is exactly 32 µs, **320 slots** (spec 4, section 3.1). The phase between the two MMCMs is not known, so the pixel clock is treated as an asynchronous clock domain: events cross through synchronisers and the data registers under a handshake.

### D5. Memory architecture and memory map

Defined in [spec 5: memory architecture](spec/memory-architecture.md). In short:

- **Amiga-style slots.** SRAM time is cut into 100 ns slots of 5 memory cycles (20 ns, 2 bytes each). **Cycle 0 of every slot belongs to the CPU**; cycles 1 and 3 to the display fetch; cycle 2 to audio and peripherals; cycle 4 is the free pool for the copper and the DMA engine. Cycles their owner doesn't use, including the CPU's, go to the free pool too. The plan is programmable (MEMSLOT0–4, spec 5, section 8.1).
- **The 20 MHz CPU waits for Chip RAM only when the display needs it:** one DMA scheduler (`dmac.v`, like the Amiga's Agnus) gives out every cycle; an urgent bitplane fetch may take the CPU's cycle 0, and that CPU access then waits one slot; a copper set to "nasty" priority or a HIGH DMA engine job owns cycle 0 while it asks (spec 5, section 6).
- **Chip RAM** = the 4 MB SRAM, shared with DMA. 100 MB/s in total.

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x3FFFFF` | 4 MB | Chip RAM (boot ROM overlays address 0 at reset) |
| `0x400000`–`0xDFFFFF` | | Reserved (bus error) |
| `0xE00000`–`0xE0FFFF` | 64 KB | Custom registers: video, audio, DMA engine, copper; palettes at `0xE04000`–`0xE04FFF` |
| `0xF00000`–`0xF0FFFF` | 64 KB | System: USB serial, timers, interrupts, SD, keyboard |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM (block RAM) |

Some boards may have 2 MB of SRAM; SYSCFG.CHIPMB reports which (spec 7).

### D6. Video

Defined in [spec 4: video](spec/video.md). In short:

- DVI over HDMI and VGA at the same time. **One mode, 576p:** 720×576 at 50 Hz with a 27 MHz pixel clock, as CEA-861 defines it, so every HDMI TV and monitor takes it; the digital form of PAL. No timing registers. The whole 720×576 is the overscan area; a normal screen is a centred window (for example a PAL Amiga 320×256 at 2× is 640×512 at (40, 32)), with the background colour as the border. Every line is exactly 320 slots
- **3 bitmap layers + background colour**, in any priority order. Each layer has its own display window, scroll, scale and 256-colour palette. No text layer. 8 sprites, Amiga-style (spec 9); the boot ROM draws its 80×30 console into a 1-plane 640×480 layer, centred at (40, 48)
- Each layer is **planar** (1–8 Amiga-style bitplanes) or **chunky** (1/2/4/8 bits per pixel), with Amiga-style plane pointers (BPLxPT), row stride (BPLSTRIDE) and data registers (BPLxDAT), and no hidden buffers. The copper resets the pointers each frame
- Whole-number scaling: 1×, 2×, 4× or 8×, across and down separately
- Video memory is fetched on demand by DMA as the beam scans, in memory cycles 1 and 3 of each slot only (no wide fetch). The budget is a rate: 4 bytes per 100 ns slot, 1.48 bytes per pixel. Layers never use the CPU's cycle
- A 256-entry palette of 24-bit colours per layer and one for the sprites (or one shared, VIDCON.SHAREPAL), or direct colour (L0 red, L1 green, L2 blue); beam position registers; vertical-blank and line interrupts; a copper (spec 10)

### D7. Audio

Defined in [spec 6: audio](spec/audio.md). In short:

- **4 Paula-style channels** of 8-bit samples from Chip RAM, played with nearest-sample playback (as on the Amiga); no CPU work while they play
- Sigma-delta DAC to the KS3's audio jack and internal speaker; HDMI audio later

### D8. Interrupts

Defined in [spec 13: interrupt controller](spec/interrupts.md). Every source has its own vector and a programmable level. Default levels:

| Level | Sources |
|-------|---------|
| 7 | NMI: Multiface button, USB "break" |
| 6 | Timers 0–3 |
| 5 | Video: vertical blank, line compare, video errors (OVERRUN) |
| 4 | DMA engine; audio channels, errors |
| 3 | USB serial |
| 2 | Keyboard |
| 1 | Software interrupt |

Interrupts are **vectored**: during the interrupt-acknowledge cycle the FPGA puts a vector number on the data bus and asserts `/DTACK`. Autovectoring through `/VPA` is not used: its slow E-clock cycle would only waste time.

### D9. Tools and languages

- **HDL:** plain Verilog-2005 so the design moves easily to another FPGA later.
- **Chip-specific parts go in small wrapper modules** in `fpga/rtl/platform/artix7/`: MMCMs, OSERDESE2 for HDMI, ODDR for the VGA DAC, block RAM, clock buffers and I/O pads. Each wrapper also has a plain behavioural version for simulation.
- **FPGA build:** Vivado (free edition), run from a Tcl script in batch mode, so builds are repeatable and nothing depends on the GUI.
- **Loading:** during development, straight into the FPGA over the KS3's JTAG header (Vivado or openFPGALoader), which leaves the flash alone. Finished builds are installed as a Next core.
- **Simulation:** Verilator for the full system, Icarus Verilog plus cocotb for block tests.
- **Soft CPU:** fx68k, a cycle-accurate 68000 core (see D10).
- **68000 software:** `vasm` for the boot ROM, `m68k-elf-gcc` later, and EhBASIC (68000 port) as the BASIC.
- **Register map:** `fpga/regmap.def` → `tools/regmap.py` → assembler, C and Verilog headers (spec 3, section 6).
- **CI:** GitHub Actions runs the register map check now, and lint (Verilator) and all simulations once there is RTL. FPGA builds happen locally in Vivado.

### D10. A 68000 core inside the XC7A35T

The fx68k core (a cycle-accurate 68000) fits easily. Trial synthesis on 2026-10-20: fx68k converted to Verilog with sv2v and synthesised with Yosys 0.33 (`synth_xilinx -family xc7`):

| Resource | fx68k uses | XC7A35T has | Share |
|----------|-----------|-------------|-------|
| LUTs | ~3,340 | 20,800 | ~16% |
| Flip-flops | ~1,440 | 41,600 | ~3% |
| 18 Kb block RAMs | 3 (microcode) | 100 | 3% |

This is a Yosys estimate; Vivado's results will differ somewhat. On ECP5 (nextpnr) fx68k reached 62 MHz on the slowest speed grade and 81 MHz on the fastest; the Artix-7 -2 is faster still, so 40 MHz has a large margin.

- **Vivado reads SystemVerilog**, so fx68k may not even need sv2v; the converted version is kept for Verilator, Icarus and Yosys. Yosys reported one latch in `rowDecoder`, which needs checking.
- **fx68k is GPL-3.0.** It will be added as a git submodule under `fpga/third_party/fx68k`. Any bitstream that includes it is covered by the GPL.

**Logic budget:** measured with Vivado (October 2026): about 15,400 LUTs (74%) with the CPU, video with sprites, copper, audio, the 4-channel DMA engine, SD card and keyboard; timing met at 100 MHz with little margin. Keep under about 85%.

### D11. Block RAM budget

The XC7A35T has 100 blocks of 18 Kb (2 KB each).

| Item | Blocks | Notes |
|------|--------|-------|
| fx68k microcode | 3 | From the trial synthesis (D10) |
| Boot ROM, 32 KB | 16 | |
| Video: palettes | 4 | Spec 4, section 7: four 256-entry palettes in one 1024 × 24 RAM, kept twice (one copy for CPU reads, one for the pixels). No line buffers, text screen or font; the plane registers are built from logic |
| USB serial FIFOs | 2 | Spec 14 |
| Keyboard byte FIFO | 1 | Spec 16 |
| **Total** | **24 of 100** | |

The boot ROM holds the console font (4 KB). Audio, the copper, the DMA engine and the SD card need no block RAM. The SRAM works from the first build, so no temporary block-RAM main memory is needed. The spare blocks leave room for a bigger boot ROM.

## 3. Specs to write before code

Each block gets a short spec first: its interface, registers, timing and a test plan. RTL is written against that spec.

1. [`docs/spec/bus-interface.md`](spec/bus-interface.md): **drafted.** fx68k at 40 MHz with phase enables, fixed-point 40/100 MHz crossing, bus cycle timing, decoding, wait states, bus errors, interrupt acknowledge, reset and halt
2. Memory map: folded into spec 3
3. [`docs/spec/registers.md`](spec/registers.md): **drafted.** Memory map, rules for all registers (32-bit, written and read as 16-bit halves), every register address in the custom and system blocks
4. [`docs/spec/video.md`](spec/video.md): **v1 scope.** One mode, 576p (720×576 at 50 Hz), three planar or chunky bitmap layers with Amiga-style plane pointers, windows, scaling, palette, direct colour, interrupts, HDMI and VGA
5. [`docs/spec/memory-architecture.md`](spec/memory-architecture.md): **v1 scope.** Slots and memory cycles, SRAM timing, CPU access at 20 MHz with no waits, fixed owners per cycle, DMACON
6. [`docs/spec/audio.md`](spec/audio.md): **drafted.** 4 Paula-style channels, 8-bit samples, nearest-sample playback, sigma-delta output
7. [`docs/spec/system.md`](spec/system.md): **drafted.** Reset sources and behaviour, boot ROM and overlay, start-up keys and colours, buttons, ID registers, installing as a Next core, board connections (timers are spec 12, interrupts 13, USB serial 14, SD card 15, keyboard 16)
8. ~~CPU board~~: dropped with the move to the KS3
9. [`docs/spec/sprites.md`](spec/sprites.md): **built** (`fpga/rtl/sprites.v`, `sprite_pix.v`; tested pixel by pixel by `make vtest`, the "spr" screen). 8 sprites with Amiga-style pointers and plain window/CTL registers in beam coordinates, any size, 2/4/8 bpp, magnify, depth among the layers, collisions; a FIFO per sprite filled just in time with the bitplanes. About 3,000 LUTs. (An earlier sprite-table design is in git history at commit 7df97fd)
10. [`docs/spec/copper.md`](spec/copper.md): **drafted.** Amiga-style beam-following coprocessor: MOVE, WAIT and SKIP, restarted each frame
11. [`docs/spec/dma-engine.md`](spec/dma-engine.md): **drafted.** One channel: byte-granular copy and fill in 1D and 2D, Chip RAM only, free memory cycles only
12. [`docs/spec/timers.md`](spec/timers.md): **drafted.** 64-bit time counter, 4 chainable 32-bit timers (clock, lines, frames), interrupts or DMA starts, watchdog
13. [`docs/spec/interrupts.md`](spec/interrupts.md): **drafted.** 24 sources with their own vectors and programmable levels, NMI from the Multiface button and USB break, software interrupt
14. [`docs/spec/serial.md`](spec/serial.md): **drafted.** FT232H module on the accelerator port in 245 FIFO mode: console and uploads at several MB/s, hardware flow control, BREAK/RESET/UPLOAD commands from the PC
15. [`docs/spec/sd-card.md`](spec/sd-card.md): **drafted.** SD card as a plain SPI byte master; software does the commands and blocks
16. [`docs/spec/keyboard.md`](spec/keyboard.md): **drafted.** PS/2 keyboard as a raw byte FIFO

## 4. Phases

Each phase ends with a test that shows it is done.

| Phase | Work | Done when |
|-------|------|-----------|
| **0. Plan** | This document, decisions agreed, specs written | Decisions D1–D11 signed off |
| **1. FPGA bring-up** | Vivado scripted build, CI for simulation, JTAG loading, HDMI and VGA test pattern, USB FIFO echo through the FT232H | Test pattern on a monitor; characters echo over USB |
| **2. Simulated computer** | fx68k + bus interface + SRAM controller (with an SRAM model) + boot ROM + a bitmap console + USB serial, in Verilator | Boot ROM prints "hello" on the simulated screen and serial port |
| **3. Computer on the board** | The same design built for the KS3; boot monitor (memory dump/edit, load over USB, run) | "hello" on a real monitor and over USB; full 4 MB RAM test passes at 20 MHz with display on |
| **4. Video** | Bitmap layers (planar and chunky), palette, scroll, direct colour, interrupts; then the copper | Demo program runs all layer formats |
| **5. Audio** | 4 Paula-style channels | Module-style playback |
| **6. DMA engine** | Copies and fills, 1D and 2D | Speed figures of spec 11 measured on the board |
| **7. Home computer** | SD card, PS/2 keyboard, EhBASIC | Boot to BASIC, load and save a program |
| **8. Next core** | Package the design as a Next core and install it in a flash slot | The KS3 boots the 68000 computer from its core menu, and still boots the Next |

## 5. Risks and open questions

| # | Item | Plan |
|---|------|------|
| Q1 | Does fx68k meet 40 MHz in Vivado with the multicycle constraints? | Very likely (62–81 MHz on ECP5); check with a Vivado trial build in phase 0/1 (spec 1, B1) |
| Q2 | Are 20 ns SRAM read and write cycles safe on the KS3's wiring? | Check against the datasheet (spec 5, M2); test on the board in phase 3. Fallback: slower cycles and fewer per slot |
| Q3 | Does the KS3 have 4 MB or 2 MB of SRAM? | Check the board (spec 5, M3); the design handles both |
| Q4 | Core format and slot size for an XC7A35T bitstream (about 2.2 MB) in the Next's flash | Check the Next's core-installation docs before phase 8 (spec 7, SY5); JTAG loading is used until then |
| Q5 | A JTAG cable for the KS3's header | Use a Xilinx-compatible cable (e.g. Digilent HS2, or an FT232H-based one with openFPGALoader) |
| Q6 | SPI-mode SD is slower than the native 4-bit bus (about 3 MB/s) | Enough for loading programs; try "high speed" SPI later (spec 15, SD2) |
| Q7 | Accelerator port pins for the FT232H: which 13 pins, and is the port's wiring good enough for 245 FIFO timing? | Check the Next's pin file and test the echo in phase 1 (spec 14, U1) |
| Q8 | fx68k: one latch in `rowDecoder` reported by Yosys | Check and run fx68k's own tests in phase 2 |

## 6. Next step

All the planning specs are drafted (section 3). To finish phase 0:

1. Review the decisions (D1–D11) and specs, and change anything that doesn't feel right.
2. Do the early checks that could change the design:
   - **fx68k at 40 MHz in Vivado** (Q1, spec 1 open point B1): a trial build for the XC7A35T-2 with the multicycle constraints, reading the timing report.
   - **SRAM size and timing** (Q2, Q3): read the chip marking on the KS3; check the datasheet timings.
   - **FT232H module and JTAG cable** (Q5, Q7): get them, and pick the accelerator port pins.
   - **Next core format** (Q4): read how third-party cores are installed on the KS3.
3. ~~Write the register-map generator.~~ Done: `fpga/regmap.def` and `tools/regmap.py` (spec 3, section 6).

**Phase 2 has started** (it needs no board): fx68k, the bus interface, the SRAM controller, boot ROM, system registers and USB serial run in Icarus Verilog (`sim/`). The boot ROM prints its checks over the simulated serial link with zero CPU wait states, also while a DMA port uses every other memory cycle. The interrupt controller, the timers and the video are in too, so the boot ROM's output also appears on the simulated screen: **phase 2 is done in simulation** (`docs/images/phase2-boot.png`). Sprites were built, removed to save logic, and built again in a smaller form (spec 9), now with fractional scaling. The video now matches the v1 spec: one mode, 576p, with its own 27 MHz pixel clock asynchronous to the system clock, three bitmap layers with Amiga-style bitplane DMA, and the boot ROM's console drawn into a 1-plane layer with a font in ROM (checked pixel by pixel against a Python model of spec 4, also with the DMA port busy).

**Phase 3 is ready to try on the board:** `fpga/ks3/build.sh` builds the boot ROM and the bitstream with Vivado and loads it over JTAG (`fpga/ks3/README.md`). The KS3 platform layer (two MMCMs: one for the system clocks, one for the 576p pixel clocks; SRAM pads, HDMI and VGA out, pins from the Next's issue 5 pin file) is in `fpga/rtl/platform/artix7/` and `fpga/rtl/top_ks3.v`. The Yosys resource figures are to be re-measured after the cut to version 1; Vivado timing is still to be seen.

Then phase 1 (FPGA bring-up) starts: scripted Vivado build, JTAG loading, HDMI/VGA test pattern and USB echo.
