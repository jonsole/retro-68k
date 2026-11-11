# Handoff

State of the project on 23 October 2026 (evening): every unit of version 1 is built and tested in simulation, and the Vivado build meets timing. For picking the work up in a new session (VS Code, or a fresh Claude session). Read this first, then `docs/design-plan.md` for the whole plan.

## What retro68k is

An Amiga-style 68000 computer on the ZX Spectrum Next KS3 board (Xilinx XC7A35T, 4 MB SRAM): fx68k at 20 MHz, 576p video over HDMI and VGA with three layers and 8 scalable sprites, a copper, 4-channel audio, a 4-channel DMA engine and blitter, an SD card, a PS/2 keyboard, and serial over an FT232H. The specs are in `docs/spec/`, the programming guide (Amiga Hardware Reference Manual style) in `docs/guide/`.

## Working rules

- Commit and push straight to `main` of `jonsole/retro-68k`. No pull requests unless asked.
- Author: `Jon Sole <jon.sole@gmail.com>` (`git -c user.name="Jon Sole" -c user.email="jon.sole@gmail.com" commit ...`).
- Claude's commits end with a `Co-Authored-By:` trailer (and the session link, if the session gives one). No model names anywhere else in the repo.
- Check CI (GitHub Actions, `.github/workflows/checks.yml`) after each push. A full run takes about 35–50 minutes.
- Every hardware change: spec first (`docs/spec/`), then RTL, then the test, then the guide. Keep the specs matching the RTL: when the build differs, change the spec in the same commit.
- Run the tests before pushing RTL; CI runs only the `spr` video screen (see below).
- Keep the design under about 85% of the LUTs by Vivado's count (17,680), so it routes at 100 MHz. Yosys (the CI check) counts about a third more than Vivado; it fails CI past 130% by its own count (about 97% by Vivado's).
- Run the Vivado build after RTL changes: timing at 100 MHz is met with little margin (+0.2 ns).

## Tools

| Tool | Notes |
|------|-------|
| Icarus Verilog 12 or 13 | `iverilog`, `vvp`. CI uses Ubuntu's; 13 is stricter (no use before declaration) |
| sv2v | Converts fx68k from SystemVerilog. Release v0.0.13 from github.com/zachjs/sv2v |
| vasm | Build from the vendored copy: `tar xzf tools/vasm/vasm.tar.gz && make -C vasm CPU=m68k SYNTAX=mot`, then put `vasm/` on `PATH` (`vasmm68k_mot`) |
| Python 3 | Pillow for the PNG output (optional) |
| Yosys | For the size check (`fpga/ks3/yosys_check.sh`) |
| Verilator 5 | For the lint (`fpga/lint.sh`). MSYS2 UCRT64 package `verilator` (lint only needs no C++ build) |
| Vivado | 2026.1. `VIVADO=/c/AMDDesignTools/2026.1/Vivado/bin/vivado.bat bash fpga/ks3/build.sh`. Builds a bitstream (`fpga/ks3/build/retro68k_ks3.bit`) in about 15 minutes; timing met. Not tried on the board yet (it arrives in early November) |

### Windows

The tools are installed on Jon's Windows machine: MSYS2 (`C:/msys64`, UCRT64 packages: gcc, make, iverilog, yosys, verilator, python, python-pillow), sv2v in `C:/tools/sv2v/sv2v-Windows`, vasm built into `C:/tools/vasmsrc/vasm`. All are on the user PATH. Run the Makefiles from an MSYS2 shell (`C:/msys64/usr/bin/bash.exe -l`, with `/ucrt64/bin` first on the PATH), not with Chocolatey's `make`. The repo is checked out with `core.autocrlf=false`: the Python tools need LF files.

## Building and testing

All from `sim/` unless noted. See `sim/README.md` for more options.

