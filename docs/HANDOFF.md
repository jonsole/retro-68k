# Handoff

State of the project on 23 October 2026 (evening): every unit of version 1 is built and tested in simulation, and the Vivado build meets timing. For picking the work up in a new session (VS Code, or a fresh Claude session). Read this first, then `docs/design-plan.md` for the whole plan.

## What retro68k is

An Amiga-style 68000 computer on the ZX Spectrum Next KS3 board (Xilinx XC7A35T, 4 MB SRAM): fx68k at 20 MHz, 576p video over HDMI and VGA with three layers and 8 scalable sprites, a copper, 4-channel audio, a blitter, a rasteriser (lines and triangles), an SD card, a PS/2 keyboard, and serial over an FT232H. The specs are in `docs/spec/`, the programming guide (Amiga Hardware Reference Manual style) in `docs/guide/`.

## Working rules

- Commit and push straight to `main` of `jonsole/retro68k`. No pull requests unless asked.
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
| `make dtest` | Blitter: 105 jobs in 4 chains (every depth, mask kind, row direction and stride sign; random minterms; overlapping copies; empty jobs), every byte of 1 MB against `dtest/dmodel.py`; then directed tests (registers, RUN and START, chains and IRQ, the MASK = 3 error, writes while busy, STOP, BLTEN, the interrupt request, the slot plan). `SEED=n` picks other random jobs | 3 min | yes |
| `make rastest` | Rasteriser: 216 LINE and TRI jobs in 12 chains, each under its own clip window (every depth, stride sign and kind of minterm; points inside, near and far outside the window; patterns, NOLAST), every byte of 1 MB against `rastest/rmodel.py`; then directed tests (registers, the spec's example line and triangle, chains and IRQ, the reserved-bit error, writes while busy, STOP, BLTEN, the interrupt request, the blitter and the rasteriser together, the copper's WAIT B). `SEED=n` picks other random jobs | 4 min | yes |
| `make dspeed` | Blitter speed: six 64 KB jobs, each one's time and memory cycles printed (the figures of spec 11, section 8) | 30 min | no |
| `make iotest` | SD card (start-up, a block read, written and read back) and PS/2 keyboard (bytes, a bad frame, sending), against `sd_model.v` and `ps2_model.v` | 5 min | yes |
| `make rtest` | The 68000 RESET instruction: the devices are reset; the CPU, overlay, memory, watchdog, RESETWHY and time counter are not | 1 min | yes |
| `make vtest` | Video: five screens (`pal`, `direct`, `spr`, `share`, `ctl`) checked pixel by pixel against `vtest/vmodel.py`; `make vtest VTESTS=spr` runs one. Each palette gets different colours; `spr` has the 8 sprites at many scales; `share` is `spr` with VIDCON.SHAREPAL; `ctl` has a copper change CTRL's depth and PALOFS part way along lines, make a split screen and write a pointer mid-line (the model tries every placement spec 4, section 5.4 allows) | 45 min each | `spr` only |
| `bash fpga/ks3/yosys_check.sh` (repo root) | Synthesis for the XC7A35T and the LUT count | 3 min | yes |
| `sh fpga/lint.sh` (repo root) | Verilator lint: a value cut short to fit (WIDTHTRUNC) is an error; slice it or waive the line | 10 s | yes |

`make BUILD=other_dir ...` builds into another directory, so a second set of runs can go alongside the first (`sim/build*/` is ignored by git). Run long simulations in the background, one per directory. The times above are for 7 runs side by side on a 16-core machine. Don't change `vtest/vmodel.py` or other test scripts while a suite that uses them is running. Edit `regmap.def`, then run `python3 tools/regmap.py` to regenerate the headers; never edit `hw.inc`, `hw.h` or `regmap.vh` by hand.

Debug switches in `sim/tb.v`:
- `+sprdbg`: sprite fetcher state at each frame start, and counts of acks, words and opaque pixels at the end.
- `+xstop`: stops at the first unknown (`x`) value on the sprite channel to the scheduler, and dumps the state.
- `+timeout=N`: the run's time limit in ns.
- `+dumpram=FILE`: Chip RAM `0x0F0000`–`0x1FFFFF` at the end (the blitter test); `+blttime`: each blitter run's time and memory cycles; `+iotest`: the keyboard sends its test bytes.

