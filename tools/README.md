# Tools

| Tool | What it does |
|------|--------------|
| `vasm/vasm.tar.gz` | The vasm assembler's source archive, unmodified, as released by Volker Barthelmann (http://sun.hasenbraten.de/vasm/). CI builds the assembler from it, so it does not depend on that site being up. Its licence allows the unmodified archive to be redistributed for non-commercial use |
| `rlink.py` | The PC side of the USB link, shared with retro-z80 (the same file in both repos; spec `monitor.md`, section 8): uploads programs and image files, makes image files, sends the control commands RESET, BREAK and UPLOAD, and is a terminal. It SLIP-escapes everything it sends (spec 14, section 3). Needs Python 3.8+ and `pyserial` |
| `regmap.py` | Reads `fpga/regmap.def` (every hardware register and field), checks it, checks it against `docs/spec/registers.md`, and writes `firmware/include/hw.inc` (vasm), `firmware/include/hw.h` (C) and `fpga/rtl/regmap.vh` (Verilog) |

## Register map

To add or change a register:

1. Edit `fpga/regmap.def`.
2. Update the register's table in `docs/spec/registers.md` (and its own spec).
3. Run `python3 tools/regmap.py`. It stops with a message if the two disagree, if anything overlaps or is misaligned, or if a generated name would be defined twice.
4. Commit the `.def`, the spec and the generated files together.

`python3 tools/regmap.py --verify` only checks, and fails if the generated files are out of date. GitHub runs it on every push.

Only the Python standard library is needed (Python 3.8 or newer).

### Generated names

| In `regmap.def` | Assembler (`hw.inc`) | C (`hw.h`) | Verilog (`regmap.vh`) |
|-----------------|----------------------|------------|-----------------------|
| block `CUSTOM` | `CUSTOM` (base), `CUSTOM_SIZE` | `CUSTOM_BASE`, `CUSTOM_SIZE` | `` `RM_CUSTOM_BASE `` |
| reg `VIDCON` | `VIDCON` (offset in block) | `VIDCON` (the register), `VIDCON_OFS` | `` `RM_VIDCON `` (offset) |
| field `VIDCON.EN` | `VIDCON_EN_B` (bit), `VIDCON_EN_M` (mask); multi-bit fields add `_W` (width) | `VIDCON_EN_SHIFT`, `VIDCON_EN_MASK` | `` `RM_VIDCON_EN `` (bit or `hi:lo`) |
| array `L` of 3 | `L_NUM`, `L_SPAN`, `L0`…`L2`, `L_CTRL` (offset in an element), `L2_CTRL` | `L_NUM`, `L_SPAN`, `L_AT(n)`, `L_CTRL(n)` | `` `RM_L_BASE ``, `` `RM_L_SPAN ``, `` `RM_L_CTRL `` |
| struct `S` with field `F` | `S_SIZEOF`, `S_F` … | `s_t`, `S_F_OFS` … | `` `RM_S_F `` … |
| const `INT_VBLANK` | `INT_VBLANK` | `INT_VBLANK` | `` `RM_INT_VBLANK `` |

Example (assembler):

```
        include "hw.inc"
        lea     CUSTOM,a6
        move.l  #VIDCON_EN_M,VIDCON(a6)        ; video on
        move.l  #picture,L0_BPL0PT(a6)         ; layer 0, plane 0 pointer
```

Example (C):

```c
#include "hw.h"
VIDCON = VIDCON_EN_MASK;
L_BPL0PT(0) = (uint32_t)picture;
```

## bin2hex.py

Turns the assembled boot ROM (`boot.bin`) into a `$readmemh` file of 16-bit words for the block RAM: `bin2hex.py boot.bin boot.hex [words]`.

## bdf2font.py

Turns an 8×16 BDF bitmap font into the boot ROM's console font: `bdf2font.py third_party/spleen/spleen-8x16-ibm-437.bdf firmware/boot/font8x16.bin`. The output is a 4096-byte binary: 256 characters × 16 bytes, one byte per pixel row, leftmost pixel in bit 7. The boot ROM includes it and draws its console with it.
