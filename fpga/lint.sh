#!/bin/sh
# Lint the RTL with Verilator. A value cut short to fit where it goes
# (WIDTHTRUNC) is an error: it is how a register rebuilt from the wrong
# number of bits slips past Icarus and Yosys. Widening (WIDTHEXPAND) is
# allowed. Where cutting is meant, slice it or waive that line with
#   /* verilator lint_off WIDTHTRUNC */ ... /* verilator lint_on WIDTHTRUNC */
# Only width cuts are gated: UNOPTFLAT (a simulation-speed note, which older
# Verilators raise for the HDMI encoder's chained bits) is off.
# The third-party CPU core is replaced by a stub with its ports
# (fpga/lint_fx68k_stub.v).
set -e
cd "$(dirname "$0")/.."
verilator --lint-only --default-language 1364-2005 -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-UNOPTFLAT -Wwarn-WIDTHTRUNC \
    -Ifpga/rtl --top-module retro68k fpga/rtl/cpu_fx68k.v fpga/rtl/bus_if.v fpga/rtl/bootrom.v fpga/rtl/sysregs.v fpga/rtl/serial.v fpga/rtl/intc.v fpga/rtl/timers.v fpga/rtl/bpldma.v fpga/rtl/sprites.v fpga/rtl/video.v fpga/rtl/copper.v fpga/rtl/audio.v fpga/rtl/dmx.v fpga/rtl/sdspi.v fpga/rtl/ps2kb.v fpga/rtl/retro68k.v fpga/retro-hw/rtl/timebase.v fpga/retro-hw/rtl/sram_ctl.v fpga/retro-hw/rtl/dmac.v fpga/retro-hw/rtl/fifo8.v fpga/retro-hw/rtl/layer_pix.v fpga/retro-hw/rtl/sigma_delta2.v fpga/retro-hw/rtl/tmds_encoder.v fpga/retro-hw/rtl/ps2_core.v fpga/retro-hw/rtl/slip_rx.v fpga/retro-hw/rtl/serial_link.v fpga/retro-hw/rtl/ft232h_if.v fpga/retro-hw/rtl/sprite_fetch.v fpga/retro-hw/rtl/sprite_pix.v fpga/retro-hw/rtl/copper_engine.v fpga/retro-hw/rtl/dmx_core.v fpga/retro-hw/platform/sim/oddr.v fpga/lint_fx68k_stub.v
# The board's HDMI encoder sits outside retro68k's hierarchy: lint it on its own
verilator --lint-only --default-language 1364-2005 -Wno-lint -Wno-style -Wno-TIMESCALEMOD -Wno-UNOPTFLAT -Wwarn-WIDTHTRUNC \
    --top-module tmds_encoder fpga/retro-hw/rtl/tmds_encoder.v
echo "lint: no widths cut short"