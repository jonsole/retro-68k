# Spec 17: Rasteriser

Status: **version 1, for review**. Written on 10 November 2026 with the wrapper, on retro-hw's rasteriser core (`fpga/retro-hw/docs/spec/raster.md`, revision 1; retro-hw PR #14), shared with retro-z80. The choices that are this machine's own are listed in open point Z1.

The rasteriser draws lines and flat-filled triangles into a bitmap in Chip RAM, from screen coordinates, while the CPU carries on with other work. Each pixel is the blitter's logic function (the minterm, spec 11) of a pattern bit A, a constant colour B and the bitmap's old pixel C, and only pixels inside a clip window are written. It is programmed as the blitter is: job registers laid out as a descriptor, chains of descriptors in Chip RAM, START, RUN and STOP. It is a separate unit beside the blitter, and the two can run at the same time.

It closes spec 11's open point D3. The third core of retro-hw's redesign, `geom` (3D points), is not built here yet.

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | LINE: a line between two points. TRI: a filled triangle. One at a time; a job may chain to a next descriptor |
| Programming | A job written straight into the job registers, or chains of 32-byte **descriptors** (laid out as those registers) in Chip RAM |
| Coordinates | Signed 16-bit whole pixels, x to the right, y down |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, packed as the blitter's: chunky layers directly, planar layers one plane at a time |
| Colour | A constant, through D = minterm(A, B, C): B the colour, C the old pixel, A a 16-bit pattern along a line (all ones in a triangle) |
| Clipping | A window (RASCLIPMIN, RASCLIPMAX), inclusive, shared by every job. Nothing outside it is written |
| Memory | Chip RAM only. Normally only free memory cycles, so the CPU is never slowed |
| Time | A line: about 0.5 µs to start, then each pixel written takes 80 ns or more. A triangle: about 1.5 µs to start, then each row 40 ns and each memory word of its span 60 ns or more (section 8; not measured yet) |
| Finishing | A flag (DMXINT.RAS) and an interrupt at the end of a chain, and after any job that asks; BUSY and ERR to poll |

## 2. Comparison with the Amiga

| Feature | Amiga blitter, line mode and area fill | retro68k rasteriser |
|---------|-----------------------------------------|---------------------|
| A line | The CPU works out the octant, the Bresenham terms and the first word's address and shift, and loads them into the blitter's registers | Two points. The rasteriser works out the rest |
| Line pattern | 16 bits (BLTBDAT), rotated a pixel at a time | The same (RASPAT) |
| One pixel a row (for fills) | SING bit | Not needed: triangles are filled directly |
| Clipping | By the CPU, before the line is set up | A clip window in hardware: lines and triangles may lie partly or wholly outside it |
| Filled shapes | Draw the outline one pixel a row in a spare plane, then a fill blit over the bounding box (inclusive or exclusive fill), then copy to the screen | TRI fills a triangle in one job, with rules that leave no gaps or doubled pixels between triangles that share an edge. Other shapes are chains of triangles |
| Pixel layout | Bitplanes: one line or fill per plane | Chunky pixels at any depth in one job; planar layers a plane at a time |
| Logic | Minterms | The same minterms |
| At the same time as a blit | No: it is the blitter | Yes: a unit of its own |

## 3. The job

A job is eight long words: the job registers, or a 32-byte descriptor in Chip RAM at an even address, which the rasteriser loads into them. Offsets are in the custom block (`0xE00000`, spec 3, section 3.5a) for the registers, and from the descriptor's start in memory. A descriptor is stored as the registers are: big-endian long words. The clip window is not part of a job (section 4).

