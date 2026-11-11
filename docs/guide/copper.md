# Chapter 5: Coprocessor Hardware

## Introduction

The **copper** is a small coprocessor that works in step with the video beam. It runs a list of instructions, the **copper list**, from Chip RAM once every frame, and with them it writes the custom registers at the beam positions you choose. It needs no help from the 68000 while it runs.

With a few instructions in its list, the copper can:

- put the plane pointers back to the top of the picture at the start of every frame;
- change colours partway down the screen, on every line, or even in the middle of a line;
- open a split screen, with new plane pointers and a new layer format from a chosen line down;
- turn DMA channels on and off, start blitter jobs, or interrupt the CPU at a chosen line.

Because the copper's writes are tied to the beam, they happen at the same place on the screen in every frame, whatever the CPU is doing at the time. Effects that would take a busy interrupt handler, or would be impossible with one, cost the CPU nothing.

This chapter covers:

- what a copper instruction is, and the instruction formats;
- writing registers with MOVE: 16-bit halves, 32-bit pointers and palette colours;
- waiting for a beam position with WAIT, in beam coordinates;
- the pixel-only WAIT, for effects that repeat on every line;
- loops with SKIP and JUMP;
- the copper's own registers: X and Y, arithmetic and conditions, storage registers, and subroutines;
- the copper's registers, and starting and stopping the copper, step by step;
- the two lists, the jump strobes, and double-buffered lists;
- worked examples: colour bars, a gradient, a split screen, a colour change in the middle of a line, a copper interrupt, and waiting for the blitter;
- copper timing: pixel accuracy, the prefetched instruction, fetch speed and priority;
- what the copper can and cannot reach.

You should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, and the Playfield Hardware chapter, because nearly everything the copper does is to write the registers described there. Interrupts are explained in the Interrupts and Timers chapter.

**Note:** The copper is built in the FPGA design (`fpga/rtl/copper.v`) and tested in simulation (`make -C sim ctest`), but not yet on the board. The examples in this chapter assemble with the macros in `copper.inc`.

### Comparison with the Amiga

If you have written Amiga copper lists, you will feel at home. The instructions are 32 bits each, MOVE, WAIT and SKIP do what they do on the Amiga, list 1 restarts every frame, and COPJMP1 and COPJMP2 work as before. The differences are mostly about range and precision:

| Feature | Amiga (OCS/ECS) | retro68k |
|---------|-----------------|----------|
| Instructions | MOVE, WAIT, SKIP, 32 bits each | The same, plus JUMP and STOP |
| Registers | None: the copper writes constants only | X and Y, with ADD, SUB, AND, OR, CMP and a conditional SKIP; 8 storage registers; CALL and RET |
| MOVE | 16 bits of data to a custom register | The same: 16 bits to one half of a 32-bit register. A pointer takes two MOVEs, high half first |
| Beam position | 8-bit line (wraps after line 255), across in steps of 4 low-resolution pixels | 11-bit line and pixel, **pixel exact**, over the whole frame, in beam coordinates |
| Compare masks | Mask bits in WAIT and SKIP | No masks. A **pixel-only** WAIT ignores the line, so an effect repeats on every line |
| Waiting for the blitter | BFD bit clear: WAIT also waits for the blitter | B bit set: WAIT also waits for the blitter |
| Lists | COP1LC, COP2LC; strobes COPJMP1, COPJMP2; list 1 restarts each frame | The same. List 1 restarts at the start of the frame, beam line 0 (the start of the vertical blank) |
| Jumping | A MOVE to COPJMP2 | JUMP to any address; the strobes still work |
| End of list | WAIT for an impossible position (`$FFFFFFFE`) | STOP, or a WAIT for line 2047 |
| Interrupting the CPU | A MOVE to INTREQ | A MOVE to COPINT |
| Protection | COPCON's CDANG bit guards the low registers | The copper cannot reach the system block at all |
| Speed | One instruction per 8 low-resolution pixels or so | One every 200 ns or better (about 5 pixels); the MOVE after a WAIT is already fetched |

### Conventions in this chapter

- Examples are 68000 assembly language for vasm, in Motorola syntax. They start with `include "hw.inc"` and then `include "copper.inc"`, which gives the copper instruction macros.
- In ordinary code **a4 holds CUSTOM** (`$E00000`) and **a5 holds SYSTEM** (`$F00000`), as in the other chapters.
- In a copper list, a register is named by its **offset in the custom block**, exactly as `hw.inc` gives it: `BGCOLOR`, `L0+L_BPL0PT`, `PALETTE0+5*4`. No base register is involved, because the copper can write only the custom block.
- Copper instructions are written with the macros (`CMOVE`, `CMOVEL`, `CWAIT`, `CWAITP`, `CWAITB`, `CSKIP`, `CSKIPP`, `CJUMP`, `CSTOP`, and those of "The Copper's Registers and Arithmetic"). In the text, the instructions themselves are written MOVE, WAIT and so on.
- Positions in WAIT and SKIP are **beam coordinates** (see "The beam position" below). The examples use `VID_X0` (144) and `VID_Y0` (49) from `hw.inc`, the first picture pixel and line: picture line L is beam line `VID_Y0+L`, and pixel 0 of a line is the start of its horizontal blank. In the text, a line or pixel of the screen ("line 100") is a picture position unless it is called a beam line or beam pixel; WAIT and SKIP operands are always beam positions.

### About this chapter

The chapter follows the order of the Amiga Hardware Reference Manual's copper chapter. First come the instructions: what a copper instruction is, then MOVE, WAIT and the pixel-only WAIT. "The Copper Registers" describes the location, strobe and control registers. "Putting Together a Copper List" and "Starting and Stopping the Copper" build a complete working program, and the next section replaces the vertical blank handler of the playfield chapter with a copper list. The sections after that are the advanced topics: loops and branches, the two lists, double-buffered lists, and a set of worked effects. "Copper Timing" explains exactly when the copper's writes happen and how fast it runs, and "What the Copper Can Reach" sets out its limits. The chapter ends with a summary of the instructions and the registers.

---

## What Is a Copper Instruction?

The copper has nine instructions. Each is **32 bits** (two 16-bit words), at an address in Chip RAM that is a multiple of 4. Bit 31 tells the two kinds apart:

- bit 31 = 0: **MOVE**, which writes a register;
- bit 31 = 1: **WAIT**, **SKIP**, **JUMP** or **STOP**, chosen by bits 30–28; and four more that work with the copper's own registers, **MOVR**, **ALU**, **SKIPC** and **CALL**, described in "The Copper's Registers and Arithmetic".

```
 MOVE
  31 30                                 16 15                                 0
 +--+-------------------------------------+-------------------------------------+
 | 0|  register offset (bit 16 = 0)       |  data                               |
 +--+-------------------------------------+-------------------------------------+

 WAIT and SKIP
  31 30  28 27 26                     16 15 14    11 10                       0
 +--+------+--+-------------------------+--+--------+---------------------------+
 | 1|  op  | P|  line, 0-2047           | B|  0000  |  pixel, 0-2047            |
 +--+------+--+-------------------------+--+--------+---------------------------+
      op: 000 = WAIT, 001 = SKIP.   P: pixel only.   B: also wait for the DMA
                                                     engine (WAIT only; 0 in SKIP)
 JUMP
  31 30  28 27    23 22                                                   2  1 0
 +--+------+--------+------------------------------------------------------+----+
 | 1| 010  |  00000 |  address in Chip RAM                                 | 00 |
 +--+------+--------+------------------------------------------------------+----+

 STOP
  31 30  28 27                                                                0
 +--+------+--------------------------------------------------------------------+
 | 1| 011  |  0                                                                 |
 +--+------+--------------------------------------------------------------------+

 MOVR, ALU, SKIPC, CALL (see "The Copper's Registers and Arithmetic")
  31 30  28 27
 +--+------+--------------------------------------------------------------------+
 | 1| 1xx  |  100 MOVR, 101 ALU, 110 SKIPC, 111 CALL or RET                     |
 +--+------+--------------------------------------------------------------------+

             Figure 5-1: The Copper Instruction Formats
```

| Instruction | Macro | What it does |
|-------------|-------|--------------|
| MOVE | `CMOVE reg,value` | Writes 16 bits to one half of a register in the custom block |
| (two MOVEs) | `CMOVEL reg,value` | Writes a whole 32-bit register: the high half, then the low half |
| WAIT | `CWAIT line,pixel` | Waits until the beam reaches the position |
| WAIT, pixel only | `CWAITP pixel` | Waits until the beam reaches the pixel position on this line, or on the next one if it has passed it |
| WAIT with B | `CWAITB line,pixel` | As WAIT, and also until the blitter is idle |
| SKIP | `CSKIP line,pixel` | Skips the next instruction if the beam has reached the position |
| SKIP, pixel only | `CSKIPP pixel` | As SKIP, comparing the pixel position only |
| JUMP | `CJUMP address` | Continues at the address |
| STOP | `CSTOP` | Stops until the next frame |

Bit patterns that are not instructions (an op field with bits that must be 0 set, for example) are reserved. The copper treats them as STOP and sets the ERR flag in COPSTAT, so a list that runs into data by mistake often stops rather than writing registers at random.

As on the Amiga, the first word of a MOVE is simply the register's offset and the second word is the data. `CMOVE BGCOLOR+2,$00FF` is the two words `$001A,$00FF`.

---

## The MOVE Instruction

MOVE writes its 16-bit data to the register half at its offset in the custom block (`$E00000` + offset). The offset is even, and up to `$7FFE`.

### Registers are written in halves

Every register is 32 bits, in two halves: the **high half** at the register's offset, the **low half** at offset + 2. A MOVE writes one half, at once, and keeps the other half, by the same rule as the CPU (Rule 2 in the Introduction chapter), as the Amiga's copper wrote its registers. **Palette entries** are the exception: a MOVE to an entry's high half is held until the copper's next MOVE to that entry's low half, so a colour changes all at once (the copper has its own hold, apart from the CPU's).

This gives three kinds of write:

- **A 16-bit register** (BPLSTRIDE, BPLxDAT, SCROLLX, DMACON, the strobes) lives in the low half. One MOVE, to the register's offset + 2, writes it:

  ```asm
          CMOVE   L0+L_BPLSTRIDE+2,-40    ; layer 0's stride = -40: step back a line
  ```

- **A 32-bit register** (a plane pointer, CTRL, WINX, a palette entry, BGCOLOR, COP1LC) takes two MOVEs, the high half first. `CMOVEL` makes the pair for you. Between the two MOVEs the register holds the new high half and the old low half, so write registers the hardware is using where it is not using them: plane pointers and layer settings in the vertical blank or before their line starts, as on the Amiga. (A palette entry changes all at once, when the second MOVE is done.)

  ```asm
          CMOVEL  L0+L_BPL0PT,$040000     ; = CMOVE L0+L_BPL0PT,$0004
                                          ;   CMOVE L0+L_BPL0PT+2,$0000
  ```

- **The low half alone**, when the high half is to stay as it is. One MOVE is enough, and it is faster: see "Changing colours" below.

Writing only the high half of a palette entry leaves it held: nothing happens until the copper's next MOVE to that entry's low half.

### Plane pointers

