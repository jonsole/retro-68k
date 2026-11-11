# Simulation

System test of the computer in Icarus Verilog: fx68k runs the boot ROM against a model of the KS3's SRAM (with the datasheet's timing checks) and of the FT232H USB module. The boot ROM prints its checks over the serial link and ends with `PASS` or `FAIL`.

```
make                      # build and run
make run ARGS=+dma        # with a DMA port reading and writing every free memory cycle
make run ARGS=+trace      # the first bus cycles and their position in the slot
make run ARGS=+bustrace=N # every bus cycle (address and data) for the first N
make run ARGS=+serial     # echo test, PC BREAK (NMI) and RESET commands
make frame                # also save the screen as build/frame.png (needs Pillow)
make run ARGS=+vcd        # waveform in build/tb.vcd
make vtest                # video test: random pictures checked pixel by pixel (vtest/)
make ctest                # copper test: a self-checking ROM, then the frame (ctest/)
make atest                # audio test: every output sample against a Python model (atest/)
make dtest                # blitter test: random jobs against a Python model, and directed tests (dtest/)
make rastest              # rasteriser test: random lines and triangles against a Python model (rastest/)
make run ARGS=+coptrace   # the copper's instructions and register writes
```

Needs `iverilog` (12), `sv2v` (converts fx68k from SystemVerilog), `vasmm68k_mot` and `python3`. Paths can be given with `make SV2V=... VASM=...`. A run takes about 2–5 minutes. The test also checks the video sync timing against 576p (CEA-861: 864 × 625 at 27 MHz).

The test reports how long /AS stayed low for every bus cycle. A zero-wait-state cycle is 150–199 ns; each wait state adds 50 ns.
