# Chapter 6: DMA Engine and Blitter Hardware

## Introduction

The **DMA engine** moves data so the 68000 does not have to. It copies and fills memory, draws graphics (it is retro68k's **blitter**), writes the hardware registers, and moves data to and from the USB serial link and the SD card. You describe a job, start it, and the CPU carries on with other work while the engine does it, using memory cycles nobody else needs.

The engine can:

- copy or fill a block of memory, at up to about 38 MB/s copying and 77 MB/s filling, against about 4 MB/s for the 68000;
- copy or fill a rectangle: part of a sprite sheet into a screen, a window of a picture, a box of colour;
- draw objects with transparent parts, a pixel at a time at any colour depth, through a colour key or a 1 bpp mask;
- draw text and shapes in one colour through a 1 bpp mask;
- combine a mask, an image and the destination with any logic function (the Amiga's minterms), or add image and destination pixel by pixel, for masks, shading and glows;
- run a chain of jobs from memory with no help from the CPU, on any of four channels at once;
- write a block of registers in one job, start other channels, or be started by the copper or a timer.

This chapter covers:

- forming a job, step by step, and a first example;
- the job registers and descriptors;
- the operations: BLIT, with its minterms and masks, and ADD;
- pixel depths, pixel positions and the automatic edge masks;
- rectangles, strides and clipping;
- overlapping copies and backwards jobs;
- drawing into planar layers, including the Amiga's cookie cut;
- chains of jobs and the descriptor RAM;
- starting jobs from the copper and from timers;
- registers, palettes and the ROM as sources and destinations;
- moving data to and from the USB serial link and the SD card;
- status, interrupts and errors;
- priority, HIGH jobs and speed.

You should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, and the Playfield Hardware chapter, since most blits draw into a layer.

**Note:** The engine is built in the FPGA design (`fpga/rtl/dmx.v`) and tested in simulation (`make -C sim dtest`, which checks random jobs byte for byte against a model), but not yet on the board.

### Comparison with the Amiga

| Feature | Amiga blitter (OCS/ECS) | retro68k DMA engine |
|---------|-------------------------|---------------------|
| Jobs at once | 1 | 4 channels, taking turns |
| Starting a job | Write the registers, write BLTSIZE; wait for the blitter before the next | The same (a channel's job registers, then RUN), or a chain of jobs in memory that runs alone |
| Pixels | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at 1, 2, 4 or 8 bits, positioned to the pixel; planar layers a plane at a time, as on the Amiga |
| Transparent drawing | A mask plane and the minterms (cookie cut) | The same minterms and a 1 bpp mask, at any colour depth; or, in chunky layers, a colour-key compare that needs no mask in memory |
| Logic | Any function of three sources (minterms) | The same: the minterm, in the Amiga's numbering, of the mask A, the image B and the destination C |
| Arithmetic | None | ADD, per pixel, wrapping or saturating, signed or unsigned |
| Edge masks | BLTAFWM, BLTALWM | Worked out by the hardware |
| Line drawing, area fill | Yes | No (version 2) |
| Register writes | The copper only | The copper, or a job: block copies into the registers |
| Disk and other transfers | Their own DMA channels | The same engine, through ports |
| Priority | BLTPRI ("blitter nasty") | The HIGH bit, per job, leaving the CPU a share |

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax, starting with `include "hw.inc"`. **a4 holds CUSTOM** (`$E00000`) and **a5 holds SYSTEM** (`$F00000`).
- The engine uses **CPU addresses**: a job's addresses are written as the CPU sees them, so a register is `CUSTOM+BGCOLOR` and a palette entry `CUSTOM+PALETTE0+5*4`.
- The examples use these constants for CTRL (section "The Job Registers"):

```asm
COPY8       equ     ($CC<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)       ; BLIT D = B, 8 bits per pixel
FILL8       equ     COPY8|(DMX_KIND_VALUE<<DMX_CTRL_BKIND_B)            ; the same, B is VALUE: a fill
RUNIT       equ     DMX_CHCTRL_RUN_M|(1<<DMX_CHCTRL_CPUSHARE_B)         ; RUN, CPU share 1 in 4
```

---

## Forming a Job

A job is eight long words: what to do, where from, where to, how big, and what comes next. You write them into one of the four channels' **job registers** and start the channel. This section clears part of a screen and copies an image onto it, from the CPU.

### Step 1: Turn the engine on

The engine uses memory cycles only while **DMACON.BLTEN** and **DMACON.DMAEN** are both set:

```asm
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
```

### Step 2: Describe the job

The job registers of channel n start at `DMXn`, in this order: CTRL, BPT, DPT, SIZE, APT, STRIDE, VALUE, NEXT. To fill 64 bytes at `$080000` with zeros:

```asm
        lea     DMX0(a4),a0
        move.l  #FILL8,DMX_CTRL(a0)             ; BLIT D = B, B is VALUE, 8 bpp
        move.l  #$080000,DMX_DPT(a0)            ; where
        move.l  #(1<<16)|64,DMX_SIZE(a0)        ; 1 row of 64 bytes
        move.l  #0,DMX_VALUE(a0)                ; the value
        move.l  #0,DMX_NEXT(a0)                 ; no more jobs after this one
```

BPT, APT and STRIDE are not used by a one-row fill.

### Step 3: Start it

```asm
        move.l  #RUNIT,DMX_CHCTRL(a0)           ; run the job in the registers
```

RUN starts the job already in the registers. The channel is **BUSY** (CHSTAT bit 0) until the job, and any jobs chained after it, are done; then **DONE** (bit 1) is set.

### Step 4: Wait, or do something else

```asm
.wait:  btst    #DMX_CHSTAT_BUSY_B,DMX_CHSTAT+3(a0)
        bne.s   .wait
```

Better, carry on with other work and take the channel's interrupt (see "Status, Interrupts and Errors"). While a channel is busy its job registers ignore writes, so you cannot spoil a running job by accident; another channel can be set up meanwhile.

### Example 6-1: Clear a box and draw an image into it

A 320 × 200 chunky 8 bpp screen at `SCREEN` (rows of 320 bytes). Clear a 64 × 48 box at (100, 50), then copy a 32 × 32 image from a sprite sheet (rows of 256 bytes) into its middle.

```asm
; Example 6-1: clear a box, then copy an image into it (8 bpp chunky)
SCREEN      equ     $100000
SHEET       equ     $140000             ; a 256-pixel-wide sheet
ROW         equ     320

            lea     DMX0(a4),a0
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)

            ; the box: 64 x 48 at (100, 50), filled with colour 0
            move.l  #FILL8,DMX_CTRL(a0)
            move.l  #SCREEN+50*ROW+100,DMX_DPT(a0)
            move.l  #(48<<16)|64,DMX_SIZE(a0)   ; 48 rows of 64
            move.l  #ROW,DMX_STRIDE(a0)         ; destination stride (low half)
            move.l  #0,DMX_VALUE(a0)
            move.l  #0,DMX_NEXT(a0)
            move.l  #RUNIT,DMX_CHCTRL(a0)
            bsr     wait0

            ; the image: 32 x 32 from the sheet's frame at (64, 0), to (116, 58)
            move.l  #COPY8,DMX_CTRL(a0)
            move.l  #SHEET+64,DMX_BPT(a0)
            move.l  #SCREEN+58*ROW+116,DMX_DPT(a0)
            move.l  #(32<<16)|32,DMX_SIZE(a0)
            move.l  #(256<<16)|ROW,DMX_STRIDE(a0)   ; image stride, destination stride
            move.l  #RUNIT,DMX_CHCTRL(a0)
            bsr     wait0
            rts

wait0:      btst    #DMX_CHSTAT_BUSY_B,DMX0+DMX_CHSTAT+3(a4)
            bne.s   wait0
            rts
```

The second job only changes the fields that differ: the job registers keep their values from the last job.

---

## The Job Registers

Each channel has these registers. The first eight are the **job registers**; a **descriptor** in memory has exactly the same layout (see "Chains of Jobs").

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `$00` | CTRL | see below | The operation, its options and the minterm |
| `$04` | BPT | ADDR (23–0), BIT (26–24) | The image B: its first pixel (CPU address), or a port number. BIT (BBIT): the first pixel's place within its byte, at 1, 2 and 4 bpp |
| `$08` | DPT | ADDR (23–0), BIT (26–24) | The destination D, which is also where C is read: its first pixel, or a port number. BIT (DBIT) as BPT's |
| `$0C` | SIZE | WIDTH (15–0), HEIGHT (31–16) | Pixels per row (bytes at 8 bpp), and rows (1 for a one-row job) |
| `$10` | APT | ADDR (23–0), BIT (26–24) | The mask A, a 1 bpp image (MASK = 1): its first byte. BIT (ABIT): the first pixel's bit, 0–7 |
| `$14` | STRIDE | ABSTRIDE (31–16), CDSTRIDE (15–0), signed | Bytes from one row's start to the next: of A and B (shared), and of C and D |
| `$18` | VALUE | 31–0 | B's constant when BKIND = VALUE (a fill), and the key colour for MASK = 2 |
| `$1C` | NEXT | 23–0 | The next descriptor; 0 = the last job |
| `$20` | CHDESC | 23–0 | The descriptor START loads |
| `$24` | CHCTRL | START (0), RUN (1), STOP (2), PAUSE (3), CPUSHARE (5–4) | Control |
| `$28` | CHSTAT | BUSY (0), DONE (1), ERR (2), PAUSED (3) | Status; DONE and ERR are sticky, write 1 to clear |
| `$2C` | CHERR | 23–0 | The address that caused an error |

Channel n is at `DMXn` = `$300` + n × `$40`. Bits not listed are reserved: write 0.

**CTRL:**

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 BLIT, 1 ADD; 2–7 are an error |
| 4 | SAT | ADD: saturate instead of wrapping |
| 5 | SIGNED | ADD: pixels are two's complement |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards (see "Overlapping Copies") |
| 11 | HIGH | May take some of the CPU's memory cycles |
| 12 | IRQ | Interrupt when this job is done |
| 14–13 | BKIND | Where B comes from: 0 memory, 1 port, 2 reserved (an error), 3 VALUE |
| 16–15 | DKIND | Where D goes: 0 memory, 1 port; 2 and 3 are an error |
| 18–17 | MASK | Where A comes from: 0 none (every pixel 1), 1 the 1 bpp image at APT, 2 a compare of B with the key colour in VALUE, 3 an error |
| 31–24 | MINTERM | BLIT's logic function of A, B and C |

---

## The Operations

There are two: **BLIT**, which does copies, fills, transparent drawing and logic, and **ADD**.

### BLIT: minterms

As on the Amiga, BLIT works out each pixel of the destination D from three inputs, bit by bit:

- **A, the mask.** One bit per pixel, widened to all of the pixel's bits (see "Masks" below). With no mask, A is 1 everywhere.
- **B, the image.** Read from BPT, or the constant VALUE when BKIND = VALUE.
- **C, the background:** the destination's old contents, read from DPT.

**MINTERM** says what D is for each of the eight ways A, B and C can be set: each bit of D is MINTERM's bit number A × 4 + B × 2 + C. This is the Amiga's numbering (LF7–LF0), so Amiga minterms work unchanged.

| MINTERM | D = | Use |
|---------|-----|-----|
| `$CC` | B | Copy; with BKIND = VALUE, fill |
| `$CA` | A ? B : C | Cookie cut: draw B where the mask is 1, leave the background where it is 0 |
| `$EE` | B OR C | Set bits |
| `$88` | B AND C | Keep only the bits B has |
| `$66` | B XOR C | Draw and undraw with the same job |
| `$22` | C AND NOT B | Clear where B is set |
| `$55` | NOT C | Invert an area |
| `$00`, `$FF` | 0, all ones | Clear or set an area |
| `$0A` | A ? 0 : C | Clear through the mask (a shape's hole) |

**Working out a minterm.** Give A the value `$F0`, B `$CC` and C `$AA`, and work out the expression you want with them, a byte at a time; the result is the minterm. For example:

- B OR C = `$CC` OR `$AA` = `$EE`;
- C AND NOT B = `$AA` AND `$33` = `$22`;
- A ? B : C = (A AND B) OR (NOT A AND C) = (`$F0` AND `$CC`) OR (`$0F` AND `$AA`) = `$C0` OR `$0A` = `$CA`.

vasm can do the sum for you: `((($F0&$CC)|(~$F0&$AA))&$FF)<<DMX_CTRL_MINTERM_B`.

### Masks

MASK says where A comes from:

| MASK | A |
|------|---|
| 0 | None: A is 1 for every pixel |
| 1 | A 1 bpp image at APT, one bit per pixel, the first pixel in the top bit of each byte; ABIT picks the first pixel's bit |
| 2 | A compare: 1 where B's pixel differs from the **key colour** (VALUE's low BPP bits), 0 where it matches |
| 3 | An error |

The mask image shares B's stride (ABSTRIDE). At 2, 4 and 8 bpp a 1 bpp mask row is shorter than B's row, so each mask row is padded out to B's stride. For a sheet of 8 bpp sprites, keep the masks in a sheet of their own with the same row length, or use a compare mask, which needs no memory at all.

**Transparent copies with a colour key.** This is how you draw an object with a transparent background into a chunky screen: draw the object's background in the key colour (usually 0), and blit it with MASK = 2 and the cookie cut minterm, `$CA`. Where the object's pixel is the key colour, A is 0, and the background stays.

```asm
KEY8        equ     ($CA<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)|(DMX_MASK_KEY<<DMX_CTRL_MASK_B)   ; A ? B : C, 8 bpp
        move.l  #KEY8,DMX_CTRL(a0)              ; A from comparing B with the key
        move.l  #0,DMX_VALUE(a0)                ; colour 0 is transparent
```

### Reads are only made when needed

- A is read only with MASK = 1. A compare mask costs no memory cycles.
- B is read unless BKIND = VALUE. For a minterm that does not use B (such as `$55`, NOT C), set BKIND = VALUE, so B is not read.
- C is read when D depends on it, and for bytes a job covers only in part at 1, 2 and 4 bpp.
- **Where A is 0 and the minterm leaves C alone** (its low four bits are `$A`, as in the cookie cut), D keeps its old pixel: at 8 bpp that byte is not written, and C is not read for it. So at 8 bpp a cookie cut with a compare mask is as fast as a copy.

At 1, 2 and 4 bpp several pixels share a byte, and the engine reads the destination to keep the pixels it does not change.

### Fills: the value

With BKIND = VALUE, B is a constant. At 8 bpp it repeats all four bytes of VALUE by address (the byte at an address ending in 0, 4, 8 or C gets VALUE's top byte), so a fill of whole long words writes VALUE exactly, and a fill with all four bytes the same fills single bytes; at 1, 2 and 4 bpp every pixel gets VALUE's low bits.

```asm
        move.l  #$00000000,DMX_VALUE(a0)        ; 8 bpp: colour 0
        move.l  #$12121212,DMX_VALUE(a0)        ; 8 bpp: colour $12 at any address
        move.l  #3,DMX_VALUE(a0)                ; 2 bpp: colour 3
```

### Example 6-2: Draw text in one colour through a 1 bpp mask

A 1 bpp image can be the mask while B is a constant colour. With MASK = 1, BKIND = VALUE and the minterm `$CA`, the job draws VALUE's colour wherever the mask has a 1 and leaves the screen alone elsewhere. This draws the characters of a 1 bpp font, or any shape, in one colour, at any colour depth. At 8 bpp the pixels outside the shape are neither read nor written.

```asm
; Example 6-2: draw character d0 at (d1, d2) in colour 7, on the
; 320-byte-wide 8 bpp screen of Example 6-1. The font is 8 x 8: 8 bytes
; a character, one byte a row, the leftmost pixel in the top bit.
FONT        equ     $150000
TEXT8       equ     ($CA<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)|(DMX_KIND_VALUE<<DMX_CTRL_BKIND_B)|(DMX_MASK_IMAGE<<DMX_CTRL_MASK_B)

drawchar:   lea     DMX3(a4),a0
.busy:      btst    #DMX_CHSTAT_BUSY_B,DMX_CHSTAT+3(a0)
            bne.s   .busy                       ; the last character is still being drawn
            and.l   #$FF,d0
            lsl.l   #3,d0                       ; 8 bytes a character
            add.l   #FONT,d0
            move.l  d0,DMX_APT(a0)              ; A: the character's mask
            mulu    #ROW,d2                     ; y x 320
            and.l   #$FFFF,d1
            add.l   d1,d2
            add.l   #SCREEN,d2
            move.l  d2,DMX_DPT(a0)              ; where it goes
            move.l  #TEXT8,DMX_CTRL(a0)
            move.l  #(8<<16)|8,DMX_SIZE(a0)     ; 8 rows of 8
            move.l  #(1<<16)|ROW,DMX_STRIDE(a0) ; mask rows 1 byte apart, screen rows 320
            move.l  #$07070707,DMX_VALUE(a0)    ; B: colour 7
            move.l  #0,DMX_NEXT(a0)
            move.l  #RUNIT,DMX_CHCTRL(a0)
            rts
```

The CPU returns as soon as the job has started; the next call waits only if the last character is not finished. For a shadow, draw the same character first in a dark colour, a pixel down and right. With the minterm `$0A` instead, the same job clears the shape to colour 0 (a hole); with `$5A` (A ? NOT C : C) it inverts the pixels under the shape.

### Logic

Any other minterm combines the image and the background bit by bit, as in the table above. With BKIND = VALUE, B is a constant: with VALUE all ones, `$66` (B XOR C) inverts an area, as `$55` does. Minterms that use C read every destination word, so they take 3 memory cycles per 2 bytes instead of 2.

### ADD: shading and effects

**ADD** (OP = 1) adds each pixel of B to its destination pixel: D = C + B, at the job's colour depth. Carries never spill from one pixel into the next. MINTERM is ignored.

- **SAT** = 0: the result wraps round, so 250 + 10 = 4 at 8 bpp.
- **SAT** = 1: the result sticks at the limit instead. Unsigned (SIGNED = 0): 250 + 10 = 255. Signed (**SIGNED** = 1): pixels are two's complement, −128 to +127 at 8 bpp.
- B can be memory or VALUE (repeated by address, as for a fill).
- The mask works as for BLIT: where A is 0, D keeps C. So a 1 bpp mask can brighten just a shape, such as a torch's circle of light.

```asm
ADD8        equ     DMX_OP_ADD|(3<<DMX_CTRL_BPP_B)|(DMX_KIND_VALUE<<DMX_CTRL_BKIND_B)   ; ADD a constant, 8 bpp
        move.l  #ADD8|DMX_CTRL_SAT_M,DMX_CTRL(a0)       ; unsigned, saturating
        move.l  #$10101010,DMX_VALUE(a0)                ; + 16
```

With palettes laid out as ramps (colour 0 dark to colour 15 bright, and so on), adding a constant brightens an area, subtracting (adding the two's complement, with wrap) darkens it, and adding a light map image lights a scene. Adding 16 moves an area into the next 16-colour palette block. Signed saturating ADD at 8 bpp mixes signed 8-bit sound samples.

ADD reads every destination word, so it takes 3 memory cycles per 2 bytes instead of 2.

### The old operations

Earlier versions of the engine had four operations of their own. Each is now a BLIT:

| Old job | CTRL | MINTERM |
|---------|------|---------|
| COPY | BPP | `$CC` |
| FILL | BPP, BKIND = VALUE | `$CC` |
| KEYCOPY (key in VALUE) | BPP, MASK = 2 | `$CA` |
| LOGIC with FN (bit source × 2 + destination) | BPP | FN's 4 bits twice: FN × `$11` |
| LOGIC with VALUE as the source | BPP, BKIND = VALUE | FN × `$11` |

---

## Pixel Depths and Positions

A job's pixels are 1, 2, 4 or 8 bits (BPP), packed as the chunky layers pack them: the first pixel of a byte in its top bits. WIDTH counts pixels.

At 8 bpp every pixel is a byte, and an address says where it is. Below 8 bpp an address picks a byte, and the BIT field of BPT and DPT (**BBIT** and **DBIT**) picks the pixel within it, counting from the top bits: at 1 bpp, 0–7; at 2 bpp, 0–3; at 4 bpp, 0–1. So the pixel at x in a 4 bpp row starting at ROW is at address ROW + x ÷ 2, pixel x mod 2. The mask is always 1 bpp, so APT's **ABIT** is 0–7 at any depth; at 8 bpp BBIT and DBIT are 0.

```asm
        ; a 4 bpp job starting at pixel x = 37 of a row at ROWADDR
        move.l  #((37&1)<<DMX_DPT_BIT_B)|(ROWADDR+37/2),DMX_DPT(a0)
```

A, B and D can start at different pixels within their bytes: the engine shifts the data to line them up, as the Amiga's barrel shifter does. You never set edge masks: the engine works out which pixels of each row's first and last bytes belong to the job, and leaves the others as they were.

---

## Rectangles, Strides and Clipping

A job is HEIGHT rows of WIDTH pixels. Each row starts a stride after the last: ABSTRIDE for the mask and the image, CDSTRIDE for the destination, so a frame can be copied from a sheet of any width into a screen of any other width.

A one-row job is a plain copy or fill of up to 65,535 bytes. For a longer memory copy, use a 2D job with equal widths and strides (for example WIDTH and both strides 16 KB, and HEIGHT the number of 16 KB blocks), or a chain. A longer port transfer is a chain.

| Stride | Effect |
|--------|--------|
| The row's bytes | The rows one after another |
| Larger | A rectangle inside a wider picture |
| 0 (ABSTRIDE) | The same image row on every destination row: stripes, or a pattern down a column |
| Negative | Rows run up the screen: an image drawn upside down |

**Clipping** is done by trimming the job before you start it; the strides stay the same, so the trimmed rows still line up:

- **Left:** skip k pixels: move BPT and DPT on by k pixels (and BBIT, DBIT below 8 bpp), APT on by k bits (and ABIT), and take k from WIDTH.
- **Right:** take the pixels past the edge from WIDTH.
- **Top:** skip r rows: add r × ABSTRIDE to APT and BPT and r × CDSTRIDE to DPT, and take r from HEIGHT.
- **Bottom:** take the rows past the edge from HEIGHT.

If WIDTH or HEIGHT comes to 0 or less, the object is off the screen: skip the job (a job of zero width or height does nothing, and a chain carries on past it).

---

## Overlapping Copies

When the source and destination overlap, as when scrolling part of the screen, the order matters. A job normally runs forwards: rows from the first, pixels from the left. That is right when the destination is **before** the source in memory (moving up or left). When the destination is **after** the source (moving down or right), set **DESC**: the job runs from the last pixel of the last row back to the first. BPT and DPT still give the first pixel of the first row either way.

```asm
        ; scroll a 200-row band of a 320-byte-wide screen down by 8 rows
        move.l  #COPY8|DMX_CTRL_DESC_M,DMX_CTRL(a0)
        move.l  #SCREEN+20*320,DMX_BPT(a0)
        move.l  #SCREEN+28*320,DMX_DPT(a0)
        move.l  #(200<<16)|320,DMX_SIZE(a0)
        move.l  #(320<<16)|320,DMX_STRIDE(a0)
```

---

## Drawing into Planar Layers

A planar layer is several 1 bpp pictures, one per plane (Playfield Hardware chapter). The engine draws into it at BPP = 0, a plane at a time, positioned to the pixel.

- **Separate planes:** one job per plane, chained (see "Chains of Jobs"), each moving BPT and DPT on by a plane.
- **Interleaved planes** (each plane's row next to the next plane's): one job does all the planes, if the source is interleaved the same way. HEIGHT = rows × planes, and each stride = one plane row's bytes.

**Transparent objects (the cookie cut).** As on the Amiga, keep a 1 bpp **mask** of the object, 1 wherever it has a pixel. For each plane, one BLIT with MINTERM `$CA`, MASK = 1, APT the mask and BPT the object's plane: the object's bits where the mask is 1, the background's elsewhere. The same mask serves every plane.

```asm
; cookie cut a 32 x 32 object into a 4-plane layer at (X, Y); 40 bytes a plane row
CUT1        equ     ($CA<<DMX_CTRL_MINTERM_B)|(DMX_MASK_IMAGE<<DMX_CTRL_MASK_B)      ; A ? B : C, 1 bpp
            lea     DMX3(a4),a0
            move.l  #CUT1,DMX_CTRL(a0)
            move.l  #OBJMASK,DMX_APT(a0)                ; the object's mask, 4 bytes a row
            move.l  #(32<<16)|32,DMX_SIZE(a0)
            move.l  #(4<<16)|40,DMX_STRIDE(a0)          ; object rows 4 bytes, screen rows 40
            move.l  #0,DMX_NEXT(a0)
            move.l  #OBJECT,d0                          ; the object's plane 0
            move.l  #((X&7)<<DMX_DPT_BIT_B)|(PLANES+Y*40+X/8),d1   ; the screen's plane 0
            moveq   #4-1,d2
.plane:     move.l  d0,DMX_BPT(a0)
            move.l  d1,DMX_DPT(a0)
            move.l  #RUNIT,DMX_CHCTRL(a0)
.wait:      btst    #DMX_CHSTAT_BUSY_B,DMX_CHSTAT+3(a0)
            bne.s   .wait
            add.l   #32*4,d0                            ; the object's next plane
            add.l   #PLANESIZE,d1                       ; the screen's next plane
            dbra    d2,.plane
```

A compare mask (MASK = 2) is for chunky layers only: in a planar layer a colour is spread over the planes, so no single plane knows which pixels are transparent.

---

## Chains of Jobs

A job's NEXT points at a **descriptor**: eight long words in memory, laid out like the job registers. When a job is done, the channel loads the descriptor at NEXT into its job registers and runs it, and so on until a job's NEXT is 0. The whole chain runs without the CPU.

Descriptors can be in Chip RAM, long-word aligned, or in the **descriptor RAM**: 2 KB at `CUSTOM+DESCRAM` (`$E06000`), room for 64. Loading a descriptor from Chip RAM takes 16 memory cycles; from the descriptor RAM it takes none, which suits short, frequent jobs.

There are two ways to start a chain:

- **START** loads the descriptor at CHDESC and runs it;
- **RUN** runs the job already in the job registers, whose NEXT points at the rest.

### Example 6-3: Draw three objects with one chain

```asm
; Example 6-3: three colour-keyed blits, chained in the descriptor RAM, started with START.
; Each object is 32 x 32 at 8 bpp, from a 256-wide sheet to a 320-wide screen.
KEY8        equ     ($CA<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)|(DMX_MASK_KEY<<DMX_CTRL_MASK_B)
DLIST       equ     CUSTOM+DESCRAM
            lea     chain(pc),a1
            lea     DLIST,a2
            moveq   #3*8-1,d0
.copy:      move.l  (a1)+,(a2)+                 ; the descriptors into the descriptor RAM
            dbra    d0,.copy
            move.l  #DLIST,DMX3+DMX_CHDESC(a4)
            move.l  #DMX_CHCTRL_START_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX3+DMX_CHCTRL(a4)
            rts

;           CTRL            BPT          DPT                   SIZE         APT STRIDE       VALUE NEXT
chain:      dc.l    KEY8,   SHEET+0,     SCREEN+40*320+10,     (32<<16)|32, 0, (256<<16)|320, 0, DLIST+32
            dc.l    KEY8,   SHEET+32,    SCREEN+40*320+90,     (32<<16)|32, 0, (256<<16)|320, 0, DLIST+64
            dc.l    KEY8|DMX_CTRL_IRQ_M, SHEET+64, SCREEN+40*320+170, (32<<16)|32, 0, (256<<16)|320, 0, 0
```

The last job sets IRQ, so the channel interrupts when all three are drawn. CHDESC reads back the descriptor running, and the job registers the job being run.

---

## Starting Jobs from the Copper and from Timers

The copper writes the job registers and CHCTRL like any other registers, so it can set up and start a job at a beam position with a few MOVEs and no descriptor at all. Its WAIT with the **B** bit waits until every channel is idle, so a list can start a blit and later wait for it (Coprocessor Hardware chapter).

```asm
            ; in a copper list: fill a 64-pixel-wide bar on 16 rows, started at line 200
            CWAIT   VID_Y0+200,0
            CMOVEL  DMX2+DMX_CTRL,FILL8
            CMOVEL  DMX2+DMX_DPT,BAR
            CMOVEL  DMX2+DMX_SIZE,(16<<16)|64
            CMOVEL  DMX2+DMX_STRIDE,320
            CMOVEL  DMX2+DMX_VALUE,$07070707
            CMOVEL  DMX2+DMX_NEXT,0
            CMOVE   DMX2+DMX_CHCTRL+2,RUNIT
```

A **timer** can start a channel when it runs out: set its CTRL.DMA bit and CTRL.DMACH to the channel (Interrupts and Timers chapter). This works like writing START to the channel's CHCTRL, so point CHDESC at the chain first. A timer repeating at a steady rate can, for example, refill a buffer at the right moment without the CPU.

A channel already busy ignores a START or RUN, whoever sends it.

---

## Registers, Palettes and the ROM

A job's image and destination can be any of these:

| Addresses | What | Read | Write |
|-----------|------|------|-------|
| `$000000`–`$3FFFFF` | Chip RAM (2 MB boards: to `$1FFFFF`) | Yes | Yes |
| `$E00000`–`$E0FFFF` | The custom registers, the palettes and the descriptor RAM | Yes | Yes |
| `$F80000`–`$F87FFF` | The boot ROM | Yes | No |

Anything else, including the system area at `$F00000` (interrupts, timers, serial, SD card), stops the channel with an error, so a runaway job cannot upset interrupts or the console.

The custom block (registers, palettes, descriptor RAM) behaves as memory: any job can use it. Each word a job writes is a write of that register half, exactly as a CPU or copper write of it (the halves rule, Introduction chapter). So a copy (MINTERM `$CC`) of four long words from memory to `CUSTOM+L0+L_WINX` sets layer 0's window and scroll in one job, and a copy into another channel's CHCTRL starts that channel: one chain can start others. A copy from `CUSTOM+BEAMPOS` to memory, repeated by the copper, keeps a log of beam positions (each half read as it is at that moment). Reading a register never changes it, so a DMA read is always safe.

Palette entries keep their hold: the engine's write of an entry's high half waits for its write of the low half. So a job that loads colours must run forwards (DESC clear) and cover whole entries.

```asm
        ; load 256 colours into PALETTE1 from a table in Chip RAM
        move.l  #COPY8,DMX_CTRL(a0)
        move.l  #COLOURS,DMX_BPT(a0)
        move.l  #CUSTOM+PALETTE1,DMX_DPT(a0)
        move.l  #(1<<16)|(256*4),DMX_SIZE(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)
```

---

## Moving Data to and from the USB Serial Link

A job can read from or write to a **port** instead of memory: BKIND or DKIND = 1, with the port number in BPT or DPT.

| Port | Device |
|------|--------|
| 0 | The SD card: as a source, the bytes SDCOUNT asks for; as a destination, bytes to send to the card (SD Card and Keyboard chapter) |
| 1 | The USB serial link: as a source, bytes received; as a destination, bytes to send |

A port job is a plain copy of bytes: BLIT with MINTERM `$CC` and MASK = 0, 8 bpp, one row, forwards, B or D a port but not both, and its memory side not registers. So it is at most 65,535 bytes; send more with a chain. The engine waits for the device: when no byte has come, or there is no room to send, the channel lets the others have their turn and tries again. The serial port must be on (SERCON.EN).

```asm
        ; send a 2 KB block to the PC
        move.l  #COPY8|(1<<DMX_CTRL_DKIND_B),DMX_CTRL(a0)
        move.l  #BLOCK,DMX_BPT(a0)
        move.l  #1,DMX_DPT(a0)                  ; port 1
        move.l  #(1<<16)|2048,DMX_SIZE(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)

        ; receive 512 bytes from the PC into BUF
        move.l  #COPY8|(1<<DMX_CTRL_BKIND_B),DMX_CTRL(a0)
        move.l  #1,DMX_BPT(a0)                  ; port 1
        move.l  #BUF,DMX_DPT(a0)
        move.l  #(1<<16)|512,DMX_SIZE(a0)
        move.l  #RUNIT,DMX_CHCTRL(a0)
```

While a channel moves data through the link, the CPU should not read or write SERDATA itself.

---

## Status, Interrupts and Errors

**CHSTAT** shows each channel's state: **BUSY** while a chain runs (or is paused), **DONE** when a chain reaches its end or is stopped, **ERR** when a job stopped with an error, and **PAUSED** while held. DONE and ERR stay set until you write 1 to them.

**Interrupts.** Each channel is its own source in the interrupt controller, DMA0–DMA3 (sources 4–7, default level 4). A channel's bit in **DMXINT** (`$3F0`) is set when a job with CTRL.IRQ finishes, or when the channel stops with an error; it requests the interrupt while its bit in **DMXINTEN** (`$3F4`) is set too. Clear DMXINT by writing 1 to the bit.

```asm
dmx3_int:   move.l  #1<<3,DMXINT(a4)            ; channel 3's interrupt: clear it
            ; ... the chain is done, or check DMX3+DMX_CHSTAT for ERR
            rte
```

**STOP** (CHCTRL bit 2) ends a running chain after its current group of words; DONE is set. **PAUSE** (bit 3) holds a channel while set, and lets it carry on when cleared: write CHCTRL again with PAUSE clear (and no START or RUN).

**Errors** stop only the channel concerned: ERR is set, **CHERR** holds the address that caused it, CHDESC the descriptor, and the channel's DMXINT bit is set. The errors are:

- an address outside the areas above, or a write to the ROM;
- OP 2–7 (only BLIT and ADD exist in this version);
- MASK = 3, BKIND = 2, or DKIND = 2 or 3;
- kinds that do not go together: a port job that is not a plain copy (MINTERM `$CC`, MASK = 0, 8 bpp, one row, forwards), B and D both ports, or a port job whose memory side is registers.

---

## Priority and Speed

The engine uses memory cycles the display, sprites, audio and the copper do not need, and cycle 0 when the CPU is not using it, so **a normal job never slows the CPU**. Its four channels take turns, a group of up to 8 words each.

A job with **HIGH** (CTRL bit 11) may also take the CPU's own cycle 0, but leaves the CPU a share of them: 1 in 2, 1 in 4 (the default) or 1 in 8 of those it asks for, set by the channel's **CPUSHARE** (CHCTRL bits 5–4: 0, 1, 2). Each cycle taken makes the CPU wait one slot (100 ns). Use HIGH when the CPU would only be waiting for the job anyway.

How fast a job runs depends on the screen and on the CPU. Some figures for a 576p line (32 µs), worked out from the slot rules:

| Situation | Copy | Fill |
|-----------|------|------|
| CPU busy, one full-screen 8 bpp chunky layer | 33 MB/s | 67 MB/s |
| CPU busy, the layers using the whole display budget | 25 MB/s | 50 MB/s |
| CPU idle, one full-screen 8 bpp chunky layer | 38 MB/s | 77 MB/s |
| In the vertical blank, CPU busy | 45 MB/s | 90 MB/s |

Jobs that read the destination (a minterm that uses C, and ADD) run at about two thirds of the copy speed. At 8 bpp a cookie cut with a compare mask runs as fast as a copy. Jobs at 1, 2 or 4 bpp that are not byte-aligned read the destination at each row's edges. Clearing a full 720 × 576 8 bpp picture (405 KB) takes about 6–8 ms, well within a 50 Hz frame.

---

## Summary of DMA Engine Registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| CTRL | DMXn + `$00` | RW | OP (2–0), SAT (4), SIGNED (5), BPP (9–8), DESC (10), HIGH (11), IRQ (12), BKIND (14–13), DKIND (16–15), MASK (18–17), MINTERM (31–24) |
| BPT | DMXn + `$04` | RW | Image B: address or port (23–0), BBIT (26–24) |
| DPT | DMXn + `$08` | RW | Destination D (and C): address or port (23–0), DBIT (26–24) |
| SIZE | DMXn + `$0C` | RW | WIDTH (15–0), HEIGHT (31–16) |
| APT | DMXn + `$10` | RW | Mask A: address (23–0), ABIT (26–24) |
| STRIDE | DMXn + `$14` | RW | ABSTRIDE (31–16), CDSTRIDE (15–0), signed |
| VALUE | DMXn + `$18` | RW | Constant B, key colour |
| NEXT | DMXn + `$1C` | RW | Next descriptor (23–0), 0 = none |
| CHDESC | DMXn + `$20` | RW | Descriptor START loads (23–0) |
| CHCTRL | DMXn + `$24` | RW | START (0), RUN (1), STOP (2), PAUSE (3), CPUSHARE (5–4) |
| CHSTAT | DMXn + `$28` | RW1C | BUSY (0), DONE (1), ERR (2), PAUSED (3) |
| CHERR | DMXn + `$2C` | R | Address of the error (23–0) |
| DMXINT | `$3F0` | W1C | CH (3–0): interrupt pending |
| DMXINTEN | `$3F4` | RW | CH (3–0): interrupt enables |
| DESCRAM | `$6000`–`$67FF` | RW | The descriptor RAM, 2 KB |

DMXn = `$300` + n × `$40`: DMX0 `$300`, DMX1 `$340`, DMX2 `$380`, DMX3 `$3C0`. The job registers ignore writes while their channel is BUSY.

Related bits elsewhere:

| Register | Bit | Function |
|----------|-----|----------|
| DMACON | BLTEN (6), DMAEN (9) | The engine may use memory cycles |
| INTENA | DMA0–DMA3 (sources 4–7) | The channels' interrupts |
| TMRn CTRL | DMA (5), DMACH (7–6) | A timer starts a channel when it runs out |

Constants in `hw.inc`: `DMX0`–`DMX3`, `DMX_CTRL` … `DMX_CHERR` (add to DMXn), the CTRL fields (`DMX_CTRL_OP_B`, `DMX_CTRL_SAT_M`, `DMX_CTRL_SIGNED_M`, `DMX_CTRL_BPP_B`, `DMX_CTRL_DESC_M`, `DMX_CTRL_HIGH_M`, `DMX_CTRL_IRQ_M`, `DMX_CTRL_BKIND_B`, `DMX_CTRL_DKIND_B`, `DMX_CTRL_MASK_B`, `DMX_CTRL_MINTERM_B`), the pixel positions `DMX_BPT_BIT_B`, `DMX_DPT_BIT_B` and `DMX_APT_BIT_B`, `DMX_SIZE_HEIGHT_B`, `DMX_STRIDE_ABSTRIDE_B`, `DMX_CHCTRL_START_M` and the other CHCTRL and CHSTAT bits, `DMX_OP_BLIT` and `DMX_OP_ADD`, `DMX_KIND_MEM`, `DMX_KIND_PORT` and `DMX_KIND_VALUE`, `DMXINT`, `DMXINTEN`, `DESCRAM`, and the descriptor layout `DMXDESC_CTRL` … `DMXDESC_NEXT`.
