# Spec 3: Register map and memory map

Status: **draft for review**

This is the one place that lists every address in the machine: the memory map, the rules every register follows, and every register's final address. The bit layouts stay in each device's spec, linked from here, so they are described in only one place.

This spec also replaces spec 2 (memory map), which is folded in here.

## 1. Memory map

| CPU address | Size | What | Spec |
|-------------|------|------|------|
| `0x000000`–`0x007FFF` | 32 KB | Boot ROM overlay for CPU reads after reset (writes go to Chip RAM) | 7, section 3.2 |
| `0x000000`–`0x3FFFFF` | 4 MB | **Chip RAM** (the KS3's SRAM), shared by the CPU and all DMA. On 2 MB boards: `0x000000`–`0x1FFFFF`, and the rest is a bus error | 5 |
| `0x400000`–`0xDFFFFF` | 10 MB | Reserved (bus error) | |
| `0xE00000`–`0xE0FFFF` | 64 KB | **Custom block**: video, copper, DMA engine and audio registers; palette | Section 3 |
| `0xF00000`–`0xF0FFFF` | 64 KB | **System block**: interrupts, timers, serial, SD card, keyboard, system control, I2C | Section 4 |
| `0xF80000`–`0xF87FFF` | 32 KB | **Boot ROM** | 7, section 3 |
| Everything else | | Unmapped (bus error) | 1, section 6 |

**Who can reach what:**

| Area | CPU (supervisor) | CPU (user mode) | Copper | DMA engine |
|------|------------------|-----------------|--------|------------|
| Chip RAM | Yes | Yes | Read (its list) | Yes |
| Custom block | Yes | Yes, or bus error with SYSCON.PROTECT | Write | Read and write |
| System block | Yes | As above | No | No |
| Boot ROM | Read (write with ROMWE) | As above | No | Read |

## 2. Rules for all registers

1. **Size and order.** Every register is 32 bits wide, at an address that is a multiple of 4, stored big-endian as the 68000 expects. Its **high half** is at the register's address and its **low half** at address + 2.
2. **Writing in halves.** Each 16-bit half is written on its own, as soon as it arrives, keeping the other half; a byte write keeps the other byte. The 68000's MOVE.L is two 16-bit writes, the high half first (in every addressing mode except −(An)), and the copper writes a half per MOVE, as the Amiga's registers were written. So between the two halves of a 32-bit register's write, the register holds the new high half and the old low half: write registers the hardware is using (plane pointers, sprite pointers, COP2LC) where it is not using them, in the blank or from the copper, as on the Amiga.

   **Palette entries are the exception:** a colour must change all at once, even in the middle of a line. A write to a palette entry's high half is held, one for each writer (the CPU, the copper and the DMA engine), until the same writer's next write to that entry's low half, which writes both halves together. A low-half write on its own keeps the entry's red. A high-half write to another entry replaces the held one (spec 4, section 4.6).

   **Don't use CLR.L on a FIFO data register** (SERDATA, KBDATA): the 68000's CLR.L reads the register first, which takes a byte out. `MOVE.L #0,...` is always safe.
3. **Reading in halves.** Each half read returns that half as it is at that moment. A MOVE.L of a register that changes (BEAMPOS, a timer's COUNT) can catch the two halves at different moments; read such a register twice, or read its halves on their own. **TIME** is the exception: reading the high half of TIMEHI captures all 64 bits for the reads of the rest (spec 12, section 3).
4. **Reading has no side effects,** except in the system block: reading the **low half** of a FIFO data register (SERDATA, KBDATA) takes a byte out (a MOVE.L, high half then low, takes one), reading SERDROP's low half clears it, and reading TIMEHI's high half captures TIME. None of these are in the custom block, so DMA and the copper can never disturb anything by reading.
5. **Sticky flags** (marked W1C below) are cleared by writing 1 to them. Writing 0 leaves them alone.
6. **Set/clear registers** (DMACON, INTENA, BPLDMA): in each 16-bit set/clear half, the top bit = 1 sets the other bits written as 1; = 0 clears them. DMACON is one such half, in the low half. INTENA has two, so a `MOVE.W` to either half, or a `MOVE.L` to both, works. Byte writes are ignored.
7. **Unused bits** read as 0; write them as 0.
8. **Unused addresses** inside the custom and system blocks read as 0 and ignore writes. Only the unmapped regions in section 1 give bus errors.
9. **Timing.** A register write takes effect as described in its spec: some at once (palette), some at a fixed point (layer settings before each line).
10. **16-bit registers** (BPLxDAT, BPLSTRIDE and others) sit in the low half: write them with `MOVE.W` to the register's address + 2, or with `MOVE.L`.

**Access column key:** R = read only, W = write only, RW = read and write, W1C = sticky flags cleared by writing 1.

## 3. Custom block (`0xE00000`)

### 3.1 Layout

| Offset | Size | Contents | Spec |
|--------|------|----------|------|
| `0x0000`–`0x00FF` | 256 B | Video global registers and DMACON | 4, 5 |
| `0x0100`–`0x027F` | 384 B | Layers 0–2 | 4 |
| `0x0280`–`0x02FF` | | Free | |
| `0x0300`–`0x03FF` | 256 B | DMA engine | 11 |
| `0x0400`–`0x06FF` | 768 B | Audio | 6 |
| `0x0700`–`0x07FF` | 256 B | Copper | 10 |
| `0x0800`–`0x3FFF` | | Free | |
| `0x4000`–`0x4FFF` | 4 KB | Palettes: PALETTE0–2 (one per layer) and SPRPALETTE, each 256 × 32-bit `0x00RRGGBB` | 4, section 6.3 |
| `0x6000`–`0x67FF` | 2 KB | DMA descriptor RAM: 64 × 32 bytes | 11, section 8 |
| `0x6800`–`0xFFFF` | | Free | |

### 3.2 Video and DMA control (`0xE00000`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x000` | VIDCON | RW | 4, 6.1 |
| `0x004` | VIDSTAT | W1C (INVBLANK R) | 4, 6.1 |
| `0x008` | VIDINTEN | RW | 4, 6.1 |
| `0x00C` | BEAMPOS | R | 4, 3.3 |
| `0x010` | FRAMECOUNT | R | 4, 3.3 |
| `0x014` | LINECMP | RW | 4, 3.4 |
| `0x018` | BGCOLOR | RW | 4, 6.1 |
| `0x01C` | PRIO | RW | 4, 4.8 |
| `0x020` | VIDSIZE | R | 4, 6.1 |
| `0x094` | DMACON | Set/clear | 5, 8. Its 16-bit value is in the low half at `0x096`, the same address as the Amiga's DMACON |

### 3.3 Layers (`0xE00100`)

Layer n (0–2) at `0x100 + n × 0x80`:

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `+0x00` | CTRL | RW | 4, 6.2 |
| `+0x04` | WINX | RW | 4, 4.3 |
| `+0x08` | WINY | RW | 4, 4.3 |
| `+0x0C` | SCROLLX | RW | 4, 4.4 |
| `+0x10` | BPLSTRIDE | RW | 4, 4.4 |
| `+0x14` | BPLDMA | Set/clear | 4, 5.5 |
| `+0x20` | BPL0PT | RW | 4, 4.4 |
| `+0x24` | BPL1PT | RW | 4, 4.4 |
| `+0x28` | BPL2PT | RW | 4, 4.4 |
| `+0x2C` | BPL3PT | RW | 4, 4.4 |
| `+0x30` | BPL4PT | RW | 4, 4.4 |
| `+0x34` | BPL5PT | RW | 4, 4.4 |
| `+0x38` | BPL6PT | RW | 4, 4.4 |
| `+0x3C` | BPL7PT | RW | 4, 4.4 |
| `+0x40` | BPL0DAT | RW | 4, 5.1 |
| `+0x44` | BPL1DAT | RW | 4, 5.1 |
| `+0x48` | BPL2DAT | RW | 4, 5.1 |
| `+0x4C` | BPL3DAT | RW | 4, 5.1 |
| `+0x50` | BPL4DAT | RW | 4, 5.1 |
| `+0x54` | BPL5DAT | RW | 4, 5.1 |
| `+0x58` | BPL6DAT | RW | 4, 5.1 |
| `+0x5C` | BPL7DAT | RW | 4, 5.1 |

### 3.5 DMA engine (`0xE00300`)

Channel n (0–3) at `0x300 + n × 0x40`; the job registers (`+0x00`–`+0x1C`) are laid out as a descriptor:

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `+0x00` | CTRL | RW | 11, 8 |
| `+0x04` | BPT | RW | 11, 8 |
| `+0x08` | DPT | RW | 11, 8 |
| `+0x0C` | SIZE | RW | 11, 8 |
| `+0x10` | APT | RW | 11, 8 |
| `+0x14` | STRIDE | RW | 11, 8 |
| `+0x18` | VALUE | RW | 11, 8 |
| `+0x1C` | NEXT | RW | 11, 8 |
| `+0x20` | CHDESC | RW | 11, 8 |
| `+0x24` | CHCTRL | RW | 11, 8 |
| `+0x28` | CHSTAT | R, W1C | 11, 8 |
| `+0x2C` | CHERR | R | 11, 8 |

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x3F0` | DMXINT | W1C | 11, 8 |
| `0x3F4` | DMXINTEN | RW | 11, 8 |

### 3.5b Sprites (`0xE00500`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x500` | SPRDMA | Set/clear | 9, 6 |
| `0x504` | SPRCOLL | W1C | 9, 6 |

Sprite n (0–7) at `0x520 + n × 0x20`:

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `+0x00` | PT | RW | 9, 6 |
| `+0x04` | H | RW | 9, 3 |
| `+0x08` | V | RW | 9, 3 |
| `+0x0C` | CTL | RW | 9, 3 |
| `+0x10` | DAT | W, R | 9, 6 |
| `+0x14` | STEP | RW | 9, 3.2 |

### 3.6 Audio (`0xE00400`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x404` | AUDRATE | RW | 6, 5 |
| `0x40C` | AUDSTAT | R, W1C | 6, 5 |
| `0x410` | AUDINTEN | RW | 6, 5 |
| `0x414` | AUDSTART | W | 6, 5 |
| `0x418` | AUDSTOP | W | 6, 5 |

Channel n (0–3) at `0x440 + n × 0x20`:

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `+0x00` | CTRL | RW | 6, 5 |
| `+0x04` | LC | RW | 6, 5 |
| `+0x08` | LEN | RW | 6, 5 |
| `+0x0C` | STEP | RW | 6, 5 |
| `+0x10` | VOL | RW | 6, 5 |
| `+0x14` | POS | R | 6, 5 |

### 3.7 Copper (`0xE00700`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x700` | COPCON | RW | 10, 6 |
| `0x704` | COP1LC | RW | 10, 6 |
| `0x708` | COP2LC | RW | 10, 6 |
| `0x70C` | COPJMP1 | W | 10, 6 |
| `0x710` | COPJMP2 | W | 10, 6 |
| `0x714` | COPPC | R | 10, 6 |
| `0x718` | COPSTAT | R, W1C | 10, 6 |
| `0x71C` | COPINT | W | 10, 6 |
| `0x720` | COPX | RW | 10, 6 |
| `0x724` | COPY | RW | 10, 6 |
| `0x728` | COPFLAGS | RW | 10, 6 |
| `0x72C` | COPSP | RW | 10, 6 |
| `0x740`–`0x75C` | COPR0–7 | RW | 10, 6 |

## 4. System block (`0xF00000`)

### 4.1 Layout

| Offset | Contents | Spec |
|--------|----------|------|
| `0x000`–`0x0FF` | Interrupt controller | 13 |
| `0x100`–`0x1FF` | Timers and watchdog | 12 |
| `0x200`–`0x2FF` | USB serial | 14 |
| `0x300`–`0x3FF` | SD card | 15 |
| `0x400`–`0x4FF` | Keyboard | 16 |
| `0x500`–`0x7FF` | Free (mouse, joysticks and other inputs later) | |
| `0x800`–`0x8FF` | System control | 7, 1 |
| `0x900`–`0xFFFF` | Free | |

### 4.2 Interrupt controller (`0xF00000`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x000` | INTCON | RW | 13, 7 |
| `0x004` | INTENA | Set/clear | 13, 7 |
| `0x008` | INTPEND | R | 13, 7 |
| `0x00C` | INTRAW | R | 13, 7 |
| `0x010` | INTPRI0 | RW | 13, 7 |
| `0x014` | INTPRI1 | RW | 13, 7 |
| `0x018` | INTPRI2 | RW | 13, 7 |
| `0x01C` | VECBASE | RW | 13, 7 |
| `0x020` | SOFTINT | W | 13, 6 |
| `0x024` | INTID | R | 13, 7 |
| `0x028` | NMICON | RW | 13, 5 |
| `0x02C` | NMISTAT | W1C | 13, 5 |

### 4.3 Timers and watchdog (`0xF00100`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x100` | TIMEHI | R (reading the high half captures all 64 bits) | 12, 3 |
| `0x104` | TIMELO | R | 12, 3 |
| `0x1C0` | WDCTRL | RW (lockable) | 12, 5 |
| `0x1C4` | WDTIME | RW (lockable) | 12, 5 |
| `0x1C8` | WDKICK | W | 12, 5 |

Timer n (0–3) at `0x140 + n × 0x20`:

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `+0x00` | CTRL | RW | 12, 6 |
| `+0x04` | PRESCALE | RW | 12, 4.2 |
| `+0x08` | RELOAD | RW | 12, 4.1 |
| `+0x0C` | COUNT | RW | 12, 4.1 |
| `+0x10` | STAT | W1C | 12, 6 |

### 4.4 USB serial (`0xF00200`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x200` | SERCON | RW | 14, 5 |
| `0x204` | SERSTAT | R | 14, 5 |
| `0x208` | SERDATA | RW (reading takes a byte) | 14, 4.1 |
| `0x20C` | SERLEVEL | RW | 14, 4.2 |
| `0x210` | SERTIME | RW | 14, 4.2 |
| `0x214` | SERIRQ | R, W1C | 14, 4.2 |
| `0x218` | SERIRQEN | RW | 14, 4.2 |
| `0x21C` | SERDROP | R (clears on read) | 14, 4.3 |

SERDROP clearing on read is the one other exception to rule 4 (section 2). It is in the system block, out of reach of DMA and the copper.

### 4.5 SD card (`0xF00300`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x300` | SDCON | RW | 15, 6 |
| `0x304` | SDDATA | RW (writing sends a byte) | 15, 3.1 |
| `0x308` | SDCOUNT | RW | 15, 3.5 |

### 4.6 Keyboard (`0xF00400`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x400` | KBCON | RW | 16, 4 |
| `0x404` | KBSTAT | R | 16, 4 |
| `0x408` | KBDATA | R (reading takes a byte) | 16, 3.2 |
| `0x40C` | KBSEND | W | 16, 3.4 |
| `0x410` | KBIRQ | R, W1C | 16, 4 |
| `0x414` | KBIRQEN | RW | 16, 4 |

### 4.7 System control (`0xF00800`)

| Offset | Name | Access | Spec |
|--------|------|--------|------|
| `0x800` | SYSID | R | 7, 5 |
| `0x804` | SYSVER | R | 7, 5 |
| `0x808` | SYSCFG | R | 7, 5 |
| `0x80C` | RESETWHY | R | 7, 2.1 |
| `0x810` | SYSCON | RW | 7, 9; 1, 9 |
| `0x814` | SYSRESET | W | 7, 2.1 |
| `0x818` | SYSBTN | R | 7, 5 |
| `0x820` | SYSSTAT | R | 1, 8 |
| `0x824` | BUSERRADDR | R | 1, 6 |
| `0x828` | BUSERRWHY | R | 1, 6 |
| `0x840` | I2CCON | RW | 7, 6 |
| `0x844` | I2CDATA | RW | 7, 6 |
| `0x848` | I2CCMD | W | 7, 6 |
| `0x84C` | I2CSTAT | R | 7, 6 |

## 5. Interrupt sources and vectors

Listed in spec 13, section 4. With the default VECBASE of 64, vectors 64–87 are used for sources 0–23. Vector 31 is NMI, 24 is spurious, 2 is bus error.

## 6. One source for the numbers

Every register, field, layout and named number is also kept in **`fpga/regmap.def`**, a short text file. **`tools/regmap.py`** (standard Python, nothing to install) reads it and:

- checks it: 4-byte alignment, no overlaps, fields inside 31–0 and not overlapping, no name generated twice;
- checks it against the tables in this spec, so the two can't disagree;
- writes `firmware/include/hw.inc` (vasm), `firmware/include/hw.h` (C) and `fpga/rtl/regmap.vh` (Verilog).

GitHub runs `python3 tools/regmap.py --verify` on every push, which fails if the spec, the `.def` file and the generated files don't all agree. `tools/README.md` explains the file format and the generated names.

## 7. Open points

| # | Item |
|---|------|
| R2 | Bit layouts in each spec should be checked against the rules in section 2 once more when the generator is written |
| R3 | The palette write delay after a copper WAIT (spec 10, open point C2) should be listed here per video mode once known |

## 8. Tests

- **Decoding:** read every listed register after reset and check its reset value; read every free address and check 0; access every unmapped region and check a bus error.
- **Halves rules:** for a sample of registers in both blocks, check that each half and each byte is written on its own; palette entries held per writer (the CPU and copper interleaved); FIFO reads taking a byte only from the low half; and captured reads.
- **Access rights:** the copper can't reach the system block; DMA can't reach the system block; PROTECT blocks user mode.
- **Generated files:** the assembler, C and Verilog files from the generator agree with this spec.