A plane pointer is 23 bits, so it always needs both halves: `CMOVEL`. Setting the four plane pointers of a layer takes four `CMOVEL`s, eight MOVE instructions:

```asm
        CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
        CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
        CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
        CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
```

### Changing colours

A palette entry is a 32-bit register, `$00RRGGBB`: layer 0's colour n is at `PALETTE0 + 4 × n` (layers 1 and 2 have PALETTE1 and PALETTE2, the sprites SPRPALETTE; Chapter 3). The examples here colour layer 0. The high half holds red (`$00RR`), the low half green and blue (`$GGBB`). BGCOLOR, the background colour, is laid out the same way, but is an ordinary register: each MOVE to it takes effect at once.

- To set a whole colour, use `CMOVEL`:

  ```asm
          CMOVEL  PALETTE0+1*4,$FF8000     ; colour 1 = orange
  ```

- To change only green and blue, one MOVE to the low half does it, and keeps the entry's red:

  ```asm
          CMOVE   PALETTE0+1*4+2,$FF00     ; colour 1: green $FF, blue $00, red kept
  ```

Palette writes take effect at once, from the next pixel, so the copper can change a colour in the middle of a line. BGCOLOR is read at the start of each line's picture, so a change made in a line's horizontal blank shows on that line, and one made during its picture shows from the next line. "Copper Timing" gives the details.

**Tip:** Because a palette entry's held high half waits for its low half, you can write the high half of a colour *before* a WAIT and the low half after it. The whole colour then changes with the one MOVE that follows the WAIT, which the copper has already fetched, so the change is exact to the pixel. Example 5-10 does this. Put nothing but the WAIT between the two MOVEs.

---

## The WAIT Instruction

WAIT makes the copper wait until the beam reaches a position on the screen. While it waits, the copper uses no memory cycles at all. When the position is reached, the copper goes on with the next instruction, which it has already fetched.

### The beam position

A WAIT gives the position as a **line** and a **pixel** in **beam coordinates**, exactly as BEAMPOS counts them: line 0 is the start of the vertical blank, and pixel 0 is the start of a line's horizontal blank. Each line starts with its blank and then shows its picture. Both are 11 bits, so the copper can reach every position in the frame, to the pixel:

| Part of the frame | Lines | Pixels |
|-------------------|-------|--------|
| Vertical blank | 0–48 | 0–863 |
| Horizontal blank | 0–624 | 0–143 |
| Picture | 49–624 (VID_Y0 onwards) | 144–863 (VID_X0 onwards) |

The beam passes 864 pixels per line (144 of horizontal blank, then 720 of picture), 37 ns each, and 625 lines per frame. Positions with a pixel of 864 or more, or a line of 625 or more, are never reached on the way, so do not use them, except for the end-of-list WAIT described below.

```asm
        CWAIT   VID_Y0+100,0            ; beam line 149: the blank before picture line 100
        CWAIT   VID_Y0+100,VID_X0       ; picture line 100's first pixel
        CWAIT   VID_Y0+100,VID_X0+360   ; the middle of picture line 100
```

A WAIT for line n, pixel 0 ends at the start of line n's horizontal blank, 144 pixels before its picture. It is the natural place for changes that must be in place before line n's picture: BGCOLOR, PRIO and the palette. CTRL, WINX, WINY, SCROLLX and the start of the line's fetch are taken at that moment, so those must be written before it, during line n − 1 (see "Copper Timing"). A colour change at picture line L, pixel P is `CWAIT VID_Y0+L,VID_X0+P`.

### Beam positions through the frame

The copper restarts its list from COP1LC at the start of every frame, beam line 0, pixel 0, the start of the vertical blank. The picture's first line, beam line 49, comes 49 lines later. Those 49 blank lines are where the per-frame set-up goes: the writes at the top of the list (plane pointers, colours) are done there, before the picture's first line is fetched.

```
     start of list --> line   0 +-----------------------------------+
     (COP1LC)                   |  vertical blank, lines 0-48       |
                                |  set-up: pointers, colours        |
                       line  49 +-----------------------------------+
                                |                                   |
                                |  the picture, lines 49-624        |
                                |  WAITs for picture lines          |
                                |                                   |
                       line 624 +-----------------------------------+
                                    |
                                    +--> next frame: the list
                                         starts again from COP1LC

                Figure 5-2: The Frame, as the Copper Sees It
```

Positions only go up through a frame, so the rule is simple:

- A WAIT ends when the beam reaches its position in this frame.
- A WAIT for a position the beam has **already passed** in this frame ends at once. A SKIP for such a position skips.

Write your WAITs in order, from the top down. A WAIT for line 100 after a WAIT for line 600 ends at once.

On the Amiga, positions wrap after line 255, and a list has to wait for line 255 at the end of the line before it can reach the lines below. Nothing like that is needed here: every line from 0 to 624 is one simple number.

### Ending a list

End every list with **STOP**. The copper then does nothing until the next frame starts, when it starts again from COP1LC.

```asm
        CSTOP
```

A WAIT for line 2047, `CWAIT 2047,0`, does the same, since the beam never gets there. The Amiga's end-of-list, the long word `$FFFFFFFE`, also stops the copper, but only because its op bits (111) are a reserved pattern: it sets COPSTAT.ERR as well. Use CSTOP in new lists, and change `$FFFFFFFE` to CSTOP when you bring an Amiga list across.

If a list is still running when the next frame starts, it is abandoned: the copper starts again from the top whatever it was doing, whether waiting, stopped or in the middle of a run of MOVEs.

### The pixel-only WAIT

The Amiga's WAIT has mask bits, so that a WAIT can ignore the line and wait for a horizontal position on whatever line the beam is on. The retro68k copper does this more simply: a WAIT with the **P** bit set, written `CWAITP pixel`, ignores the line altogether.

- If the beam has not yet reached the pixel position on the current line, the copper waits for it on this line.
- If the beam has already passed it, the copper waits for it on the next line.

So a pixel-only WAIT always waits for the next time the beam comes to that pixel. A block that starts with `CWAITP 0` runs once at the start of each line's horizontal blank, before the line's picture, whatever line it is on, which is what you want for an effect that repeats on every line:

```asm
        CWAIT   VID_Y0+100,0            ; the blank before picture line 100
        CMOVEL  BGCOLOR,$000080         ; line 100's background
        CWAITP  0                       ; the blank before line 101
        CMOVEL  BGCOLOR,$000090         ; line 101's background
        CWAITP  0                       ; the blank before line 102
                                        ; ... and so on
```

Each block is 12 bytes instead of 16 with ordinary WAITs, and, more usefully, the same block can be used on any line, so a loop can repeat it (see "Loops and Branches"). Start a run of pixel-only WAITs with an ordinary WAIT, so that the run begins on the line you mean.

A pixel-only WAIT relies on the copper finishing the block before the beam comes round again. A block that does more than about 150 instructions' worth of work, so that it runs past the next occurrence of its pixel position, makes the next WAIT wait for the line after, and the effect slips a line. Keep per-line blocks short.

### Waiting for the blitter

A WAIT with the **B** bit set, written `CWAITB line,pixel`, waits until the beam has reached the position **and** the blitter has nothing left to do, nor the rasteriser (the line and triangle unit, Chapter 6). This is the Amiga's "wait for the blitter" (there, the BFD bit clear). It lets a list start a blitter job, wait for it to finish, and start the next. Example 5-12 shows it. The blitter is described in its own chapter (Chapter 6).

---

## The Copper Registers

The copper's registers are in the custom block at `$E00700`. All are 32 bits, and follow the register rules.

### Location registers

**COP1LC** and **COP2LC** each hold the address of a copper list in Chip RAM: bits 22–2 of the address, so a list always starts at a multiple of 4.

- **COP1LC** is list 1, the **main list**. The copper starts it again from the top at the start of every frame (beam line 0, the start of the vertical blank).
- **COP2LC** is list 2. The copper goes there only when told to, by the COPJMP2 strobe.

Write them from the CPU with `MOVE.L`, which writes both halves in the right order. From the copper, use `CMOVEL`.

```asm
        move.l  #my_list,COP1LC(a4)
```

A write to COP1LC does not move the copper by itself: the new address is used at the start of the next frame (or at the next COPJMP1 strobe). This is what makes double-buffered lists work (see "Double-Buffered Lists").

### Jump strobes

**COPJMP1** and **COPJMP2** are **strobes**: writing to them makes something happen, and the value written does not matter. Write the low half (offset + 2): the strobes act on a write to it.

| Strobe | What it does |
|--------|--------------|
| COPJMP1 | The copper starts again at COP1LC, now |
| COPJMP2 | The copper goes on at COP2LC, now |

Either the CPU or the copper can write them:

```asm
        move.w  #0,COPJMP1+2(a4)        ; CPU: restart list 1 at once
        CMOVE   COPJMP2+2,0             ; copper: continue at list 2
```

A strobe from the CPU also wakes a copper that is waiting or stopped.

### The control register: COPCON

| Bits | Field | Meaning |
|------|-------|---------|
| 0 | EN | 1: the copper is on (DMACON.COPEN and DMACON.DMAEN must also be set) |
| 1 | IRQEN | 1: a write to COPINT raises the copper interrupt |
| 5–4 | PRI | The copper's priority for memory cycles: 0 normal, 1 high, 2 nasty, 3 as 1 (see "Copper Timing") |

```asm
        move.l  #COPCON_EN_M|(0<<COPCON_PRI_B),COPCON(a4)  ; on, normal priority
```

### Status: COPSTAT and COPPC

**COPSTAT** tells you what the copper is doing, and holds two sticky flags:

| Bit | Flag | Meaning |
|-----|------|---------|
| 0 | WAITING | The copper is in a WAIT |
| 1 | STOPPED | The copper has reached a STOP (or a reserved instruction) |
| 2 | ERR | Sticky: the copper met a reserved instruction. Write 1 to clear |
| 3 | IRQ | Sticky: a write to COPINT. Write 1 to clear |

**COPPC** reads the address of the instruction the copper is running. Together with COPSTAT it is useful when a list does not do what you expect: read them in the vertical blank to see whether the list reached its STOP, or which WAIT it is stuck on.

### The interrupt strobe: COPINT

A write to **COPINT** sets COPSTAT.IRQ. With COPCON.IRQEN set, that raises the COPPER interrupt (source 2). It is meant to be written by the copper itself, as `CMOVE COPINT+2,0`; see Example 5-11.

---

## Putting Together a Copper List

A copper list is just a run of long words in Chip RAM. All memory is Chip RAM, so the list can sit in your program's own data, next to the code that uses it. Put a `CNOP 0,4` in front of it to align it to a long word.

A typical list has three parts:

1. **The set-up**, run in the vertical blank: plane pointers, the colours and settings the top of the picture needs.
2. **The effects**, each a WAIT for a position followed by the MOVEs to make there, from the top of the screen down.
3. **A STOP.**

### Example 5-1: Colour bars

Example 3-10 in the playfield chapter made colour bars by having the CPU watch the beam. Here is the same picture as a copper list: the background colour changes every 8 lines, 72 bars in all. Each new colour is written at the start of the bar's first line, in its horizontal blank, because BGCOLOR is read at the start of each line's picture. The assembler's `REPT` writes the 71 WAIT and MOVE pairs.