| Register | Descriptor | Name | Bits | Meaning |
|----------|------------|------|------|---------|
| `0x340` | `+0x00` | RASCTRL | see below | Options, the colour and MINTERM |
| `0x344` | `+0x04` | RASP0 | X 31–16, Y 15–0, both signed | Point 0: a line's start |
| `0x348` | `+0x08` | RASP1 | X 31–16, Y 15–0 | Point 1: a line's end |
| `0x34C` | `+0x0C` | RASP2 | X 31–16, Y 15–0 | Point 2, for a triangle. A line ignores it |
| `0x350` | `+0x10` | RASDPT | ADDR 23–0 | The byte holding pixel (0, 0) of the bitmap |
| `0x354` | `+0x14` | RASSTRIDE | DSTRIDE 15–0, signed | Bytes from one row of the bitmap to the next |
| `0x358` | `+0x18` | RASPAT | PATTERN 15–0 | LINE: A for each pixel in turn, from bit 15, going round. `0xFFFF` for a solid line. A triangle ignores it: its A is 1 |
| `0x35C` | `+0x1C` | RASNEXT | ADDR 23–0 | The next descriptor's address; 0 for none |

**RASCTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 7–0 | VALUE | The colour, in its low bits (as many as the pixel has): B for every pixel |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 12 | IRQ | Set DMXINT.RAS when this job ends (section 7) |
| 16 | TRI | 0 = LINE, 1 = TRI |
| 17 | NOLAST | LINE: the last pixel (at point 1) is not drawn, so joined lines don't draw a corner twice |
| 31–24 | MINTERM | The logic function of A, B and C (section 3.1) |

BPP, IRQ and MINTERM are where BLTCTRL has them, and RASNEXT where BLTNEXT is.

**RASCTRL's other bits (23–18, 15–13, 11–10) are reserved: write 0. A job with any of them set is an error** (section 7). So a blitter descriptor given to the rasteriser by mistake is refused if it has RTL, BCONST or a key mask set, and the bits stay free for later versions. In the other job registers, bits not listed are ignored and read back as written.

Address bits 23–22 are ignored: a job reaches Chip RAM only, and an address past 4 MB wraps round, as in the blitter (spec 11, section 4).

### 3.1 The minterm

Each bit of a pixel's new value D is MINTERM's bit number A × 4 + B × 2 + C, exactly as in the blitter (spec 11, section 3.1), with:

- **A:** the pattern's bit for this pixel of a line; 1 for every pixel of a triangle.
- **B:** VALUE's low bits, the same for every pixel.
- **C:** the pixel's old value in the bitmap.

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Draw in the colour. A line's pattern has no effect |
| `0xCA` | A ? B : C | A dashed line: the colour where the pattern is 1, the bitmap left alone where it is 0 |
| `0xC0` | A ? B : 0 | A dashed line on black |
| `0x66` | B XOR C | Draw and undraw with the same job (rubber bands, cursors). Use NOLAST for joined lines |
| `0xEE`, `0x88` | B OR C, B AND C | Set or keep bits: draw into some planes of a chunky pixel |
| `0x55` | NOT C | Invert |

In a triangle only MINTERM's high four bits matter (A is 1).

### 3.2 The bitmap

RASDPT is the byte holding pixel (0, 0), and row y starts DSTRIDE × y bytes after it. Pixels are packed from the most significant end of each byte, as everywhere in this machine (spec 4; spec 11, section 3.3). So for a layer's bitmap RASDPT is the plane pointer and DSTRIDE the bytes a row.

- **Negative coordinates are real places.** Pixel (−1, 0) is the pixel before (0, 0) in memory. Whether they are drawn is the window's business, not the bitmap's.
- **A bitmap that is the wrong way up** (row 0 at the highest address) has a negative DSTRIDE and RASDPT at its last row.
- **To draw into part of a bitmap with its own origin** (a window on the screen), point RASDPT at that part's pixel (0, 0); if that pixel is not at a byte's start (depths under 8 bits), add the odd pixels to every x instead.

## 4. The clip window

