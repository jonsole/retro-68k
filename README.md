# retro68k

A homebrew Motorola 68000 computer with Amiga-style shared memory and an FPGA handling video and audio. It runs on a **ZX Spectrum Next KS3** board: the 68000 is a core inside the board's Artix-7 FPGA, and main memory is the board's fast SRAM.

## Goals

- **CPU:** 68000 at 20 MHz, the fx68k core inside the FPGA
- **Memory:** 4 MB of Amiga-style Chip RAM in fast SRAM, shared with DMA in fixed memory cycles; the CPU has its own cycle in every slot, and waits only when the display would otherwise be late, as on the Amiga; one Agnus-like scheduler gives out every cycle
- **ROM:** boot ROM with a monitor, held in FPGA block RAM
- **Video:** HDMI and VGA in one mode, 576p (720×576 at 50 Hz, the digital form of PAL; a PAL Amiga screen sits in a centred window); 3 bitmap layers, planar or chunky, with Amiga-style bitplane pointers; scaling 1–8×; a 256-colour palette per layer (or one shared) or direct colour; a copper (MOVE, WAIT, SKIP)
- **Audio:** 4 Paula-style channels of 8-bit samples, sigma-delta output
- **Blitter:** copies, fills and cut-outs of rectangles in Chip RAM, with Amiga minterms, at 1 to 8 bits per pixel
- **I/O:** USB serial (FT232H module), SD card (SPI), PS/2 keyboard, timers, interrupts

## Block diagram

```
                       ZX Spectrum Next KS3
 +---------------------------------------------------------------+
 |  Artix-7 XC7A35T FPGA                                         |
 |  +--------+   +-----------+   +-----------------------------+ |      +-----------+
 |  | fx68k  |<->| bus, glue |<->| SRAM controller (slots)     |<------>| 4 MB SRAM |
 |  | 68000  |   | boot ROM  |   +-----------------------------+ |      +-----------+
 |  +--------+   +-----------+     ^      ^      ^      ^        |
 |                    |           video  audio  copper blitter   |---> HDMI, VGA
 |                    v                                          |---> audio jack
 |         timers, interrupts, SD, keyboard, serial              |
 +---------------------------------------------------------------+
            |            |              |
         SD card     PS/2 keyboard   FT232H USB
                                     (accelerator port)
```

## Status

The computer runs in simulation (`make -C sim`): fx68k boots the ROM, checks memory, interrupts and video, and prints to the USB serial link and the screen. The boot ROM draws its console text into a 1-plane bitmap layer with a font in ROM; the picture at the bottom right is a second bitmap layer, fetched from Chip RAM as the beam scans:

![Simulated screen after the boot ROM's checks](docs/images/phase2-boot.png)

Where the work stands, how to build and test, and what comes next: [`docs/HANDOFF.md`](docs/HANDOFF.md).

## Design plan

Decisions, memory map, phases and open questions are in [`docs/design-plan.md`](docs/design-plan.md). Each block has a spec in [`docs/spec/`](docs/spec/).

## Repository layout

| Folder              | Contents                                       |
|---------------------|------------------------------------------------|
| `docs/`             | Design plan and specs                          |
| `fpga/`             | Register map source (`regmap.def`); Verilog in `fpga/rtl/` |
| `firmware/boot/`    | 68000 assembly boot ROM / monitor              |
| `firmware/include/` | Generated hardware definitions for assembler (`hw.inc`) and C (`hw.h`) |
| `tools/`            | Register map generator (`regmap.py`), `bin2hex.py`; later build scripts and the USB loader |
| `sim/`              | System simulation (Icarus Verilog): `make -C sim` |
| `hardware/`         | Wiring for the FT232H module                   |

## Toolchain

- **68000 code:** `vasm` (Motorola syntax) or `m68k-elf-gcc`
- **FPGA:** Vivado (free edition), scripted with Tcl; simulation with Verilator and Icarus Verilog
- **Loading:** JTAG during development (`fpga/ks3/build.sh --program`, see [`fpga/ks3/README.md`](fpga/ks3/README.md)); installed as a Next core when finished

## Roadmap

1. [ ] FPGA bring-up: HDMI/VGA test pattern, USB serial echo
2. [x] Whole computer in simulation: boot ROM checks on the serial link and the screen
3. [ ] Computer on the board: "hello" on a monitor, RAM test, boot monitor (build script ready: `fpga/ks3/build.sh`)
4. [ ] Video: bitmap layers, palettes, scrolling, sprites with fractional scaling, copper (done in simulation)
5. [ ] Audio: 4 sample channels
6. [ ] Blitter: copies, fills and cut-outs (done in simulation)
7. [ ] Home computer: SD card, PS/2 keyboard, BASIC
8. [ ] Installed as a Next core

## License

MIT — see `LICENSE`. The fx68k core, when added, is GPL-3.0, so FPGA builds that include it are covered by the GPL.
