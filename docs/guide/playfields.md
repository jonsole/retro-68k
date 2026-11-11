# Chapter 3: Playfield Hardware

## Introduction

This chapter tells you how to put pictures on the screen. The retro68k display is built from **playfields**: bitmaps in Chip RAM that the hardware reads by DMA and turns into pixels while the beam sweeps the screen. In this machine the playfields are called **layers**. There are three, L0, L1 and L2, and each is a complete playfield of its own, with its own pointers, window, scroll, scale and colours.

The chapter covers:

- the fixed screen mode and how to find its size;
- forming a basic playfield, step by step;
- bitplanes, interleaved bitplanes and chunky pixels, and how each is laid out in memory;
- the display window, and scaling for low-resolution looks;
- the stride, and scrolling, both fine and coarse, across and down;
- resetting the plane pointers every frame;
- split screens;
- priority and transparency, including a dual-playfield screen;
- the colour registers, palette offsets and the background colour;
- direct colour, from 9 to 24 bits per pixel;
- the fetch budget: how much the display can read, with worked examples;
- feeding a layer's data registers from the CPU;
- video interrupts and the beam position.

You should know 68000 assembly language, and you should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, because every register in this chapter follows those rules. Interrupt handlers are explained in full in the Interrupts and Timers chapter; this chapter uses them without repeating the details.

If you have programmed the Amiga's playfields, you already know most of what follows. The plane pointers (BPLxPT), the data registers (BPLxDAT) and the way the copper or CPU resets the pointers each frame all work as they do on the Amiga. What is new is that there are three playfields instead of one or two, that each can be planar or chunky, that the hardware works out the fetch from the display window by itself, and that each layer can be scaled up by a whole number. The Amiga's modulo is replaced by a **stride** (BPLSTRIDE): the number of bytes from the start of one line to the start of the next.

### Comparison with the Amiga

| Feature | Amiga (OCS/ECS) | retro68k |
|---------|-----------------|----------|
| Playfields | 1, or 2 in dual-playfield mode | 3 layers, in any order |
| Pixel layout | Planar, 1–6 planes | Per layer: planar with 1–8 planes, or chunky with 1, 2, 4 or 8 bits per pixel |
| Colours | 32 colour registers of 12 bits; EHB and HAM | 256-entry palette of 24-bit colours; a layer of up to 4 bits picks a 16-colour block of it. Direct colour up to 24 bits |
| Plane pointers | BPL1PT–BPL6PT | BPL0PT–BPL7PT, per layer |
| Line to line | BPL1MOD (odd planes), BPL2MOD (even planes): bytes skipped after the fetch, so they depend on how many words are fetched and must be adjusted for fine scroll | One BPLSTRIDE per layer: bytes from the start of one line to the start of the next, whatever is fetched |
| Data registers | BPL1DAT–BPL6DAT; writing BPL1DAT starts the shifters | BPL0DAT–BPL7DAT; writing BPL0DAT completes a group |
| Display window | DIWSTRT/DIWSTOP, one for the screen | WINX/WINY, one per layer |
| Data fetch | DDFSTRT/DDFSTOP, set by hand | Worked out by the hardware from each layer's window |
| Fine scroll | BPLCON1, 0–15 pixels | SCROLLX, 0–15 pixels, per layer |
| Pixel size | Lores and hires; line doubling with copper tricks | 1×, 2×, 4× or 8× per layer, across and down separately |
| Priority | BPLCON2: playfield 2 in front or behind | PRIO: any order of the three layers |
| Video mode | PAL or NTSC | 576p only: 720 × 576 at 50 Hz, the digital form of PAL |

Note that the planes are numbered from 0 here, not from 1. Plane 0 gives bit 0 of the pixel's colour number, as the Amiga's plane 1 does.

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax, and start with `include "hw.inc"`.
- In ordinary code **a4 holds CUSTOM** (`$E00000`) and **a5 holds SYSTEM** (`$F00000`). Interrupt handlers assume nothing about these registers.
- In `hw.inc`, `L0`, `L1` and `L2` are the offsets of the three layers in the custom block (`$100`, `$180` and `$200`), and `L_CTRL`, `L_WINX`, `L_BPL0PT` and so on are the offsets of the registers inside a layer. So layer 1's CTRL register is `L1+L_CTRL(a4)`. The same address also has a ready-added name, `L1_CTRL`. When code works on one layer, it usually puts the layer's address in an address register:

  ```asm
          lea     L1(a4),a0               ; a0 = layer 1
          move.l  #40,L_BPLSTRIDE(a0)     ; layer 1's BPLSTRIDE
  ```

- Write zero to a register with `MOVE.L #0` rather than `CLR.L`, which reads the register first. The 16-bit registers (BPLSTRIDE, BPLxDAT, SCROLLX, DMACON) sit in the low half of their long word: write them with `MOVE.L`, or with `MOVE.W` to the register's address + 2.
- The complete examples run in supervisor mode with the vector table in Chip RAM at address 0, as the boot ROM leaves it. They take over the display, so they first turn off whatever the boot ROM left on the screen.

### About this chapter

The first sections build a working screen as quickly as possible: "The Screen" describes the one video mode, and "Forming a Basic Playfield" goes through the registers in the order you set them, ending with a complete program. The sections after that explain each part in more depth, in roughly the order you will need them: the pixel formats and how they sit in memory, the display window, scaling, the stride, scrolling, resetting the pointers each frame, and split screens. Then come the parts that concern more than one layer: priority and transparency, the palette, and direct colour. "The Fetch Budget" tells you how much the display can read, so that you can check a screen design before you build it. The chapter ends with the data registers, the video interrupts and the beam position, and a summary of every register.

---

## The Screen

The display has **one video mode, 576p**: 720 × 576 at 50 Hz, exactly as the CEA-861 standard defines it, on HDMI and VGA at the same time. Every HDMI TV and monitor takes it. It is the digital form of PAL, so Amiga PAL screens fit it well. There are no timing registers.

| Mode | Pixel clock | Visible | Total (pixels × lines) | Line time | Frame | Refresh |
|------|-------------|---------|------------------------|-----------|-------|---------|
| 576p | 27 MHz | 720 × 576 | 864 × 625 | 32.0 µs | 20.0 ms | 50 Hz |

### Beam coordinates

