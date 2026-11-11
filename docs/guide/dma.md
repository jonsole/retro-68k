# Chapter 6: Blitter Hardware

## Introduction

The **blitter** moves rectangles of pixels so the 68000 does not have to. It copies and fills memory and draws graphics: you describe a job, start it, and the CPU carries on with other work while the blitter does it, using memory cycles nobody else needs.

The blitter can:

- copy or fill a block of memory, at about 17 MB/s copying and 25 MB/s filling, against about 4 MB/s for the 68000;
- copy or fill a rectangle: part of a sprite sheet into a screen, a window of a picture, a box of colour;
- draw objects with transparent parts, a pixel at a time at any colour depth, through a colour key or a 1 bpp mask;
- draw text and shapes in one colour through a 1 bpp mask;
- combine a mask, a source and the destination with any logic function (the Amiga's minterms);
- run a chain of jobs from memory with no help from the CPU;
- be started by the copper at a beam position.

This chapter covers:

- forming a job, step by step, and a first example;
- the job registers and descriptors;
- minterms, masks and fills;
- pixel depths, pixel positions and the automatic edge masks;
- rectangles, strides and clipping;
- overlapping copies;
- drawing into planar layers, including the Amiga's cookie cut;
- chains of jobs;
- starting jobs from the copper;
- status, interrupts and errors;
- priority and speed.

You should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, and the Playfield Hardware chapter, since most blits draw into a layer.

**Note:** The blitter is built in the FPGA design (`fpga/rtl/dmx.v`, on retro-hw's `blitter.v`) and tested in simulation (`make -C sim dtest`, which checks random jobs byte for byte against a model), but not yet on the board.

**If you used the DMA engine** (before November 2026): it had four channels, ADD jobs, port jobs for the serial link and the SD card, jobs that wrote registers and palettes, a descriptor RAM, HIGH jobs and timer starts. All of those are gone, and the registers have new names and some new bits. The blitter is one job at a time, in Chip RAM only. The CPU now moves SD card and serial bytes itself, and the copper or the CPU loads registers and palettes. Lines and triangles are coming as a separate unit.

### Comparison with the Amiga

| Feature | Amiga blitter (OCS/ECS) | retro68k blitter |
|---------|-------------------------|------------------|
| Jobs at once | 1 | 1 |
| Starting a job | Write the registers, write BLTSIZE; wait for the blitter before the next | The same (the job registers, then RUN), or a chain of jobs in memory that runs alone |
| Pixels | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at 1, 2, 4 or 8 bits, positioned to the pixel; planar layers a plane at a time, as on the Amiga |
| Transparent drawing | A mask plane and the minterms (cookie cut) | The same minterms and a 1 bpp mask, at any colour depth; or, in chunky layers, a colour-key compare that needs no mask in memory |
| Logic | Any function of three sources (minterms) | The same: the minterm, in the Amiga's numbering, of the mask A, the source B and the destination C |
| Edge masks | BLTAFWM, BLTALWM | Worked out by the hardware |
| Overlapping copies | Descending mode | RTL (each row right to left), and negative strides (rows bottom-up) |
| Line drawing, area fill | Yes | Not in the blitter: a separate unit, to come |
| Priority | BLTPRI ("blitter nasty") | The slot plan (MEMSLOT0–4) |

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax, starting with `include "hw.inc"`. **a4 holds CUSTOM** (`$E00000`).
- The blitter uses **CPU addresses**, in Chip RAM only.
- The examples use these constants for BLTCTRL (section "The Job Registers"):

```asm
COPY8       equ     ($CC<<BLTCTRL_MINTERM_B)|(3<<BLTCTRL_BPP_B)     ; D = B, 8 bits per pixel
FILL8       equ     COPY8|BLTCTRL_BCONST_M                          ; the same, B is VALUE: a fill
```

---

## Forming a Job

A job is eight long words: what to do, where from, where to, how big, and what comes next. You write them into the **job registers** and start the blitter. This section clears part of a screen and copies an image onto it, from the CPU.

### Step 1: Turn the blitter on

The blitter uses memory cycles only while **DMACON.BLTEN** and **DMACON.DMAEN** are both set:

```asm
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
```

### Step 2: Describe the job

The job registers are BLTCTRL, BLTBPT, BLTDPT, BLTSIZE, BLTAPT, BLTSTRIDE, BLTVALUE and BLTNEXT, in that order from `$300`. To fill 64 bytes at `$080000` with zeros:

```asm
        move.l  #FILL8,BLTCTRL(a4)              ; D = B, B is VALUE, 8 bpp
        move.l  #$080000,BLTDPT(a4)             ; where
        move.l  #(1<<16)|64,BLTSIZE(a4)         ; 1 row of 64 bytes
        move.l  #0,BLTVALUE(a4)                 ; the value
        move.l  #0,BLTNEXT(a4)                  ; no more jobs after this one
```

BLTBPT, BLTAPT and BLTSTRIDE are not used by a one-row fill.

### Step 3: Start it

```asm
        move.l  #BLTCMD_RUN_M,BLTCMD(a4)        ; run the job in the registers
```

RUN starts the job already in the registers. The blitter is **BUSY** (BLTSTAT bit 0) until the job, and any jobs chained after it, are done; then **DMXINT.BLT** is set.

### Step 4: Wait, or do something else

```asm
.wait:  btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
        bne.s   .wait
```

Better, carry on with other work and take the blitter's interrupt (see "Status, Interrupts and Errors"). While the blitter is busy the job registers ignore writes, so you cannot spoil a running job by accident; but you cannot set up the next one either. Put jobs that follow each other in a chain.

### Example 6-1: Clear a box and draw an image into it

A 320 × 200 chunky 8 bpp screen at `SCREEN` (rows of 320 bytes). Clear a 64 × 48 box at (100, 50), then copy a 32 × 32 image from a sprite sheet (rows of 256 bytes) into its middle.

```asm
; Example 6-1: clear a box, then copy an image into it (8 bpp chunky)
SCREEN      equ     $100000
SHEET       equ     $140000             ; a 256-pixel-wide sheet
ROW         equ     320

            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)

            ; the box: 64 x 48 at (100, 50), filled with colour 0
            move.l  #FILL8,BLTCTRL(a4)
            move.l  #SCREEN+50*ROW+100,BLTDPT(a4)
            move.l  #(48<<16)|64,BLTSIZE(a4)    ; 48 rows of 64
            move.l  #ROW,BLTSTRIDE(a4)          ; destination stride (low half)
            move.l  #0,BLTVALUE(a4)
            move.l  #0,BLTNEXT(a4)
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            bsr     bltwait

            ; the image: 32 x 32 from the sheet's frame at (64, 0), to (116, 58)
            move.l  #COPY8,BLTCTRL(a4)
            move.l  #SHEET+64,BLTBPT(a4)
            move.l  #SCREEN+58*ROW+116,BLTDPT(a4)
            move.l  #(32<<16)|32,BLTSIZE(a4)
            move.l  #(256<<16)|ROW,BLTSTRIDE(a4)    ; source stride, destination stride
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            bsr     bltwait
            rts

bltwait:    btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            bne.s   bltwait
            rts
```

The registers keep their values, so the second job only writes what changes.

---

## The Job Registers

| Offset | Name | Fields | Meaning |
|--------|------|--------|---------|
| `$300` | BLTCTRL | KEY 7–0, BPP 9–8, RTL 10, IRQ 12, BCONST 13, MASK 18–17, MINTERM 31–24 | What to do (below) |
| `$304` | BLTBPT | ADDR 23–0, BIT 26–24 | The source B: the first row's first pixel |
| `$308` | BLTDPT | ADDR 23–0, BIT 26–24 | The destination D: the first row's first pixel |
| `$30C` | BLTSIZE | WIDTH 15–0, HEIGHT 31–16 | Pixels per row, and rows |
| `$310` | BLTAPT | ADDR 23–0, BIT 26–24 | The 1 bpp mask image A (MASK = 1): the first row's first bit |
| `$314` | BLTSTRIDE | BSTRIDE 31–16, DSTRIDE 15–0 | Bytes from one row to the next, signed, for B and for D |
| `$318` | BLTVALUE | ASTRIDE 31–16, VALUE 15–0 | The mask's stride, signed; and the constant for a fill |
| `$31C` | BLTNEXT | ADDR 23–0 | The next job's descriptor, or 0 |

| BLTCTRL field | Meaning |
|---------------|---------|
| MINTERM | The logic function of A, B and C (next section). `$CC` copies B |
| MASK | Where the mask A comes from: 0 none, 1 the image at BLTAPT (`BLT_MASK_IMAGE`), 2 the source compared with KEY (`BLT_MASK_KEY`) |
| KEY | The transparent colour for MASK = 2 |
| BCONST | The source is VALUE, not memory: a fill |
| BPP | 0, 1, 2, 3 for 1, 2, 4, 8 bits per pixel |
| RTL | Work each row right to left (see "Overlapping Copies") |
| IRQ | Set DMXINT.BLT when this job ends, even in the middle of a chain |

Write the other bits as 0. A **descriptor** is the same eight long words in Chip RAM, at any even address: START loads it into the job registers and runs it (see "Chains of Jobs").

---

## Minterms, Masks and Fills

### Minterms

For every pixel the blitter has three inputs:

- **A**, the mask: one bit for the whole pixel;
- **B**, the source pixel;
- **C**, the destination's old pixel.

MINTERM says what D, the new pixel, is for each combination, bit by bit: bit number A × 4 + B × 2 + C of MINTERM is the result. This is the Amiga's minterm. To work one out, write the function with A = `$F0`, B = `$CC` and C = `$AA`: "B where A is set, else C" is (`$F0` AND `$CC`) OR (NOT `$F0` AND `$AA`) = `$CA`.

| MINTERM | D | Use |
|---------|---|-----|
| `$CC` | B | Copy; with BCONST, fill |
| `$CA` | A ? B : C | Cookie cut: the object where the mask is 1, the background elsewhere |
| `$EE` | B OR C | Set bits |
| `$88` | B AND C | Keep only the bits B has |
| `$66` | B XOR C | Draw, and undraw with the same job |
| `$22` | C AND NOT B | Clear where B is set |
| `$55` | NOT C | Invert an area |
| `$00`, `$FF` | 0, all ones | Clear or set an area |
| `$0A` | A ? 0 : C | Clear through the mask |

With no mask (MASK = 0) A is 1 everywhere.

### Masks

- **A colour key (MASK = 2).** A is 1 where the source pixel differs from KEY. With MINTERM `$CA` every source pixel is drawn except the key colour: transparent objects with nothing extra in memory. This is for chunky layers.
- **A mask image (MASK = 1).** A comes from a 1 bpp picture at BLTAPT, one bit a pixel, the first pixel in a byte's top bit, whatever the job's depth. The mask has its own stride, ASTRIDE: at 8 bpp a mask row is an eighth as long as a source row.

```asm
; a 32 x 32 object from a sheet, colour 0 transparent, to (X, Y) on an 8 bpp screen
KEYED       equ     ($CA<<BLTCTRL_MINTERM_B)|(BLT_MASK_KEY<<BLTCTRL_MASK_B)|(3<<BLTCTRL_BPP_B)   ; KEY = 0
            move.l  #KEYED,BLTCTRL(a4)
            move.l  #OBJECT,BLTBPT(a4)
            move.l  #SCREEN+Y*ROW+X,BLTDPT(a4)
            move.l  #(32<<16)|32,BLTSIZE(a4)
            move.l  #(256<<16)|ROW,BLTSTRIDE(a4)
            move.l  #0,BLTNEXT(a4)
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
```

### Fills: the value

With BCONST the source is **VALUE**, 16 bits: one memory word of pixels. For a plain colour, repeat the pixel to fill the word:

| Depth | Colour c | VALUE |
|-------|----------|-------|
| 8 bpp | 7 | `$0707` |
| 4 bpp | 5 | `$5555` |
| 2 bpp | 1 | `$5555` |
| 1 bpp | 1 | `$FFFF` |

Other values give patterns: `$AAAA` at 1 bpp is alternate pixels, `$0F00` at 8 bpp alternate bytes. VALUE lies over memory words (the two bytes at each even address), so a pattern lines up with memory, not with the rectangle's left edge: the same pattern in two overlapping fills joins up.

### Example 6-2: Draw text in one colour through a 1 bpp mask

A font of 8 × 8 characters, one byte a row, is a ready-made set of masks. Each character is a fill through its mask.

```asm
; Example 6-2: draw character d0 at pixel (d1, d2) in colour 7, on the
; 8 bpp screen of example 6-1. FONT: 8 bytes a character.
TEXT8       equ     ($CA<<BLTCTRL_MINTERM_B)|(BLT_MASK_IMAGE<<BLTCTRL_MASK_B)|BLTCTRL_BCONST_M|(3<<BLTCTRL_BPP_B)

putc:       bsr     bltwait                     ; the registers ignore writes while busy
            and.l   #$FF,d0
            lsl.l   #3,d0
            add.l   #FONT,d0
            move.l  d0,BLTAPT(a4)               ; the character's 8 mask rows, bit 0 first
            mulu    #ROW,d2
            add.l   d1,d2
            add.l   #SCREEN,d2
            move.l  d2,BLTDPT(a4)
            move.l  #TEXT8,BLTCTRL(a4)
            move.l  #(8<<16)|8,BLTSIZE(a4)
            move.l  #ROW,BLTSTRIDE(a4)          ; destination stride
            move.l  #(1<<16)|$0707,BLTVALUE(a4) ; mask stride 1 byte; colour 7
            move.l  #0,BLTNEXT(a4)
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            rts
```

### What a job costs

The blitter works a destination word (two bytes) at a time, and reads only what the minterm needs:

| Job | Memory cycles a word |
|-----|----------------------|
| Fill (`$CC`, BCONST) | 1: the write |
| Copy (`$CC`) | 2: read B, write |
| Cookie cut with a key (`$CA`, MASK = 2) | 3: read B, read C, write |
| Cookie cut with a mask image | 3, and a mask word for every 16 pixels |
| A minterm that uses C (`$66`, `$EE`, …) | One more than without |

A row that starts or ends part-way through a byte also reads its first or last word, to keep the pixels outside the job.

---

## Pixel Depths and Positions

A job's pixels are 1, 2, 4 or 8 bits (BPP), packed as the chunky layers pack them: the first pixel of a byte in its top bits. WIDTH counts pixels.

At 8 bpp every pixel is a byte, and an address says where it is. Below 8 bpp an address picks a byte, and the BIT field of BLTBPT and BLTDPT picks the pixel within it, counting from the top bits: at 1 bpp, 0–7; at 2 bpp, 0–3; at 4 bpp, 0–1. So the pixel at x in a 4 bpp row starting at ROWADDR is at address ROWADDR + x ÷ 2, pixel x mod 2. The mask is always 1 bpp, so BLTAPT's BIT is 0–7 at any depth.

```asm
        ; a 4 bpp job starting at pixel x = 37 of a row at ROWADDR
        move.l  #((37&1)<<BLTDPT_BIT_B)|(ROWADDR+37/2),BLTDPT(a4)
```

A, B and D can start at different pixels within their bytes: the blitter shifts the data to line them up, as the Amiga's barrel shifter does. You never set edge masks: the blitter works out which pixels of each row's first and last bytes belong to the job, and leaves the others as they were.

---

## Rectangles, Strides and Clipping

A job is HEIGHT rows of WIDTH pixels. Each row starts a stride after the last: ASTRIDE for the mask, BSTRIDE for the source, DSTRIDE for the destination, so a frame can be copied from a sheet of any width into a screen of any other width.

A one-row job is a plain copy or fill of up to 65,535 bytes. For a longer one, use a job with equal widths and strides (for example WIDTH and both strides 16 KB, and HEIGHT the number of 16 KB blocks), or a chain.

| Stride | Effect |
|--------|--------|
| The row's bytes | The rows one after another |
| Larger | A rectangle inside a wider picture |
| 0 (BSTRIDE) | The same source row on every destination row: stripes, or a pattern down a column |
| Negative | Rows run up the screen: with only one of BSTRIDE and DSTRIDE negative, an image drawn upside down |

**Clipping is yours to do.** The blitter writes exactly the rectangle it is given, with no clip window and no check against the size of the screen or of memory. Trim the job before you start it; the strides stay the same, so the trimmed rows still line up:

- **Left:** skip k pixels: move BLTBPT and BLTDPT on by k pixels (and their BIT fields below 8 bpp), BLTAPT on by k bits, and take k from WIDTH.
- **Right:** take the pixels past the edge from WIDTH.
- **Top:** skip r rows: add r × ASTRIDE to BLTAPT, r × BSTRIDE to BLTBPT and r × DSTRIDE to BLTDPT, and take r from HEIGHT.
- **Bottom:** take the rows past the edge from HEIGHT.

If WIDTH or HEIGHT comes to 0 or less, the object is off the screen: skip the job (a job of zero width or height does nothing, and a chain carries on past it).

---

## Overlapping Copies

When the source and destination overlap, as when scrolling part of the screen, the order matters: a pixel must be read before it is overwritten.

| The destination is | Do this |
|--------------------|---------|
| Above the source, or to its left | Nothing special |
| Below the source | Work the rows bottom-up: point BLTBPT and BLTDPT at the **last** row, and make both strides negative |
| To the right, in the same rows | Set **RTL**: point BLTBPT and BLTDPT at each row's **last** pixel (address and BIT); the blitter works leftwards from there |

```asm
        ; scroll a 200-row band of a 320-byte-wide screen down by 8 rows
        move.l  #COPY8,BLTCTRL(a4)
        move.l  #SCREEN+(20+199)*320,BLTBPT(a4)     ; the band's last row ...
        move.l  #SCREEN+(28+199)*320,BLTDPT(a4)
        move.l  #(200<<16)|320,BLTSIZE(a4)
        move.l  #((-320&$FFFF)<<16)|(-320&$FFFF),BLTSTRIDE(a4)   ; ... and upwards

        ; scroll one 320-pixel row right by 4 pixels
        move.l  #COPY8|BLTCTRL_RTL_M,BLTCTRL(a4)
        move.l  #LINE+315,BLTBPT(a4)                ; the last source pixel
        move.l  #LINE+319,BLTDPT(a4)                ; the last destination pixel
        move.l  #(1<<16)|316,BLTSIZE(a4)
```

With RTL a mask image's BLTAPT names the row's last mask bit in the same way.

---

## Drawing into Planar Layers

A planar layer is several 1 bpp pictures, one per plane (Playfield Hardware chapter). The blitter draws into it at BPP = 0, a plane at a time, positioned to the pixel.

- **Separate planes:** one job per plane, chained (see "Chains of Jobs"), each moving BLTBPT and BLTDPT on by a plane.
- **Interleaved planes** (each plane's row next to the next plane's): one job does all the planes, if the source is interleaved the same way. HEIGHT = rows × planes, and each stride = one plane row's bytes.

**Transparent objects (the cookie cut).** As on the Amiga, keep a 1 bpp **mask** of the object, 1 wherever it has a pixel. For each plane, one job with MINTERM `$CA`, MASK = 1, BLTAPT the mask and BLTBPT the object's plane: the object's bits where the mask is 1, the background's elsewhere. The same mask serves every plane.

```asm
; cookie cut a 32 x 32 object into a 4-plane layer at (X, Y); 40 bytes a plane row
CUT1        equ     ($CA<<BLTCTRL_MINTERM_B)|(BLT_MASK_IMAGE<<BLTCTRL_MASK_B)      ; A ? B : C, 1 bpp
            move.l  #CUT1,BLTCTRL(a4)
            move.l  #OBJMASK,BLTAPT(a4)                 ; the object's mask, 4 bytes a row
            move.l  #(32<<16)|32,BLTSIZE(a4)
            move.l  #(4<<16)|40,BLTSTRIDE(a4)           ; object rows 4 bytes, screen rows 40
            move.l  #4<<16,BLTVALUE(a4)                 ; mask rows 4 bytes
            move.l  #0,BLTNEXT(a4)
            move.l  #OBJECT,d0                          ; the object's plane 0
            move.l  #((X&7)<<BLTDPT_BIT_B)|(PLANES+Y*40+X/8),d1   ; the screen's plane 0
            moveq   #4-1,d2
.plane:     move.l  d0,BLTBPT(a4)
            move.l  d1,BLTDPT(a4)
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
.wait:      btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            bne.s   .wait
            add.l   #32*4,d0                            ; the object's next plane
            add.l   #PLANESIZE,d1                       ; the screen's next plane
            dbra    d2,.plane
```

A colour key does not work in a planar layer: a colour is spread over the planes.

---

## Chains of Jobs

A **descriptor** is a job in Chip RAM: the eight long words of the job registers, in the same order, at any even address. Its last long word, NEXT, is the address of the next descriptor, or 0. The blitter loads a descriptor into the job registers (16 memory cycles), runs it, and goes on to NEXT, with no CPU in between.

- **START** (BLTCMD bit 0) loads the descriptor at **BLTDESC** and runs it.
- **RUN** (bit 1) runs the job in the job registers; if its BLTNEXT is not 0 the chain goes on from there.

While a chain runs, BLTDESC reads as the descriptor being run and the job registers as its job.

### Example 6-3: Draw three objects with one chain

```asm
; Example 6-3: three colour-keyed blits, chained in Chip RAM, started with START.
            lea     chain(pc),a0                ; the ROM's copy of the chain ...
            lea     CHAIN,a1                    ; ... to Chip RAM
            moveq   #3*8-1,d0
.copy:      move.l  (a0)+,(a1)+
            dbra    d0,.copy
            move.l  #CHAIN,BLTDESC(a4)
            move.l  #BLTCMD_START_M,BLTCMD(a4)
            rts

;                   CTRL    BPT        DPT                 SIZE          APT  STRIDE        VALUE  NEXT
chain:      dc.l    KEYED,  SHEET,     SCREEN+40*ROW+30,   (32<<16)|32,  0,   (256<<16)|ROW,  0,   CHAIN+32
            dc.l    KEYED,  SHEET+32,  SCREEN+40*ROW+90,   (32<<16)|32,  0,   (256<<16)|ROW,  0,   CHAIN+64
            dc.l    KEYED|BLTCTRL_IRQ_M, SHEET+64, SCREEN+40*ROW+150, (32<<16)|32, 0, (256<<16)|ROW, 0, 0
```

A game can keep one chain for a whole frame's drawing: build it while the last frame shows, START it in the vertical blank, and take the interrupt when it ends.

---

## Starting Jobs from the Copper

The copper can write the blitter's registers like any others, so it can start a job at a beam position: for example to redraw a panel just after the beam has passed it. BLTCMD's strobes are in its low half:

```asm
            CWAIT   200,0                       ; line 200
            CMOVEL  BLTDESC,PANELJOBS           ; the chain to run
            CMOVE   BLTCMD+2,BLTCMD_START_M     ; START
```

The copper's **WAIT with the B bit** (`CWAITB`) also waits until the blitter is idle, as the Amiga's blitter-finished bit does. Use it before writing the job registers or starting a job from a list, since writes are ignored while the blitter is busy:

```asm
            CWAITB  0,0                         ; when the blitter is idle ...
            CMOVEL  BLTDESC,NEXTJOBS
            CMOVE   BLTCMD+2,BLTCMD_START_M
```

Never put a start between the two MOVEs of a 32-bit pair in a list that uses RESUME (Copper chapter): the pair may run twice.

---

## Status, Interrupts and Errors

| Register | Bits | Meaning |
|----------|------|---------|
| BLTSTAT | BUSY (0) | A job or a chain is running |
| | ERR (2) | The last job stopped on an error. Cleared by the next START or RUN |
| DMXINT | BLT (0) | A job with IRQ ended, or the blitter stopped (the end of a chain, STOP, an error). Write 1 to clear |
| DMXINTEN | BLT (0) | Let DMXINT.BLT raise the interrupt |

The blitter is interrupt source 4 (`INT_BLT`), level 4 unless changed (Interrupts chapter):

```asm
; a handler for the blitter's interrupt
blt_int:    move.l  #DMXINT_BLT_M,CUSTOM+DMXINT     ; acknowledge
            ; ... start the next chain, or flag the frame as drawn ...
            rte

            ; setting up: the vector, the enables
            move.l  #blt_int,(VECBASE_DEFAULT+INT_BLT)*4.w
            move.l  #DMXINT_BLT_M,DMXINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_BLT),INTENA+2(a5)    ; a5 = SYSTEM
```

**STOP** (BLTCMD bit 2) ends the job after the word in hand and does not follow the chain. The job cannot be resumed. Clearing DMACON.BLTEN instead holds the blitter where it is until BLTEN is set again.

**Errors.** The only error is MASK = 3. Nothing is written; ERR and DMXINT.BLT are set, and BLTDESC still names the descriptor. There is **no address check**: a pointer past the end of memory wraps round and the job writes somewhere else in Chip RAM, so check your arithmetic, and clip.

---

## Priority and Speed

The blitter takes only memory cycles nobody else wants: the display, audio, the copper and the CPU all go first. With the default slot plan **the CPU is never slowed** by a job.

Measured in simulation, with the display off:

| Job | Speed |
|-----|-------|
| Fill | 25 MB/s |
| Copy | 17 MB/s |
| Cookie cut with a colour key | 12.5 MB/s |
| Cookie cut with a mask image, 8 bpp | 12 MB/s |
| Copy at 1 bpp | 133 million pixels a second |

A full 720 × 576 8 bpp screen (405 KB) is cleared in about 17 ms and copied in about 25 ms; the 68000 copies about 4 MB/s.

The blitter's own steps set these figures, not the memory: it asks for one memory cycle in three or four. So giving it more cycles with the slot plan (MEMSLOT0–4, Introduction and System Control chapter) gains little. How much a busy screen slows it has not been measured yet.

For the best speed:

- use 8 bpp or byte-aligned rectangles, which need no edge reads;
- prefer a plain copy to a cookie cut where the background is known (two cycles a word against three);
- chain small jobs: a chained job costs 16 cycles to load, less than an interrupt and a handler.

---

## Summary of Blitter Registers

In the custom block (`$E00000`).

| Offset | Name | Access | Fields |
|--------|------|--------|--------|
| `$300` | BLTCTRL | RW | KEY 7–0, BPP 9–8, RTL 10, IRQ 12, BCONST 13, MASK 18–17, MINTERM 31–24 |
| `$304` | BLTBPT | RW | ADDR 23–0, BIT 26–24 |
| `$308` | BLTDPT | RW | ADDR 23–0, BIT 26–24 |
| `$30C` | BLTSIZE | RW | WIDTH 15–0, HEIGHT 31–16 |
| `$310` | BLTAPT | RW | ADDR 23–0, BIT 26–24 |
| `$314` | BLTSTRIDE | RW | BSTRIDE 31–16, DSTRIDE 15–0 |
| `$318` | BLTVALUE | RW | ASTRIDE 31–16, VALUE 15–0 |
| `$31C` | BLTNEXT | RW | ADDR 23–0 |
| `$320` | BLTDESC | RW | ADDR 23–0: the descriptor START loads; reads as the one running |
| `$324` | BLTCMD | W | START 0, RUN 1, STOP 2 |
| `$328` | BLTSTAT | R | BUSY 0, ERR 2 |
| `$3F0` | DMXINT | W1C | BLT 0 |
| `$3F4` | DMXINTEN | RW | BLT 0 |
| `$094` | DMACON | Set/clear | BLTEN 6, DMAEN 9 |

The job registers and BLTDESC ignore writes while BUSY. A descriptor in memory is `BLTJOB_CTRL` to `BLTJOB_NEXT` in `hw.inc` (32 bytes, `BLTJOB_SIZEOF`). The full definition is spec 11 (`docs/spec/dma-engine.md`).
