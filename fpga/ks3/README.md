# Building for the ZX Spectrum Next KS3

One script builds the boot ROM and the FPGA bitstream with Vivado, and can load it into the board over JTAG:

```
fpga/ks3/build.sh                    # -> fpga/ks3/build/retro68k_ks3.bit (and .bin)
fpga/ks3/build.sh --program          # build, then load it over JTAG with Vivado
fpga/ks3/build.sh --program-only     # load the last build
fpga/ks3/build.sh --ofl digilent_hs2 # load with openFPGALoader instead
```

**You need:** Vivado (the free edition covers the KS3's XC7A35T; Linux or Windows with Git Bash/WSL), `git`, `python3`, and either `vasmm68k_mot` on the PATH or `curl`, `make` and a C compiler (the script then builds vasm itself). Put Vivado on the PATH with `source <Vivado>/settings64.sh`, or set `VIVADO=/path/to/vivado`.

A build takes about 10–20 minutes. The script stops with an error if timing isn't met; the reports are in `fpga/ks3/build/` (`timing.txt`, `utilization.txt`, `clocks.txt`, `drc.txt`, `io.txt`, `vivado.log`).

**Loading** over JTAG needs a cable on the KS3's JTAG header (a Xilinx-compatible one, e.g. Digilent HS2, or an FT232H/FT2232H-based cable with openFPGALoader). It only changes the FPGA until the next power-off; the flash and the Next core are not touched.

## What to expect on the board (version 1)

- HDMI and VGA at 576p (720×576, 50 Hz): the boot ROM's checks on a blue 640×480 console, drawn into a 1-plane bitmap layer and centred in the screen with the dark grey background colour as a border, with a small 4-plane test picture at the bottom right. On real hardware the RAM test covers all 4 MB, which takes a few seconds.
- The reset button restarts it; the Multiface button is the NMI (the boot ROM prints "NMI").
- With an FT232H module on the accelerator port, the same text appears on a PC terminal, and the PC can send BREAK, RESET and UPLOAD (spec 14). Without one, nothing waits for it.
- In the build: fx68k, bus interface, SRAM controller, boot ROM, system registers, USB serial, interrupts, timers, video (three bitmap layers, a palette each, direct colour, 8 sprites with fractional scaling), the copper, 4-channel audio, the blitter, the SD card (SPI) and the PS/2 keyboard.
- The boot ROM does not use the SD card or the keyboard yet.

## Files

| File | What |
|------|------|
| `build.sh` | The one script: boot ROM, Vivado, JTAG |
| `build.tcl` | Vivado non-project flow: synthesis, place and route, reports, bitstream |
| `program.tcl` | Load the bitstream over JTAG with Vivado's hardware manager |
| `ks3.xdc` | Pins (from the Next's `zxnext_pins_issue5.xdc`; issue 5 is the KS3) and timing constraints |
| `yosys_check.sh` | Synthesis with Yosys, as a check without Vivado (used by CI) |

The top level is `fpga/rtl/top_ks3.v`; the board-specific parts are in `fpga/rtl/platform/artix7/`.

## Things to check on the first build

- **Timing:** that fx68k meets 40 MHz (spec 1, B1) and the 40/100 MHz crossings meet their 15 ns limits.
- **Clocks:** two MMCMs from the 50 MHz oscillator. MMCM 1 (VCO 1000 MHz) makes the 100 and 40 MHz system clocks; MMCM 2 (VCO 1080 MHz) makes the 27 MHz pixel clock and the 135 MHz HDMI serialiser clock. The pixel clock is asynchronous to the system clock (exact frequency, unknown phase), and `ks3.xdc` declares the two clock groups asynchronous; `clocks.txt` lists the clocks Vivado sees. There is one video mode, 576p, and no timing registers.
- **FT232H pins** on the accelerator port are provisional (spec 14, U6): `accel_io[7:0]` = D7–D0, `[8]` RXF#, `[9]` TXE#, `[10]` RD#, `[11]` WR#, `[12]` SIWU#.
- **SRAM:** the 20 ns memory cycles on the real board (spec 5, M2); the boot ROM's RAM test shows the result.

## Resource use

The figures below were measured with Yosys (`yosys_check.sh`) before the cut to version 1, with the sprites taken out of the table. They will be re-measured for the version 1 design. Vivado's figures will differ a little.

| Part | LUTs (Yosys) |
|------|------|
| Video (old design: 4 layers, text, palette, timing) | about 3,300 |
| fx68k | about 3,300 |
| Timers | about 950 |
| The rest | about 1,350 |