Two registers, written by the CPU or the copper, shared by every job. They are not part of a descriptor: a chain runs under one window.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x36C` | RASCLIPMIN | X 31–16, Y 15–0, both signed | The window's first column and first row |
| `0x370` | RASCLIPMAX | X 31–16, Y 15–0, both signed | Its last column and last row: the window includes them |

- **Only pixels inside the window are written**: XMIN ≤ x ≤ XMAX and YMIN ≤ y ≤ YMAX. Points may lie anywhere; the shape is the same whatever the window is, and the window only decides which of its pixels are written.
- **The window is the only thing that keeps a job inside its bitmap.** There is no address check. Set it to the bitmap, or to a smaller box to clip to a window on the screen.
- A window with XMAX < XMIN or YMAX < YMIN draws nothing.
- Writes are ignored while BUSY. The registers are not reset (they are 0 after power-on, a window of the one pixel (0, 0)).

## 5. What is drawn

### 5.1 LINE

The pixels of the line from point 0 to point 1 are those of Bresenham's algorithm, stepping one pixel along the longer axis each time, starting at point 0 with the error term at half the longer length (rounded down). Both ends are drawn, unless NOLAST leaves out point 1.

- A line with both ends beyond the same side of the window is skipped whole, at no cost.
- Otherwise **every pixel is stepped**, written or not, and those inside the window are written. So a line's pixels inside the window are the same whatever the window is, but a line that runs far outside it costs time (section 8): software should cut very long lines down roughly first.
- The pattern moves on one bit for every pixel stepped, written or not.
- Pixels are written one at a time, in order. With a minterm that reads C, a pixel that two joined lines both draw is combined twice: with XOR it would come out undrawn. NOLAST on each line of a polyline leaves the shared corners to the next line.
- A line and the same line reversed may differ by a pixel, where the error term is exactly on a tie.

### 5.2 TRI

The three points may be given in any order. The rasteriser sorts them by y, divides for the three slopes, and fills row by row.

| Rule | |
|------|--|
| Rows | From the top point's y up to, not including, the bottom point's y |
| An edge from (xa, ya) down to (xb, yb) | Its slope is s = floor((xb − xa) × 65536 ÷ (yb − ya)), and its x in row y is X = xa × 65536 + s × (y − ya): a fixed-point number with 16 fraction bits |
| A row's span | Between the long edge (top to bottom) and the short edge for that row (top to middle above the middle point's y, middle to bottom from it): the pixels x with ceil(X_left ÷ 65536) ≤ x < ceil(X_right ÷ 65536) |
| Clipping | Rows outside the window are stepped without writing; a span is cut to the window's columns |

So:

- two triangles that share an edge fill every pixel along it exactly once (no gaps, and nothing doubled under XOR);
- a triangle's bottom row and right-hand edge pixels are left for its neighbours, as in most rasterisers;
- a triangle with no area draws nothing;
- the result does not depend on the order of the points;
- each pixel is written once, so any minterm works. A span is written a memory word at a time.

Other filled shapes are chains of triangles: a convex polygon of n corners is a fan of n − 2.

### 5.3 The exact result

This is the definition the test model (`sim/rastest/rmodel.py`) follows; it is the core's (retro-hw's raster spec, section 4.5). A pixel (x, y) is at bit position 8 × (RASDPT + y × DSTRIDE) + x × bits, where bit position n means bit 7 − (n mod 8) of the byte at address n div 8. Byte addresses are taken modulo 4 MB.

```
bits = 1 << BPP

plot(x, y, A):
    if XMIN ≤ x ≤ XMAX and YMIN ≤ y ≤ YMAX:
        C = the pixel at (x, y);  B = VALUE's low bits
        each bit j:  D[j] = MINTERM[4 × A + 2 × B[j] + C[j]]
        the pixel at (x, y) becomes D

LINE (TRI = 0):  (x0, y0) = RASP0, (x1, y1) = RASP1
    dx = |x1 − x0|;  dy = |y1 − y0|
    sx = +1 if x1 ≥ x0 else −1;  sy = +1 if y1 ≥ y0 else −1
    xmajor = (dx ≥ dy);  major = max(dx, dy);  minor = min(dx, dy)
    err = major div 2;  (x, y) = (x0, y0)
    for i = 0 .. major:
        if not (NOLAST and i = major):
            plot(x, y, PATTERN[15 − (i mod 16)])
        err = err − minor
        if err < 0:
            err = err + major
            step the minor axis (y by sy if xmajor, else x by sx)
        step the major axis (x by sx if xmajor, else y by sy)

