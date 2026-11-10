# Architecture notes

> Early notes. The current decisions are in [design-plan.md](design-plan.md), which wins where the two differ.

## CPU

The MC68000 has a 24-bit address bus (16 MB), a 16-bit data bus, and an asynchronous bus: every cycle ends when the device pulls `/DTACK` low. That makes mixing fast SRAM with a slower FPGA simple: SRAM gets `/DTACK` right away, the FPGA holds it off until it is ready.

Key signals: `A1–A23`, `D0–D15`, `/AS`, `/UDS`, `/LDS`, `R/W`, `/DTACK`, `FC0–FC2`, `/IPL0–2`, `/BERR`, `/RESET`, `/HALT`.

Use `/UDS` and `/LDS` for byte lanes: SRAM is two 8-bit chips (high byte and low byte) or one 16-bit chip with `/UB` and `/LB`.

## Fast SRAM

- Suggested parts: 10–15 ns async SRAM, e.g. IS61WV51216 (512K×16) or AS6C4008 (512K×8, slower but cheaper).
- At 20 MHz a 68000 bus cycle is 200 ns (4 clocks), so any SRAM under ~55 ns runs with zero wait states.
- Generate `/DTACK` combinationally from the address decode for SRAM and ROM.

## Address decoding / glue logic

Either a small CPLD (ATF1504/ATF1508) or put the glue logic in the FPGA. Using the FPGA saves a chip but means the FPGA must be configured before the CPU leaves reset, so hold `/RESET` and `/HALT` low until the FPGA's `CONF_DONE` goes high.

Glue logic duties:
- Chip selects for ROM, SRAM, FPGA, I/O
- `/DTACK` generation (with wait states for slow devices)
- `/BERR` watchdog for accesses to unmapped space
- Interrupt priority encoding onto `/IPL0–2`
- Boot overlay: ROM at `0x000000` until the first write to an overlay-off register

## FPGA: video

- Candidate chips: Lattice ECP5 (open toolchain), iCE40 UP5K (small), Gowin GW1N/GW2A (cheap, used on Tang boards), Xilinx Artix-7.
- Video RAM: dedicated SRAM on the FPGA side so video fetches never steal CPU cycles. The CPU writes VRAM through the FPGA, which arbitrates.
- Output: VGA through a resistor DAC to start, then DVI/HDMI (TMDS from the FPGA).
- Modes to aim for: 80×30 text, 320×240×8bpp, 640×480×4bpp, hardware sprites, scrolling, a blitter.
- **Version 1 (decided, spec 4):** one fixed mode, 576p (720×576 at 50 Hz, CEA-861, 27 MHz pixel clock from its own MMCM), with normal screens as centred windows, three bitmap layers (planar or chunky) with Amiga-style plane pointers, whole-number scaling, a 256-entry palette and direct colour. No text mode (the boot ROM draws its text into a bitmap) and no sprites. A simple copper (MOVE, WAIT, SKIP) and a one-channel DMA engine for copies and fills. (Since grown: sprites, a fuller copper, and a blitter, spec 11; a 4-channel DMA engine came and went in between.)

## FPGA: audio

- Output through I2S DAC (e.g. PCM5102) or sigma-delta PWM with an RC filter.
- Ideas: 4–8 PCM channels with DMA from VRAM, or an FM / wavetable synth in logic.
- Raise a vertical-blank or audio-buffer interrupt on the CPU.
- **Version 1 (decided, spec 6):** 4 Paula-style channels of 8-bit samples from Chip RAM, nearest-sample playback, sigma-delta output.

## Interrupts

| Level | Source                  |
|-------|-------------------------|
| 7     | NMI button              |
| 6     | Timer                   |
| 5     | FPGA (vblank, audio)    |
| 4     | UART                    |
| 2     | Keyboard / SD           |

Use autovectored interrupts (`/VPA` during IACK) to keep things simple.