| Command | What it checks | Time | In CI |
|---------|---------------|------|-------|
| `python3 tools/regmap.py --verify` (repo root) | `fpga/regmap.def` against `docs/spec/registers.md` and the generated `hw.inc`, `hw.h`, `regmap.vh` | seconds | yes |
| `make run ARGS=+serial` | Boot ROM self-test, serial echo, BREAK and RESET | 5–50 min | yes |
| `make run ARGS=+dma` | Boot ROM with the DMA port busy | 5–50 min | yes |
| `make ctest` | Copper: self-checking ROM, then 14 colour changes checked in the frame (`ctest/ccheck.py`) | 10–80 min | yes |
| `make atest` | Audio: every output sample against a Python model | 3–10 min | yes |
| `make dtest` | DMA engine: 56 random jobs on 4 channels (BLIT with common and random minterms, every MASK, ADD), every byte of 1 MB against `dtest/dmodel.py`; then 16 directed tests (palettes, ROM, registers, errors, STOP, PAUSE, ports, HIGH, a timer start, MASK = 3). `SEED=n` picks other random jobs | 1 min | yes |
| `make iotest` | SD card (start-up, a block read and written by DMA) and PS/2 keyboard (bytes, a bad frame, sending), against `sd_model.v` and `ps2_model.v` | 5 min | yes |
| `make rtest` | The 68000 RESET instruction: the devices are reset; the CPU, overlay, memory, watchdog, RESETWHY and time counter are not | 1 min | yes |
| `make vtest` | Video: four screens (`pal`, `direct`, `spr`, `share`) checked pixel by pixel against `vtest/vmodel.py`; `make vtest VTESTS=spr` runs one. Each palette gets different colours; `spr` has the 8 sprites at many scales; `share` is `spr` with VIDCON.SHAREPAL | 45 min each | `spr` only |
| `bash fpga/ks3/yosys_check.sh` (repo root) | Synthesis for the XC7A35T and the LUT count | 3 min | yes |
| `sh fpga/lint.sh` (repo root) | Verilator lint: a value cut short to fit (WIDTHTRUNC) is an error; slice it or waive the line | 10 s | yes |

`make BUILD=other_dir ...` builds into another directory, so a second set of runs can go alongside the first (`sim/build*/` is ignored by git). Run long simulations in the background, one per directory. The times above are for 7 runs side by side on a 16-core machine. Don't change `vtest/vmodel.py` or other test scripts while a suite that uses them is running. Edit `regmap.def`, then run `python3 tools/regmap.py` to regenerate the headers; never edit `hw.inc`, `hw.h` or `regmap.vh` by hand.