TRI (TRI = 1):
    sort RASP0, RASP1, RASP2 by y:  (xt, yt), (xm, ym), (xb, yb)
    slope(a, b) = floor((xb − xa) × 65536 / (yb − ya))       # only for yb > ya
    for y = yt .. yb − 1:
        XL = xt × 65536 + slope(t, b) × (y − yt)              # the long edge
        XS = xt × 65536 + slope(t, m) × (y − yt)   if y < ym  # the short edge
             xm × 65536 + slope(m, b) × (y − ym)   otherwise
        left = ceil(min(XL, XS) / 65536);  right = ceil(max(XL, XS) / 65536)
        for x = left .. right − 1:  plot(x, y, 1)
```

- **What is written.** Only bytes that hold a plotted pixel are written. In such a byte, the other pixels keep their value.
- **Reads.** The old word is read first when MINTERM depends on C (its bits 7, 5, 3, 1 differ from bits 6, 4, 2, 0; in a triangle only bits 7–4 count), or when the write covers only part of a byte (depths under 8 bits; a span's ends).

### 5.4 Worked examples

**A line** from (2, 1) to (9, 4): dx 7, dy 3, x is the longer axis, the error term starts at 3. The pixels, in order:

```
(2,1) (3,1) (4,2) (5,2) (6,3) (7,3) (8,4) (9,4)
```

With RASPAT `0xF0F0` the first four pixels have A = 1 and the next four A = 0; with MINTERM `0xCA` only the first four are drawn.

**A triangle** with points (10, 2), (3, 6), (14, 9), in any order. Sorted: top (10, 2), middle (3, 6), bottom (14, 9). Slopes: the long edge 4/7 (`0x0000_9249`), top to middle −7/4 (`0xFFFE_4000`), middle to bottom 11/3 (`0x0003_AAAA`).

| Row y | Pixels x |
|-------|----------|
| 2 | none (both edges at x = 10) |
| 3 | 9 to 10 |
| 4 | 7 to 11 |
| 5 | 5 to 11 |
| 6 | 3 to 12 |
| 7 | 7 to 12 |
| 8 | 11 to 13 |

Row 9, the bottom point's, is not drawn: a triangle below, sharing that point or edge, draws it.

**Registers** for that triangle in colour 5 on a 320 × 200, 8 bpp bitmap at `0x10000`:

| Register | Value |
|----------|-------|
| RASCLIPMIN, RASCLIPMAX | `0x00000000`, `0x013F00C7` (0, 0 to 319, 199) |
| RASCTRL | `0xCC010305` (MINTERM `0xCC`, TRI, BPP = 3, VALUE 5) |
| RASP0, RASP1, RASP2 | `0x000A0002`, `0x00030006`, `0x000E0009` |
| RASDPT, RASSTRIDE | `0x10000`, 320 |
| RASNEXT | 0 |

then RUN to RASCMD. With MINTERM `0x66` instead, running it twice restores the bitmap. Both examples are directed tests (section 11, R2 and R4).

## 6. Memory cycles

The rasteriser is requester 6 (RAS) of the memory scheduler (spec 5, section 6), straight after the blitter: last in the spare-cycle order, but for the test port.

- **It uses cycles nobody else wants**, as the blitter does (spec 11, section 5), and takes its turn after the blitter's requests. Both ask for a cycle only now and then, so each still gets most of what it asks for while the other runs. **The CPU is never slowed** (with the default slot plan).
- **The slot plan** (MEMSLOT0–4, bit 6, RAS) can make the rasteriser an owner of cycles, as for any requester.
- **A descriptor** takes 16 read cycles (32 bytes) to load.
- **A pixel of a line** is one write, after one read where section 5.3 says. **A triangle's row** is one write for each memory word (16 bits at an even address) the span touches, after one read where needed: at 8 bpp with a minterm that does not read C, no reads at all when the span starts and ends on even addresses, and one or two a row otherwise.

## 7. Control and status registers

Offsets in the custom block at `0xE00000` (spec 3, section 3.5a). The job registers (`0x340`–`0x35C`) are in section 3 and the clip window (`0x36C`, `0x370`) in section 4.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x360` | RASDESC | ADDR 23–0 | The descriptor START loads. Read: the descriptor running, or the last one loaded. Bit 0 and bits 23–22 are not kept. Writes are ignored while BUSY |
| `0x364` | RASCMD | START (0), RUN (1), STOP (2) | Write only, strobes, as BLTCMD (spec 11, section 7). START: load the descriptor at RASDESC into the job registers and run it. RUN: run the job already in the job registers. Either way, at the end of a job with RASNEXT not 0, RASDESC becomes RASNEXT and that descriptor is loaded and run. START and RUN are ignored while BUSY; START wins over RUN. STOP ends the job after the pixel (LINE) or row (TRI) in hand; the chain is not followed, and the job cannot be resumed. STOP is ignored while idle |
| `0x368` | RASSTAT | BUSY (0), ERR (2) | Read only. BUSY: a job or a chain is running. ERR: the last job stopped on an error; cleared by the next START or RUN |
| `0x3F0` | DMXINT | BLT (0), RAS (1) | Shared with the blitter (spec 11, section 7). RAS is set when a rasteriser job with IRQ ends, and whenever the rasteriser stops: the chain's end, STOP, an error. Write 1 to a bit to clear it. A flag that comes due in the same clock as the write stays set |
| `0x3F4` | DMXINTEN | BLT (0), RAS (1) | Interrupt enables |