```asm
; Example 5-1: colour bars. The background colour changes every 8 lines:
; 72 bars, from blue at the top to red at the bottom.

            include "hw.inc"
            include "copper.inc"

BAR         equ     8                   ; lines per bar

            cnop    0,4                 ; instructions are long-word aligned
bars_list:  CMOVEL  BGCOLOR,$0000FF     ; bar 0, set in the vertical blank
            rept    71                  ; bars 1-71
            CWAIT   VID_Y0+(REPTN+1)*BAR,0                      ; the blank before the bar
            CMOVEL  BGCOLOR,(((REPTN+1)*3)<<16)|(255-(REPTN+1)*3)
            endr
            CSTOP
```

The first instruction runs at beam line 0, at the start of the frame and of the vertical blank, and sets the colour for bar 0, which starts at beam line 49 (picture line 0). The first WAIT is for beam line 57, pixel 0: the start of picture line 8's horizontal blank. The list is 72 × 8 + 71 × 4 + 4 = 864 bytes, and it takes the CPU no time at all.

---

## Starting and Stopping the Copper

### Step by step

To start the copper:

1. **Write the list** in Chip RAM, at a multiple of 4, ending with STOP.
2. **Write its address to COP1LC**, with `MOVE.L`.
3. **Write COPCON**: EN, and IRQEN and PRI if you need them.
4. **Turn on copper DMA**: set COPEN, and DMAEN if it is not on already, in DMACON.
5. **The display must be on** (VIDCON.EN). The beam, and so the frame, runs only while it is.

The copper starts at the start of the next frame. From then on it runs its list from COP1LC at the start of every frame (beam line 0, pixel 0), with no further help.

Three switches must all be on for the copper to run: COPCON.EN, DMACON.COPEN and DMACON.DMAEN. Turning any of them off stops it.

### Example 5-2: Starting the copper

This program shows the colour bars of Example 5-1, with every layer off so that the background fills the screen.

```asm
; Example 5-2: start the copper with the colour bars of Example 5-1.
; Assumes supervisor mode.

            include "hw.inc"
            include "copper.inc"

BAR         equ     8

start:      move.w  #$2700,sr           ; no interrupts while we set up
            lea     CUSTOM,a4
            move.l  #0,L0+L_CTRL(a4)    ; no layers: the background shows
            move.l  #0,L1+L_CTRL(a4)
            move.l  #0,L2+L_CTRL(a4)
            move.l  #0,COPCON(a4)       ; copper off while we set it up
            move.l  #bars_list,COP1LC(a4)                   ; step 2: the list
            move.l  #COPCON_EN_M|(0<<COPCON_PRI_B),COPCON(a4)  ; step 3: on, normal priority
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M,DMACON+2(a4) ; step 4
            move.l  #VIDCON_EN_M,VIDCON(a4)                 ; step 5: the display on

main:       ; (your program's main loop goes here)
            bra.s   main

            cnop    0,4
bars_list:  CMOVEL  BGCOLOR,$0000FF
            rept    71
            CWAIT   VID_Y0+(REPTN+1)*BAR,0
            CMOVEL  BGCOLOR,(((REPTN+1)*3)<<16)|(255-(REPTN+1)*3)
            endr
            CSTOP
```

### What happens in each frame

```
 line 0, pixel 0       the frame and the vertical blank start:
                       - VIDSTAT.VBLANK is set and FRAMECOUNT goes up by 1
                       - the copper starts again at COP1LC, whatever it was doing
 lines 0-48            the copper runs the set-up part of the list:
                       plane pointers, colours (49 lines, 1.57 ms: plenty of time)
 line 49, pixel 0      the display starts fetching the picture's first line,
                       using the pointers the copper has just written
 lines 49-624          the copper waits for each position in its list and makes
                       its writes there; then it reaches STOP and waits
 line 0                the next frame: the list starts again

          Figure 5-3: The Copper's Frame
```

The set-up part has the whole vertical blank, 49 lines, to finish before the display needs the pointers. That is enough for thousands of instructions.

### Starting at once: COPJMP1

The copper waits for the start of the next frame before it first runs its list. If you want it to start straight away, write COPJMP1 after step 4. The list then runs from the top at once, part-way through a frame: its WAITs for positions the beam has already passed end at once, so the rest of that one frame may look wrong. From the next frame on, everything is normal. Usually it is simpler to let the copper start by itself.

### Stopping the copper

To stop the copper, clear COPEN in DMACON (write it with bit 15 clear), or clear COPCON.EN:

```asm
        move.w  #DMACON_COPEN_M,DMACON+2(a4)    ; bit 15 clear: COPEN off
```

The copper stops at once. The registers it wrote keep their last values, so the screen goes on showing whatever the copper last set: for example, the colours from the bottom of the screen, and plane pointers that are no longer reset each frame. To restart the copper cleanly, set COPEN again: it starts at the start of the next frame.

A copper list may also stop itself for one frame with STOP: that is the normal end of every list.

---

## Resetting the Bitplane Pointers Each Frame

The plane pointers walk through memory as the display fetches, and the hardware does not put them back (see "Resetting the Pointers Every Frame" in the playfield chapter). In Example 3-1, a vertical blank interrupt handler wrote them back every frame. On the Amiga this is the copper's job, and here too it is the natural way: four `CMOVEL`s at the top of the list, and there is no interrupt handler at all.

### Example 5-3: A basic playfield with the copper

This is Example 3-1, the 320 × 256 16-colour playfield, with the copper resetting the pointers. Step 7 of Example 3-1 (the VBLANK handler) has gone, and so has every interrupt.

The order of the start-up matters a little. Bitplane DMA is turned off first, so that the layer fetches nothing until the copper has written the pointers. Then the copper and the display are turned on, and the program waits for a new frame to start: in its vertical blank the copper writes the pointers for the first time, and the program turns bitplane DMA on before beam line 49, when the first line of the picture is fetched.

```asm
; Example 5-3: a basic playfield, with the copper resetting the plane
; pointers every frame. The same picture as Example 3-1: 320 x 256 in 4
; separate bitplanes, shown 2x by 2x as a 640 x 512 window in the middle
; of the screen. Assumes supervisor mode.

            include "hw.inc"
            include "copper.inc"

SCREEN      equ     $040000             ; the picture, in Chip RAM
WIDTH       equ     320                 ; source pixels across
HEIGHT      equ     256                 ; source lines
PLANES      equ     4
ROWBYTES    equ     WIDTH/8             ; 40 bytes per plane line
PLANESIZE   equ     ROWBYTES*HEIGHT     ; 10240 bytes per plane
WIN_X       equ     VID_X0+(VID_W-2*WIDTH)/2    ; the window: 640 x 512 at
WIN_Y       equ     VID_Y0+(VID_H-2*HEIGHT)/2   ; picture position (40, 32)
CTRL_PIC    equ     L_CTRL_EN_M|L_CTRL_PLANAR_M|((PLANES-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)

start:      move.w  #$2700,sr           ; no interrupts
            lea     CUSTOM,a4
            bsr     draw                ; the picture in Chip RAM

            ; turn off anything left on, e.g. by the boot ROM
            move.w  #DMACON_BPLEN_M|DMACON_COPEN_M,DMACON+2(a4)    ; bit 15 clear: off
            move.l  #0,COPCON(a4)
            move.l  #0,L0+L_CTRL(a4)
            move.l  #0,L1+L_CTRL(a4)
            move.l  #0,L2+L_CTRL(a4)
            move.l  #(2<<PRIO_BACK_B)|(1<<PRIO_MIDDLE_B)|(0<<PRIO_FRONT_B),PRIO(a4)

            ; the layer, as in Example 3-1, but no pointers: the copper sets them
            lea     L0(a4),a0
            move.l  #(WIN_X<<16)|(WIN_X+2*WIDTH),L_WINX(a0)
            move.l  #(WIN_Y<<16)|(WIN_Y+2*HEIGHT),L_WINY(a0)
            move.l  #0,L_SCROLLX(a0)
            move.l  #ROWBYTES,L_BPLSTRIDE(a0)   ; 40 bytes per plane line
            lea     colours(pc),a1
            lea     PALETTE0(a4),a2
            moveq   #16-1,d0
.col:       move.l  (a1)+,(a2)+
            dbra    d0,.col
            move.l  #$000000,BGCOLOR(a4)
            move.l  #CTRL_PIC,L_CTRL(a0)

            ; the copper
            move.l  #copper_list,COP1LC(a4)
            move.l  #COPCON_EN_M,COPCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)

            ; wait for a frame to start: the copper writes the pointers
            ; in its vertical blank, then bitplane DMA may start
            move.l  FRAMECOUNT(a4),d0
.vb:        cmp.l   FRAMECOUNT(a4),d0
            beq.s   .vb
            move.w  #DMACON_SETCLR_M|DMACON_BPLEN_M,DMACON+2(a4)

main:       ; (your program's main loop goes here)
            bra.s   main

; The copper list: put layer 0's pointers back to the top of the picture.
            cnop    0,4
copper_list:
            CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
            CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
            CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
            CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
            CSTOP

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

The later examples in this chapter build on this one: each gives a new `copper_list`, and any changes to the start-up.

### Scrolling and double buffering with the copper

To scroll or to swap screen buffers, the CPU changes the addresses **in the list**: the data words of the `CMOVEL`s. Each `CMOVEL` is 8 bytes, and the pointer's high and low halves are its words at +2 and +6. Change them between the copper's set-up and the start of the next frame, for example once the picture has started (beam line 49 or later), so that the copper never reads a pointer half-changed. A safer way, for bigger changes, is to use two lists (see "Double-Buffered Lists").

```asm
; Point the list's BPL0PT at d0 (a long): the CMOVEL is the list's first
; instruction, so its two data words are at copper_list+2 and +6
            swap    d0
            move.w  d0,copper_list+2    ; high half
            swap    d0
            move.w  d0,copper_list+6    ; low half
```

---

## Loops and Branches

### SKIP

SKIP compares the beam position as WAIT does, but it does not wait. If the beam **has reached** the position in this frame, the copper skips the next instruction; if not, it runs it. A pixel-only SKIP, `CSKIPP pixel`, compares only the pixel position on the current line.

### JUMP

JUMP makes the copper continue at another address in Chip RAM, at once. On the Amiga, the only way to jump was to write COP2LC and strobe COPJMP2; here JUMP goes straight to any address and leaves COP2LC free for other uses.

### A loop that ends at a line

Together, SKIP and JUMP make a loop that repeats until the beam reaches a line:

```
 loop:  CWAITP  pixel           ; wait for the pixel, on the next line
        ...                     ; the work for this line
        CSKIP   last,pixel      ; reached the last line? then skip the JUMP
        CJUMP   loop            ; otherwise round again
        ...                     ; the rest of the list