Debug switches in `sim/tb.v`:
- `+sprdbg`: sprite fetcher state at each frame start, and counts of acks, words and opaque pixels at the end.
- `+xstop`: stops at the first unknown (`x`) value on the sprite channel to the scheduler, and dumps the state.
- `+timeout=N`: the run's time limit in ns.
- `+dumpram=FILE`: Chip RAM `0x0F0000`–`0x1FFFFF` at the end (the DMA test); `+dmxsend`: the PC sends 64 bytes (the DMA test's port job); `+iotest`: the keyboard sends its test bytes.

## Where things stand

Done and tested in simulation:

| Part | Files | Tests |
|------|-------|-------|
| CPU, bus, SRAM, scheduler (`dmac.v`, with HIGH and CPUSHARE), boot ROM (second port for DMA) | `fpga/rtl/`, `firmware/boot/boot.s` | boot |
| Video: 3 layers, planar/chunky, scaling, scroll, BPLSTRIDE, priority, direct colour, a palette per layer and one for the sprites (SHAREPAL for one) | `video.v`, `bpldma.v`, `layer_pix.v` | vtest pal, direct, share |
| Sprites: 8, any size, 2/4/8 bpp, fractional scaling across and down (SPRxSTEP, 5.11, 16× to 1/16), depth, collisions, FIFO per sprite, changes while drawn, reuse down the screen, manual mode (SPRxDAT) | `sprites.v`, `sprite_pix.v`, `video.v` | vtest spr, share |
| Copper: MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET, RESUME | `copper.v`, `firmware/include/copper.inc` | ctest |
| Audio: 4 channels, 8/16-bit, pan, interpolation | `audio.v` | atest |
| DMA engine and blitter: 4 channels, BLIT (Amiga minterms of a mask A, an image B and the destination C; A a 1 bpp image or a key compare) and ADD at 1/2/4/8 bpp, 2D, DESC, descriptor chains or direct job registers, registers/palettes/ROM, ports 0 (SD) and 1 (serial), HIGH, timer starts | `dmx.v` | dtest |
| SD card: SPI byte master, SDCOUNT for DMA port 0 | `sdspi.v` | iotest |
| PS/2 keyboard: receive with FIFO, send | `ps2kb.v` | iotest |
| Serial, interrupts, timers | `serial.v`, `intc.v`, `timers.v` | boot |
| The 68000 RESET instruction: resets the devices (not the CPU, overlay, watchdog, time counter or USB link) | `retro68k.v` (`dev_rst`), `timers.v` | rtest |

Size (Vivado, XC7A35T): 16,638 LUTs (80.0%) after the blitter (29 October; 15,730 before), 12 block RAM tiles, 8 DSP slices. Timing met at 100 MHz, worst setup slack +0.066 ns (register bus write to the sprite registers' RAM), hold +0.050 ns. Per-unit figures from before the sprite rework: video 4,964 (sprites.v 1,809, the 8 sprite pixel units 779, bpldma.v 923), DMA engine 2,327, audio 1,225, copper 665, SD 66, keyboard 87.

### Recent decisions to know about

- **Beam coordinates** (spec 4, section 3.3). (0, 0) is the start of the horizontal and vertical blanks, so the picture is beam pixels 144–863 and lines 49–624. `hw.inc` has `VID_X0` = 144, `VID_Y0` = 49. Layer settings for line n must be written before line n starts; colours, BGCOLOR and PRIO can still change in line n's blank.
- **Sprites** have unsigned positions and are clipped at all four edges. No flips. A write to SPRxCTL starts a sprite and the vertical blank stops them all, so each frame the registers are written with CTL last; PT, H, V and STEP act on a running sprite from the next line (wobbles, zooms, image switches). The fetcher works a line at a time (settings frozen at beam pixels 840-847, a line-start pass at pixel 0, the pixel side takes them at pixel 12), so HSTART must be 16 or more. A sprite in manual mode (SPRxDAT) should not be shrunk across.
- **Sprite scaling**: screen pixel i shows source pixel ⌊i × XSTEP ÷ 2048⌋; the image is ⌈window × step ÷ 2048⌉. Shrinking across fetches every word (costs memory cycles in proportion); shrinking down skips lines.
- **DMA engine**: job registers laid out as a descriptor; RUN runs them, START loads CHDESC first; NEXT chains. BLIT replaced COPY, FILL, KEYCOPY and LOGIC on 29 October 2026, shared with retro-z80 (same op codes, minterm numbering and MASK values; our long-word layout; WIDTH is 16 bits so APT fits). The custom block is memory to the engine: any job can use it. REGLIST was dropped (a copy into registers does it). A port job is a plain copy (BLIT 0xCC, no mask). Channels take turns by groups of 8 words.
- **SD card**: software does the SPI-mode protocol; the hardware moves bytes, and DMA moves blocks. No interrupt.
- **Area technique.** Per-channel state in distributed RAM, worked on one channel at a time (as in `bpldma.v`, `sprites.v`, `dmx.v`), rather than flip-flop arrays with wide muxes.

## Next jobs

In rough order:

1. **Try the bitstream on the board** (early November): HDMI and VGA at 576p, the boot ROM's console, the serial link, then the SD card and keyboard (`fpga/ks3/README.md` says what to expect).
2. **Boot ROM**: SD card start-up and a small FAT32 reader to load programs (spec 15, section 4); a keyboard decoder and layout table (spec 16); ROMLOCK.
3. **Timing margin**: +0.25 ns. The closest path is now in the audio engine (channel select to the sample position's enable); the sprite deadline calculator is pipelined.
4. **Small items**:
   - the serial link surviving a reset (spec);
   - the SD card and keyboard on the board (spec 15, SD1; spec 16, K3).
5. **Guide chapter** for audio (chapter 7 in the Amiga order).
6. **Trims**, if room is needed: timers, the audio engine, the copper's storage registers.
7. **Optional**: the TG68K 68020 option (`docs/tg68k-feasibility.md`).

### Known gaps

- Only the `spr` video screen is in CI (its own job, about an hour); `pal`, `direct` and `share` run locally.
- Sprite open points (spec 9, section 9): S1, measure the memory budget table in simulation; S2, whether sprites' share of free cycles should be capped.
- The DMA engine's speed figures (spec 11, section 7, open point D2) and the HIGH CPU shares are worked out, not measured.
- The SD test covers single blocks; multi-block transfers (CMD18, CMD25) are left to software and untested.