**The job registers** can be written while the rasteriser is idle; writes are ignored while BUSY. A descriptor load overwrites all eight. They hold the job as loaded or written, so after a job, writing only what changes and RUN starts a similar one: for a polyline, RASP0 and RASP1; for a triangle fan, one point. The copper can do the same.

**DMACON:** the blitter's bit, **BLTEN** (bit 6), with DMAEN, also lets the rasteriser use memory cycles. While it is clear a running job waits before its next memory access (BUSY stays set). There is no separate enable.

**Interrupts:** the rasteriser shares the blitter's source, 4 (BLT), of the interrupt controller (spec 13): the request is (DMXINT.BLT and DMXINTEN.BLT) or (DMXINT.RAS and DMXINTEN.RAS). The handler reads DMXINT to see which.

**The copper:** a WAIT with the B bit waits until the blitter **and** the rasteriser are idle (spec 10).

**Errors:** a reserved bit set in RASCTRL (section 3) is the only one. It is found before the job writes anything: the job and the chain end, ERR and DMXINT.RAS are set, and RASDESC still names the descriptor.

**Reset** (every reset, and the 68000's RESET instruction): the rasteriser is idle, RASDESC is 0, ERR, DMXINT and DMXINTEN are clear. The job registers and the clip window are not reset (they are 0 after power-on).

**The blitter and the rasteriser at once.** They are separate units with their own registers, descriptors and memory requests, and neither waits for the other. Nothing stops them writing the same memory: where their destinations overlap, the order of the writes is not specified.

**Typical use:**

1. Set the window once (RASCLIPMIN, RASCLIPMAX).
2. One job: write the job registers (RASNEXT = 0), then RUN to RASCMD.
3. A chain (a mesh, a polygon, a frame of wire-frame lines): write descriptors to Chip RAM, the first one's address to RASDESC, then START.
4. Carry on. Take the interrupt, or poll RASSTAT.BUSY.

## 8. Time

From the core's design (retro-hw's raster spec, section 4.4), in 10 ns clocks; a memory access also waits for its cycle, 20 ns or more. Not measured in this machine yet (open point Z2).

| Step | Time |
|------|------|
| Descriptor load (START, or a chain) | 16 read cycles: about 1 µs |
| Set-up and the first row's address | About 25 clocks: 0.25 µs |
| TRI: the sort and the three slopes | About 110 clocks: 1.1 µs |
| LINE: each pixel stepped | 2 clocks; if it is written, about 6 more and its memory accesses |
| TRI: each row | 4 clocks, and for each memory word of the span about 4 clocks and its memory accesses |

So a triangle pays about 1.5 µs before its first pixel, and then fills at 8 bpp at up to about 25 MB/s, as a blitter fill does; many tiny triangles are slow, and a few pixels may be quicker as a line or by the CPU. A line pixel takes about 100 ns (150 ns where it reads first), about ten times a 68000's rate. A line's end far outside the window costs 20 ns for each pixel stepped there: up to 1.3 ms for an end at ±32767.