```

The pixel-only WAIT makes the loop run once per line. Each pass costs the loop's own instructions plus two, the SKIP and the JUMP; at about 200 ns per instruction that is far less than the 32 µs of a line.

### Example 5-4: A gradient background

The simplest way to give every line its own colour is to write out one block per line. The assembler writes them: here a background that fades from dark blue at the top to orange at the bottom, with a new colour on all 576 lines. Each line is a pixel-only WAIT and a `CMOVEL`, 12 bytes, so the list is under 7 KB.

```asm
; Example 5-4: a gradient background. Every line gets its own background
; colour: red rises from 0 to 251 down the screen, blue falls from 255.

            include "hw.inc"
            include "copper.inc"

            cnop    0,4
gradient:   CMOVEL  BGCOLOR,$0000FF     ; line 0, set in the vertical blank
            CWAIT   VID_Y0+1,0          ; the blank before line 1
            rept    575                 ; lines 1-575
            CMOVEL  BGCOLOR,((((REPTN+1)*7)>>4)<<16)|(255-(((REPTN+1)*7)>>4))
            CWAITP  0                   ; the next line's blank
            endr
            CSTOP
```

The ordinary WAIT for the start of line 1 starts the run on the right line; every WAIT after it is pixel-only and simply waits for the start of the next line's horizontal blank. The last `CWAITP` waits through line 575, the picture's last, until the frame ends and the list starts again. The gradient can share the screen with any layers: the background shows wherever no layer has a pixel.

If the CPU should make the colours (for example to animate them), it can build the same list in memory. A MOVE is the register offset in the high word and the data in the low word, and a WAIT is made from the `COP_` equates in `hw.inc`:

```asm
; Build one line's block at a0: WAIT pixel only for pixel 0, the start of
; the horizontal blank, then BGCOLOR = d0 ($00RRGGBB)

line_block: move.l  #COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|COP_PIXONLY|0,(a0)+
            swap    d0
            move.w  #BGCOLOR,(a0)+      ; MOVE to the high half ...
            move.w  d0,(a0)+            ; ... red
            swap    d0
            move.w  #BGCOLOR+2,(a0)+    ; MOVE to the low half ...
            move.w  d0,(a0)+            ; ... green and blue
            rts
```

### Example 5-5: Scan lines with a loop

When the same thing happens on every line, a loop makes the list short. This one paints a band of "scan lines" behind the picture: on lines 100 to 399, the background alternates between two blues, line by line. Only blue changes, so each colour is one MOVE to BGCOLOR's low half.

```asm
; Example 5-5: scan lines. Lines 100-399 alternate between two blues;
; the other lines are black.

            include "hw.inc"
            include "copper.inc"

            cnop    0,4
scan_list:  CMOVEL  BGCOLOR,$000000     ; black from line 0
            CWAIT   VID_Y0+100,0        ; the blank before line 100
stripes:    CMOVE   BGCOLOR+2,$00C0     ; even lines: blue $0000C0
            CWAITP  0
            CMOVE   BGCOLOR+2,$0060     ; odd lines: blue $000060
            CWAITP  0
            CSKIP   VID_Y0+400,0        ; reached line 400? leave the loop
            CJUMP   stripes
            CMOVE   BGCOLOR+2,$0000     ; black again from line 400
            CSTOP
```

Follow the loop through once. The first MOVE lands at the start of line 100, in its horizontal blank, and sets line 100's colour. The first pixel-only WAIT ends at the start of line 101, and the second MOVE sets line 101. The second WAIT ends at the start of line 102. The SKIP asks: has the beam reached line 400? Not yet, so the JUMP runs and the loop goes round. On the 150th pass the second WAIT ends at the start of line 400, the SKIP skips the JUMP, and the last MOVE makes line 400 black. Seven instructions do the work of 600.

---

## Using the Two Lists

Most programs need only list 1. List 2 is useful when part of the list should change while the rest stays fixed.

### Jumping to list 2

A MOVE to **COPJMP2** makes the copper continue at the address in COP2LC. Unlike JUMP, whose address is fixed in the list, COPJMP2 jumps to wherever COP2LC points **now**, so the CPU can choose where the copper goes by writing one register. A common layout:

- **List 1**, in COP1LC, does the set-up every frame (plane pointers and so on), then strobes COPJMP2.
- **List 2**, in COP2LC, is the effect for this part of the program. To change the effect, the CPU writes another list's address to COP2LC.

The copper reads COP2LC at the moment of the strobe, early in the vertical blank. Whenever the CPU writes COP2LC, the change shows from a whole frame: the current one, if the copper has not yet reached the strobe, or else the next. The list being run is never cut off halfway.

### Example 5-6: Choosing an effect with COP2LC

This list 1 replaces the list in Example 5-3. It resets the pointers, then goes to list 2. Two lists 2 are ready: `plain`, which only stops, and the scan lines of Example 5-5.

```asm
; Example 5-6: list 1 resets the pointers, then goes to whichever list
; COP2LC holds. Replaces copper_list in Example 5-3.

            cnop    0,4
copper_list:
            CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
            CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
            CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
            CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
            CMOVE   COPJMP2+2,0         ; continue at COP2LC
plain:      CSTOP                       ; list 2: no effect

stripes_list:                           ; list 2: the scan lines of Example 5-5
            CMOVEL  BGCOLOR,$000000
            CWAIT   VID_Y0+100,0
.loop:      CMOVE   BGCOLOR+2,$00C0
            CWAITP  0
            CMOVE   BGCOLOR+2,$0060
            CWAITP  0
            CSKIP   VID_Y0+400,0
            CJUMP   .loop
            CMOVE   BGCOLOR+2,$0000
            CSTOP

; In the start-up, before the copper is turned on:
            move.l  #plain,COP2LC(a4)

; Later, in the main program: scan lines on, and off again
            move.l  #stripes_list,COP2LC(a4)
            move.l  #plain,COP2LC(a4)
```

The copper can write COP1LC and COP2LC too, with `CMOVEL`. A list can set COP2LC and then strobe COPJMP2, or set COP1LC to choose the list for the next frame, so that the copper chains its own lists.

### Background work: COPCON.RESUME

Some copper work is not tied to the beam at all: a long queue of blitter jobs, say, each started when the one before it is done. Such a list may take several frames. On the Amiga it would be cut off at every vertical blank, when list 1 starts again. Here you can let it carry on, by setting **COPCON.RESUME**:

- When the copper enters list 2 through COPJMP2, it remembers that it is "in list 2".
- If it is still there when the vertical blank comes, the hardware writes its place in the list into **COP2LC**, and then starts list 1 as always.
- List 1 does its set-up and ends with a MOVE to COPJMP2, as in Example 5-6. List 2 carries on where it was cut off.

```
 frame n     list 1 ... COPJMP2 -> list 2: job A, job B, WAITB ...  | cut off
                                                                     | COP2LC <- the WAITB
 frame n+1   list 1 ... COPJMP2 -> list 2: WAITB (again), job C, ... STOP

          Figure 5-4: A Background List Carried Across Frames
```

The place saved is the instruction that was not finished: a WAIT that was still waiting runs again, whole. A STOP, a COPJMP1 strobe or the vertical blank itself ends "in list 2"; a JUMP, CALL or RET does not, so the background list can loop and call subroutines. Only the place is saved: X, Y, the flags and R0–R7 are simply left as they are, so a list 1 that uses them must save and restore them (Example 5-16).

A background list has to follow a few rules:

- **No beam WAITs.** A WAIT for a beam position waits for it in the current frame, so after a resume it would wait for that position in the new frame. Use `CWAITB 0,0`: beam line 0, pixel 0 is the first position of every frame, and always passed, so this waits for the blitter only.
- **Mind a pair cut in two.** If the cut-off comes between the two halves of a `CMOVEL`, list 2 carries on from the low half after the frame's list 1: in between, the register holds the new high half and the old low half (a palette entry keeps the copper's held high half, unless list 1 writes a palette high half itself). Write the registers list 2 uses where that does no harm, or write them in list 1.
- **End by pointing COP2LC at an idle list.** Otherwise the next COPJMP2 runs the list again from the last place saved.
- **The CPU hands out work only when the copper is idle.** While a background list runs, the hardware may overwrite COP2LC at the next vertical blank. So the CPU writes COP2LC only when the copper is in the idle list: COPPC tells it where the copper is, or the idle list can raise a COPINT when it is reached.

### Example 5-7: A background job queue

```asm
; Example 5-7: list 2 runs a queue of blitter jobs in the background,
; across as many frames as it takes. List 1 is the one in Example 5-6.
; JOB1-JOB3 are the blitter's descriptor chains (see Example 5-12).

            cnop    0,4
idle:       CSTOP                                   ; list 2 when there is no work

jobs:       CMOVEL  BLTDESC,JOB1
            CMOVE   BLTCMD+2,BLTCMD_START_M
            CWAITB  0,0                             ; until the blitter is idle
            CMOVEL  BLTDESC,JOB2
            CMOVE   BLTCMD+2,BLTCMD_START_M
            CWAITB  0,0
            CMOVEL  BLTDESC,JOB3
            CMOVE   BLTCMD+2,BLTCMD_START_M
            CWAITB  0,0
            CMOVEL  COP2LC,idle                     ; done: back to the idle list
            CMOVE   COPINT+2,0                      ; tell the CPU
            CSTOP

; In the start-up: RESUME on, list 2 idle
            move.l  #idle,COP2LC(a4)
            move.l  #COPCON_EN_M|COPCON_IRQEN_M|COPCON_RESUME_M,COPCON(a4)

; Later, in the main program, when the copper is idle (after the last COPINT):
            move.l  #jobs,COP2LC(a4)                ; starts at the next frame's COPJMP2
```

Each job's start strobe is a single MOVE after its `CMOVEL`, never inside it, so a resume never starts a job twice. If you need beam-timed effects as well, put them in list 1, before the COPJMP2: list 2 then gets the rest of each frame.

---

## Double-Buffered Lists

When the CPU builds a new list every frame (for a raster bar that moves, for example), it must never change a list while the copper is running it: the copper would run a mixture of old and new instructions, and it may already have fetched the next instruction before the CPU changed it. The answer is the same as for screen buffers: **two lists**.

1. Build the next frame's list in the buffer the copper is not using.
2. Write its address to COP1LC. The copper is not disturbed: it finishes the current frame with the old list.
3. At the next vertical blank the copper starts the new list. Wait for that (FRAMECOUNT goes up at the same moment), and then the old buffer is free to build in.

### Example 5-8: A moving raster bar

The CPU builds a list with a 16-line bar of colours in the background, at a line that moves down the screen by 2 lines every frame.

```asm
; Example 5-8: double-buffered copper lists. Every frame the CPU builds a
; list with a 16-line raster bar at line d0, in the buffer the copper is
; not running, then makes it the next frame's list. Uses a4 = CUSTOM.

            include "hw.inc"
            include "copper.inc"

LISTA       equ     $00A000             ; two list buffers in Chip RAM
LISTB       equ     $00A400
C_WAIT      equ     COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)
C_STOP      equ     COP_EXT|(COP_OP_STOP<<COP_OP_SHIFT)
BG_HI       equ     BGCOLOR<<16         ; MOVE to BGCOLOR's high half (data in bits 15-0)
BG_LO       equ     (BGCOLOR+2)<<16     ; MOVE to its low half

raster:     lea     LISTA,a2            ; a2: the buffer to build in
            lea     LISTB,a3            ; a3: the other one
            moveq   #1,d0               ; the bar's first line, 1-560