## Where things stand

Done and tested in simulation:

| Part | Files | Tests |
|------|-------|-------|
| CPU, bus, SRAM, scheduler (retro-hw's generic `dmac.v`; the slot plan in MEMSLOT0–4; a nasty copper owns cycle 0), boot ROM | `fpga/rtl/`, `firmware/boot/boot.s` | boot, dtest |
| Video: 3 layers, planar/chunky, scaling, scroll, BPLSTRIDE, priority, direct colour, a palette per layer and one for the sprites (SHAREPAL for one) | `video.v`, retro-hw's `layer_fetch.v` and `layer_pix.v` | vtest pal, direct, share, ctl |
| Sprites: 8, any size, 2/4/8 bpp, fractional scaling across and down (SPRxSTEP, 5.11, 16× to 1/16), depth, collisions, FIFO per sprite, changes while drawn, reuse down the screen, manual mode (SPRxDAT) | `sprites.v`, `sprite_pix.v`, `video.v` | vtest spr, share |
| Copper: MOVE/WAIT/SKIP/JUMP, MOVR, ALU, SKIPC, CALL/RET, RESUME | `copper.v`, `firmware/include/copper.inc` | ctest |
| Audio: 4 channels, 8/16-bit, pan, interpolation | `audio.v` (retro-hw's `audio_engine.v`) | atest |
| Blitter (retro-hw's redesigned `blitter.v`): one job at a time, Amiga minterms of a mask A (none, a 1 bpp image or a key compare), a source B (memory or a constant) and the destination C, at 1/2/4/8 bpp, rectangles with a stride each for A, B and D, RTL and negative strides for overlaps, descriptor chains in Chip RAM or direct job registers | `dmx.v` | dtest |
| Rasteriser (retro-hw's `raster.v`): lines and flat-filled triangles from screen points, through the blitter's minterms with a constant colour and a 16-bit line pattern, clipped to a window; its own job registers, descriptor chains and memory requester, so it runs beside the blitter | `dmx.v` | rastest |
| SD card: SPI byte master (the CPU moves every byte) | `sdspi.v` | iotest |
| PS/2 keyboard: receive with FIFO, send | `ps2kb.v` | iotest |
| Serial, interrupts, timers | `serial.v`, `intc.v`, `timers.v` | boot |
| The 68000 RESET instruction: resets the devices (not the CPU, overlay, watchdog, time counter or USB link) | `retro68k.v` (`dev_rst`), `timers.v` | rtest |

Size (Vivado, XC7A35T, 11 November, with retro-hw's size batches and its audio_engine): 15,128 LUTs (72.7%), 10,303 flip-flops, 11.5 block RAM tiles, worst setup slack +0.557 ns, hold +0.043 ns. Before those (branch `raster`) it was 16,166 LUTs (77.7%), 10,809 flip-flops, 11.5 block RAM tiles. With the blitter alone it was 14,687 (70.6%); with the 4-channel DMA engine 16,555 (79.6%). Timing met at 100 MHz, worst setup slack +0.392 ns, hold +0.051 ns. **With the rasteriser (10 November, branch `raster`) the Vivado build has not been run yet**: the core is about 1,430 LUTs alone, so expect about 78–80%. Yosys gives 22,360 LUTs by its own count (108%; about 16,690 by Vivado's, 80%) and 11,037 flip-flops. Per-unit figures from before the sprite rework: video 4,964 (sprites.v 1,809, the 8 sprite pixel units 779, bpldma.v 923), DMA engine 2,327, audio 1,225, copper 665, SD 66, keyboard 87.

### Recent decisions to know about

- **Beam coordinates** (spec 4, section 3.3). (0, 0) is the start of the horizontal and vertical blanks, so the picture is beam pixels 144–863 and lines 49–624. `hw.inc` has `VID_X0` = 144, `VID_Y0` = 49. Layer settings for line n (CTRL.EN and VSCALE, the window, SCROLLX) must be written before line n starts; colours, BGCOLOR and PRIO can still change in line n's blank. CTRL's depth, PLANAR and HSCALE act from the layer's next group fetched, TRANSP and PALOFS from the next pixel (issue #34).
- **Sprites** have unsigned positions and are clipped at all four edges. No flips. A write to SPRxCTL starts a sprite and the vertical blank stops them all, so each frame the registers are written with CTL last; PT, H, V and STEP act on a running sprite from the next line (wobbles, zooms, image switches). The fetcher works a line at a time (settings frozen at beam pixels 840-847, a line-start pass at pixel 0, the pixel side takes them at pixel 12), so HSTART must be 16 or more. A sprite in manual mode (SPRxDAT) should not be shrunk across.
- **Sprite scaling**: screen pixel i shows source pixel ⌊i × XSTEP ÷ 2048⌋; the image is ⌈window × step ÷ 2048⌉. Shrinking across fetches every word (costs memory cycles in proportion); shrinking down skips lines.
- **Blitter** (10 November 2026, spec 11): the 4-channel DMA engine was replaced by a wrapper on retro-hw's redesigned blitter core (retro-hw PR #14). One job at a time, in Chip RAM only: job registers laid out as a descriptor (BLTCTRL to BLTNEXT), RUN runs them, START loads BLTDESC first, NEXT chains. Gone with the old core: ADD, the channels, HIGH, PAUSE, port jobs (SD and serial; SDCOUNT too), jobs on registers, palettes and the ROM, the descriptor RAM, timer starts (TMRn CTRL.DMA), the range check and CHERR. Lines and triangles are the rasteriser's (below); `geom` later.
- **Rasteriser** (10 November 2026, spec 17): a second wrapper in `dmx.v`, on retro-hw's `raster.v` with triangles. Job registers RASCTRL to RASNEXT at `0x340` (a descriptor is the same 8 long words), RASDESC, RASCMD, RASSTAT as the blitter's, and the clip window in RASCLIPMIN and RASCLIPMAX. It is requester 6 of the scheduler (MEMSLOTn bit 6, RAS; the test port moved to 7 and lost its owner bit), shares DMACON.BLTEN, DMXINT and DMXINTEN (bit 1, RAS) and interrupt source 4 with the blitter, and the copper's WAIT B waits for both. A reserved RASCTRL bit is an error. These choices were made without Jon's review: spec 17, open point Z1 lists them.
- **SD card**: software does the SPI-mode protocol and moves every byte, blocks included; the hardware clocks bytes. No interrupt.
- **Area technique.** Per-channel state in distributed RAM, worked on one channel at a time (as in retro-hw's `layer_fetch.v`, `sprites.v`), rather than flip-flop arrays with wide muxes.

## Next jobs

In rough order:

1. **Try the bitstream on the board** (early November): HDMI and VGA at 576p, the boot ROM's console, the serial link, then the SD card and keyboard (`fpga/ks3/README.md` says what to expect).
2. **Boot ROM**: SD card start-up and a small FAT32 reader to load programs (spec 15, section 4); a keyboard decoder and layout table (spec 16); ROMLOCK.
3. **Timing margin**: +0.56 ns. The closest path is in the sprite fetch (`sprite_fetch.v`, `dl` to `pk_v`); the audio engine's closest is the bus's read strobe through the channel settings' read address, +0.68 ns.
4. **Small items**:
   - the serial link surviving a reset (spec);
   - the SD card and keyboard on the board (spec 15, SD1; spec 16, K3).
5. **Guide chapter** for audio (chapter 7 in the Amiga order).
6. **Trims**, if room is needed: timers, the copper's storage registers.
7. **Optional**: the TG68K 68020 option (`docs/tg68k-feasibility.md`).

### Known gaps

- The rasteriser's times are worked out, not measured (spec 17, Z2).
- Only the `spr` video screen is in CI (its own job, about an hour); `pal`, `direct` and `share` run locally.
- Sprite open points (spec 9, section 9): S1, measure the memory budget table in simulation; S2, whether sprites' share of free cycles should be capped.
- The blitter's speed (spec 11, section 8) is measured in simulation with the display off; not with a busy screen, nor on the board (open point D2).
- The SD test covers single blocks; multi-block transfers (CMD18, CMD25) are left to software and untested.