## 9. FPGA resources

| Item | Resource |
|------|----------|
| The core (`raster.v`, with triangles) | About 1,430 LUTs alone in Vivado on this part, 1,825 LUTs and 781 flip-flops by Yosys (retro-hw's raster spec, R6) |
| The job registers (8 × 32 bits), the clip window (2 × 32) and the control registers | Flip-flops, driving the core's job ports directly |
| The scheduler's eighth requester | A wider mux in `dmac.v` |
| Block RAM, DSP | None |

The whole design went from 14,687 LUTs (70.6%) to 16,166 (77.7%) with the rasteriser (Vivado 2026.1, XC7A35T, 11 November 2026), and from 9,627 flip-flops to 10,809; timing at 100 MHz is met (worst setup slack +0.392 ns, hold +0.051 ns).

## 10. Open points

| # | Item |
|---|------|
| Z1 | This machine's own choices, made without review, each simple to change: (a) the wrapper lives in `dmx.v` beside the blitter's, sharing DMXINT and DMXINTEN (spec 11, D7); (b) its own requester, 6, taking the test port's owner bit in MEMSLOTn (the port is now requester 7 and can own no cycle); (c) DMACON.BLTEN enables both units, with no bit of its own (bit 4 is free); (d) one interrupt source with the blitter, not a source of its own (5 is free); (e) the copper's WAIT B waits for both; (f) reserved RASCTRL bits are an error, where the blitter ignores its own (spec 11, D5); (g) the descriptor layout: points together, the pattern a long word of its own, the colour in RASCTRL's low byte; (h) the window as two corner points |
| Z2 | Measure the times of section 8 in simulation and on the board, alone and with the blitter and a display running |
| Z3 | Closed: built in Vivado (section 9) |
| Z4 | The core does not reset the register that holds the old word (as the blitter's, spec 11, D8), so in simulation the first job after power-on writes unknown bits if it never reads memory first (a plain 8 bpp line). In hardware the bits cancel and the result is right. `rgen.py` starts with a job that reads; a reset in retro-hw's `raster.v` would be the proper cure |
| Z5 | A window per descriptor would let one chain draw into several windows. The core's descriptor has no room for it (retro-hw's raster spec, section 2.1) |
| Z6 | Shading, depth, and filled shapes other than triangles are not in this revision of the core (its R4). `geom`, for 3D points, would be a third unit |

## 11. Tests

`sim/rastest` (`make rastest`):

- **Random:** chains of jobs from `rgen.py`, every byte of 1 MB of Chip RAM against the model of section 5.3 (`rmodel.py`), so also that nothing outside a window is written. Among them a LINE and a TRI for every depth, stride sign and kind of minterm (plain, through the pattern, with the old pixel, both, random); points inside the window, just outside and far outside; random patterns and NOLAST; flat and one-pixel shapes; windows at negative coordinates; bitmaps at any byte address; chains started by START and by RUN, with descriptors at any even address; the ignored bits of the job registers set at random.
- **Directed** (checked by the test ROM): R1 the job registers, RASDESC and the window read back, bytes written on their own; R2 the example line by RUN; R3 the pattern through `0xCA`, NOLAST and the window's edge; R4 the example triangle by START, the job registers then holding the descriptor; R5, R6 a chain with DMXINT.RAS only at its end, and after a job with IRQ; R7, R8 a reserved RASCTRL bit by RUN and in a chain (ERR, DMXINT, nothing written, RASDESC, ERR cleared by the next start); R9 writes to the job registers, RASDESC and the window ignored while BUSY, and STOP mid-job, the chain not followed; R10 BLTEN clear holding a job; R11 the interrupt request and the two DMXINT bits; R12 a blitter fill and a line running together; R13 the copper's WAIT B waiting for the rasteriser.

The core has its own tests in retro-hw (`test/raster`): every memory write against the same model, random waits, both byte orders, lines only (`TRI` 0), and the properties of section 5.2 (shared edges, point order).