.frame:     move.l  a2,a0
            bsr.s   build
            move.l  a2,COP1LC(a4)       ; the copper's list from the next frame
            move.l  FRAMECOUNT(a4),d1
.wait:      cmp.l   FRAMECOUNT(a4),d1
            beq.s   .wait               ; the copper now runs the new list ...
            exg     a2,a3               ; ... so build in the old one next time
            addq.w  #2,d0               ; move the bar down
            cmp.w   #560,d0
            bls.s   .frame
            moveq   #1,d0               ; back to the top
            bra.s   .frame

; Build the list at a0: black, then the bar from line d0.w (1-560), then black.
build:      movem.l d0-d2/a1,-(sp)
            move.l  #BG_HI|$0000,(a0)+  ; black from line 0, set in the blank
            move.l  #BG_LO|$0000,(a0)+
            add.w   #VID_Y0,d0          ; the beam line: each colour goes at its start
            lea     bar_colours(pc),a1
            moveq   #16,d2              ; 16 bar lines, then black
.line:      moveq   #0,d1
            move.w  d0,d1
            swap    d1                  ; the line, in bits 26-16
            or.l    #C_WAIT|0,d1
            move.l  d1,(a0)+            ; WAIT line, pixel 0: its horizontal blank
            move.w  #BGCOLOR,(a0)+      ; MOVE BGCOLOR (high half): red
            move.w  (a1)+,(a0)+
            move.w  #BGCOLOR+2,(a0)+    ; MOVE BGCOLOR+2 (low half): green, blue
            move.w  (a1)+,(a0)+
            addq.w  #1,d0
            dbra    d2,.line
            move.l  #C_STOP,(a0)+
            movem.l (sp)+,d0-d2/a1
            rts

bar_colours:                            ; 16 lines of bar, then black
            dc.l    $200000,$400000,$600000,$800000,$A00000,$C00000,$E00000,$FF2000
            dc.l    $FF2000,$E00000,$C00000,$A00000,$800000,$600000,$400000,$200000
            dc.l    $000000
```

Each list is 8 + 17 × 12 + 4 = 216 bytes, so the two buffers of 1 KB each leave plenty of room for more effects.

---

## Copper Effects

The examples in this section build on Example 5-3. Each gives a new `copper_list`, which starts by resetting the plane pointers as before.

### Example 5-9: A split screen

On the Amiga, a split screen is made by the copper writing new plane pointers partway down. This example shows the 4-plane picture of Example 5-3 on the top 384 lines of the window, and from line 416 down a status panel: a different picture, 320 × 64 in 2 planes, using colours 16–19. The layer's CTRL changes to 2 planes and palette block 1, and its pointers move to the panel.

The timing comes from "Writing new pointers partway down" in the playfield chapter:

- **CTRL** for line L + 1 must be written during the visible part of line L (before the end of line L, beam pixel 864, where line L + 1's horizontal blank starts).
- **The pointers** for line L + 1 must be written after the layer's last fetch on line L, and before line L + 1 starts. The layer stops fetching about 32 source pixels (here 64 screen pixels) before its window's right edge, at beam pixel 824 (picture pixel 680), so the gap is from about beam pixel 760 to the end of the line, 864.
- A pointer written in that gap is used as written: it is the start of line L + 1, and nothing is added to it. BPLSTRIDE stays 40, which suits the panel too, since its planes are also 40 bytes per line.
- Write each pointer whole (`CMOVEL`, high half first). In the gap a pointer reads as the end of line L's words, and a MOVE of one half merges with that.
- With vertical scaling, the split must come after the **last** copy of a source line. At 2× down, starting at line 32, the copies are lines 32 and 33, 34 and 35, and so on; line 415 is a last copy.

So the list waits for beam pixel 792 (picture pixel 648) on line 415 and writes three registers: six MOVEs, which must all be done by the end of the line, beam pixel 864. The first is already fetched; at normal priority each of the others may take about 200 ns, so the last lands near beam pixel 819. That fits, but on a busy screen other DMA could hold the copper up. Setting COPCON.PRI to 1 makes sure it is not (see "Copper Timing").

```asm
; Example 5-9: a split screen. From line 416 the layer shows a 2-plane
; status panel in colours 16-19. Replaces copper_list in Example 5-3; in
; its start-up, turn the copper on with high priority:
;           move.l  #COPCON_EN_M|(1<<COPCON_PRI_B),COPCON(a4)

PANEL       equ     $050000             ; the panel: 320 x 64, 2 separate planes
PANELPLANE  equ     ROWBYTES*64         ; 2560 bytes per plane
SPLIT       equ     WIN_Y+2*192         ; beam line 465 (line 416): the panel's first
CTRL_PANEL  equ     L_CTRL_EN_M|L_CTRL_PLANAR_M|((2-1)<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(1<<L_CTRL_PALOFS_B)

            cnop    0,4
copper_list:
            CMOVEL  L0+L_CTRL,CTRL_PIC  ; the top: 4 planes, colours 0-15
            CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
            CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
            CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
            CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
            CWAIT   SPLIT-1,WIN_X+2*WIDTH-32    ; line 415, beam pixel 792: last fetch done
            CMOVEL  L0+L_CTRL,CTRL_PANEL        ; from line 416: 2 planes, colours 16-19
            CMOVEL  L0+L_BPL0PT,PANEL           ; used as written for line 416
            CMOVEL  L0+L_BPL1PT,PANEL+PANELPLANE
            CSTOP
```

The list puts CTRL back at the top of every frame, so the top part always starts with 4 planes. The panel needs its four colours in palette entries 16–19, set once by the CPU or in the list.

The panel's picture runs down to the bottom of the window, line 543, which is 128 screen lines: the 64 source lines of the panel at 2×. Further splits work the same way: one WAIT and a few MOVEs each.

### Example 5-10: Changing a colour in the middle of a line

Palette writes take effect at once, so the copper can change a colour partway across a line. This list changes two colours in the right half of the screen, from pixel 360, on lines 200 to 299, and puts them back in each horizontal blank. It shows the two ways to make a colour change exact:

- Colour 1 goes from white `$FFFFFF` to yellow `$FFFF00`: only the low half changes, so **one MOVE** does it.
- Colour 2 goes from red `$FF0000` to sky blue `$0080FF`, which changes both halves. The list writes the new high half **before** the WAIT, where it is held (a palette entry), and the low half after it. The MOVE straight after the WAIT is already fetched, so colour 2 changes exactly at pixel 360. Colour 1's MOVE needs its own fetch and lands a few pixels later.

```asm
; Example 5-10: colours changed in the middle of a line. On lines 200-299,
; from pixel 360, colour 2 is sky blue and colour 1 yellow. Replaces
; copper_list in Example 5-3.

            cnop    0,4
copper_list:
            CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
            CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
            CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
            CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
            CWAIT   VID_Y0+200,0            ; the start of line 200
midline:    CMOVE   PALETTE0+2*4,$0000       ; colour 2's new high half: held (a palette entry)
            CWAITP  VID_X0+360              ; the middle of this line
            CMOVE   PALETTE0+2*4+2,$80FF     ; colour 2 = $0080FF, exactly here
            CMOVE   PALETTE0+1*4+2,$FF00     ; colour 1 = $FFFF00, a fetch later
            CWAITP  0                       ; the next line's horizontal blank
            CMOVEL  PALETTE0+2*4,$FF0000     ; both back for the next line
            CMOVE   PALETTE0+1*4+2,$FFFF
            CSKIP   VID_Y0+300,0            ; past line 299? leave the loop
            CJUMP   midline
            CSTOP
```

The changes back are made in the horizontal blank, where nothing is shown, so their exact timing does not matter. The colours change at the same place on every line and in every frame, without any work by the CPU.

### Example 5-11: A copper interrupt

The copper cannot write the interrupt controller (it is in the system block), but it can interrupt the CPU with a MOVE to **COPINT**. That sets COPSTAT.IRQ, and with COPCON.IRQEN set, COPSTAT.IRQ raises the COPPER interrupt, source 2, with its own vector. The handler clears it by writing 1 to COPSTAT.IRQ.

Unlike the LINE interrupt, which comes at one line set in LINECMP, the copper can interrupt at any position, as many times per frame as the list says. This example interrupts the CPU at line 544, when the beam has left the window: a good moment for the CPU to start changing the picture, because the display will not read it again until the next frame.

```asm
; Example 5-11: a copper interrupt at line 544, the line after the window.
; Added to Example 5-3: a new list, and the interrupt set-up.

VECTORS     equ     $000000             ; the vector table, in Chip RAM
frames      equ     $008000             ; long: frames counted by the handler

            cnop    0,4
copper_list:
            CMOVEL  L0+L_BPL0PT,SCREEN+0*PLANESIZE
            CMOVEL  L0+L_BPL1PT,SCREEN+1*PLANESIZE
            CMOVEL  L0+L_BPL2PT,SCREEN+2*PLANESIZE
            CMOVEL  L0+L_BPL3PT,SCREEN+3*PLANESIZE
            CWAIT   WIN_Y+2*HEIGHT,0    ; beam line 593 (line 544): the window is done
            CMOVE   COPINT+2,0          ; interrupt the CPU
            CSTOP

; In the start-up, with a5 = SYSTEM, instead of the plain COPCON write:
            move.l  #copint,VECTORS+(VECBASE_DEFAULT+INT_COPPER)*4
            move.l  #0,frames
            move.l  #COPSTAT_IRQ_M,COPSTAT(a4)          ; clear an old flag
            move.l  #COPCON_EN_M|COPCON_IRQEN_M,COPCON(a4)  ; on, COPINT interrupts
            move.l  INTPRI0(a5),d0                      ; the copper at level 5
            and.l   #~($F<<(4*INT_COPPER)),d0
            or.l    #5<<(4*INT_COPPER),d0
            move.l  d0,INTPRI0(a5)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_COPPER),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            ; ... and, once everything is on:
            move.w  #$2000,sr                           ; take interrupts

; The handler: clear the flag, count the frame.
copint:     move.l  #COPSTAT_IRQ_M,CUSTOM+COPSTAT
            addq.l  #1,frames
            rte
```

The example sets the source's level itself (5, the level of the other video interrupts), so it does not depend on the level the controller starts with. If a list writes COPINT at several places, the handler can read BEAMPOS to see which one it is, or the list can write a value into a spare register just before (for example LINECMP, if the LINE interrupt is not in use) for the handler to read.

A write to COPINT sets the flag once. If the flag is still set from an earlier write that the handler has not yet cleared, the two count as one, so leave the handler enough time between two COPINTs: the CPU takes at least 3 µs to start a handler.

### Example 5-12: Waiting for the blitter

The copper starts a blitter job at line 0, then waits for line 300 **and** for the blitter to finish before starting a second one. (The blitter's registers are described in Chapter 6.) On the Amiga, lists do the same with the blitter: a copper-driven blit, then a WAIT with BFD clear before the next.

```asm
; Example 5-12: the copper starts blitter jobs. JOB1 and JOB2 are
; descriptor chains in Chip RAM, set up as the blitter chapter describes.

JOB1        equ     $060000
JOB2        equ     $060100

            cnop    0,4