Every position the hardware uses (the beam position, LINECMP, the copper's WAIT and SKIP, layer windows and sprite windows) is given in **beam coordinates**: **beam pixels** across (`hpixel`) and **beam lines** down (`vline`). They count the blanking too. Each line starts with its **horizontal blank** (front porch, sync, back porch) and then shows its 720 pixels. Each frame starts with the **vertical blank** and then shows its 576 lines.

| | Beam pixels (across) | Beam lines (down) |
|--|--|--|
| 0 | The start of the horizontal blank | The start of the vertical blank |
| Blank | 0–143 | 0–48 |
| The picture | 144–863 (720 pixels) | 49–624 (576 lines) |
| Total | 864 per line | 625 per frame |

```
  hpixel  0              144 (VID_X0)                 864
 vline 0 +--------------+------------------------------+
         |          vertical blank (lines 0-48)        |
      49 +--------------+------------------------------+
(VID_Y0) |              |                              |
         |  horizontal  |           picture            |
         |    blank     |          720 x 576           |
         |   (0-143)    |                              |
     625 +--------------+------------------------------+

                  Figure 3-1: The Screen and the Beam
```

The horizontal blank is 144 pixels (5.33 µs). The vertical blank is 49 lines (1.57 ms). A frame starts at beam line 0, pixel 0, and positions only go up through it.

`hw.inc` gives the picture's top left corner as **VID_X0** (144) and **VID_Y0** (49), its size as **VID_W** (720) and **VID_H** (576), and the beam's total as **BEAM_W** (864) and **BEAM_H** (625). So the picture's pixel (x, y), counted from its top left corner, is at beam position (VID_X0 + x, VID_Y0 + y). This chapter calls that **picture position** (x, y) where it helps.

The pixels are not quite square: on a 4:3 screen each one is 16/15 as wide as it is tall, about the shape of an Amiga PAL pixel.

### Normal screens and overscan

HDMI sends exactly the visible pixels, with no border beyond them, so the whole 720 × 576 is the **overscan** area. A normal screen is a smaller window in the middle, with the background colour round it as the border, as on the Amiga (positions here are picture positions):

| Screen | Source | Window |
|--------|--------|--------|
| PAL Amiga, normal | 320 × 256 at 2 × 2 | 640 × 512 at (40, 32) |
| PAL Amiga, overscan | up to 360 × 288 at 2 × 2 | up to the full 720 × 576 |
| 640 × 480 | 640 × 480 at 1 × 1 | at (40, 48) |

A computer monitor shows all 720 × 576 pixels. A TV may crop a few percent off each edge, so keep text and anything important inside the normal area.

VIDSIZE holds the screen size, 720 × 576. To read it:

```asm
        include "hw.inc"

        lea     CUSTOM,a4
        move.l  VIDSIZE(a4),d0          ; VVISIBLE in bits 26-16, HVISIBLE in 10-0
        move.l  d0,d1
        and.l   #VIDSIZE_HVISIBLE_M,d1  ; d1 = 720
        swap    d0
        and.l   #VIDSIZE_VVISIBLE_M>>16,d0  ; d0 = 576
```

---

## Forming a Basic Playfield

To show a picture you need: the picture in Chip RAM, a display window, a plane pointer for each bitplane, a stride, some colours, and the layer, DMA and display turned on. This section goes through the steps for the most common case, one layer showing a 320 × 256 picture in 16 colours at 2 × 2, as a 640 × 512 window in the middle of the screen: the Amiga's PAL lores screen. Each step is explained in more detail later in the chapter.

### Step 1: Choose the format and allocate memory

A layer is either **planar** (1 to 8 bitplanes, as on the Amiga) or **chunky** (1, 2, 4 or 8 bits per pixel, packed in words). For 16 colours you need 4 bits per pixel: 4 bitplanes, or chunky 4 bpp. This example uses 4 bitplanes, stored one after the other.

Each bitplane holds one bit of every pixel, 16 pixels to a word. One line of a 320-pixel plane is 320 ÷ 8 = 40 bytes, and a whole plane of 256 lines is 40 × 256 = 10,240 bytes. Four planes take 40,960 bytes.

All memory is Chip RAM, so any free, even address will do. The picture must start on an even address, and each plane must too.

```asm
SCREEN      equ     $040000             ; the picture, in Chip RAM
WIDTH       equ     320                 ; source pixels across
HEIGHT      equ     256                 ; source lines
PLANES      equ     4
ROWBYTES    equ     WIDTH/8             ; 40 bytes per plane line
PLANESIZE   equ     ROWBYTES*HEIGHT     ; 10240 bytes per plane
```

### Step 2: Define the display window

The **display window** is the rectangle of the screen where the layer shows. It is given in beam pixels and lines by WINX (XSTART in bits 26–16, XEND in bits 10–0) and WINY (YSTART and YEND, the same way). The window includes XSTART and YSTART but stops just before XEND and YEND. Outside its window, a layer is transparent.

The picture is 320 × 256, and CTRL (step 6) will show each source pixel 2 × 2, so it covers 640 × 512 screen pixels. Centred in the 720 × 576 picture, that window starts at picture position (40, 32), which is beam position (184, 81):

```asm
WIN_X       equ     VID_X0+(VID_W-640)/2    ; 144 + 40 = 184
WIN_Y       equ     VID_Y0+(VID_H-512)/2    ; 49 + 32 = 81

        lea     L0(a4),a0               ; a0 = layer 0
        move.l  #(WIN_X<<16)|(WIN_X+640),L_WINX(a0) ; XSTART 184, XEND 824
        move.l  #(WIN_Y<<16)|(WIN_Y+512),L_WINY(a0) ; YSTART 81, YEND 593
```

You never set a data-fetch start or stop: the hardware works out from the window, the scale and the fine scroll which words to fetch and when.

### Step 3: Set the plane pointers

Each bitplane has a pointer, BPL0PT to BPL7PT. Before the first line of the window, each pointer must hold the address of the first word of its plane's first line. As each word is fetched the pointer moves on by 2, so during the frame the pointers walk through memory; they do not go back by themselves.

```asm
setptrs: move.l #SCREEN+0*PLANESIZE,L_BPL0PT(a0)
         move.l #SCREEN+1*PLANESIZE,L_BPL1PT(a0)
         move.l #SCREEN+2*PLANESIZE,L_BPL2PT(a0)
         move.l #SCREEN+3*PLANESIZE,L_BPL3PT(a0)
         rts
```

### Step 4: Set the stride

At the end of each line, the hardware moves every plane pointer of the layer to the start of the next line: the start of the line just shown plus the stride, BPLSTRIDE. The stride is the number of bytes from the start of one line to the start of the next. Here the planes are separate and each plane line is 40 bytes, so the stride is 40.

```asm
        move.l  #ROWBYTES,L_BPLSTRIDE(a0)       ; 40
```

### Step 5: Set the colours

Each layer has its own palette of 256 entries, each a long word `$00RRGGBB`. Layer 0's is PALETTE0 in the custom block (`$E04000`). A 4-plane layer uses 16 of them: entries 0–15 unless you choose another block with the palette offset (step 6). The background colour, BGCOLOR, shows wherever no layer has a pixel.

```asm
        lea     colours(pc),a1
        lea     PALETTE0(a4),a2
        moveq   #16-1,d0
.col:   move.l  (a1)+,(a2)+
        dbra    d0,.col
        move.l  #$000000,BGCOLOR(a4)
```

### Step 6: Set the layer's format and turn it on

CTRL holds the format, the scale and the colour block, and the enable bit:

| Bits | Field | Here |
|------|-------|------|
| 0 | EN | 1: the layer is on |
| 1 | PLANAR | 1: bitplanes |
| 18–16 | PLANES | Number of planes − 1: 3 |
| 7–6 | HSCALE | 1: each source pixel 2 screen pixels wide |
| 9–8 | VSCALE | 1: each source line shown on 2 screen lines |
| 15–12 | PALOFS | 0: colours 0–15 |

```asm
        move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((PLANES-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B),L_CTRL(a0)
```

### Step 7: Arrange for the pointers to be reset each frame

At the end of a frame the pointers have walked off the end of the picture. Something must put them back before the next frame starts. On the Amiga this is the copper's job, and it will be here too; until then, the CPU does it in the **vertical blank interrupt**. The handler clears the VBLANK flag and writes the pointers again:

```asm
vblank: move.l  a0,-(sp)
        lea     CUSTOM,a0
        move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)   ; clear the flag
        lea     L0(a0),a0
        bsr.s   setptrs
        move.l  (sp)+,a0
        rte
```

To enable it: put the handler's address in its vector, enable VBLANK in the video unit (VIDINTEN) and in the interrupt controller (INTENA and INTCON), and lower the CPU's interrupt mask. Video interrupts are level 5 unless you change it.

### Step 8: Turn on bitplane DMA and the display

The layers fetch only when **DMACON.DMAEN** and **DMACON.BPLEN** are both set and the display is on (**VIDCON.EN**). DMACON is a set/clear register at the same address as the Amiga's (`$E00096` for its low half): bit 15 set means "set the bits written as 1".

```asm
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
        move.l  #VIDCON_EN_M,VIDCON(a4)
```

### Example 3-1: A basic playfield

Here are the steps put together. The picture is a pattern of 16 × 16-pixel squares in all 16 colours.

```asm
; Example 3-1: a basic playfield. A 320 x 256 picture in 4 separate
; bitplanes (16 colours), shown 2x across and 2x down as a 640 x 512
; window in the middle of the 720 x 576 picture, as a PAL Amiga lores
; screen. Assumes supervisor mode and the vector table in Chip RAM at 0.

            include "hw.inc"

VECTORS     equ     $000000             ; the vector table, in Chip RAM
SCREEN      equ     $040000             ; the picture, in Chip RAM
WIDTH       equ     320                 ; source pixels across
HEIGHT      equ     256                 ; source lines
PLANES      equ     4
ROWBYTES    equ     WIDTH/8             ; 40 bytes per plane line
PLANESIZE   equ     ROWBYTES*HEIGHT     ; 10240 bytes per plane
WIN_X       equ     VID_X0+(VID_W-2*WIDTH)/2    ; the window: 640 x 512 at
WIN_Y       equ     VID_Y0+(VID_H-2*HEIGHT)/2   ; picture position (40, 32)

start:      move.w  #$2700,sr           ; no interrupts while we set up
            lea     CUSTOM,a4
            lea     SYSTEM,a5
            bsr     draw                ; step 1: the picture in Chip RAM

            ; turn off anything left on, e.g. by the boot ROM, whose copper
            ; list would otherwise go on resetting layers 0 and 1's pointers
            move.w  #DMACON_COPEN_M,DMACON+2(a4)    ; copper off (bit 15 clear: clear)
            move.l  #0,COPCON(a4)
            move.l  #0,L0+L_CTRL(a4)    ; (MOVE.L #0, never CLR.L)
            move.l  #0,L1+L_CTRL(a4)
            move.l  #0,L2+L_CTRL(a4)
            move.l  #(2<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B),PRIO(a4)

            lea     L0(a4),a0           ; a0 = layer 0
            ; step 2: the display window, in beam coordinates
            move.l  #(WIN_X<<16)|(WIN_X+2*WIDTH),L_WINX(a0)     ; XSTART 184, XEND 824
            move.l  #(WIN_Y<<16)|(WIN_Y+2*HEIGHT),L_WINY(a0)    ; YSTART 81, YEND 593
            move.l  #0,L_SCROLLX(a0)
            ; step 3: the plane pointers
            bsr     setptrs
            ; step 4: the stride: 40 bytes from one plane line to the next
            move.l  #ROWBYTES,L_BPLSTRIDE(a0)
            ; step 5: the colours
            lea     colours(pc),a1
            lea     PALETTE0(a4),a2
            moveq   #16-1,d0
.col:       move.l  (a1)+,(a2)+
            dbra    d0,.col
            move.l  #$000000,BGCOLOR(a4)
            ; step 6: the layer: planar, 4 planes, 2x by 2x, colours 0-15
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((PLANES-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(0<<L_CTRL_PALOFS_B),L_CTRL(a0)
            ; step 7: reset the pointers in every vertical blank
            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)       ; clear an old flag
            move.l  #VIDINTEN_VBLANK_M,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)  ; set/clear: other sources untouched
            move.l  #INTCON_MASTER_M,INTCON(a5)
            ; step 8: bitplane DMA and the display on
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)
            move.w  #$2000,sr           ; take interrupts (video is level 5)

main:       ; (your program's main loop goes here)
            bra.s   main

; Layer 0's plane pointers for the top of the picture (a0 = layer 0)
setptrs:    move.l  #SCREEN+0*PLANESIZE,L_BPL0PT(a0)
            move.l  #SCREEN+1*PLANESIZE,L_BPL1PT(a0)
            move.l  #SCREEN+2*PLANESIZE,L_BPL2PT(a0)
            move.l  #SCREEN+3*PLANESIZE,L_BPL3PT(a0)
            rts

; Vertical blank: clear the flag, put the pointers back to the top
vblank:     move.l  a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)
            lea     L0(a0),a0
            bsr.s   setptrs
            move.l  (sp)+,a0
            rte

; A test picture: squares of 16 x 16 pixels, colour (x/16 + y/16) and 15
draw:       lea     SCREEN,a0
            moveq   #0,d4               ; plane
.plane:     moveq   #0,d3               ; line
.line:      move.w  d3,d2
            lsr.w   #4,d2               ; colour of the line's first word
            moveq   #ROWBYTES/2-1,d1
.word:      moveq   #0,d0
            btst    d4,d2               ; this plane's bit of the colour
            beq.s   .put
            moveq   #-1,d0
.put:       move.w  d0,(a0)+
            addq.w  #1,d2               ; next word, next colour
            dbra    d1,.word
            addq.w  #1,d3
            cmp.w   #HEIGHT,d3
            bne.s   .line
            addq.w  #1,d4
            cmp.w   #PLANES,d4
            bne.s   .plane
            rts

colours:    dc.l    $000000,$FFFFFF,$FF0000,$00FF00,$0000FF,$FFFF00,$00FFFF,$FF00FF
            dc.l    $808080,$C0C0C0,$800000,$008000,$000080,$808000,$008080,$800080
```

The background colour, black here, shows round the window as a border: 40 pixels at each side and 32 lines at the top and bottom. A TV that crops the edges of the picture loses only some of the border. For a full overscan picture, make the window larger, up to the whole 720 × 576 (see "Scaling").

### Stopping the display

To turn a layer off, write 0 to its CTRL. To stop all bitplane DMA, clear BPLEN in DMACON (write it with bit 15 clear): the layers then show only what the CPU puts in their data registers (see "Feeding the Data Registers from the CPU"). To show only the background colour, set VIDCON.BLANKALL. Clearing VIDCON.EN stops the beam itself: there is no picture and no sync signal, so the monitor loses the signal.

```asm
        move.w  #DMACON_BPLEN_M,DMACON+2(a4)    ; bit 15 clear: BPLEN off
```

---

## Bitplanes and Chunky Pixels

Each layer is planar or chunky, set by CTRL.PLANAR. The two formats differ only in how a pixel's colour number is stored; everything else in this chapter (window, scale, scroll, stride, priority) works the same way for both.

### Planar layers

A planar layer has 1 to 8 **bitplanes** (CTRL.PLANES holds the number of planes − 1). Each bitplane is a separate bitmap holding one bit of every pixel, 16 pixels to a word, with the leftmost pixel in bit 15. The hardware takes one bit from the same position in each plane to make the pixel's colour number: plane 0 gives bit 0, plane 1 bit 1, and so on.

```
                     word 0 of the line            word 1 ...
           bit:  15 14 13 12 ...          1  0
   plane 3:       0  0  1  1 ...          0  1         ---> bit 3
   plane 2:       0  1  0  1 ...          1  1         ---> bit 2
   plane 1:       1  1  0  0 ...          0  1         ---> bit 1
   plane 0:       1  0  1  0 ...          1  1         ---> bit 0
                  |  |
                  |  +-- pixel 1: %0110 = colour 6
                  +----- pixel 0: %0011 = colour 3

             Figure 3-2: Four Bitplanes Making 16 Colours
```

| Planes | Colours | Like the Amiga's |
|--------|---------|------------------|
| 1 | 2 | 1 plane |
| 2 | 4 | 2 planes |
| 3 | 8 | 3 planes |
| 4 | 16 | 4 planes |
| 5 | 32 | 5 planes (32 colours) |
| 6 | 64 | 6 planes (as EHB, but 64 real colours) |
| 7 | 128 | |
| 8 | 256 | (AGA) |

Bitplanes suit the same things they suit on the Amiga: changing the number of colours by adding a plane, drawing one plane at a time, and cheap effects such as showing a plane on its own.

### Separate and interleaved bitplanes

You decide where the planes are in memory. The hardware only follows the pointers. Two layouts are common.

**Separate planes**, as most Amiga programs use: each plane is a complete bitmap, one after the other.

```
 SCREEN                  +--------------------------+
 (BPL0PT)                | plane 0, line 0          |  40 bytes
                         | plane 0, line 1          |
                         |  ...                     |
                         | plane 0, line 255        |
 SCREEN + 10240          +--------------------------+
 (BPL1PT)                | plane 1, line 0          |
                         |  ...                     |
 SCREEN + 20480 (BPL2PT) +--------------------------+
                         | plane 2 ...              |
 SCREEN + 30720 (BPL3PT) +--------------------------+
                         | plane 3 ...              |
                         +--------------------------+

     Figure 3-3: Separate Bitplanes, 320 x 256, 4 Planes
```

The pointers start one plane apart, and the stride is one plane line: 40.

**Interleaved planes**: the lines of all the planes are kept together, so one picture line is plane 0's line, then plane 1's, plane 2's and plane 3's.

```
 SCREEN       +--------------+--------------+--------------+--------------+
 line 0       | plane 0 (40) | plane 1 (40) | plane 2 (40) | plane 3 (40) |
              +--------------+--------------+--------------+--------------+
 line 1       | plane 0      | plane 1      | plane 2      | plane 3      |
              +--------------+--------------+--------------+--------------+
 ...            ^ BPL0PT       ^ BPL1PT       ^ BPL2PT       ^ BPL3PT
                 = SCREEN       = SCREEN+40    = SCREEN+80    = SCREEN+120

     Figure 3-4: Interleaved Bitplanes, 320 x 256, 4 Planes
```

The pointers start one plane line apart. Each plane's next line starts one whole picture line later, after all four planes' lines, so the stride is planes × the plane line: 4 × 40 = 160. Interleaved planes keep a whole picture line in one place, which makes it easy to scroll vertically and to copy or clear lines.

| Layout | Pointers | BPLSTRIDE |
|--------|----------|-----------|
| 320 × 256, 4 planes, separate | BPLpPT = SCREEN + p × 10240 | 40 |
| 320 × 256, 4 planes, interleaved | BPLpPT = SCREEN + p × 40 | 4 × 40 = 160 |
| 320 × 256, 5 planes, separate | BPLpPT = SCREEN + p × 10240 | 40 |
| 320 × 256, 5 planes, interleaved | BPLpPT = SCREEN + p × 40 | 5 × 40 = 200 |

The boot ROM shows a small 4-plane interleaved picture: 64 × 32 pixels, so each plane line is 8 bytes and the stride is 4 × 8 = 32. It is shown 2 × 2 at (400, 300), in front of the console, in colours 16–31:

```asm
; Example 3-2: a 64 x 32 picture in 4 interleaved planes, from the boot ROM
BITMAP      equ     $020000
BM_W        equ     64
BM_H        equ     32
BM_PL       equ     4
BM_LINE     equ     BM_W/8              ; 8 bytes per plane line
BM_X        equ     VID_X0+400          ; shown 2x at picture position (400, 300)
BM_Y        equ     VID_Y0+300

            lea     L1(a4),a0
            move.l  #BITMAP+0*BM_LINE,L_BPL0PT(a0)
            move.l  #BITMAP+1*BM_LINE,L_BPL1PT(a0)
            move.l  #BITMAP+2*BM_LINE,L_BPL2PT(a0)
            move.l  #BITMAP+3*BM_LINE,L_BPL3PT(a0)
            move.l  #BM_PL*BM_LINE,L_BPLSTRIDE(a0)      ; 32
            move.l  #(BM_X<<16)|(BM_X+2*BM_W),L_WINX(a0)
            move.l  #(BM_Y<<16)|(BM_Y+2*BM_H),L_WINY(a0)
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((BM_PL-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(1<<L_CTRL_PALOFS_B),L_CTRL(a0)
```

### Chunky layers

A chunky layer keeps all the bits of a pixel together. CTRL.BPP gives the depth:

| BPP | Bits per pixel | Pixels per word | Colours |
|-----|----------------|-----------------|---------|
| 0 | 1 | 16 | 2 |
| 1 | 2 | 8 | 4 |
| 2 | 4 | 4 | 16 |
| 3 | 8 | 2 | 256 |

Pixels are packed into words with the **leftmost pixel in the most significant bits**. At 8 bpp each byte is one pixel, in order, so a chunky 8 bpp picture is simply an array of bytes.

```
 one word:      bit 15                                            bit 0
   1 bpp:       | p0| p1| p2| p3| p4| p5| p6| p7| p8| p9|p10|...|p15|
   2 bpp:       |  p0   |  p1   |  p2   |  p3   |  p4   | ... |  p7   |
   4 bpp:       |      p0       |      p1       |  p2   ...    p3    |
   8 bpp:       |              p0               |        p1          |

               Figure 3-5: Chunky Pixels in a Word
```

A chunky layer has one pointer, BPL0PT; the other pointers are left alone. Like a planar layer it is fetched in groups of 16 pixels, so a group is as many consecutive words as it has bits per pixel: 1 word at 1 bpp, 2 at 2 bpp, 4 at 4 bpp, 8 at 8 bpp. They go into the data registers from the top down: the first word (the leftmost pixels) into BPL(b−1)DAT, the last into BPL0DAT. The number of bytes in one line of a chunky picture is width × bits per pixel ÷ 8: 320 bytes for 320 pixels at 8 bpp, 160 at 4 bpp.

Chunky pixels are easier and faster for the CPU to draw one at a time, since one pixel is one byte (8 bpp) or one nibble (4 bpp). Planar pixels are better for drawing whole shapes plane by plane, and for using fewer bits per pixel than a chunky depth allows (3, 5, 6 or 7).

A 1-bit chunky layer and a 1-plane planar layer are the same thing. The boot ROM's console uses a 1 bpp chunky layer of 640 × 480, 80 bytes per line, in a window centred in the picture, at picture position (40, 48):

```asm
CON         equ     $030000             ; the console: 640 x 480, 1 bit per pixel
CON_X       equ     VID_X0+(VID_W-640)/2    ; 144 + 40 = 184
CON_Y       equ     VID_Y0+(VID_H-480)/2    ; 49 + 48 = 97

            lea     L0(a4),a0
            move.l  #CON,L_BPL0PT(a0)
            move.l  #640/8,L_BPLSTRIDE(a0)      ; 80 bytes per line
            move.l  #(CON_X<<16)|(CON_X+640),L_WINX(a0)
            move.l  #(CON_Y<<16)|(CON_Y+480),L_WINY(a0)
            move.l  #L_CTRL_EN_M,L_CTRL(a0)     ; chunky, 1 bit per pixel, colours 0-1
```

### Memory needed

| Picture | Format | Bytes |
|---------|--------|-------|
| 320 × 256, 16 colours | 4 planes or 4 bpp | 40,960 |
| 320 × 256, 32 colours | 5 planes | 51,200 |
| 320 × 256, 256 colours | 8 planes or 8 bpp | 81,920 |
| 640 × 480, 2 colours (the console) | 1 plane or 1 bpp | 38,400 |
| 640 × 512, 16 colours | 4 planes or 4 bpp | 163,840 |
| 640 × 512, 256 colours | 8 planes or 8 bpp | 327,680 |
| 720 × 576, 256 colours | 8 planes or 8 bpp | 414,720 |

There are 2 or 4 MB of Chip RAM, so even a 256-colour full screen leaves plenty of room for several buffers.

### Summary: format registers

| Register | Field | Bits | Function |
|----------|-------|------|----------|
| CTRL | PLANAR | 1 | 1: planar, 0: chunky |
| CTRL | BPP | 3–2 | Chunky depth: 0–3 for 1, 2, 4, 8 bpp |
| CTRL | PLANES | 18–16 | Planar: number of planes − 1 |
| BPL0PT–BPL7PT | ADDR | 22–0 | Address of the plane's next word; even (chunky: BPL0PT only) |

---

## The Display Window

Each layer has its own display window, set by WINX and WINY in beam coordinates (see "Beam coordinates" in "The Screen"):

| Register | Bits 26–16 | Bits 10–0 |
|----------|------------|-----------|
| WINX | XSTART: first pixel of the window | XEND: first pixel after the window |
| WINY | YSTART: first line of the window | YEND: first line after the window |

The window covers `XSTART ≤ hpixel < XEND` and `YSTART ≤ vline < YEND`. A full-screen window is XSTART 144, XEND 864, YSTART 49, YEND 625 (VID_X0, VID_X0 + VID_W, VID_Y0, VID_Y0 + VID_H), which is also the value after reset. Outside its window, a layer is transparent: lower layers or the background colour show through, and nothing is fetched for it.

A window is clamped to the picture. A start in the blank counts as the picture's edge: the layer's first pixel then shows there, at VID_X0 or VID_Y0, so a layer is not clipped as a sprite is. An end past the last pixel or line counts as the picture's end.

```
        VID_X0                                       VID_X0+VID_W
 VID_Y0 +-------------------------------------------------------+
        |                                                       |
        |        XSTART                    XEND                 |
        | YSTART   +-------------------------+                  |
        |          |                         |                  |
        |          |   the layer's pixels    |                  |
        |          |                         |                  |
        | YEND     +-------------------------+                  |
        |          (first line after the window)                |
        +-------------------------------------------------------+
 VID_Y0+VID_H

                 Figure 3-6: A Layer's Display Window
```

Because every layer has its own window, windows can overlap, sit side by side, or be stacked one above the other. A status panel at the bottom of the screen is simply a second layer with a window covering the bottom lines; it needs no copper.

The window is given in **screen** pixels (beam pixels). With scaling (next section), the window covers fewer **source** pixels: a 640-pixel-wide window at 2× shows 320 source pixels.

### Centring a window

There is one screen size, so a centred window can be worked out when you assemble. For a window W pixels wide and H lines high, XSTART is VID_X0 + (720 − W) ÷ 2 and YSTART is VID_Y0 + (576 − H) ÷ 2. This fragment centres a 640 × 512 window, for a 320 × 256 picture at 2 × 2: it gives beam pixels 184–824 across and beam lines 81–593 down.

```asm
WIN_W       equ     640
WIN_H       equ     512
WIN_X       equ     VID_X0+(VID_W-WIN_W)/2  ; 184
WIN_Y       equ     VID_Y0+(VID_H-WIN_H)/2  ; 81

        lea     L0(a4),a0
        move.l  #(WIN_X<<16)|(WIN_X+WIN_W),L_WINX(a0)
        move.l  #(WIN_Y<<16)|(WIN_Y+WIN_H),L_WINY(a0)
```

### When window changes take effect

The hardware reads CTRL, WINX, WINY and SCROLLX for each line at the start of its horizontal blank (beam pixel 0), before its picture. **To change line L, write during the visible part of line L − 1 or earlier.** This lets you move a window or change a layer's format partway down the screen.

Some of CTRL is read more often, so that a copper can change it partway **along** a line:

- **TRANSP and PALOFS** are read for every pixel: a write shows from the next pixel. Where they change, one pixel may show a mix of the old and new values.
- **BPP, PLANAR, PLANES and HSCALE** go with each 16-pixel group: the hardware takes them as it starts fetching a group, and shows the group with them. The fetch works a group ahead, so a write shows from the next or the second group past the beam (16–32 source pixels on), never partway into a group.
- A scale changed partway along a line upsets the line, though: the number of groups fetched for the line was worked out at its start. A wider scale leaves the last groups unshown; a narrower one runs out of groups before the window ends, and the rest of the line is transparent (OVERRUN is set). Either way the next line starts where it should.
- Put a setting back in the right border, after the layer's window, if the next line should start as before.

### How much is fetched

The window also decides how much the hardware fetches for each line. For one line of one plane it fetches:

```
   source pixels  =  window width ÷ horizontal scale   (rounded up)
   bytes fetched  =  source pixels × bits per pixel ÷ 8, rounded up to a whole word
                     (planar: 1 bit per pixel, since each plane is fetched separately)
```

| Window width | Scale | Format | Source pixels | Bytes fetched |
|--------------|-------|--------|---------------|-------------|
| 640 | 2× | 4 planes | 320 | 40 bytes per plane |
| 640 | 2× | chunky 8 bpp | 320 | 320 bytes |
| 640 | 1× | chunky 4 bpp | 640 | 320 bytes |
| 320 | 1× | 5 planes | 320 | 40 bytes per plane |
| 128 | 2× | 4 planes | 64 | 8 bytes per plane |
| 100 | 1× | 2 planes | 100 | 14 bytes per plane (100 bits, rounded up to 7 words) |

The hardware fetches whole groups of 16 source pixels, so with fine scroll it may fetch one group more (one word more per plane; for a chunky layer, one group's words), as "Scrolling" explains. The picture must have this much data on each line. How much is fetched plays no part in where the next line starts: the stride alone decides that (see "The Stride").

### Summary: window registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| WINX | Ln + `$04` | RW | XSTART (26–16), XEND (10–0): window across, beam pixels (full screen 144, 864) |
| WINY | Ln + `$08` | RW | YSTART (26–16), YEND (10–0): window down, beam lines (full screen 49, 625) |
| VIDSIZE | `$020` | R | VVISIBLE (26–16), HVISIBLE (10–0): the screen size |

---

## Scaling

Each layer can show every source pixel 1, 2, 4 or 8 times across (CTRL.HSCALE) and every source line 1, 2, 4 or 8 times down (CTRL.VSCALE), independently:

| HSCALE, VSCALE | Scale |
|----------------|-------|
| 0 | 1× |
| 1 | 2× |
| 2 | 4× |
| 3 | 8× |

This gives the low-resolution looks of older machines on a modern screen, with sharp pixels:

| Picture | Scale | On the 720 × 576 picture (picture position) | Looks like |
|---------|-------|-------------------------|------------|
| 320 × 256 | 2 × 2 | 640 × 512 at (40, 32) | Amiga PAL lores, non-interlaced |
| 640 × 256 | 1 × 2 | 640 × 512 at (40, 32) | Amiga PAL hires, non-interlaced |
| 360 × 288 | 2 × 2 | Full screen | Amiga PAL lores, full overscan |
| 320 × 240 | 2 × 2 | 640 × 480 at (40, 48) | Amiga NTSC lores |
| 160 × 128 | 4 × 4 | 640 × 512 at (40, 32) | Chunky 8-bit-era graphics |
| 320 × 512 | 2 × 1 | 640 × 512 at (40, 32) | Tall pixels |

There is no fractional scaling and no shrinking.

Scaling is free in memory and, across the screen, in bandwidth: a layer at 2× across fetches half as much per screen pixel as the same layer at 1×. Scaling **down** the screen saves nothing in bandwidth, because the hardware fetches each source line again for every screen line it appears on. It does save memory, and it does save the CPU drawing time.

If the window width is not a whole multiple of the scale, the last source pixel is cut short. With vertical scaling, the first screen line of the window shows the first copy of the first source line; if the height is not a whole multiple of the scale, the last source line is cut short.

With vertical scaling, the pointers go back to the start of the source line after each copy except the last, and move on to the next source line (the line's start plus BPLSTRIDE) only after the last copy. You do not need to do anything about this; just set the stride for the source picture.

---

## The Stride

The stride, BPLSTRIDE, is the number of bytes from the start of one line of a plane to the start of the next. It takes the place of the Amiga's modulo, and it is simpler: it does not depend on how much the hardware fetches.

Here is what happens to each plane pointer during one line. At the start of the line, the pointer holds the address of the line's first word. The hardware fetches the line, word by word, and the pointer moves on by 2 bytes for each word. When it fetches the line's **first** word, the hardware also saves the pointer's value: the line's start. When it fetches the line's **last** word, it sets the pointer to that saved start plus BPLSTRIDE. So:

```
   next line's start  =  this line's start  +  BPLSTRIDE
```

The number of words fetched makes no difference. The window width, the scale and the fine scroll do not change the stride, and you never adjust it for them. If the lines of the picture follow each other in memory, BPLSTRIDE is the number of bytes in one line of the picture (one plane's line, for separate planes), whatever part of the line the window shows:

```
               picture lines in memory: 80 bytes each (640 pixels, 1 plane)

     line y's start                                   line y+1's start
           v                                                 v
   ...-----+--------------------+----------------------------+--------------
           | shown: 40 bytes    | not shown: 40 bytes        | shown ...
   ...-----+--------------------+----------------------------+--------------
           <------------------ BPLSTRIDE = 80 ---------------->

   The stride is 80 whether the window shows all 640 pixels, 320 of them,
   or any other part, and whatever the fine scroll.

     Figure 3-7: The Stride for a Window Narrower Than the Picture
```

In general, BPLSTRIDE is the picture's **row stride**: the number of bytes from the start of one of its plane lines to the start of the next.

| Picture | Window shows | BPLSTRIDE |
|---------|--------------|-----------|
| 320 × 256, 4 planes, separate | all, 2× | 40 |
| 320 × 256, 4 planes, interleaved | all, 2× | 4 × 40 = 160 |
| 640 × 256, 4 planes, interleaved | 320 source pixels | 4 × 80 = 320 |
| 320 × 256, chunky 8 bpp | all, 2× | 320 |
| 640 × 480, chunky 4 bpp | 320 source pixels | 320 |
| 640 × 480, chunky 8 bpp | 320 source pixels | 640 |

BPLSTRIDE is a signed 16-bit number of bytes, and it must be even (bit 0 always reads 0). It sits in the low half of its long word: write it with `MOVE.L`, or with `MOVE.W` to its address + 2. There is one BPLSTRIDE per layer, used for all of its planes. Unlike the Amiga, there are no separate values for odd and even planes.

Other strides show the picture differently:

- BPLSTRIDE = 0 shows the same source line on every screen line, since each line starts where the last one did.
- BPLSTRIDE = −(row stride) steps **back** one row each line, so the picture is shown upside down. Point the pointers at the picture's last line and the picture appears flipped top to bottom. For a 320-byte-wide 8 bpp picture, that is BPLSTRIDE = −320.

The stride is live. The hardware reads it at the end of the line, as the next line's horizontal blank starts, when it moves the pointers on to the next line. So a value written at any time during a line, or in the horizontal blank before it, applies at the end of that line. Changing it partway down the screen is a simple way to make effects, as Example 3-6 below shows.

### Summary: the stride

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| BPLSTRIDE | Ln + `$10` | RW | Signed, even: bytes from the start of one line to the start of the next, for all the layer's plane pointers. 16 bits, in the low half |

---

## Scrolling

### Vertical scrolling

To scroll a picture up and down, change the address of the first line you give the pointers. To start the display at picture line y:

```
   BPLpPT  =  plane p's first line  +  y × row stride
```

The stride stays the same. To scroll smoothly, add or subtract one row stride per line scrolled, in each frame's vertical blank. The picture in memory must be tall enough for the window. To scroll endlessly, without copying, use pointer wrap (see "Endless scrolling: pointer wrap" below).

### Horizontal scrolling

A picture wider than its window can be scrolled across in two parts:

- **Coarse scrolling**, in whole words, by moving the pointers. Moving every pointer on by 2 bytes scrolls a planar layer 16 pixels to the left (a chunky 8 bpp layer 2 pixels, a 4 bpp layer 4 pixels).
- **Fine scrolling**, within a word, by SCROLLX: the number of source pixels (0–15) the hardware skips at the start of each line.

To show the picture from source pixel x on a planar layer:

```
   BPLpPT   =  plane p's line start  +  (x ÷ 16) × 2       (bytes; ÷ rounds down)
   SCROLLX  =  x mod 16
```

For a chunky layer, a word holds fewer pixels, so the fine scroll is smaller:

| Format | Pixels per word | BPL0PT moves by | SCROLLX |
|--------|-----------------|-----------------|---------|
| Planar, any planes; chunky 1 bpp | 16 | (x ÷ 16) × 2 | x mod 16 (0–15) |
| Chunky 2 bpp | 8 | (x ÷ 8) × 2 | x mod 8 (0–7) |
| Chunky 4 bpp | 4 | (x ÷ 4) × 2 | x mod 4 (0–3) |
| Chunky 8 bpp | 2 | (x ÷ 2) × 2 | x mod 2 (0–1) |

The hardware takes SCROLLX modulo the number of pixels in a word, so at 8 bpp a SCROLLX of 5 scrolls by 1 pixel.

**The stride never depends on scroll.** When SCROLLX is not 0, the hardware fetches one extra group on each line to supply the pixels that slide in from the right, but the next line still starts at this line's start plus BPLSTRIDE. On the Amiga you had to start the fetch a word early and subtract 2 from the modulo; here you do neither. Coarse scrolling does not change the stride either: it moves the line's start, and the stride counts from there. The picture must have a word to spare on the right of the part you show, which it always has if x + source width ≤ picture width.

Note that SCROLLX works the opposite way to the Amiga's BPLCON1. BPLCON1 delays the picture, moving it to the right; SCROLLX skips pixels, moving the picture to the **left** and showing more of its right-hand side. With the formulas above, increasing x always moves the view to the right through the picture, so the picture slides left on the screen.

The scroll registers take effect at different times: the pointers are used at once, and SCROLLX at the next line. Change both in the vertical blank and they change together.

### Example 3-3: A scrolling routine

This routine points a layer at a 640 × 256 picture in 4 interleaved planes, from any position (x, y). The layer's window shows 320 source pixels (640 screen pixels at 2×), but the stride is still the picture's row stride: BPLSTRIDE = 4 × 80 = 320.

```asm
BACK        equ     $040000             ; the picture
BK_W        equ     640                 ; picture width, source pixels
BK_PL       equ     4
BK_ROW      equ     BK_W/8              ; 80 bytes per plane line
BK_STRIDE   equ     BK_ROW*BK_PL        ; 320 bytes from one line to the next
VIEW_W      equ     320                 ; source pixels in the window

; once:     move.l  #BK_STRIDE,L_BPLSTRIDE(a0)      ; 320

; Point the layer at a0 at the picture from (d0.w, d1.w), in source
; pixels; 0 <= d0 <= BK_W - VIEW_W. Call it in the vertical blank.
scroll_back:
            movem.l d0-d2/a1,-(sp)
            moveq   #15,d2
            and.w   d0,d2
            move.w  d2,L_SCROLLX+2(a0)  ; fine: x mod 16 (16-bit register, low half)
            moveq   #0,d2
            move.w  d0,d2
            lsr.w   #4,d2
            add.l   d2,d2               ; coarse: whole words, in bytes
            mulu    #BK_STRIDE,d1       ; y lines down
            add.l   d2,d1
            add.l   #BACK,d1            ; d1 = plane 0's first word
            lea     L_BPL0PT(a0),a1
            moveq   #BK_PL-1,d2
.pt:        move.l  d1,(a1)+            ; BPLpPT (MOVE.L: high half first)
            add.l   #BK_ROW,d1          ; the next plane's line
            dbra    d2,.pt
            movem.l (sp)+,d0-d2/a1
            rts
```

The pointers are consecutive long words, so the routine writes them with `MOVE.L d1,(a1)+`. Do not write registers with `-(An)`: in that mode the 68000 writes the low half first.

### Endless scrolling: pointer wrap

A game that scrolls through a long map does not need the whole map in memory as a picture, only the lines on the screen and a few more. With **pointer wrap**, those lines are kept as a **ring** in a block of memory, and the display goes round it by itself.

CTRL.WRAP (bits 23–20) sets the size of the block, 2^(WRAP + 9) bytes:

| WRAP | Block | WRAP | Block |
|------|-------|------|-------|
| 0 | No wrap (the default) | 7 | 64 KB |
| 1 | 1 KB | 8 | 128 KB |
| 2 | 2 KB | 9 | 256 KB |
| ... | ... | 13 | 4 MB |

Each pointer then stays inside the block it is in. The block must be **aligned**: it starts at a multiple of its own size. When the display moves a pointer on, a word at a time and to the line's start plus BPLSTRIDE at the end of a line, only the address bits inside the block change, so a pointer that runs off the end of the block carries on from its start. With a 64 KB wrap, a pointer at `$10000` stays between `$10000` and `$1FFFF`.

Two things to remember:

- Wrap applies only to the moves the display makes. A pointer value **you** write is used as it is, so work out the address inside the block yourself (`AND` with the block size − 1, then add the block's start).
- The wrap is on bytes, not lines. Lines are easiest to handle when the row stride divides the block size exactly, so that no line is split at the end of the block. Pad each line if you need to (the stride includes the padding).

To scroll down through a map: the ring holds more lines than the window shows. Each frame you move the pointers on by one stride per line scrolled, and draw the map's new lines into the ring just below the visible ones, where the display has not reached yet. Scrolling up is the same the other way round.

### Example 3-4: An endless vertical scroll

A 320 × 256 view, shown at 2×, of a map as tall as you like, in 4 interleaved planes. Each plane line is padded from 40 to 64 bytes, so the stride is 256 bytes, and a 128 KB block holds a ring of 512 lines: the 256 on the screen and 256 more to draw into ahead of them.

```asm
RING        equ     $040000             ; the ring: 128 KB, aligned to 128 KB
RING_SIZE   equ     $20000
RING_WRAP   equ     8                   ; 2^(8+9) = 128 KB
RG_PL       equ     4
RG_ROW      equ     64                  ; bytes per plane line (40 shown, 24 padding)
RG_STRIDE   equ     RG_ROW*RG_PL        ; 256 bytes from one line to the next

; once, with a0 = the layer:
            move.l  #RG_STRIDE,L_BPLSTRIDE(a0)          ; 256
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((RG_PL-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(RING_WRAP<<L_CTRL_WRAP_B),L_CTRL(a0)

; Each frame, in the vertical blank: show map line d1.l (any line of the
; map; it goes up by 1 per line scrolled) at the top of the window.
; The map line y is kept in the ring at line y mod 512.
ring_scroll:
            movem.l d1-d2/a1,-(sp)
            lsl.l   #8,d1               ; y * RG_STRIDE (256)
            and.l   #RING_SIZE-1,d1     ; inside the block
            add.l   #RING,d1            ; d1 = plane 0 of the top line
            lea     L_BPL0PT(a0),a1
            moveq   #RG_PL-1,d2
.pt:        move.l  d1,(a1)+
            add.l   #RG_ROW,d1          ; the next plane: never crosses the end,
            dbra    d2,.pt              ; as every line is whole in the block
            movem.l (sp)+,d1-d2/a1
            rts
```

The display does the rest: as it fetches down the screen, a pointer that passes `RING+$1FFFF` carries on at `RING`, so the bottom of the screen shows the ring's first lines. Before map line y + 256 scrolls into view, draw it at ring line (y + 256) mod 512, with the same `AND`.

Wrap works for chunky layers too, and each plane of a separate-planes layer can have its own ring, in its own block of the same size. Wrap is not across a line: a picture that scrolls sideways must still be wide enough, or be redrawn at its edges.

### Summary: scrolling

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| SCROLLX | Ln + `$0C` | RW | Fine scroll: source pixels (0–15) skipped at the start of each line; taken modulo the pixels in a word for chunky layers |
| BPL0PT–BPL7PT | Ln + `$20`–`$3C` | RW | Plane pointers: coarse scrolling, across and down |
| CTRL.WRAP | Ln + `$00`, bits 23–20 | RW | Pointer wrap: the pointers stay in an aligned block of 2^(WRAP + 9) bytes; 0 off |

---

## Resetting the Pointers Every Frame

The plane pointers are not reset by the hardware. At the end of a frame each pointer has moved on by BPLSTRIDE for every source line shown, and if nothing rewrites it, the next frame carries on from there through memory. As on the Amiga, something must write the pointers at the start of every frame:

- **the copper**, which does it in the vertical blank with a few MOVE instructions in its list, as Amiga programs do (Chapter 5 has the list for Example 3-1). The boot ROM resets its own layers' pointers this way;
- **the CPU**, in its vertical blank interrupt, which is what the examples in this chapter do.

The VBLANK interrupt comes at the start of the frame (beam line 0, pixel 0), the start of the vertical blank, after the last picture line has been fetched and the pointers have stopped moving. The hardware starts fetching the picture's first line at the start of that line's horizontal blank (beam line 49, pixel 0). So the handler has the whole vertical blank, 49 lines or about 1.5 ms, to write the pointers. A layer whose window starts lower down is fetched later, at the start of the horizontal blank of its YSTART line.

The handler is also the natural place to make any other change that must happen between frames: scroll positions, which buffer is shown, a new palette.

### Double buffering

To animate without flicker, draw into one buffer while the other is shown, and swap them between frames. The main program draws the next frame into the hidden buffer, stores its address in a variable, and waits for the vertical blank; the handler loads the pointers from the variable.

```asm
; Example 3-5: double buffering. The handler shows the buffer whose address
; is in "shown"; 4 separate planes of PLANESIZE bytes.
shown       equ     $008000             ; long: the buffer to show
PLANESIZE   equ     10240

vblank:     movem.l d0/a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)
            lea     L0+L_BPL0PT(a0),a0
            move.l  shown,d0
            move.l  d0,(a0)+            ; BPL0PT
            add.l   #PLANESIZE,d0
            move.l  d0,(a0)+            ; BPL1PT
            add.l   #PLANESIZE,d0
            move.l  d0,(a0)+            ; BPL2PT
            add.l   #PLANESIZE,d0
            move.l  d0,(a0)+            ; BPL3PT
            movem.l (sp)+,d0/a0
            rte

; In the main program: show the buffer at a1 from the next frame on, then
; wait until that frame has started (FRAMECOUNT counts the vertical blanks)
showbuf:    move.l  a1,shown
            move.l  FRAMECOUNT(a4),d0
.wait:      cmp.l   FRAMECOUNT(a4),d0
            beq.s   .wait
            rts
```

---

## Split Screens

A **split screen** shows different pictures, or different parts of one picture, in bands down the screen: a scrolling game area above a fixed status panel, for example. There are three ways to make one.

### Different layers

The simplest way is to use one layer for each band. Give each layer a window covering its band, and set each one up independently: its own pointers, stride, scroll, scale and format. A layer is fetched only on the lines its window covers, so bands that do not overlap cost no extra bandwidth.

```
 picture
 line  32 +-----------------------------------------+
          |  layer 0: game area                      |
          |  320 x 224, 5 planes, 2x, scrolling      |
          |  WINY 81-529 (VID_Y0+32 to VID_Y0+480)   |
      480 +-----------------------------------------+
          |  layer 1: status panel, 640 x 64, 2 pl.  |
      544 +-----------------------------------------+  WINY 529-593

            Figure 3-8: A Split Screen from Two Layers
```

### Changing the stride partway down

Because the stride is used at the end of each line, changing it during a line changes where the **next** line starts. Change BPLSTRIDE during line L and line L + 1 starts at (line L's start + new BPLSTRIDE). This is a clean way to make a one-layer split: the write can land anywhere in line L, up to the start of line L + 1's horizontal blank, which is easy to hit from an interrupt.

- To jump to another part of memory at line L + 1, set BPLSTRIDE during line L to (address wanted − line L's start), then put the row stride back during line L + 1. The jump applies to all of the layer's planes, so the new picture must have the same plane layout.
- To repeat a line, set BPLSTRIDE to 0 for as many lines as you want it repeated.
- To show a reflection, set BPLSTRIDE to −(row stride) and leave it there: from then on each line steps back a row.

The LINE interrupt (see "Video Interrupts") is made for this: it comes at the start of beam line LINECMP, 144 pixels before the line's picture, and its handler writes BPLSTRIDE while that line is being shown. With vertical scaling, the stride is used only after the last copy of a source line, so the change takes effect at the end of the source line being shown.

### Example 3-6: A reflection

This example extends Example 3-1. From picture line 384 down (beam line 433, source line 176), the LINE interrupt sets the stride to step back one row per source line, so the picture above the line is reflected below it. It also switches the layer to colours 16–31, a darker set, from the next line. The vertical blank handler puts the pointers, the stride and the colours back for the next frame.

```asm
; Example 3-6: a reflection, added to Example 3-1
MIRROR      equ     VID_Y0+384          ; beam line where the reflection starts
CTRL_TOP    equ     L_CTRL_EN_M|L_CTRL_PLANAR_M|((PLANES-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)

            ; in the set-up: colours 16-31 for the water, then the interrupts
            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
            move.l  #mirror,VECTORS+(VECBASE_DEFAULT+INT_LINE)*4
            move.l  #MIRROR<<LINECMP_VLINE_B,LINECMP(a4)
            move.l  #VIDSTAT_VBLANK_M|VIDSTAT_LINE_M,VIDSTAT(a4)    ; clear old flags
            move.l  #VIDINTEN_VBLANK_M|VIDINTEN_LINE_M,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK)|(1<<INTB_LINE),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)

; Vertical blank: the pointers back to the top, the stride and colours
; back to normal
vblank:     move.l  a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)
            lea     L0(a0),a0
            bsr     setptrs
            move.l  #ROWBYTES,L_BPLSTRIDE(a0)
            move.l  #CTRL_TOP|(0<<L_CTRL_PALOFS_B),L_CTRL(a0)
            move.l  (sp)+,a0
            rte

; Line MIRROR: from the end of the current source line, each line steps
; back one row instead of on: BPLSTRIDE = -(row stride). The new
; PALOFS shows from the next screen line.
mirror:     move.l  a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_LINE_M,VIDSTAT(a0)
            move.l  #-ROWBYTES,L0+L_BPLSTRIDE(a0)
            move.l  #CTRL_TOP|(1<<L_CTRL_PALOFS_B),L0+L_CTRL(a0)
            move.l  (sp)+,a0
            rte
```

### Writing new pointers partway down

On the Amiga, the copper makes splits by writing new plane pointers in the horizontal blank. You can write the pointers at any time here too, since they are live, but you need to know exactly what the hardware does with them:

- A line's fetch begins at the **start of its horizontal blank** (beam pixel 0). During the line, the hardware keeps fetching until about 32 source pixels before the window's right edge, each word moving its pointer on. At the start of the next line's horizontal blank it sets each pointer it fetched from to the line's start plus BPLSTRIDE.
- A write to a pointer wins over the hardware's own change in the same clock, and it also sets that pointer's saved line start.

So a pointer written during the gap between the layer's last fetch on line L and the start of line L + 1 (its horizontal blank) is used **as written** as the start of line L + 1: nothing is added and nothing taken off. A pointer written earlier in line L is used for the rest of line L, from the next word fetched (one or two groups past the beam), and line L + 1 then starts at the value written plus BPLSTRIDE; one written after line L + 1's horizontal blank has started is too late for its start. With a full-width window the gap is under a microsecond, too short for the CPU to hit reliably; it is meant for the copper. With the CPU, use separate layers or the stride method above.

In the gap a pointer reads back as the end of line L's words, not as line L + 1's start, and a write of one half of it (a MOVE, or a word write) merges with that value. So write each pointer whole: a long-word write, or `CMOVEL`, which writes the high half first.

---

## Priority and Transparency

### Transparency

Where a layer has no pixel to show, it is **transparent** and the layer behind it shows through. A layer is transparent:

- outside its display window;
- where its pixel value is 0, if CTRL.TRANSP is set;
- where its data was not ready in time (see "When a Layer Runs Short").

If TRANSP is clear, the layer is solid everywhere inside its window, and pixel value 0 shows colour 0 of its block. Where no layer has a pixel, the **background colour**, BGCOLOR, shows. BGCOLOR is a 24-bit colour `$RRGGBB` of its own, not a palette entry.

### Priority

PRIO lists the three layers from front to back:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Number of the layer in front |
| 3–2 | MIDDLE | Number of the layer in the middle |
| 5–4 | BACK | Number of the layer at the back |

Any order is allowed. A field holding 3 names no layer, so a layer left out of PRIO is never shown, whatever its CTRL says (it is still fetched if it is enabled). After reset PRIO is L0 in front, then L1, then L2: `(2<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B)`.

For each pixel, the hardware shows the colour of the front-most layer that is not transparent there:

```
                        front              back
   PRIO = L1, L0, L2:    L1  ---->  L0  ---->  L2  ---->  BGCOLOR
                          |          |          |
            the first non-transparent pixel, looking from the front, is shown

                   Figure 3-9: Choosing a Pixel
```

PRIO and BGCOLOR take effect at the start of each line, so you can change the order partway down the screen.

### Dual playfields

The Amiga's dual-playfield mode splits its bitplanes into two independent playfields, one in front of the other, each with its own colours and scrolling. Here any two layers do the same, without giving up planes: each layer keeps its own depth, and you have a third layer to spare.

To make a dual-playfield screen:

1. Set up the back layer as an ordinary solid playfield.
2. Set up the front layer with CTRL.TRANSP set, and draw it with colour 0 wherever the back layer should show.
3. Give the two layers different colour blocks with PALOFS (next section).
4. Put the front layer first in PRIO.

Each layer scrolls independently, so you can scroll the two at different speeds for a parallax effect.

### Example 3-7: Dual playfields with parallax

The back layer is a 640 × 256 picture in 4 interleaved planes, colours 32–47, scrolled across one pixel per frame by the routine from Example 3-3. The front layer is 320 × 256 in 3 separate planes, colours 16–23, with a band of coloured blocks; its colour 0 is transparent. Both are 2 × 2, in the same 640 × 512 window at picture position (40, 32) as Example 3-1. Bandwidth: 3 ÷ 8 ÷ 2 + 4 ÷ 8 ÷ 2 = 0.44 bytes per pixel, well within the budget.

```asm
; Example 3-7: two playfields, as in the Amiga's dual-playfield mode.
; Layer 1 (behind): a 640 x 256 picture in 4 interleaved planes, colours
;   32-47 (PALOFS 2), 320 x 256 of it seen at a time (2x by 2x) and
;   scrolled across one pixel per frame.
; Layer 0 (in front): a 320 x 256 picture in 3 separate planes, colours
;   16-23 (PALOFS 1), with colour 0 transparent so layer 1 shows through.
; Both in a 640 x 512 window at picture position (40, 32).
; Assumes supervisor mode and the vector table in Chip RAM at 0.

            include "hw.inc"

VECTORS     equ     $000000

; layer 1: the background
BACK        equ     $040000
BK_W        equ     640                 ; picture width, source pixels
BK_H        equ     256
BK_PL       equ     4
BK_ROW      equ     BK_W/8              ; 80 bytes per plane line
BK_STRIDE   equ     BK_ROW*BK_PL        ; 320 bytes from one line to the next
VIEW_W      equ     320                 ; source pixels in the window
WIN_X       equ     VID_X0+40           ; both layers: 640 x 512 at
WIN_Y       equ     VID_Y0+32           ; picture position (40, 32)

; layer 0: the foreground
FRONT       equ     $060000
FG_W        equ     320
FG_H        equ     256
FG_PL       equ     3
FG_ROW      equ     FG_W/8
FG_PLANE    equ     FG_ROW*FG_H         ; 10240 bytes per plane

scroll_x    equ     $008000             ; word: layer 1's scroll position
scroll_d    equ     $008002             ; word: +1 or -1

start:      move.w  #$2700,sr
            lea     CUSTOM,a4
            lea     SYSTEM,a5
            bsr     draw_back
            bsr     draw_front
            move.w  #0,scroll_x
            move.w  #1,scroll_d

            move.l  #0,L2+L_CTRL(a4)    ; layer 2 off

            ; layer 1: behind, solid, 2x by 2x
            lea     L1(a4),a0
            move.l  #(WIN_X<<16)|(WIN_X+640),L_WINX(a0)
            move.l  #(WIN_Y<<16)|(WIN_Y+512),L_WINY(a0)
            move.l  #BK_STRIDE,L_BPLSTRIDE(a0)  ; 320
            moveq   #0,d0
            moveq   #0,d1
            bsr     scroll_back
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((BK_PL-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(2<<L_CTRL_PALOFS_B),L_CTRL(a0)

            ; layer 0: in front, colour 0 transparent, 2x by 2x
            lea     L0(a4),a0
            move.l  #(WIN_X<<16)|(WIN_X+640),L_WINX(a0)
            move.l  #(WIN_Y<<16)|(WIN_Y+512),L_WINY(a0)
            move.l  #0,L_SCROLLX(a0)
            move.l  #FG_ROW,L_BPLSTRIDE(a0)     ; 40
            bsr     front_ptrs
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|((FG_PL-1)<<L_CTRL_PLANES_B)|L_CTRL_TRANSP_M|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(1<<L_CTRL_PALOFS_B),L_CTRL(a0)

            ; layer 0 in front, then layer 1; layer 2 in no slot (3)
            move.l  #(3<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B),PRIO(a4)

            ; colours 16-23 of layer 0's palette, 32-47 of layer 1's
            lea     fg_colours(pc),a1
            lea     PALETTE0+16*4(a4),a2
            moveq   #8-1,d0
.c0:        move.l  (a1)+,(a2)+
            dbra    d0,.c0
            lea     bk_colours(pc),a1
            lea     PALETTE1+32*4(a4),a2
            moveq   #16-1,d0
.c1:        move.l  (a1)+,(a2)+
            dbra    d0,.c1
            move.l  #$000000,BGCOLOR(a4)

            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            move.l  #VIDINTEN_VBLANK_M,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)  ; set/clear: other sources untouched
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)
            move.w  #$2000,sr

main:       ; (your program's main loop goes here)
            bra.s   main

; Point layer 1 (a0) at the background from (d0.w, d1.w), in source pixels.
; 0 <= d0 <= BK_W - VIEW_W. Pointers are live, so call this in the
; vertical blank.
scroll_back:
            movem.l d0-d2/a1,-(sp)
            moveq   #15,d2
            and.w   d0,d2
            move.w  d2,L_SCROLLX+2(a0)  ; fine: x mod 16 (16-bit register, low half)
            moveq   #0,d2
            move.w  d0,d2
            lsr.w   #4,d2
            add.l   d2,d2               ; coarse: whole words, in bytes
            mulu    #BK_STRIDE,d1       ; y lines down
            add.l   d2,d1
            add.l   #BACK,d1            ; d1 = plane 0's first word
            lea     L_BPL0PT(a0),a1
            moveq   #BK_PL-1,d2
.pt:        move.l  d1,(a1)+            ; BPLpPT (MOVE.L: high half first)
            add.l   #BK_ROW,d1          ; the next plane's line
            dbra    d2,.pt
            movem.l (sp)+,d0-d2/a1
            rts

; Layer 0's (a0) pointers for the top of the foreground
front_ptrs: move.l  #FRONT+0*FG_PLANE,L_BPL0PT(a0)
            move.l  #FRONT+1*FG_PLANE,L_BPL1PT(a0)
            move.l  #FRONT+2*FG_PLANE,L_BPL2PT(a0)
            rts

; Vertical blank: reset both layers' pointers; move layer 1 on a pixel
vblank:     movem.l d0-d1/a0,-(sp)
            lea     CUSTOM,a0
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a0)
            lea     L0(a0),a0
            bsr.s   front_ptrs
            lea     L1-L0(a0),a0
            move.w  scroll_x,d0
            add.w   scroll_d,d0
            beq.s   .turn               ; at the left edge
            cmp.w   #BK_W-VIEW_W,d0
            bne.s   .go                 ; not yet at the right edge
.turn:      neg.w   scroll_d
.go:        move.w  d0,scroll_x
            moveq   #0,d1
            bsr     scroll_back
            movem.l (sp)+,d0-d1/a0
            rte

; Background: squares of 16 x 16, colour (x/16 + y/16) and 15
draw_back:  lea     BACK,a0
            moveq   #0,d3               ; line
.line:      moveq   #0,d4               ; plane
.plane:     move.w  d3,d2
            lsr.w   #4,d2
            moveq   #BK_ROW/2-1,d1
.word:      moveq   #0,d0
            btst    d4,d2
            beq.s   .put
            moveq   #-1,d0
.put:       move.w  d0,(a0)+
            addq.w  #1,d2
            dbra    d1,.word
            addq.w  #1,d4
            cmp.w   #BK_PL,d4
            bne.s   .plane
            addq.w  #1,d3
            cmp.w   #BK_H,d3
            bne.s   .line
            rts

; Foreground: clear, then a band across lines 96-143 in colours 1-7
draw_front: lea     FRONT,a0
            move.w  #FG_PL*FG_PLANE/4-1,d0
.clr:       move.l  #0,(a0)+
            dbra    d0,.clr
            moveq   #0,d4               ; plane
.plane:     lea     FRONT+96*FG_ROW,a0
            move.l  d4,d0
            mulu    #FG_PLANE,d0
            add.l   d0,a0
            move.w  #48*FG_ROW/2-1,d1
            moveq   #0,d2               ; word number
.word:      move.w  d2,d3
            and.w   #7,d3               ; colour of this word (0: a hole)
            moveq   #0,d0
            btst    d4,d3
            beq.s   .put
            moveq   #-1,d0
.put:       move.w  d0,(a0)+
            addq.w  #1,d2
            dbra    d1,.word
            addq.w  #1,d4
            cmp.w   #FG_PL,d4
            bne.s   .plane
            rts

fg_colours: dc.l    $000000,$FF4040,$40FF40,$4040FF,$FFFF40,$40FFFF,$FF40FF,$FFFFFF
bk_colours: dc.l    $101010,$202020,$303030,$404040,$505050,$606060,$707070,$808080
            dc.l    $000060,$000070,$000080,$000090,$0000A0,$0000B0,$0000C0,$0000D0
```

### Summary: priority and transparency

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| PRIO | `$01C` | RW | FRONT (1–0), MIDDLE (3–2), BACK (5–4): layer numbers, front to back; 3 = none |
| BGCOLOR | `$018` | RW | RGB (23–0): colour where no layer has a pixel |
| CTRL.TRANSP | Ln + `$00`, bit 4 | RW | 1: pixel value 0 is transparent |

---

## Colour Registers and Palette Offsets

### The palettes

There are four palettes, each of 256 entries of 24-bit colour: one for each layer and one for the sprites. A layer takes its colours from its own palette only, so three 8-bit layers can show 765 different colours at once, plus the background. They are memory-mapped in the custom block:

| Palette | Used by | Address |
|---------|---------|---------|
| PALETTE0 | Layer 0 | `$E04000`–`$E043FF` |
| PALETTE1 | Layer 1 | `$E04400`–`$E047FF` |
| PALETTE2 | Layer 2 | `$E04800`–`$E04BFF` |
| SPRPALETTE | The sprites (Chapter 4) | `$E04C00`–`$E04FFF` |

Entry n of a palette is the long word at its address + n × 4, holding `$00RRGGBB`. The top byte reads as 0; write it as 0. After reset the palettes hold nothing useful: set every colour you use.

```asm
        move.l  #$FF8000,PALETTE1+5*4(a4)       ; layer 1's colour 5 = orange
```

You can read and write any entry at any time. A write takes effect from the next pixel, so you can change colours in the middle of a line; there is no need to wait for the vertical blank, although changing a colour while it is on screen shows the change from that point on. Write each entry with one `MOVE.L` so the colour never shows half-changed.

### Which entries a layer uses

The pixel value from a layer is turned into a palette index:

| Layer depth | Palette index |
|-------------|---------------|
| Up to 4 bits (chunky 1, 2 or 4 bpp; planar 1–4 planes) | PALOFS × 16 + pixel value |
| More than 4 bits (chunky 8 bpp; planar 5–8 planes) | Pixel value; PALOFS is ignored |

CTRL.PALOFS (bits 15–12) picks one of 16 blocks of 16 colours. So up to 16 shallow layers' worth of colour sets can sit in the palette at once, and you can switch a layer's colours with one write to its CTRL: for example, a darker set for a "paused" screen, or a different set for each band of a split screen.

```
 palette:  0     16    32    48          240   255
           +-----+-----+-----+--- ... ---+-----+
           |blk 0|blk 1|blk 2|           |blk15|
           +-----+-----+-----+--- ... ---+-----+
              ^     ^     ^
              |     |     +-- layer 1: 4 planes, PALOFS 2: colours 32-47
              |     +-------- layer 0: 3 planes, PALOFS 1: colours 16-23
              +-------------- layer 2: chunky 1 bpp, PALOFS 0: colours 0-1

      an 8 bpp or 5-8 plane layer uses all 256 entries directly

                Figure 3-10: Palette Offsets
```

Each layer picks its block from its own palette, so the layers in the figure could all use PALOFS 0 without clashing; it shows the blocks only.

### One palette for everything (SHAREPAL)

With **VIDCON.SHAREPAL** (bit 5) set, every layer and every sprite takes its colours from PALETTE0, as on a machine with one palette; PALETTE1, PALETTE2 and SPRPALETTE are then not used. One write then changes a colour everywhere it shows, for example copper colour bars that should run through all three layers. The layers then share PALETTE0's 256 entries: a deep layer and shallow layers clash unless you keep them apart, for example a 32-colour layer (5 planes, entries 0–31) with a 16-colour layer at PALOFS 2 or more.

### The background colour

BGCOLOR (`$RRGGBB` in bits 23–0) is not part of the palette. It shows wherever no layer has a pixel. It is read at the start of each line, so writing it partway down the screen changes it from the next line on, which makes it easy to draw colour bars (Example 3-10). As on the Amiga, writing the background colour is a quick way to show progress during start-up.

**VIDCON.BLANKALL** shows the background colour over the whole screen, hiding every layer, without stopping them.

### Summary: colours

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| PALETTE0–2 | `$4000`, `$4400`, `$4800` | RW | Layers 0–2's palettes, each 256 × `$00RRGGBB`; takes effect at the next pixel |
| SPRPALETTE | `$4C00` | RW | The sprites' palette, 256 × `$00RRGGBB` |
| VIDCON.SHAREPAL | `$000`, bit 5 | RW | 1: every layer and sprite uses PALETTE0 |
| BGCOLOR | `$018` | RW | Background colour `$RRGGBB`; read at the start of each line |
| CTRL.PALOFS | Ln + `$00`, bits 15–12 | RW | Colour block for layers of up to 4 bits per pixel |
| VIDCON.BLANKALL | `$000`, bit 2 | RW | 1: show only the background colour |

---

## Direct Colour

In **direct colour**, set by VIDCON.DIRECT, the three layers together make one picture with the colour in each pixel, instead of an index into the palette. Each layer gives one channel:

| Channel | From | Depth |
|---------|------|-------|
| Red | Layer 0 | Its number of planes (planar), or bits per pixel (chunky) |
| Green | Layer 1 | The same |
| Blue | Layer 2 | The same |

Each channel's value is widened to 8 bits by repeating its bits, so that full scale stays full scale: a 5-bit value `abcde` becomes `abcdeabc`, and a 4-bit value `abcd` becomes `abcdabcd`. The one rule covers many formats:

| Colour | L0 | L1 | L2 | Bits per pixel | Bandwidth at 2× across |
|--------|----|----|----|----------------|------------------------|
| 24-bit (8/8/8) | 8 bpp or 8 planes | 8 bpp or 8 planes | 8 bpp or 8 planes | 24 | 1.5 bytes per pixel: just over the budget; 0.75 at 4× across |
| 21-bit (7/7/7) | 7 planes | 7 planes | 7 planes | 21 | 1.31 |
| 16-bit (5/6/5) | 5 planes | 6 planes | 5 planes | 16 | 1.0 |
| 12-bit (4/4/4), as the Amiga's colour registers | 4 bpp or 4 planes | 4 bpp or 4 planes | 4 bpp or 4 planes | 12 | 0.75 |
| 9-bit (3/3/3) | 3 planes | 3 planes | 3 planes | 9 | 0.56 |

In direct colour the palette, PRIO, PALOFS and TRANSP are not used, and nor is the background colour, except with BLANKALL. **Set the three layers to the same window, scroll and scale**, since each pixel is made from the same position in all three. Where a layer has no pixel (outside its window, turned off, or out of data), its channel is 0. So outside the windows the screen is black, and a layer with a smaller window leaves that channel at 0 outside it.

With chunky layers, 24-bit and 12-bit colour are easy for the CPU: each pixel is one byte (or nibble) in each of three buffers. A 16-bit 5/6/5 screen needs planar layers, since chunky depths are only 1, 2, 4 or 8.

### Example 3-8: A 24-bit screen

24-bit colour at 2× across needs 1.5 bytes per pixel, just over the display's budget of 1.48 (see "The Fetch Budget"). A narrower window does not help, because the budget counts at every point across the screen, not over the whole line. There are two ways to fit: keep 2× across and drop to 21-bit colour (7/7/7, three 7-plane layers, 1.31 bytes per pixel), or keep 24 bits and show each source pixel 4× across (0.75 bytes per pixel). This example takes the second way, because chunky 8 bpp layers are the easiest for the CPU to draw: one byte per channel per pixel.

So the example uses three chunky 8 bpp layers of 160 × 256, shown 4× across and 2× down in the 640 × 512 window of Example 3-1. Each pixel is twice as wide as it is tall, which suits smooth pictures such as gradients and photographs. The picture is a gradient: red rises from left to right and green from top to bottom, with blue at half.

```asm
; Example 3-8: a 24-bit direct-colour screen. Three chunky 8 bpp layers of
; 160 x 256, shown 4x across and 2x down as a 640 x 512 window at
; picture position (40, 32): layer 0 is red, layer 1 green, layer 2 blue.
; Bandwidth: 3 x 8 bits / 8 / 4 = 0.75 bytes per pixel. (At 2x across it
; would be 1.5, just over the budget of 1.48.)
; Assumes supervisor mode and the vector table in Chip RAM at 0.

            include "hw.inc"

VECTORS     equ     $000000
WIDTH       equ     160
HEIGHT      equ     256
WIN_X       equ     VID_X0+40           ; picture position (40, 32)
WIN_Y       equ     VID_Y0+32
RED         equ     $040000             ; 40960 bytes each
GREEN       equ     $050000
BLUE        equ     $060000
CTRL_8BPP   equ     L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(2<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)

start:      move.w  #$2700,sr
            lea     CUSTOM,a4
            lea     SYSTEM,a5
            bsr     draw
            lea     L0(a4),a0           ; the same window, scroll and scale for all three
            moveq   #3-1,d0
.layer:     move.l  #(WIN_X<<16)|(WIN_X+4*WIDTH),L_WINX(a0)
            move.l  #(WIN_Y<<16)|(WIN_Y+2*HEIGHT),L_WINY(a0)
            move.l  #0,L_SCROLLX(a0)
            move.l  #WIDTH,L_BPLSTRIDE(a0)      ; 160 bytes per line
            move.l  #CTRL_8BPP,L_CTRL(a0)
            lea     L_SPAN(a0),a0       ; the next layer
            dbra    d0,.layer
            bsr     setptrs
            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            move.l  #VIDINTEN_VBLANK_M,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)  ; set/clear: other sources untouched
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M|VIDCON_DIRECT_M,VIDCON(a4)
            move.w  #$2000,sr

main:       ; (your program's main loop goes here)
            bra.s   main

setptrs:    move.l  #RED,CUSTOM+L0_BPL0PT
            move.l  #GREEN,CUSTOM+L1_BPL0PT
            move.l  #BLUE,CUSTOM+L2_BPL0PT
            rts

vblank:     move.l  #VIDSTAT_VBLANK_M,CUSTOM+VIDSTAT
            bsr.s   setptrs
            rte

; Red rises from left to right, green from top to bottom; blue is half on
draw:       lea     RED,a0              ; red: line 0 ...
            moveq   #0,d0
.r0:        move.w  d0,d1
            mulu    #51,d1
            lsr.l   #5,d1               ; 0-253 across 160 pixels
            move.b  d1,(a0)+
            addq.w  #1,d0
            cmp.w   #WIDTH,d0
            bne.s   .r0
            lea     RED,a1              ; ... copied down to the other lines
            move.w  #(HEIGHT-1)*WIDTH/4-1,d0
.r1:        move.l  (a1)+,(a0)+
            dbra    d0,.r1
            lea     GREEN,a0            ; green: every byte of line y is y
            moveq   #0,d2
.g0:        move.l  d2,d1
            mulu    #$0101,d1
            move.w  d1,d3
            swap    d1
            move.w  d3,d1               ; four copies of y
            moveq   #WIDTH/4-1,d0
.g1:        move.l  d1,(a0)+
            dbra    d0,.g1
            addq.w  #1,d2
            cmp.w   #HEIGHT,d2
            bne.s   .g0
            lea     BLUE,a0             ; blue: $80 everywhere
            move.l  #$80808080,d1
            move.w  #HEIGHT*WIDTH/4-1,d0
.b0:        move.l  d1,(a0)+
            dbra    d0,.b0
            rts
```

A 16-bit 5/6/5 screen at 2× across (1.0 bytes per pixel) is set up the same way with planar layers. Only the CTRL values and the pointers change:

```asm
; 16-bit colour, 320 x 256 at 2x by 2x: red 5 planes, green 6, blue 5
CTRL_565_R  equ     L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
CTRL_565_G  equ     L_CTRL_EN_M|L_CTRL_PLANAR_M|(5<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
CTRL_565_B  equ     CTRL_565_R

            move.l  #CTRL_565_R,L0+L_CTRL(a4)   ; 5 pointers, BPL0PT-BPL4PT
            move.l  #CTRL_565_G,L1+L_CTRL(a4)   ; 6 pointers, BPL0PT-BPL5PT
            move.l  #CTRL_565_B,L2+L_CTRL(a4)   ; 5 pointers, BPL0PT-BPL4PT
```

Plane 0 of each layer holds the channel's lowest bit.

### Summary: direct colour

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| VIDCON.DIRECT | `$000`, bit 4 | RW | 1: direct colour, L0 red, L1 green, L2 blue; takes effect at the next pixel |

---

## The Fetch Budget

### How the display fetches

Each layer has eight 16-bit data registers, BPL0DAT–BPL7DAT, and eight 16-bit shift registers. There is no other storage: the data registers hold the layer's **next group** of 16 source pixels, while the shift registers show the current group. A planar group is one word per plane (plane p in BPLpDAT); a chunky group is b consecutive words for b bits per pixel, the first in BPL(b−1)DAT and the last in BPL0DAT. Either way every layer is a whole 16 pixels ahead.

- At the start of each line's horizontal blank (beam pixel 0), each layer whose window covers the line starts fetching. The DMA fills a group's data registers from the highest down, BPL0DAT last; the group is complete when BPL0DAT is written.
- The shift registers take the line's first group as soon as it is complete, in the horizontal blank. That empties the data registers, so the DMA fetches the second group straight away, and it is already waiting when the window starts. (The Amiga fetches ahead of its display window in the same way.)
- After that, each time the shifters use up a group (every 16 source pixels), they take the next one from the data registers at once, and the DMA fetches another.
- The layers that want a word take turns, one word each, so no layer waits for more than one word from each of the others.

So each layer is always one group ahead, and the display reads memory at the rate it shows it. The display has **memory cycles 1 and 3 of every 100 ns slot**: 4 bytes every 100 ns, or 40 MB/s. These are its own cycles. It also uses any cycle nobody else wants, and, as on the Amiga, a fetch about to be late takes the CPU's cycle 0: the CPU then waits one slot. Screens within the budget below rarely need that; a screen a little over it (up to 1.5 bytes per pixel, measured) still shows correctly, at the CPU's expense.

### The budget

Because data is fetched while it is shown, the limit is a **rate**: bytes per screen pixel that the beam passes, counting the blanking. A line is 864 pixels (720 visible and 144 of blanking) and lasts 32 µs, which is exactly 320 memory slots:

| Bytes per line | Pixels per line | Budget |
|----------------|-----------------|--------|
| 320 slots × 4 = 1280 | 864 | **1.48 bytes per pixel** |

Put another way: the display has 4 bytes every 100 ns, and a pixel lasts 37 ns.

A layer needs:

```
   bytes per screen pixel  =  bits per pixel ÷ 8 ÷ horizontal scale
```

where, for a planar layer, bits per pixel is the number of planes. Vertical scaling does not reduce it. **At every point across the screen, the layers whose windows cover that point must add up to no more than the budget.**

### Worked examples

**A 5-plane 320 × 256 picture at 1×** (the Amiga's 32-colour lores screen, but here with 1× pixels): 5 ÷ 8 ÷ 1 = 0.625. Fits.

**The boot ROM's screen**: the console, 1 bpp at 1× (0.125), with the 4-plane picture at 2× on top (4 ÷ 8 ÷ 2 = 0.25) on some lines: 0.375 where they overlap.

**Dual playfields, Example 3-7**: 3 planes at 2× (0.1875) + 4 planes at 2× (0.25) = 0.4375. Fits, with room for a third layer.

**A 256-colour game screen with an overlay**: an 8 bpp layer at 1× (1.0) and a 4 bpp layer at 1× over it (0.5) = 1.5. Just over the budget. Show the overlay at 2× (0.25, total 1.25: fits), or give it fewer colours (3 planes at 1×: 0.375, total 1.375: fits), or move it to a band of its own.

**Two full-width 8 bpp layers at 1×**: 2.0. Too much. Show one of them at 2× (1.0 + 0.5 = 1.5): still just over. Show both at 2× (0.5 + 0.5 = 1.0), or one at 4× (1.0 + 0.25 = 1.25): fits.

**Three 64-colour playfields**: 6 planes + 6 planes + 8 planes, all at 2×: 0.375 + 0.375 + 0.5 = 1.25. Fits.

**24-bit direct colour**: three 8 bpp layers at 2× = 3 × 0.5 = 1.5, just over. At 4× across, as in Example 3-8: 0.75, fits. **21-bit 7/7/7 at 2×**: 21 ÷ 8 ÷ 2 = 1.31, fits. **16-bit 5/6/5 at 2×**: 16 ÷ 8 ÷ 2 = 1.0, fits.

| Screen | Bytes per pixel | Fits? |
|--------|-----------------|-------|
| One 8 bpp layer at 1× | 1.0 | Yes |
| 5 planes at 1× | 0.625 | Yes |
| 5 planes + 3 planes, both at 2× | 0.5 | Yes |
| 6 + 6 + 8 planes, all at 2× | 1.25 | Yes |
| 8 bpp at 1× + 4 bpp at 2× | 1.25 | Yes |
| 8 bpp at 1× + 4 bpp at 1× | 1.5 | **No** (just over) |
| 16-bit direct colour at 2× | 1.0 | Yes |
| 21-bit direct colour at 2× | 1.31 | Yes |
| 24-bit direct colour at 4× across | 0.75 | Yes |
| 24-bit direct colour at 2× | 1.5 | **No** (just over) |
| Two 8 bpp layers at 1× | 2.0 | **No** |

### Using the windows

The budget applies point by point, so layers that do not overlap do not add up. A status panel **below** a game area adds nothing on the game's lines, and a narrow layer down the side of the screen counts only where it is. When you design a screen, add up the layers line by line, and across each line where windows start and stop.

Fine scroll adds one word per plane per line, which is too little to matter. The fetch for each line starts at the start of its horizontal blank, so the first two groups of a window at the left edge are fetched during the blank and cost nothing in the visible part.

Each layer has one group of time in hand (its data registers). Close to the budget, very deep layers at 1× (8 planes or 8 bpp) are the first to run short.

### When a layer runs short

If a layer's next group is not complete when its shifters need it, the layer shows transparent pixels (in direct colour, 0) for those 16 source pixels and tries again at the next group. It also sets its **OVERRUN** flag in VIDSTAT (bit 4 for L0, 5 for L1, 6 for L2), which can raise the VIDERR interrupt. Nothing else on the screen goes wrong, and the CPU is never affected. A screen that fits the budget never overruns, so OVERRUN is mainly a check while you develop: run your screen for a frame, then test the flags.

```asm
        move.l  #VIDSTAT_OVERRUN_M,VIDSTAT(a4)  ; clear the flags
        ; ... wait for a frame or two ...
        move.l  VIDSTAT(a4),d0
        and.l   #VIDSTAT_OVERRUN_M,d0
        bne     too_much                ; a layer ran short
```

---

## Feeding the Data Registers from the CPU

The data registers BPL0DAT–BPL7DAT can be written by the CPU (and later the copper), just as the DMA writes them. You can feed a whole layer this way, or just some of its planes.

### A whole layer

For a layer with no DMA, a write of **BPL0DAT completes the group**, exactly as the DMA's last word does. So write the higher data registers first and BPL0DAT last: for a planar layer, one word per plane; for a chunky layer of b bits per pixel, the group's b words from BPL(b−1)DAT (leftmost pixels) down to BPL0DAT. A 1 bpp chunky layer, like a 1-plane layer, needs BPL0DAT only.

With bitplane DMA off (DMACON.BPLEN clear, or a layer's BPLDMA all clear), a layer that is enabled in CTRL shows only what the CPU writes to its data registers. This is how you can make patterns that need no memory at all, or test the display. BPLEN is shared by all three layers: while it is off, none of them fetches. To stop one layer's DMA only, clear all its bits in BPLDMA.

The timing follows the fetch rules in "How the display fetches":

- At the start of each line's horizontal blank (beam pixel 0) the hardware throws away any group still waiting in the data registers. **Write the line's first group after the horizontal blank has started.**
- The first group goes straight into the shifters (once the blank has started), which empties the data registers again; a second group written before the window starts waits there.
- Any further group must be written within 16 source pixels of the previous one being taken. That is short for the CPU, so in practice the CPU feeds windows of one or two groups: 16 or 32 source pixels, which scaling can stretch to 128 or 256 screen pixels.
- If a group is missing when it is needed, the layer is transparent for it and OVERRUN is set, as usual.

### Example 3-9: A layer fed by the CPU

The CPU waits for each horizontal blank and writes two groups into layer 0, a 1-plane layer 32 source pixels wide, shown 8× across. The pattern turns one pixel each line, drawing stripes. This uses the whole CPU, with interrupts off.

```asm
; Example 3-9: feeding a layer from the CPU. Bitplane DMA is off; in each
; horizontal blank the CPU writes layer 0's BPL0DAT twice: the first group
; goes straight into the shifters, the second waits in BPL0DAT. The layer
; is 32 source pixels wide (two groups), shown 8x across.

            include "hw.inc"

start:      move.w  #$2700,sr
            lea     CUSTOM,a4
            move.w  #DMACON_BPLEN_M,DMACON+2(a4)    ; bit 15 clear: BPLEN off
            move.l  #0,L1+L_CTRL(a4)
            move.l  #0,L2+L_CTRL(a4)
            move.l  #$000040,BGCOLOR(a4)
            move.l  #$202020,PALETTE0+0*4(a4)
            move.l  #$FFC000,PALETTE0+1*4(a4)
            lea     L0(a4),a0
            move.l  #((VID_X0+232)<<16)|(VID_X0+232+32*8),L_WINX(a0)   ; 256 screen pixels, centred
            move.l  #(VID_Y0<<16)|(VID_Y0+VID_H),L_WINY(a0)            ; every line
            move.l  #0,L_SCROLLX(a0)
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|(0<<L_CTRL_PLANES_B)|(3<<L_CTRL_HSCALE_B),L_CTRL(a0)
            move.l  #VIDCON_EN_M,VIDCON(a4)

main:       moveq   #16,d2              ; d2 = a little way into the blank (0-143)
            move.w  #$FF00,d3           ; the pattern
.visible:   move.w  BEAMPOS+2(a4),d0    ; low half: hpixel
            and.w   #BEAMPOS_HPIXEL_M,d0
            cmp.w   d2,d0
            bhs.s   .visible            ; wait for the start of a line
.blank:     move.w  BEAMPOS+2(a4),d0
            and.w   #BEAMPOS_HPIXEL_M,d0
            cmp.w   d2,d0
            blo.s   .blank              ; wait until d2 pixels into its blank
            move.w  d3,L0+L_BPL0DAT+2(a4)   ; group 1: into the shifters
            move.w  d3,d0
            not.w   d0
            move.w  d0,L0+L_BPL0DAT+2(a4)   ; group 2: waits in BPL0DAT
            ror.w   #1,d3               ; the next line's pattern
            bra.s   .visible
```

The data registers can also be read back, which is occasionally useful when debugging.

### One plane at a time: BPLDMA

Each layer's **BPLDMA** register turns DMA on and off **plane by plane** (bits 7–0 for planes 0–7). Like DMACON it is a set/clear register: write it with bit 15 set to turn the planes written as 1 on, with bit 15 clear to turn them off. All planes are on after reset. For a chunky layer, bit 0 turns the whole layer's DMA on or off.

A plane with its DMA off is not fetched and its pointer does not move. Its data register keeps whatever you last wrote, and the shifters take it again with every group. So a plane can show a constant 16-pixel pattern that costs no memory cycles at all, while the other planes come from memory as usual. Writing the data register changes the pattern from the next group, which lets the copper change it line by line. The DMA still completes each group itself, when it has fetched its last enabled plane; your writes to a DMA-off plane never complete a group.

This is the Amiga trick of setting more planes than are fetched, with more control: any plane can be the one left out.

```asm
; Layer 1: a 4-plane picture by DMA, plus a fifth plane fed with a constant
; pattern, so every second group of 8 pixels uses colours 16-31 instead
; of 0-15. Plane 4 costs no memory cycles. a4 = CUSTOM.
            include "hw.inc"
            lea     L1(a4),a0
            move.w  #1<<4,L_BPLDMA+2(a0)        ; SET/CLR clear: plane 4's DMA off
            move.w  #$FF00,L_BPL4DAT+2(a0)      ; 8 pixels set, 8 clear, every group
            move.l  #L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B),L_CTRL(a0)  ; 5 planes
```

To give plane 4 back to the DMA, set its bit again with bit 15 set, and point BPL4PT at its data:

```asm
            move.w  #L_BPLDMA_SETCLR_M|(1<<4),L_BPLDMA+2(a0)
```

### Summary: data registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| BPL0DAT–BPL7DAT | Ln + `$40`–`$5C` | RW | Plane data, 16 bits in the low half; for a layer with no DMA, writing BPL0DAT completes the group. A DMA-off plane shows its value every group |
| BPLDMA | Ln + `$14` | Set/clear | SETCLR (15), PLANES (7–0): DMA on per plane (chunky: bit 0). All on after reset |

---

## Video Interrupts and the Beam Position

### The beam position

BEAMPOS holds the beam's position in beam coordinates: the line, `vline`, in bits 26–16 and the pixel, `hpixel`, in bits 10–0, both counting from 0 at the start of the blanking (see "Beam coordinates" in "The Screen"). The picture is lines 49–624 and pixels 144–863. Read it with `MOVE.L`: reading the high half captures both, so the line and pixel always match. If you need only the pixel, a `MOVE.W` of the low half (BEAMPOS + 2) is enough.

While the beam is in the vertical blank, `vline` is less than VID_Y0 (49), and VIDSTAT.INVBLANK (bit 8) reads 1. FRAMECOUNT counts frames: it goes up by one at the start of each frame (beam line 0, pixel 0, the start of the vertical blank) and wraps at 65536.

```asm
; Wait until the beam reaches beam line d0.w (VID_Y0 = the first picture line)
wait_line:  move.l  d1,-(sp)
.w:         move.l  BEAMPOS(a4),d1      ; one read: vline and hpixel match
            swap    d1
            and.w   #BEAMPOS_VLINE_M>>16,d1
            cmp.w   d0,d1
            bne.s   .w
            move.l  (sp)+,d1
            rts
```

### Example 3-10: Colour bars

The background colour is read at the start of each line, so a write during beam line L − 1 changes line L. This loop changes it every 8 lines from a table, which makes colour bars behind (or instead of) the layers, as Amiga programs do with the copper. It runs with interrupts off, one frame per pass.

```asm
; Example 3-10: colour bars. Changes BGCOLOR every 8 lines from a table of
; 72 colours (576 lines). Uses wait_line, above.
bars:       lea     CUSTOM,a4
.frame:     lea     bar_colours+4(pc),a1
            moveq   #VID_Y0+7,d0        ; write during picture line 7 for line 8, ...
.bar:       bsr     wait_line
            move.l  (a1)+,BGCOLOR(a4)
            addq.w  #8,d0
            cmp.w   #VID_Y0+VID_H-8,d0
            blo.s   .bar                ; ... up to picture line 567 for line 568
            moveq   #0,d0
            bsr     wait_line           ; the start of the frame: the vertical blank
            move.l  bar_colours(pc),BGCOLOR(a4)     ; picture line 0's colour
            bra.s   .frame

bar_colours:
            rept    72
            dc.l    ((REPTN*3)<<16)|(255-REPTN*3)
            endr
```

### Video interrupts

The video unit raises three interrupt sources in the interrupt controller:

| Flag (VIDSTAT bit) | Source | When |
|--------------------|--------|------|
| VBLANK (0) | VBLANK, source 0 | Start of the frame, the start of the vertical blank: beam line 0, pixel 0 |
| LINE (1) | LINE, source 1 | Start of beam line LINECMP, pixel 0: the start of its horizontal blank, 144 pixels before its picture |
| OVERRUN (4, 5, 6 for L0, L1, L2) | VIDERR, source 3 | A layer's group was not ready in time |

Each flag is **sticky**: it is set by the event and stays set until you write 1 to it in VIDSTAT. It raises its interrupt only if its bit in **VIDINTEN** is set (VIDINTEN has the same layout as VIDSTAT). From there the request goes through the interrupt controller: the source must also be enabled in INTENA, with INTCON.MASTER on, and the CPU's interrupt mask must be below the source's level (5 by default for all three). The vector is VECBASE + the source number, so with the default VECBASE of 64, VBLANK uses vector 64, LINE 65 and VIDERR 67. The Interrupts and Timers chapter explains this path in full.

To set up an interrupt:

```asm
        move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4
        move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)       ; clear an old flag
        move.l  #VIDINTEN_VBLANK_M,VIDINTEN(a4)     ; the video unit may ask
        move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)  ; set/clear: other sources untouched
        move.l  #INTCON_MASTER_M,INTCON(a5)
        move.w  #$2000,sr                           ; the CPU takes it
```

The handler must clear the flag before it returns, by writing 1 to it, or the interrupt comes straight back:

```asm
vblank:     move.l  #VIDSTAT_VBLANK_M,CUSTOM+VIDSTAT
            ; ... the frame's work ...
            rte
```

You can also poll the flags with interrupts off, as the boot ROM's video test does: wait for VIDSTAT.VBLANK to be set, then clear it.

```asm
.frame:     move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_VBLANK_M,d0
            beq.s   .frame                  ; not yet
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
```

**LINE** comes once per frame, at the start of the beam line in LINECMP (bits 26–16): pixel 0, the start of that line's horizontal blank, 144 pixels (5.3 µs) before its picture. For picture line L, write VID_Y0 + L. To have it on several lines, write the next line number into LINECMP in the handler. The 68000 takes from about 2 µs to about 10 µs to start a handler, depending on the instruction it is in the middle of, so a LINE handler runs during the line it was asked for (32 µs); that is enough to change CTRL, WINX, WINY, SCROLLX, PRIO or BGCOLOR for the **next** line, or BPLSTRIDE for the end of this one.

### Summary: interrupts and the beam

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| VIDSTAT | `$004` | W1C (INVBLANK R) | VBLANK (0), LINE (1), OVERRUN L0–L2 (4–6): sticky flags; INVBLANK (8): the beam is in the vertical blank (beam line < 49) |
| VIDINTEN | `$008` | RW | Interrupt enables, as VIDSTAT bits 0–6 |
| BEAMPOS | `$00C` | R | `vline` (26–16), `hpixel` (10–0), beam coordinates |
| FRAMECOUNT | `$010` | R | Frame counter (15–0), up at the start of each frame |
| LINECMP | `$014` | RW | Beam line (26–16) for the LINE interrupt |

---

## When Register Writes Take Effect

| Registers | Take effect |
|-----------|-------------|
| CTRL.EN, VSCALE, WINX, WINY, SCROLLX | At the start of each line's horizontal blank (beam pixel 0), before its picture. To change line L, write during the visible part of line L − 1 or earlier |
| CTRL.BPP, PLANAR, PLANES, HSCALE | From the layer's next group fetched (16–32 source pixels after the beam) |
| CTRL.TRANSP, PALOFS | At once (the next pixel) |
| BPLxPT, BPLSTRIDE | At once: they are live. The next word fetched uses the new pointer; BPLSTRIDE is used at the end of the line, when the pointers move on to the next line. A CPU write to a pointer wins over the DMA's own change in the same clock, and also sets the pointer's saved line start |
| BPLxDAT | At once; a write of BPL0DAT completes the group |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144), so a write in the line's horizontal blank still changes it |
| VIDCON.DIRECT, VIDCON.BLANKALL, palette | At once (the next pixel) |

---

## Summary of Playfield Registers

All offsets are from CUSTOM (`$E00000`). Layer n's registers are at Ln + offset, where L0 = `$100`, L1 = `$180` and L2 = `$200`; `hw.inc` also gives each one ready-added, as `L0_CTRL`, `L1_BPL0PT` and so on. Access: R read only, RW read and write, W1C sticky flags cleared by writing 1, SC set/clear.

### Global registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| VIDCON | `$000` | RW | EN (0): display on. BLANKALL (2): background colour only. DIRECT (4): direct colour. SHAREPAL (5): everything on PALETTE0 |
| VIDSTAT | `$004` | W1C | VBLANK (0), LINE (1), OVERRUN L0 (4), L1 (5), L2 (6), SPRUNDER (7, sprites); INVBLANK (8, R) |
| VIDINTEN | `$008` | RW | Enables for VIDSTAT bits 0, 1, 4–7 |
| BEAMPOS | `$00C` | R | `vline` (26–16), `hpixel` (10–0), beam coordinates |
| FRAMECOUNT | `$010` | R | Frames (15–0) |
| LINECMP | `$014` | RW | LINE interrupt beam line (26–16) |
| BGCOLOR | `$018` | RW | Background colour, RGB (23–0) |
| PRIO | `$01C` | RW | FRONT (1–0), MIDDLE (3–2), BACK (5–4); 3 = no layer |
| VIDSIZE | `$020` | R | VVISIBLE (26–16), HVISIBLE (10–0) |
| DMACON | `$094` | SC | BPLEN (8), DMAEN (9): both needed for bitplane DMA; SPREN (5): sprites; SETCLR (15). 16 bits, low half at `$096` |
| PALETTE0–2 | `$4000`–`$4BFF` | RW | Layers 0–2's palettes, each 256 × `$00RRGGBB`, `$400` bytes apart |
| SPRPALETTE | `$4C00`–`$4FFF` | RW | The sprites' palette |

### Layer registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| CTRL | Ln + `$00` | RW | EN (0), PLANAR (1), BPP (3–2), TRANSP (4), HSCALE (7–6), VSCALE (9–8), PALOFS (15–12), PLANES (18–16), WRAP (23–20) |
| WINX | Ln + `$04` | RW | XSTART (26–16), XEND (10–0), beam pixels. Reset: 144, 864 |
| WINY | Ln + `$08` | RW | YSTART (26–16), YEND (10–0), beam lines. Reset: 49, 625 |
| SCROLLX | Ln + `$0C` | RW | Fine scroll, 0–15 source pixels (3–0) |
| BPLSTRIDE | Ln + `$10` | RW | Stride: bytes from one line's start to the next, signed, even (15–0) |
| BPLDMA | Ln + `$14` | Set/clear | SETCLR (15), PLANES (7–0): DMA on per plane; chunky: bit 0. All on after reset |
| BPL0PT–BPL7PT | Ln + `$20`, `$24` … `$3C` | RW | Plane pointers (22–0), even; chunky layers use BPL0PT only |
| BPL0DAT–BPL7DAT | Ln + `$40`, `$44` … `$5C` | RW | Plane data (15–0); writing BPL0DAT completes the group |

### CTRL fields

| Bits | Field | Values |
|------|-------|--------|
| 0 | EN | 1: layer on |
| 1 | PLANAR | 0: chunky, 1: planar |
| 3–2 | BPP | Chunky: 0 = 1 bpp, 1 = 2 bpp, 2 = 4 bpp, 3 = 8 bpp |
| 4 | TRANSP | 1: pixel value 0 is transparent |
| 7–6 | HSCALE | 0–3: 1×, 2×, 4×, 8× across |
| 9–8 | VSCALE | 0–3: 1×, 2×, 4×, 8× down |
| 15–12 | PALOFS | Colour block (index = PALOFS × 16 + pixel) for layers of up to 4 bits |
| 18–16 | PLANES | Planar: planes − 1 (0–7) |
