# Spec 11: Blitter

Status: **version 2, for review**. Rebuilt on 10 November 2026 on retro-hw's redesigned blitter core (`fpga/retro-hw/docs/spec/blitter.md`, revision 2; retro-hw PR #14), shared with retro-z80.

The blitter works on rectangles of pixels in Chip RAM: it copies, fills, combines and cuts out, while the CPU carries on with other work. Each destination pixel is a logic function (the minterm) of a mask A, a source B and the destination's old contents C, as in the Amiga's blitter. A job can name a next job, so a list of jobs runs with no CPU in between.

**What changed from version 1, and why.** Version 1 was a 4-channel DMA engine: BLIT and ADD jobs, peripheral ports (the SD card, the serial link), the custom registers, palettes and boot ROM as job memory, a 2 KB descriptor RAM, a HIGH bit to take the CPU's memory cycles, PAUSE, timer starts and an address range check. Its shared core tried to do too much (retro-hw's own words) and was about 2,750 LUTs here; the redesign is about 1,060 (Vivado, the core alone). It became three cores: this one for rectangles; `raster` for lines and triangles (spec 17); `geom` for 3D points. This spec follows the new blitter core:

| Version 1 | Now |
|-----------|-----|
| 4 channels taking turns | One job at a time, with chains |
| ADD | Gone |
| Port jobs: the SD card (port 0), the serial link (port 1) | Gone. The CPU moves those bytes (specs 14 and 15); SDCOUNT is gone. A FIFO mover may come back later (open point D4) |
| The custom block (registers, palettes, descriptor RAM) and the boot ROM as job memory | Gone: a job reaches Chip RAM only. The copper or the CPU loads registers and palettes. The descriptor RAM at `0xE06000` is gone |
| HIGH (a job taking the CPU's cycle 0) | Gone. The slot plan (MEMSLOT0–4) can still give the blitter any cycle |
| PAUSE; timers starting channels (TMRn CTRL.DMA, DMACH) | Gone. DMACON.BLTEN holds the blitter |
| The address range check, CHERR | Gone: an address past the memory wraps. Software keeps jobs in bounds |
| DESC (a whole job backwards) | RTL (each row right to left); rows bottom-up by negative strides |
| A and B shared a stride | A has its own (ASTRIDE): old open point D6 is closed |
| VALUE 32 bits, also the key colour | VALUE 16 bits (one memory word of pixels); KEY is its own field |
| A destination word left unchanged was not written | Every destination word of the row is written; C is read first when the minterm needs it |
| LINE planned as an OP of this engine | Lines and triangles are the rasteriser's, a unit of its own beside the blitter (spec 17) |

The job registers keep their version 1 places where the field still exists. Software written for version 1 needs porting: the CTRL bits, VALUE and the control registers differ.

## 1. Summary

| Item | Value |
|------|-------|
| Jobs | One at a time. A job may chain to a next descriptor |
| Programming | A job written straight into the job registers, or chains of 32-byte **descriptors** (laid out as those registers) in Chip RAM |
| Operation | D = minterm(A, B, C), any of the 256, per bit |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, positioned to the pixel: chunky layers directly, planar layers one plane at a time (section 6.1) |
| A (the mask) | None (all ones), a 1 bpp image, or B compared with a key colour |
| B (the source) | Chip RAM, or a constant word (a fill) |
| Direction | Left to right, or right to left (RTL) for overlapping copies; rows in either order, by the sign of the strides |
| Clipping | None: software trims the rectangle (section 3.5) |
| Memory | Chip RAM only. Normally only free memory cycles, so the CPU is never slowed |
| Speed | Measured in simulation (section 8): a fill 25 MB/s, a copy 17 MB/s, a cookie-cut 12 MB/s. A 68000 at 20 MHz copies about 4 MB/s |
| Finishing | A flag and an interrupt at the end of a chain, and after any job that asks; BUSY and ERR to poll |

## 2. Comparison with the Amiga

| Feature | Amiga blitter | retro68k blitter |
|---------|---------------|------------------|
| Jobs at once | 1 | 1 |
| Starting jobs | CPU or copper writes registers, then waits for the blitter to finish before the next job | The same (the job registers), or a chain of jobs the blitter works through alone |
| Pixel layout | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at any depth: one blit for all colour depths. Planar layers: one blit per plane, as on the Amiga (section 6.1) |
| Masked (cookie-cut) drawing | A separate mask plane and the minterm logic | The same minterms and a 1 bpp mask, at any colour depth; or a colour-key compare, which needs no mask in memory |
| Logic | Any function of 3 sources (minterms) | The same: the minterm, in the Amiga's numbering, of the mask A, the source B and the destination C |
| Edge masks | First-word and last-word mask registers | Automatic, from the starting pixel and the width |
| Overlapping copies | Descending mode | RTL for rows, negative strides for bottom-up |
| Priority | BLTPRI ("blitter nasty") for all blits | The slot plan (spec 5, section 8.1) |
| Line drawing, area fill | Yes | Not here: the rasteriser (spec 17) draws lines and fills triangles |

## 3. The job

A job is eight long words: the job registers, or a 32-byte descriptor in Chip RAM at an even address, which the blitter loads into them. Offsets are in the custom block (`0xE00000`, spec 3, section 3.5) for the registers, and from the descriptor's start in memory. A descriptor is stored as the registers are: big-endian long words.

| Register | Descriptor | Name | Bits | Meaning |
|----------|------------|------|------|---------|
| `0x300` | `+0x00` | BLTCTRL | see below | Options, KEY and MINTERM |
| `0x304` | `+0x04` | BLTBPT | ADDR 23–0, BIT 26–24 | The source B: the byte holding the first row's first pixel (with RTL, its last pixel: the first one worked on). BIT (BBIT): that pixel's place in its byte, in pixels from the most significant end (0–7 at 1 bpp, 0–3 at 2, 0–1 at 4, 0 at 8) |
| `0x308` | `+0x08` | BLTDPT | ADDR 23–0, BIT 26–24 | The destination D, which is also where C is read. As BLTBPT (DBIT) |
| `0x30C` | `+0x0C` | BLTSIZE | WIDTH 15–0, HEIGHT 31–16 | Pixels per row, and rows. Either 0 is an empty job |
| `0x310` | `+0x10` | BLTAPT | ADDR 23–0, BIT 26–24 | The mask image A (MASK = 1), 1 bpp: the byte holding the first row's first mask bit (with RTL, its last). BIT (ABIT): that bit, from the most significant end (0–7) |
| `0x314` | `+0x14` | BLTSTRIDE | BSTRIDE 31–16, DSTRIDE 15–0, both signed | Bytes from one row's start to the next, for B and for D |
| `0x318` | `+0x18` | BLTVALUE | ASTRIDE 31–16 (signed), VALUE 15–0 | ASTRIDE: the same for A. VALUE: the constant B (BCONST): one memory word of pixels (section 3.2) |
| `0x31C` | `+0x1C` | BLTNEXT | ADDR 23–0 | The next descriptor's address; 0 for none |

**BLTCTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 7–0 | KEY | The key colour for MASK = 2, in its low bits (as many as the pixel has) |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | RTL | Work each row right to left (section 3.4) |
| 12 | IRQ | Set DMXINT.BLT when this job ends (section 7) |
| 13 | BCONST | B is VALUE, not memory (a fill) |
| 18–17 | MASK | Where A comes from: 0 none (every pixel 1), 1 the 1 bpp image at BLTAPT, 2 a compare of B with KEY (A is 1 where B differs), 3 an error |
| 31–24 | MINTERM | The logic function of A, B and C (section 3.1) |

Bits not listed are reserved: write 0. The blitter ignores them (they read back as written).

Address bits 23–22 are ignored: a job reaches Chip RAM only (section 4).

### 3.1 The minterm

For each pixel of the job, the blitter works out D from three inputs, bit by bit, as the Amiga's blitter does:

- **A, the mask.** One bit per pixel, used for every bit of the pixel.
- **B, the source.** Read from BLTBPT, or VALUE with BCONST.
- **C, the background:** the destination's old contents, read from BLTDPT.

Each bit of D is MINTERM's bit number A × 4 + B × 2 + C, as the Amiga's minterm (LF7–LF0). So A = `0xF0`, B = `0xCC` and C = `0xAA`, and any expression of them gives its minterm (for example A ? B : C is (`0xF0` AND `0xCC`) OR (NOT `0xF0` AND `0xAA`) = `0xCA`):

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Copy; with BCONST, fill |
| `0xCA` | A ? B : C | Cookie-cut: draw B where the mask is 1, leave the background where it is 0 |
| `0xEE` | B OR C | Set bits |
| `0x88` | B AND C | Keep only the bits B has |
| `0x66` | B XOR C | Draw and undraw with the same job |
| `0x22` | C AND NOT B | Clear where B is set |
| `0x55` | NOT C | Invert an area |
| `0x00`, `0xFF` | 0, all ones | Clear or set an area |
| `0x0A` | A ? 0 : C | Clear through the mask (a shape's hole) |

With MASK = 0, A is 1 everywhere, so only MINTERM's high four bits matter.

**The version 1 operations as jobs:**

| Old job | Now |
|---------|-----|
| COPY | MINTERM `0xCC` |
| FILL | MINTERM `0xCC`, BCONST, VALUE the colour in every pixel of a word |
| KEYCOPY | MINTERM `0xCA`, MASK = 2, KEY the transparent colour |
| LOGIC with FN | MINTERM `FN × 0x11` |
| ADD | None: the CPU does it |

### 3.2 The mask and the constant

- **MASK = 1, the image.** A's bits are packed from the most significant end of each byte, one a pixel, whatever BPP is. So a mask's rows are shorter than an 8 bpp source's: A has its own stride (ASTRIDE).
- **MASK = 2, the key.** A is 1 where B's pixel differs from KEY's low bits and 0 where it matches. It costs no memory. With BCONST it compares VALUE's pixels.
- **VALUE, the constant B.** VALUE lies over every memory word of the destination (the two bytes at an even address, the even byte in bits 15–8): a pixel takes VALUE's bits at its own place in its word. So a plain colour is the pixel value repeated to fill 16 bits (`0x5555` for colour 1 at 2 bpp, `0x0707` for colour 7 at 8 bpp), and a pattern in VALUE lines up with memory words, not with the rectangle's left edge.

### 3.3 The exact result

This is the definition the test model (`sim/dtest/dmodel.py`) follows. A bit position n means bit 7 − (n mod 8) of the byte at address n div 8, so positions run left to right through a row. Byte addresses are taken modulo 4 MB.

```
bits = 1 << BPP
for r = 0 .. HEIGHT − 1:                                  # rows in the order given
    pd = 8 × (BLTDPT.ADDR + r × DSTRIDE) + DBIT × bits
    pb = 8 × (BLTBPT.ADDR + r × BSTRIDE) + BBIT × bits
    pa = 8 × (BLTAPT.ADDR + r × ASTRIDE) + ABIT
    for i = 0 .. WIDTH − 1:                               # pixels in the order worked
        k = −i if RTL else i
        C = the pixel at bit position pd + k × bits       # bits wide
        B = VALUE's bits at (pd + k × bits) mod 16        if BCONST (bit 15 is place 0)
            the pixel at bit position pb + k × bits       otherwise
        A = 1                                             if MASK = 0
            the bit at bit position pa + k                if MASK = 1
            1 if B ≠ KEY's low bits, else 0               if MASK = 2
        for each bit j of the pixel:
            D[j] = MINTERM[4 × A + 2 × B[j] + C[j]]
        the pixel at pd + k × bits becomes D
```

- **What is written.** Only bytes that hold at least one pixel of a row are written. In such a byte, pixels outside the row keep their value.
- **Nothing else changes.** No word outside the destination rows is written, and A and B are never written.
- **Overlap.** The result above is what the blitter gives whenever no memory word is written before it is read as A or B for a later pixel (section 3.4). With an overlap worked the wrong way the result is not specified.

### 3.4 Direction

A copy whose source and destination overlap must not overwrite source pixels it has yet to read.

- **Rows.** The blitter always goes from the row the pointers name to the next by adding the strides. To work from the bottom row up, give the bottom row's addresses and negative strides.
- **Within a row.** With RTL the blitter works each row from its last pixel to its first: the pointers and their BIT fields name the row's last pixel, and words are taken in falling address order.

| Destination is | Use |
|----------------|-----|
| To the left of the source, or above it | The job as it is |
| To the right, in the same rows | RTL |
| Below | Rows bottom-up (negative strides) |

The result is the same in either direction when source and destination don't overlap. A stride of 0 repeats the same row.

### 3.5 Shapes of jobs

**Linear jobs** (memcpy, memset): BPP = 8, HEIGHT = 1, WIDTH = the length in bytes, up to 65,535. A longer one is a job with equal widths and strides (for example WIDTH = BSTRIDE = DSTRIDE = 16 KB, HEIGHT = the number of 16 KB blocks), or a chain.

**Rectangles** (blits): WIDTH × HEIGHT pixels, with each row starting a stride after the last. A, B and D have their own strides, so an image can be copied out of a sprite sheet into a screen, through a 1 bpp mask sheet with shorter rows.

**Clipping is done by software.** To draw only part of an image (an object partly off the screen), trim the job before starting it, keeping the strides the same:

- **Left edge:** skip k pixels: move BLTBPT and BLTDPT on by k pixels (bytes, plus BBIT and DBIT below 8 bpp), BLTAPT by k bits (bytes plus ABIT), and subtract k from WIDTH.
- **Right edge:** subtract the pixels past the edge from WIDTH.
- **Top edge:** skip r rows: add r × ASTRIDE to BLTAPT, r × BSTRIDE to BLTBPT and r × DSTRIDE to BLTDPT, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is fully off the screen: the job does nothing.

With RTL, or rows bottom-up, the pointers name the other end, and the same trims apply from that end.

### 3.6 Worked examples

A 320-pixel-wide, 8 bpp bitmap at `0x10000` (stride 320) in each case. CTRL is BLTCTRL; `0x300` is BPP = 3.

| Job | Registers |
|-----|-----------|
| Fill the 32 × 16 rectangle at (40, 20) with colour 7 | CTRL `0xCC002300` (MINTERM `0xCC`, BCONST), VALUE `0x0707`, WIDTH 32, HEIGHT 16, DPT `0x10000` + 20 × 320 + 40, DSTRIDE 320 |
| Copy a 32 × 32 image at `0x20000` (stride 32) to (100, 50) | CTRL `0xCC000300`, BPT `0x20000`, BSTRIDE 32, DPT `0x10000` + 50 × 320 + 100, DSTRIDE 320, WIDTH 32, HEIGHT 32 |
| The same, with colour 0 transparent | As the copy, with CTRL `0xCA040300` (MINTERM `0xCA`, MASK = 2, KEY 0) |
| An 8 × 8 character from a 1 bpp font at `0x30000` (one byte a row) in colour 15 at (8, 8) | CTRL `0xCA022300` (MINTERM `0xCA`, MASK = 1, BCONST), APT `0x30000` + 8 × character, ASTRIDE 1, VALUE `0x0F0F`, DPT `0x10000` + 8 × 320 + 8, DSTRIDE 320, WIDTH 8, HEIGHT 8 |
| Scroll the whole 320 × 200 picture down 8 rows | A copy with the rows bottom-up: BPT `0x10000` + 191 × 320, DPT `0x10000` + 199 × 320, BSTRIDE −320, DSTRIDE −320, WIDTH 320, HEIGHT 192 |
| Scroll it right 4 pixels | A copy right to left: CTRL `0xCC000700` (RTL), BPT `0x10000` + 315 (the last source pixel of row 0), DPT `0x10000` + 319, strides 320, WIDTH 316, HEIGHT 200 |

## 4. What a job can reach

**Chip RAM only.** The pointers and BLTNEXT are CPU addresses, but only their low 22 bits are used: there is no range check, and an address past 4 MB wraps round into Chip RAM. Software keeps jobs in bounds. A descriptor's address also loses its bit 0, so BLTNEXT ends a chain when its bits 21–1 are 0.

The custom registers, the palettes, the boot ROM and the system block cannot be a job's source or destination (in version 1 the first three could). Registers and palettes are loaded by the copper (spec 10) or the CPU. The descriptor RAM is gone: descriptors live in Chip RAM.

## 5. Memory cycles

The blitter is requester 5 (BLT) of the memory scheduler (spec 5, section 6): in the spare-cycle order after the display, audio, the copper and the CPU, ahead of the rasteriser (spec 17) and the DMA port.

- **One memory cycle** (20 ns) reads or writes 2 bytes at an even address, with byte selects for single bytes (spec 5, section 4.2).
- **The blitter uses cycles nobody else wants**: cycle 4, cycle 2 when audio isn't using it, display cycles (1 and 3) no layer or sprite needs, and cycle 0 whenever the CPU isn't using it. **The CPU is never slowed** (with the default slot plan, spec 5, section 8.1).
- **The slot plan** (MEMSLOT0–4) can make the blitter the owner of cycles: `0x20` in MEMSLOT0 gives it cycle 0 in place of the CPU, which then gets spare cycles only.
- **A descriptor** takes 16 read cycles (32 bytes) to load.

## 6. How a blit works

The blitter works through each row a destination word (16 bits at an even address) at a time. Each word takes these memory accesses, in this order:

| Access | When |
|--------|------|
| Read B | B is memory, and MINTERM depends on B or MASK = 2. One word for each 16 source bits used: sometimes two for the row's first word, none for a word the last read still covers |
| Read A | MASK = 1 and MINTERM depends on A: one word for every 16 pixels |
| Read C | MINTERM depends on C, or the word is the row's first or last and a byte of it is only partly inside the row |
| Write D | Always, with the byte selects off for bytes wholly outside the row |

So a fill is one access a word, a copy two, and a cookie-cut with a key colour three.

"Depends on" is read from MINTERM alone: it depends on C when bits 7, 5, 3, 1 differ from bits 6, 4, 2, 0; on B when bits 7, 6, 3, 2 differ from 5, 4, 1, 0; on A when bits 7–4 differ from bits 3–0. With MASK = 0 only bits 7–4 count.

The datapath for a word:

| Stage | What |
|-------|------|
| B | The source bits for this word, lined up to the destination by a barrel shifter over the last and the current source word (as the Amiga's); or VALUE |
| A | The image's bits, one a pixel, widened to the pixel; or 1 where B's pixel differs from KEY; or all ones |
| Combine | The minterm of A, B and C, bit by bit |
| Edges | In the row's first and last words, pixels outside the row keep C |

**Edge masks are automatic.** The blitter works out which pixels of the first and last words of each row belong to the job from DBIT and WIDTH. There are no mask registers to set, unlike the Amiga's first-word and last-word masks.

The blitter may read one source or mask word past the row's last pixel. It never writes outside the row.

**A cookie-cut reads C at every depth**, 8 bpp included: where A is 0 the old pixel is written back. (Version 1 skipped the byte at 8 bpp.) So a cookie-cut costs three accesses a word, and a plain copy two.

### 6.1 Planar layers

A planar layer (spec 4, section 4.2) is several 1 bpp pictures, one per plane. The blitter draws into it at BPP = 0, a plane at a time, positioned to the pixel:

- **Separate planes:** one job per plane, chained, with BLTBPT and BLTDPT moved on by a plane each time.
- **Interleaved planes** (each row of each plane next to the row of the next plane): one job does all the planes, if the source is interleaved the same way: HEIGHT = rows × planes, and each stride = one plane row's bytes.
- **Transparent drawing (cookie cut)**, as on the Amiga: keep a 1 bpp mask of the object (1 where it has a pixel). For each plane, one job with MINTERM `0xCA`, MASK = 1, BLTAPT the mask and BLTBPT the object's plane. The same mask serves every plane. A key colour is for chunky layers: in a planar layer, a colour is spread over the planes.

## 7. Control and status registers

Offsets in the custom block at `0xE00000` (spec 3, section 3.5). The job registers (`0x300`–`0x31C`) are in section 3.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x320` | BLTDESC | ADDR 23–0 | The descriptor START loads. Read: the descriptor running, or the last one loaded. Bit 0 and bits 23–22 are not kept. Writes are ignored while BUSY |
| `0x324` | BLTCMD | START (0), RUN (1), STOP (2) | Write only, strobes. START: load the descriptor at BLTDESC into the job registers and run it. RUN: run the job already in the job registers. Either way, at the end of a job with BLTNEXT not 0, BLTDESC becomes BLTNEXT and that descriptor is loaded and run. START and RUN are ignored while BUSY; START wins over RUN. STOP ends the job after the destination word in hand; the chain is not followed, and the job cannot be resumed. STOP is ignored while idle |
| `0x328` | BLTSTAT | BUSY (0), ERR (2) | Read only. BUSY: a job or a chain is running. ERR: the last job stopped on an error; cleared by the next START or RUN |
| `0x3F0` | DMXINT | BLT (0), RAS (1) | BLT is set when a job with IRQ ends, and whenever the blitter stops: the chain's end, STOP, an error. Write 1 to clear. A flag that comes due in the same clock as the write stays set, so none is lost. RAS is the rasteriser's (spec 17) |
| `0x3F4` | DMXINTEN | BLT (0), RAS (1) | Interrupt enables |

**The job registers** can be written while the blitter is idle; writes are ignored while BUSY. A descriptor load overwrites all eight. They hold the job as loaded or written: the blitter's progress is kept inside it, not in them. So after a job, writing only the fields that change (for example BLTBPT and BLTDPT) and RUN starts a similar one, which suits the copper: a few MOVEs set up and start a blit with nothing in memory.

**DMACON** (spec 5, section 8): bit 6, **BLTEN**, with DMAEN, lets the blitter use memory cycles. While it is clear a running job waits before its next memory access (BUSY stays set). The same bit holds the rasteriser.

**Interrupts:** the blitter is source 4 (BLT) of the interrupt controller (spec 13), default level 4. It requests its interrupt while DMXINT.BLT and DMXINTEN.BLT are both set; the rasteriser shares the source, with the RAS bits (spec 17, section 7). (DMXINT keeps its version 1 name and place; bits 3–1 were channels 1–3.)

**Errors:** MASK = 3 is the only one. It is found before the job writes anything: the job and the chain end, ERR and DMXINT.BLT are set, and BLTDESC still names the descriptor.

**Reset** (every reset, and the 68000's RESET instruction): the blitter is idle, BLTDESC is 0, ERR, DMXINT and DMXINTEN are clear. The job registers are not reset (they are 0 after power-on).

**Typical use:**

1. One job: write the job registers (BLTNEXT = 0), then RUN to BLTCMD.
2. A chain: write descriptors to Chip RAM, the first one's address to BLTDESC, then START to BLTCMD. (Or write the first job into the job registers, with BLTNEXT pointing at the rest, and RUN.)
3. Carry on. Take the interrupt, or poll BLTSTAT.BUSY.

The copper can also start jobs, for example to change a screen area at a set beam position, and its WAIT with the B bit waits until the blitter and the rasteriser are both idle (spec 10).

## 8. Speed

The blitter puts up one memory request at a time and works a word in several clocks, so its own steps, not the memory, set the speed: a memory cycle is 20 ns, and it uses a quarter to a third of those it could have. Measured in simulation (`make -C sim dspeed`), with the display off and the CPU polling BLTSTAT from ROM; the jobs are 4 rows of 16 KB:

| Job (64 KB at 8 bpp unless said) | Accesses a word | Time a word | Speed |
|----------------------------------|-----------------|-------------|-------|
| Fill (`0xCC`, BCONST) | 1 | 80 ns | 25 MB/s |
| Copy (`0xCC`) | 2 | 120 ns | 16.7 MB/s |
| Invert with a constant (`0x66`, BCONST) | 2 | 120 ns | 16.7 MB/s |
| Cookie-cut with a key (`0xCA`, MASK = 2) | 3 | 160 ns | 12.5 MB/s |
| Cookie-cut with a mask image (`0xCA`, MASK = 1) | 3, and 1 for every 16 pixels | 170 ns | 11.8 MB/s |
| Copy at 1 bpp, source and destination 3 bits apart | 2 | 120 ns | 16.7 MB/s (133 million pixels a second) |

With the CPU reading Chip RAM all the while instead, each job took under 1% longer, and the CPU had no wait states.

A 576p line is 32 µs, so a 720-pixel 8 bpp row is filled in about a line's time (29 µs) and copied in about a line and a half (43 µs). For comparison, a 68000 at 20 MHz copies about 4 MB/s (`MOVE.L (A0)+,(A1)+`). A busy display takes cycles the blitter would have used; that is not measured yet (open point D2).

Version 1's figures (copy 25–38 MB/s, fill 50–77 MB/s) were worked out from the free memory cycles and were not reached in practice; the redesign chose a small, simple core first (retro-hw's blitter spec, B2).

## 9. FPGA resources

| Item | Resource |
|------|----------|
| The core (`blitter.v`, with the mask image) | About 1,060 LUTs (Vivado, alone) and 400 flip-flops (Yosys); both from retro-hw's blitter spec, B2 |
| The job registers (8 × 32 bits) and the control registers | Flip-flops, driving the core's job ports directly |
| Block RAM, DSP | None (version 1: one block RAM, 2 DSP slices) |

Version 1's engine was about 2,300 LUTs here. The whole design went from 16,555 LUTs (79.6%) to 14,687 (70.6%) with this one (Vivado 2026.1, XC7A35T, 10 November 2026), and from 10,698 flip-flops to 9,627; timing at 100 MHz is met (worst setup slack +0.503 ns, hold +0.036 ns).

## 10. Open points

| # | Item |
|---|------|
| D1 | Closed: built in Vivado (section 9) |
| D2 | Measure the speed with a busy display and CPU, and on the board |
| D3 | Closed: lines and triangles are the rasteriser's (spec 17), retro-hw's `raster` core with its own registers at `0x340`, beside the blitter in `dmx.v`. `geom` (3D points) is later still. They are separate cores, not operations of this one, so version 1's OP codes (LINE, span fill, triangle, MIX) are gone |
| D4 | A FIFO mover for the SD card and the serial link (version 1's port jobs) is decided later (retro-hw's blitter spec, B3). Until then the CPU moves those bytes |
| D5 | Reserved bits of the job registers are ignored, not an error (the core's `job_bad` is tied off). Software written for version 1's CTRL gets a wrong picture, not ERR |
| D6 | Closed: the mask has its own stride (ASTRIDE) |
| D7 | Closed: `dmx.v` keeps its name, and DMXINT and DMXINTEN theirs; the rasteriser's wrapper is in it and shares them (bit 1, RAS) |
| D8 | Closed: retro-hw's `blitter.v` resets the registers the write data is built from, so a first job that never reads C is safe in simulation |

## 11. Tests

`sim/dtest` (`make dtest`):

- **Random:** chains of jobs from `dgen.py`, every byte of 1 MB of Chip RAM against the model of section 3.3 (`dmodel.py`). Among them one job for every depth, mask kind, row direction (RTL) and stride sign; random minterms, widths from 1 pixel, every BIT, constant and memory B, strides of 0; copies that overlap their source in every direction; jobs of no width or height inside chains; chains started by START and by RUN, with descriptors at any even address.
- **Directed** (checked by the test ROM): the job registers and BLTDESC read back, bytes written on their own; a fill by RUN with the bytes either side untouched; a copy by START, the job registers then holding the descriptor; a chain with DMXINT only at its end, and after a job with IRQ; MASK = 3 by RUN and in a chain (ERR, DMXINT, nothing written, BLTDESC, ERR cleared by the next start); writes to the job registers and BLTDESC ignored while BUSY; STOP mid-job, the chain not followed; BLTEN clear holding a job; the interrupt request.
- **The slot plan** (T17–T19): a job never makes the CPU wait with the default plan, and does with the blitter owner of every cycle.

The core has its own tests in retro-hw (`test/blitter`): every memory write against a pixel-exact model, random waits, both byte orders.