dma_list:   CWAIT   VID_Y0,0                        ; the start of the picture
            CMOVEL  BLTDESC,JOB1                    ; the first job ...
            CMOVE   BLTCMD+2,BLTCMD_START_M         ; ... start it
            CWAITB  VID_Y0+300,0                    ; line 300, and the blitter idle
            CMOVEL  BLTDESC,JOB2                    ; the second job
            CMOVE   BLTCMD+2,BLTCMD_START_M
            CSTOP
```

`CWAITB` waits for the blitter to have **nothing** to do, including jobs started by the CPU. If a job runs late, the copper's later writes in the list come late too; and if the blitter is still busy at the next vertical blank, the list starts again regardless. So do not put a `CWAITB` before writes that must happen at a fixed place on the screen, such as the plane pointers, and keep `CWAITB` for the end of a list.

## The Copper's Registers and Arithmetic

The Amiga's copper could only write constants. This copper also has a few registers of its own, and simple arithmetic on them, so that a short loop can do the work of a long unrolled list, and a list can count, compare and call subroutines.

| Register | Size | Address | Used for |
|----------|------|---------|----------|
| X | 16 bits | COPX, `$720` | A register offset to write through, or data |
| Y | 16 bits | COPY, `$724` | Data, or a counter |
| Flags | Z, N, C | COPFLAGS, `$728` | Set by arithmetic, tested by SKIPC |
| R0–R7 | 16 bits each | COPR0–COPR7, `$740`–`$75C` | Storage: saving X, Y and the flags, values kept between frames, values passed to and from the CPU |
| The stack | 8 return addresses | COPSP, `$72C`, reads how many | CALL and RET |

All of them except the stack's contents can be read and written by the CPU, at their addresses in the custom block, and by the copper itself with an ordinary MOVE: `CMOVE COPX+2,PALETTE0` loads X. They are 16-bit registers, in the low half. Nothing resets them at the vertical blank: X, Y, the flags and R0–R7 keep their values from frame to frame. (The stack is emptied at each vertical blank, unless COPCON.STKKEEP is set.)

In this chapter, and in `copper.inc`, the registers are named `CX`, `CY`, `CF` and `CR0`–`CR7` when they are operands of an instruction.

### Writing through X and Y: MOVR

An ordinary MOVE has both the register and the data written into the instruction. The **MOVR** instructions are MOVEs that can take either of them, or both, from the copper's registers instead:

- **The register from X.** X holds a register's offset in the custom block, and the MOVE writes to that register. This is like the 68000's `MOVE.W D0,(A0)`, with X as the address register. Change X, and the same instruction writes somewhere else.
- **The data from X or Y.** The value written is whatever is in X or Y at the time, rather than a number fixed in the list.

X holds an **offset**, as the copper's register names do, not a full address: load it with `CLDI CX,BGCOLOR+2`, not with `$E0001A`. As in a MOVE, an offset with bit 1 clear is a register's high half and one with bit 1 set its low half; bit 0 and bit 15 of X are ignored.

As with every copper instruction, the register written is named first:

```
        CMOVR   BGCOLOR+2,CY    ; BGCOLOR's low half = Y
        CMOVXR  CY              ; the register half at X = Y
```

**The instructions**

| Macro | Writes | To | Example (X = `BGCOLOR+2`, Y = `$1234` before) | Result |
|-------|--------|----|-----------------------------------------------|--------|
| `CMOVX n` | The number n | The register half at X | `CMOVX $00FF` | BGCOLOR's low half = `$00FF` |
| `CMOVXP n` | The number n | The register half at X, then X = X + 2 | `CMOVXP $00FF` | The same, and X = `BGCOLOR+4` |
| `CMOVR reg,CY` | Y | reg (`CMOVR reg,CX`: X) | `CMOVR PALETTE0+2,CY` | Colour 0's low half = `$1234` |
| `CMOVXR CY` | Y | The register half at X (`CMOVXR CX`: X) | `CMOVXR CY` | BGCOLOR's low half = `$1234` |
| `CMOVXRP CY` | Y | The register half at X, then X = X + 2 | `CMOVXRP CY` | The same, and X = `BGCOLOR+4` |

None of them change the flags.

**Stepping through registers: the P forms.** The forms ending in `P` add 2 to X after the write, as the 68000's `(A0)+` does. Two steps of 2 take X from a register's high half to its low half, then on to the next register, so a run of P forms walks through consecutive registers without naming each one. For example, to write a whole palette entry, then move on to the next:

```
        CLDI    CX,PALETTE0+5*4  ; X = colour 5, high half
        CMOVXP  $00FF           ; red = $FF (held: a palette entry); X = colour 5, low half
        CMOVXRP CY              ; green, blue = Y: colour 5 changes all at once;
                                ; X = colour 6, high half
```

**The halves rule still holds.** A MOVR writes its half at once, exactly as a CMOVE does (a palette entry's high half is held until the copper's low-half write). Strobes (COPJMP1, COPJMP2, COPINT, a blitter start) act on a write to their low half, whether it comes from a MOVE or a MOVR. A MOVR can reach only the custom block, as a MOVE can.

**How a MOVR is made up.** The macros build it; this is for reading a list in memory:

```
  31 30  28 27 26 25 24 23            16 15                                 0
 +--+------+--+--+--+--+----------------+-------------------------------------+
 | 1| 100  | A| S| I| X|    00000000    |  number (S = 0), or offset (A = 0)  |
 +--+------+--+--+--+--+----------------+-------------------------------------+
   A: the register is the one at X        S: the data is a register (X or Y)
   I: X = X + 2 afterwards (with A only)  X: with S, the data is X (else Y)
   With A and S both set, bits 15-0 are 0. A and S both clear is reserved.

             Figure 5-5: The MOVR Instruction
```

So `CMOVXRP CY` is `$CE000000`: op 100, A, S and I set, X clear (the data is Y).

### Arithmetic and comparing: the ALU instructions

Each ALU instruction does one operation on **one of the copper's registers**, X or Y, using a **source**: a number written in the instruction, or another copper register. The result goes back into the register, as in `X = X + 4`.

The register being changed is always written **first**, and the source second:

```
        CADDI   CX,4            ; X = X + 4
        CSUB    CY,CR2          ; Y = Y - R2
```

This is the other way round from the 68000, where `ADD.W #4,D0` puts the source first. Read a copper ALU instruction as an assignment: `CADDI CX,4` is "X = X + 4".

**Two forms of each instruction.** Every operation has a form for a number and a form for a register. The number form has an `I` (immediate) on the end of its name:

| Form | Source | Example | Means |
|------|--------|---------|-------|
| `CADDI` | A 16-bit number in the instruction | `CADDI CX,4` | X = X + 4 |
| `CADD` | A copper register: `CX`, `CY` or `CR0`–`CR7` | `CADD CX,CR3` | X = X + R3 |

The number can be any 16-bit value or expression, such as `PALETTE0+16*4` or `$0604`. The source registers cannot be the custom registers: only X, Y and R0–R7.

**The instructions**

| Macro | Means | Example (X = `$0010` and R3 = `$0003` before) | X after | Flags |
|-------|-------|-----------------------------------------------|---------|-------|
| `CLDI d,n` / `CLD d,src` | Load: d = source | `CLDI CX,$0100` | `$0100` | Unchanged |
| `CST CRn,d` | Store: Rn = d (the register named first is written, as always) | `CST CR3,CX` | `$0010` (R3 = `$0010`) | Unchanged |
| `CADDI d,n` / `CADD d,src` | Add: d = d + source | `CADD CX,CR3` | `$0013` | Set |
| `CSUBI d,n` / `CSUB d,src` | Subtract: d = d − source | `CSUBI CX,$0011` | `$FFFF` | Set |
| `CANDI d,n` / `CAND d,src` | AND: d = d AND source | `CANDI CX,$00F0` | `$0010` | Set |
| `CORI d,n` / `COR d,src` | OR: d = d OR source | `CORI CX,$0001` | `$0011` | Set |
| `CCMPI d,n` / `CCMP d,src` | Compare: works out d − source, **keeps only the flags** | `CCMPI CX,$0010` | `$0010` (unchanged) | Set |

Here `d` is `CX` or `CY`. All arithmetic is 16 bits: a result that goes past `$FFFF` wraps round to `$0000` and up, and one that goes below 0 wraps to `$FFFF` and down (as `CSUBI` does in the table).

There is no instruction to load a custom register into X or Y: the copper cannot read the custom registers. Values come from numbers in the list, from the CPU (which can write COPX, COPY and COPR0–7), or from earlier arithmetic.

**The flags.** Add, subtract, AND, OR and compare set three flags, which a SKIPC instruction (below) can test. They mean what the 68000's do:

| Flag | Set when |
|------|----------|
| Z, zero | The result is `$0000` |
| N, negative | Bit 15 of the result is 1 (the result is negative, read as a signed number) |
| C, carry | `CADD`: the true sum was more than `$FFFF`, so it wrapped. `CSUB` and `CCMP`: the source was bigger than the register (unsigned), so the result wrapped below 0. `CAND` and `COR` always clear C |

`CCMP` exists only to set the flags: it subtracts as `CSUB` does, but leaves the register as it was. Use it just before a SKIPC.

Loads and stores (`CLD`, `CLDI`, `CST`) do not change the flags, with one exception: the flags themselves can be loaded and stored, as the register `CF`, so that a list can save them and put them back:

```
        CST     CR7,CF          ; R7 = the flags (Z in bit 0, N in bit 1, C in bit 2)
        ...
        CLD     CF,CR7          ; the flags = R7
```

`CF` can be used only with `CLD`, `CLDI` and `CST`.

### Testing the flags: SKIPC

**SKIPC** skips the next instruction if a condition on the flags holds. The conditions are those of the 68000's branches. They are easiest to read as the result of the `CCMP` or `CCMPI` just before:

| Macro | After `CCMPI CX,n`, skips if | Tests |
|-------|------------------------------|-------|
| `CSKIPEQ` | X = n | Z |
| `CSKIPNE` | X ≠ n | not Z |
| `CSKIPLO` | X < n (unsigned) | C |
| `CSKIPHS` | X ≥ n (unsigned) | not C |
| `CSKIPHI` | X > n (unsigned) | not C and not Z |
| `CSKIPLS` | X ≤ n (unsigned) | C or Z |
| `CSKIPMI` | bit 15 of X − n is 1 | N |
| `CSKIPPL` | bit 15 of X − n is 0 | not N |

After `CADD`, `CSUB`, `CAND` or `COR` the same conditions test the result: `CSKIPEQ` after `CSUBI CY,1` skips when Y has just reached 0.

As with SKIP, the instruction skipped is usually a `CJUMP` back to the top of a loop: the loop goes round until the condition holds, then the skip steps over the `CJUMP` and the list carries on. A loop of 8 passes:

```
        CLDI    CY,8            ; Y = 8
.loop:  ...                     ; the work: done 8 times
        CSUBI   CY,1            ; Y = Y - 1: 7, 6, ... 0
        CSKIPEQ                 ; Y = 0? then skip the CJUMP ...
        CJUMP   .loop           ; ... else go round again
        ...                     ; carries on here after the 8th pass
```

