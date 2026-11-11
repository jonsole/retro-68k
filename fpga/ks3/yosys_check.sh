#!/usr/bin/env bash
# Synthesise the KS3 design with Yosys for the Artix-7, as a check that it
# builds and fits, without Vivado. Not a replacement for the Vivado build
# (no place and route, no timing); used by CI.
#   fpga/ks3/yosys_check.sh        needs yosys, sv2v, python3 and vasmm68k_mot (or $VASM)
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# pwd -W gives C:/... paths under MSYS2, which a native Windows yosys can read
root="$(cd "$here/../.." && (pwd -W 2>/dev/null || pwd))"
out="$here/build-yosys"
rtl="$root/fpga/rtl"
fx="$root/fpga/third_party/fx68k"
vasm="${VASM:-vasmm68k_mot}"
mkdir -p "$out"
"$vasm" -quiet -Fbin -I "$root/firmware/include" -I "$root/firmware/boot" -o "$out/boot.bin" "$root/firmware/boot/boot.s"
python3 "$root/tools/bin2hex.py" "$out/boot.bin" "$out/boot.hex"
cp "$fx/microrom.mem" "$fx/nanorom.mem" "$out/"
sv2v "$fx/fx68k.sv" "$fx/fx68kAlu.sv" "$fx/uaddrPla.sv" > "$out/fx68k.v"
files="cpu_fx68k bus_if bootrom sysregs serial intc timers sprites video copper audio dmx sdspi ps2kb retro68k por_align top_ks3"
src=""; for f in $files; do src="$src $rtl/$f.v"; done
for f in timebase sram_ctl dmac fifo8 layer_pix sigma_delta2 audio_engine tmds_encoder ps2_core slip_rx serial_link ft232h_if sprite_fetch sprite_pix copper_engine blitter raster layer_fetch; do src="$src $root/fpga/retro-hw/rtl/$f.v"; done
for f in ks3_clocks vga_out; do src="$src $rtl/platform/artix7/$f.v"; done
for f in oddr hdmi_out; do src="$src $root/fpga/retro-hw/platform/artix7/$f.v"; done
cd "$out"
yosys -q -l yosys.log -p "read_verilog -sv fx68k.v; read_verilog -I$rtl $src; synth_xilinx -family xc7 -top top_ks3; stat" >/dev/null 2>&1 \
    || { grep -i error yosys.log; exit 1; }
python3 - <<'PY'
import re
log = open("yosys.log").read().split("=== design hierarchy ===")[-1]
# "LUT6  123" (older Yosys) or "123  LUT6" (newer)
n = lambda c: sum(int(a or b) for a, b in re.findall(r"^\s+(?:%s\s+(\d+)|(\d+)\s+%s)$" % (c, c), log, re.M))
luts = sum(n("LUT%d" % i) for i in range(1, 7)) + 4 * n("RAM128X1D") + 4 * n("RAM64X1D") + 4 * n("RAM32M")
ffs = n("FDRE") + n("FDSE") + n("FDCE") + n("FDPE") + n("FDRE_1")
bram = n("RAMB36E1") + n("RAMB18E1") / 2
print(f"KS3 (XC7A35T): about {luts} LUTs ({100*luts/20800:.0f}%), {ffs} flip-flops ({100*ffs/41600:.0f}%), "
      f"{bram:g} of 50 block RAMs, {n('DSP48E1')} of 90 DSP slices")
# Yosys counts about a third more LUTs than Vivado does for this design
# (21,382 against 15,917 in October 2026), so its count is only a rough
# guide: Vivado's is the real one (fpga/ks3/build.sh). Fail past 130% of
# the device by Yosys's count, about 97% by Vivado's.
print("  (Yosys counts high: about %d by Vivado's count, %.0f%%)" % (luts / 1.34, 100 * luts / 1.34 / 20800))
if luts > 1.30 * 20800 or bram > 50:
    raise SystemExit("does not fit")
PY