**How an ALU instruction is made up.** Like the others, it is 32 bits. The macros build it; this is for reading a list in memory:

```
  31 30  28 27  25 24 23 22 21 20      16 15                                 0
 +--+------+------+-----+-----+----------+-------------------------------------+
 | 1| 101  |  fn  |  d  |  s  |  00000   |  number (s = 0), or n of Rn (s = 3) |
 +--+------+------+-----+-----+----------+-------------------------------------+
   fn: 0 LD, 1 ST, 2 ADD, 3 SUB, 4 AND, 5 OR, 6 CMP (7 reserved)
   d:  the register changed (for ST: stored): 0 X, 1 Y, 3 the flags (LD, ST only)
   s:  the source: 0 the number in bits 15-0, 1 X, 2 Y, 3 Rn (n in bits 2-0)

             Figure 5-6: The ALU Instruction
```

So `CADDI CY,$0604` is `$D4800604`: op 101, fn 2 (ADD), d 1 (Y), s 0 (a number), number `$0604`.

### Subroutines: CALL and RET

`CCALL address` continues at the address and remembers where it came from; `CRET` goes back. The return addresses are kept in a stack inside the copper, 8 deep, so subroutines can call subroutines up to 8 levels. A CALL with 8 already in use, or a RET with none, stops the copper and sets COPSTAT.ERR.

### How fast the registers are

Every instruction, old or new, is one fetch of two words, and a CJUMP, CCALL, CRET or a SKIP that skips throws the prefetched instruction away. So a loop costs a fetch for every instruction in it, on every pass. Use loops to make lists **short**, and unrolled MOVEs where the writes must be **fast**: the loop in Example 5-13 writes a colour every 6 instructions, the unrolled list every 2.

### Example 5-13: A gradient palette with a loop

This list fills colours 16–47 with a gradient from black towards cyan: 32 colours, from 6 instructions instead of 64 MOVEs.

```asm
; Example 5-13: colours 16-47, a gradient. X walks through the palette
; registers (high half, low half, next entry); Y is the colour's green
; and blue.

            cnop    0,4
gradient:   CLDI    CX,PALETTE0+16*4     ; colour 16, high half
            CLDI    CY,$0000
.loop:      CMOVXP  $0000               ; red = 0 (held: a palette entry), X on to the low half
            CMOVXRP CY                  ; green, blue = Y: the entry is written
            CADDI   CY,$0604            ; green + 6, blue + 4
            CCMPI   CX,PALETTE0+48*4     ; past colour 47?
            CSKIPHS
            CJUMP   .loop
            CSTOP
```

It takes 32 passes of 6 instructions, 192 fetches: about 40 µs at COPCON.PRI 1, well inside the vertical blank. X holds the address of a register half, which is a 15-bit offset in the custom block, so 16 bits are plenty.

### Example 5-14: A raster bar subroutine

A subroutine that draws an 8-line raster bar from the line it is called on, in the colour that is in X. The list calls it three times, at three heights.

```asm
; Example 5-14: three raster bars from one subroutine. X = the bar's
; green and blue; Y counts the lines.

            cnop    0,4
bars_list:  CWAIT   VID_Y0+100,0
            CLDI    CX,$0040            ; a dark blue bar ...
            CCALL   bar
            CWAIT   VID_Y0+250,0
            CLDI    CX,$4000            ; ... a green one ...
            CCALL   bar
            CWAIT   VID_Y0+400,0
            CLDI    CX,$4040            ; ... and a cyan one
            CCALL   bar
            CSTOP

bar:        CLDI    CY,8                ; 8 lines
.line:      CWAITP  0                   ; the next line's horizontal blank
            CMOVR   BGCOLOR+2,CX        ; the next line's colour
            CADDI   CX,$1010            ; a little brighter
            CSUBI   CY,1
            CSKIPEQ                     ; 8 lines done?
            CJUMP   .line
            CWAITP  0
            CMOVE   BGCOLOR+2,$0000     ; back to black
            CRET
```

Each pass of `.line` is 6 instructions in the horizontal blank, which is 144 pixels (5.3 µs) long: at normal priority there is time for about 25.

### Example 5-15: Values from the CPU, and a frame counter

The storage registers are a mailbox between the CPU and the copper. Here the CPU sets a colour in COPR0 whenever it likes, and the copper puts it on the screen at line 200 of each frame. The copper also counts frames in COPR1, which the CPU can read.

```asm
; Example 5-15: the copper takes a colour from COPR0, and counts frames
; in COPR1.

            cnop    0,4
mail_list:  CLD     CX,CR1              ; frames + 1
            CADDI   CX,1
            CST     CR1,CX
            CWAIT   VID_Y0+200,0
            CLD     CX,CR0              ; the colour the CPU left
            CMOVR   BGCOLOR+2,CX
            CSTOP

; In the CPU, at any time:
            move.l  #$00F0,COPR0(a4)    ; next frame: green from line 200
            move.l  COPR1(a4),d0        ; frames counted by the copper
```

The CPU's write lands between two copper instructions, so the copper sees either the old colour or the new one, never half of each.

### Example 5-16: A background list that uses the registers

This is Example 5-7's job queue with a loop: 100 blitter jobs, one after another, with Y pointing at the next job's descriptor. With COPCON.RESUME, the list can be cut off anywhere at the vertical blank, and carries on from there in the next frame (see "Background work: COPCON.RESUME"). Only its place is saved by the hardware, so list 1 must leave X, Y and the flags as it found them: it saves them in storage registers before it uses them, and puts them back before its COPJMP2.

```asm
; Example 5-16: list 2 starts 100 blitter jobs, whose descriptors
; are JOBSIZE bytes apart from JOBS, in one 64 KB block. List 1 uses X,
; Y and the flags too, so it saves list 2's in R5-R7.

JOBS        equ     $070000
JOBSIZE     equ     32
NJOBS       equ     100

            cnop    0,4
list1:      CST     CR5,CX              ; save list 2's registers
            CST     CR6,CY
            CST     CR7,CF
            CCALL   gradient_sub        ; list 1's own work (uses X, Y, the flags)
            CLD     CX,CR5              ; put them back
            CLD     CY,CR6
            CLD     CF,CR7
            CMOVE   COPJMP2+2,0         ; list 2 carries on

idle:       CSTOP

jobs:       CLDI    CY,JOBS&$FFFF       ; the first descriptor
.next:      CMOVE   BLTDESC,JOBS>>16    ; descriptor, high half ...
            CMOVR   BLTDESC+2,CY        ; ... low half
            CMOVE   BLTCMD+2,BLTCMD_START_M    ; start it
            CWAITB  0,0                 ; until the blitter is idle
            CADDI   CY,JOBSIZE
            CCMPI   CY,(JOBS+NJOBS*JOBSIZE)&$FFFF
            CSKIPHS                     ; all 100 done?
            CJUMP   .next
            CMOVEL  COP2LC,idle         ; back to the idle list
            CMOVE   COPINT+2,0          ; tell the CPU
            CSTOP

gradient_sub:                           ; Example 5-13, as a subroutine
            CLDI    CX,PALETTE0+16*4
            CLDI    CY,$0000
.loop:      CMOVXP  $0000
            CMOVXRP CY
            CADDI   CY,$0604
            CCMPI   CX,PALETTE0+48*4
            CSKIPHS
            CJUMP   .loop
            CRET
```

The flags are saved too: if the cut-off came between list 2's `CCMPI` and its `CSKIPHS`, the SKIPC still sees list 2's flags. The `CMOVE`/`CMOVR` pair that writes the descriptor is a high half and a low half, so a cut-off between them runs the pair again, whole; the start strobe comes after the pair, so it never runs twice.

If list 1 makes CALLs and COPCON.STKKEEP is set, list 1's CALLs must all have returned before its COPJMP2, so that list 2's own return addresses are on top of the stack again.

---

## Copper Timing

### How exact a WAIT is

The copper compares its WAIT position against the beam position as the memory side sees it, a few clocks behind the pixel clock. A WAIT ends within about one pixel of its position. A pixel lasts 37 ns.

### The prefetched instruction

While it waits, the copper has already fetched the next instruction. When the WAIT ends, a MOVE that follows is made within 10–20 ns, well inside one pixel. Every instruction after that needs its own fetch from Chip RAM. So:

- The **first** MOVE after a WAIT is exact. Put the write that must be exact there.
- The writes after it come one fetch apart each (see "How fast the copper runs" below).
- A palette change shows within about 1–2 pixels of the WAIT position.
- To change a whole palette entry exactly, write its high half before the WAIT (a palette entry's high half is held) and its low half after it (Example 5-10). Other registers have no hold: write their halves where a half-changed value does no harm.

The copper holds only one prefetched instruction. A SKIP that skips throws it away, and the copper fetches the instruction after it; a JUMP fetches its target.

### When the writes take effect

The copper's writes take effect exactly as the CPU's do:

| Registers | Take effect |
|-----------|-------------|
| Palette, VIDCON.DIRECT, VIDCON.BLANKALL | At once, from the next pixel |
| BPLxPT, BPLSTRIDE | At once: they are live. BPLSTRIDE is used when the pointers are reset, at the start of the next line's horizontal blank. A copper write to a pointer wins over the display's own change in the same clock, and also sets the pointer's saved line start |
| BPLxDAT | At once; a write of BPL0DAT completes a group for a layer with no DMA |
| CTRL.EN, VSCALE, WINX, WINY, SCROLLX | At the start of each line's horizontal blank (beam pixel 0): to change line L, write during the visible part of line L − 1 |
| CTRL.BPP, PLANAR, PLANES, HSCALE | From the layer's next group fetched: 16–32 source pixels after the beam |
| CTRL.TRANSP, PALOFS | From the next pixel |
| PRIO, BGCOLOR | At the start of each line's picture (beam pixel 144): write in line L's horizontal blank, or earlier, to change line L |

A good rule: make changes for line L in its horizontal blank, after `CWAIT VID_Y0+L,0`, except CTRL, WINX, WINY and SCROLLX, which must be written before the end of the line before, and the plane pointers, which have their own window (Example 5-9).

CTRL's depth and palette block can also change partway along a line, for an effect: a PALOFS write shows from the next pixel, like a colour change (the one pixel where it changes may show a mix of the old and new blocks); a depth or PLANAR write shows from the layer's next group fetched, one or two groups (16–32 source pixels) past the beam, never in the middle of a group. Put the setting back in the right border, after the layer's window, so the next line starts as before. A scale (HSCALE) changed partway along a line upsets the line's group count: see the playfield chapter.

### How fast the copper runs

Each instruction is two 16-bit words, two memory cycles. The copper has its own DMA channel in the memory scheduler (see "Chip RAM and the Memory Slots" in the Introduction chapter). At normal priority it gets cycle 4 of each 100 ns slot, plus any cycle nobody else wants:

| Where the beam is | Fetch speed (normal priority) |
|-------------------|-------------------------------|
| Visible part of a line | At least about 20 MB/s: one instruction every 200 ns (about 5 pixels) or better |
| Horizontal blank | Faster: the display fetches only the first two groups of each layer's line |
| Vertical blank | Much faster: the display fetches nothing, so cycles 1 and 3 are free too |

Plan with the slow figure. Then:

| Time | Instructions, at 200 ns each |
|------|------------------------------|
| One pixel (37 ns) | Less than 1 |
| The horizontal blank (144 pixels, 5.3 µs) | About 26: 13 `CMOVEL`s |
| One line (32 µs) | About 160 |
| The vertical blank (49 lines, 1.57 ms) | About 7800 |

While it waits, the copper uses no memory cycles, so a list that is mostly WAITs costs the rest of the machine almost nothing.

### Priority: COPCON.PRI

Normally the copper takes cycle 4 and leftover cycles, after the display and the audio. When a list must make several writes in a short time, you can raise its priority with COPCON.PRI:

| PRI | Name | The copper gets |
|-----|------|-----------------|
| 0 | Normal | Cycle 4 and the cycles nobody else wants, after the display and audio, ahead of the CPU and the blitter (the default) |
| 1 | High | Cycle 4 as its own, and first place among the leftover cycles: ahead of audio, the blitter and display fetches that are not urgent. The display keeps its own cycles 1 and 3 |
| 2 | Nasty | As 1, and while it has an instruction to fetch it owns the CPU's cycle 0, like the Amiga's "blitter nasty" mode. The CPU's Chip RAM accesses then wait for cycles the copper leaves |

At every level, a display fetch that is about to be late still comes first, so raising the copper's priority never spoils the picture. And priority matters only while the copper has an instruction to fetch: while it waits, it takes nothing, whatever PRI says.

When to use them:

- **PRI 0** for almost every list. Copper lists are short, and most of the copper's time is spent waiting.
- **PRI 1** when a burst of writes must fit in a short gap: new plane pointers between a layer's last fetch and the start of the next line (Example 5-9), many colour changes in one horizontal blank, or writes on a screen that is close to its fetch budget, where the display leaves few spare cycles. The cost is small: the blitter and audio wait a little.
- **PRI 2** only when even that is not enough, for short bursts. It slows the CPU while the copper fetches.

The copper can write COPCON itself, so a list can raise its priority just before a burst and lower it after:

```asm
        CMOVE   COPCON+2,COPCON_EN_M|(1<<COPCON_PRI_B)  ; high priority ...
        CWAIT   VID_Y0+415,VID_X0+648
        CMOVEL  L0+L_BPL0PT,$050000                     ; ... for the burst
        CMOVEL  L0+L_BPL1PT,$050A00
        CMOVE   COPCON+2,COPCON_EN_M                    ; normal again
```

Write EN as 1 every time (and IRQEN if you use it): a write with EN clear turns the copper off.

### The copper and the CPU

The copper and the CPU share the bus to the registers. The copper goes first, so a CPU register access at the same moment may wait one clock. This is too small to notice.

Both can write the same register. The last write wins, and the halves never mix, because each has its own holding latch. But it is easy to lose track of who set what, so let one of them own each register: if the copper resets the plane pointers, the CPU should change the list, not the pointers.

---

## What the Copper Can Reach

| Area | The copper can |
|------|----------------|
| Chip RAM | Read its list. Nothing else: it cannot write Chip RAM |
| Custom block, `$E00000`–`$E07FFF` | Write: video and layer registers, DMACON, the blitter, audio, its own registers, and the palettes at `$E04000` |
| Custom block above `$E07FFF` | Nothing (a MOVE's offset is at most `$7FFE`) |
| System block, `$F00000` | Nothing: not the interrupt controller, timers, serial or system control |
| Boot ROM | Nothing: a list must be in Chip RAM |

Some consequences:

- **The copper only writes, apart from its own registers.** It cannot read a custom register or a memory location, so it cannot copy data. It can test values in its own registers (X, Y, R0–R7, which the CPU can set), and the beam position.
- **A copper list cannot live in the boot ROM.** Code in ROM must copy its list to Chip RAM first.
- **The copper cannot reach the interrupt controller**, so it interrupts the CPU through COPINT, and cannot disturb the CPU's interrupt set-up. Nor can it reach the system control registers, so a runaway list can never reset the machine or change the overlay. This is why there is no CDANG bit: nothing dangerous is in reach.
- **It can turn DMA on and off.** A MOVE to DMACON or to a layer's BPLDMA works as it does from the CPU, so the copper can, for example, turn a plane's DMA off for a band of lines and feed its BPLxDAT itself, one word per line. Take care with COPEN and DMAEN: clearing either stops the copper.
- **It can control itself.** It can write COP1LC, COP2LC, COPCON and the strobes. A MOVE to COPJMP1 starts the list again at once, so a list that does this unconditionally loops for ever, writing registers as fast as it can.
- **Read-only registers ignore its writes**, as they do the CPU's.

---

## Summary of Copper Instructions

| Instruction | Macro | Encoding (32 bits) | Does |
|-------------|-------|--------------------|------|
| MOVE | `CMOVE reg,value` | 0, offset (30–16, even), data (15–0) | Writes 16 bits to the register half at offset, at once (a palette entry's high half is held until its low half follows) |
| MOVE × 2 | `CMOVEL reg,value` | Two MOVEs: reg, then reg + 2 | Writes a whole 32-bit register |
| WAIT | `CWAIT line,pixel` | `$80000000` + line << 16 + pixel | Waits until the beam reaches the position in this frame |
| WAIT (P) | `CWAITP pixel` | `$88000000` + pixel | Waits for the pixel position on this line, or the next if passed |
| WAIT (B) | `CWAITB line,pixel` | `$80008000` + line << 16 + pixel | As WAIT, and until the blitter is idle |
| SKIP | `CSKIP line,pixel` | `$90000000` + line << 16 + pixel | Skips the next instruction if the beam has reached the position |
| SKIP (P) | `CSKIPP pixel` | `$98000000` + pixel | As SKIP, pixel position only |
| JUMP | `CJUMP address` | `$A0000000` + address (22–2) | Continues at the address |
| STOP | `CSTOP` | `$B0000000` | Stops until the next vertical blank (or a strobe) |
| MOVR | `CMOVX`, `CMOVXP`, `CMOVR`, `CMOVXR`, `CMOVXRP` | `$C0000000` + A (27), S (26), I (25), X (24), data or offset (15–0) | MOVE through X and Y; I: X + 2 afterwards |
| ALU | `CLD(I)`, `CST`, `CADD(I)`, `CSUB(I)`, `CAND(I)`, `COR(I)`, `CCMP(I)` | `$D0000000` + fn (27–25), d (24–23), s (22–21), value or n (15–0) | Arithmetic on X and Y, loads and stores |
| SKIPC | `CSKIPEQ` ... `CSKIPLS` | `$E0000000` + cc (27–24) | Skips the next instruction if the condition holds |
| CALL | `CCALL address` | `$F0000000` + address (22–2) | Pushes the next address, continues at address |
| RET | `CRET` | `$F8000000` | Continues at the popped address |
| (reserved) | | Other patterns | Act as STOP and set COPSTAT.ERR |

Line and pixel are 11 bits each (0–2047), in beam coordinates, counted as in BEAMPOS: line 0 is the start of the vertical blank and the picture is lines 49–624 (VID_Y0 on); pixel 0 is the start of a line's horizontal blank and the picture is pixels 144–863 (VID_X0 on). The list starts at (0, 0), and positions only go up through a frame.

---

## Summary of Copper Registers

All offsets are from CUSTOM (`$E00000`). Access: R read only, W write only, RW read and write, W1C sticky flags cleared by writing 1.

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| COPCON | `$700` | RW | EN (0): copper on. IRQEN (1): COPINT raises the interrupt. RESUME (2): the vertical blank saves list 2's place in COP2LC. STKKEEP (3): the vertical blank keeps the stack. PRI (5–4): 0 normal, 1 high, 2 nasty |
| COP1LC | `$704` | RW | List 1 address (22–2): restarted at the start of every frame (beam line 0) |
| COP2LC | `$708` | RW | List 2 address (22–2). Written by the hardware only with COPCON.RESUME |
| COPJMP1 | `$70C` | W | Strobe: start again at COP1LC now |
| COPJMP2 | `$710` | W | Strobe: continue at COP2LC now |
| COPPC | `$714` | R | Address of the instruction being run (22–2); when stopped, the STOP that stopped it |
| COPSTAT | `$718` | R, W1C | WAITING (0), STOPPED (1); ERR (2) and IRQ (3) sticky, write 1 to clear |
| COPINT | `$71C` | W | Strobe: sets COPSTAT.IRQ |
| COPX, COPY | `$720`, `$724` | RW | X and Y (15–0) |
| COPFLAGS | `$728` | RW | Z (0), N (1), C (2) |
| COPSP | `$72C` | RW | Read: return addresses on the stack (0–8). Write: empties the stack |
| COPR0–COPR7 | `$740`–`$75C` | RW | Storage registers (15–0) |
| DMACON | `$094` | Set/clear | COPEN (7) and DMAEN (9) must be set for the copper to run. 16 bits, low half at `$096` |

The copper interrupt is source 2, COPPER (vector 66 with the default VECBASE): COPSTAT.IRQ with COPCON.IRQEN. It must also be enabled in INTENA, with INTCON.MASTER on.

### State after reset

| Register | After reset |
|----------|-------------|
| COPCON | 0: the copper off, normal priority |
| DMACON | 0: COPEN and DMAEN off |
| COP1LC, COP2LC | Not set: write them before turning the copper on |
| COPSTAT | 0 |
| X, Y, the flags, R0–R7, the stack | 0, empty |

### Equates in hw.inc and copper.inc

| Name | Value | Meaning |
|------|-------|---------|
| `COPCON_EN_M`, `COPCON_IRQEN_M`, `COPCON_RESUME_M`, `COPCON_STKKEEP_M` | `$1`, `$2`, `$4`, `$8` | COPCON bits |
| `COPCON_PRI_B`, `COPCON_PRI_M` | 4, `$30` | COPCON.PRI field |
| `COPSTAT_WAITING_M` ... `COPSTAT_IRQ_M` | `$1` ... `$8` | COPSTAT bits |
| `DMACON_COPEN_M` | `$80` | DMACON's copper enable |
| `INT_COPPER`, `INTB_COPPER` | 2 | The copper's interrupt source and its INTENA bit |
| `COP_EXT` | `$80000000` | Bit 31: not a MOVE |
| `COP_OP_SHIFT` | 28 | Position of the op field (bits 30–28) |
| `COP_OP_WAIT` ... `COP_OP_STOP` | 0 ... 3 | WAIT, SKIP, JUMP, STOP |
| `COP_PIXONLY` | `$08000000` | Bit 27, P: compare the pixel position only |
| `COP_BLT` | `$00008000` | Bit 15, B: WAIT also waits for the blitter |
| `COP_V_SHIFT`, `COP_H_SHIFT` | 16, 0 | Positions of the line and pixel fields |
| `COP_OP_MOVR` ... `COP_OP_CALL`, `COP_FN_LD` ... `COP_FN_CMP`, `COP_CC_EQ` ... `COP_CC_LS` | | The new instructions' fields |
| `CX`, `CY`, `CF`, `CR0`–`CR7` | | Operands of the register macros, in `copper.inc` |
| `CMOVE` ... `CRET` | (macros) | The instructions, in `copper.inc` |
