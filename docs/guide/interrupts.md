# Interrupts and Timers

## Introduction

This chapter tells you how to make the retro68k hardware interrupt the 68000, and how to use the timers to measure and control time. It covers:

- how an interrupt travels from a unit, through the interrupt controller, to the 68000;
- setting up an interrupt handler, step by step;
- enabling, disabling and clearing interrupts;
- interrupt levels and priorities, and how to change them;
- the nonmaskable interrupt (NMI), used to get control back from a program that has gone wrong;
- the software interrupt, for doing work later at a lower priority;
- the 64-bit time counter;
- the four general timers: periodic interrupts, timeouts, counting video lines and frames, and chaining timers together;
- the watchdog, which resets the computer if software hangs.

The interrupt controller and the timers both live in the **system block** at `$F00000`. The copper and the blitter cannot reach the system block, so only the CPU can change these registers.

### Comparison with the Amiga

If you have programmed the Amiga, most of this will be familiar. The big differences are that each source has its own vector, that you choose each source's level, and that the timers are much wider than the CIA timers.

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Interrupt sources | 14, in Paula | 24 plus NMI, in the interrupt controller |
| Finding the source | One autovector per level; the handler reads INTREQR | One vector per source: the CPU jumps straight to the right handler |
| Levels | Fixed for each source | You choose, 1 to 6, for each source |
| Enables | INTENA (set/clear register, bit 15) with a master bit | INTENA (two set/clear halves, bits 15 and 31) and INTCON.MASTER |
| Clearing | Write INTREQ | Write 1 to the flag in the unit that asked |
| Software interrupt | SOFTINT in INTREQ | SOFTINT register |
| Timers | 4 x 16 bits, in two 8520 CIAs, about 0.7 MHz | 4 x 32 bits with 16-bit prescalers, from 100 MHz |
| Time of day | 24-bit CIA event counters | 64-bit counter in 10 ns steps |
| Watchdog | None | Yes |

### Conventions in this chapter

- All examples are 68000 assembly language for vasm, in Motorola syntax. They begin with `include "hw.inc"`, which gives the names of every register, field and number used here.
- Register names are offsets from their block. In ordinary code **a5 holds SYSTEM** (`$F00000`), so the interrupt enables are at `INTENA(a5)` and timer 0's control register at `TMR0+TMR_CTRL(a5)`. Interrupt handlers do not assume anything about a5; they use full addresses such as `SYSTEM+TMR0_STAT`.
- For each field, hw.inc gives `_B` (the bit number), `_M` (the mask, already shifted) and, for fields wider than one bit, `_W` (the width). For example `TMR_CTRL_IRQ_B` is 4 and `TMR_CTRL_IRQ_M` is `$10`.
- The examples run in supervisor mode, as interrupt handlers and system code do. `MOVE` to SR is a privileged instruction.

### Rules for the registers

Every register is 32 bits wide. The 68000 reaches it as two 16-bit halves, so the hardware follows these rules (they are the same for every unit):

- Each half is written on its own, as soon as it is written, keeping the other half. `MOVE.L` writes the high half, then the low half.
- Each half is read on its own, as it is at that moment. TIME is the exception: reading TIMEHI's high half captures all 64 bits (see "The Time Counter").
- Don't use `CLR.L` on a FIFO data register such as SERDATA: it reads the register first, which takes a byte. `MOVE.L #0,reg` is always safe.
- Sticky flags (Access W1C in the tables) are cleared by writing 1. Writing 0 leaves them alone.
- Unused bits read as 0. Write them as 0.

---

## How an Interrupt Reaches the 68000

The 68000 has seven interrupt levels. Level 1 is the lowest priority and level 7 the highest. The CPU's status register (SR) holds an **interrupt mask** in bits 10-8: the CPU accepts an interrupt only if its level is higher than the mask. Level 7 is the exception: it is the nonmaskable interrupt and is always accepted.

| SR value | Mask | The CPU accepts |
|----------|------|-----------------|
| `$2000` | 0 | Levels 1-7 (all) |
| `$2100` | 1 | Levels 2-7 |
| `$2300` | 3 | Levels 4-7 |
| `$2500` | 5 | Levels 6-7 |
| `$2600` | 6 | Level 7 only |
| `$2700` | 7 | Level 7 only (NMI) |

(The `$2000` bit is the supervisor bit; these values also keep the CPU in supervisor mode.)

Many units can ask for an interrupt: the video, the copper, the blitter, audio, the timers, the USB serial link, the SD card and the keyboard. The **interrupt controller** collects these requests, picks the most important one, and passes its level to the CPU. Figure 1 shows the path.

```
     UNIT (video, timer, ...)          INTERRUPT CONTROLLER ($F00000)

     status flag (sticky) --+
                            AND---- request n --+--------------> INTRAW bit n
     unit's enable ---------+                   |
                                                AND------------> INTPEND bit n
     INTENA bit n ------------------------------+                    |
     INTCON.MASTER -----------------------------+                    |
                                                                     v
                                   INTPRI0-2       +--------------------------+
                                   (level of n) ---->| highest level that has   |
                                                     | a pending source         |
                                                     +------------+-------------+
                                                                  |  IPL2-0
                                                                  v
     68000                                           +--------------------------+
                                                     | level > SR mask? (or 7)  |
     handler <---- vector table at 0 <-- vector -----| acknowledge cycle:       |
                   (vector x 4)          VECBASE + n | lowest pending source n  |
                                                     | at that level            |
                                                     +--------------------------+

                 Figure 1: How an interrupt reaches the 68000
```

Step by step:

1. Something happens in a unit, for example the video reaches the start of vertical blanking. The unit sets a **status flag**, here VIDSTAT.VBLANK. If the unit's own **enable** for that flag is on (here VIDINTEN.VBLANK), the unit raises its **request line** to the controller. You can see the request lines in **INTRAW**.
2. If the source's bit in **INTENA** is on, and **INTCON.MASTER** is on, the request is **pending**. You can see pending sources in **INTPEND**.
3. The controller looks up each pending source's level in **INTPRI0-2**, finds the highest level that has a pending source, and drives the 68000's IPL lines with that level.
4. When the CPU's mask allows that level, the 68000 finishes its current instruction and runs an **interrupt acknowledge** cycle for the level. The controller answers with the vector of the pending source at that level with the **lowest source number**. The vector is **VECBASE + source number**; VECBASE is 64 after reset.
5. The 68000 saves SR and the PC on the supervisor stack, raises its mask to the level it accepted, and jumps to the address held in the vector table at **vector x 4**.
6. Your handler clears the cause in the unit, usually by writing 1 to the unit's sticky flag. The request line drops. The handler ends with `RTE`. If another source at the same level is still pending, the CPU is interrupted again straight away.

Because each source has its own vector, your handler never has to work out which unit interrupted. (On the Amiga, a level 3 handler had to read INTREQR to tell the copper, the vertical blank and the blitter apart.) The only sources that share a vector are flags inside one unit, such as the three audio stream flags; the handler reads that unit's status register to tell them apart.

### Requests are level-sensitive

A request stays up as long as the unit's flag is set. Nothing is lost while an interrupt is held off by INTENA, the master bit or the CPU's mask: as soon as it is allowed, it happens. The other side of this is that **a handler must clear the cause before it returns**, or the same interrupt is taken again at once, for ever.

### Spurious interrupts

If a request goes away between the controller raising the IPL lines and the CPU's acknowledge (for example, the CPU cleared the flag or turned the source off at that moment), the controller has nothing to give. It answers with **vector 24**, the 68000's spurious-interrupt vector. This is rare but it can happen, so always install a handler for it. It need do nothing:

```asm
            include "hw.inc"

VECTORS     equ     $000000                 ; the 68000's vector table

spurious:   rte                             ; nothing to do

install_spurious:
            move.l  #spurious,VECTORS+VEC_SPURIOUS*4
            rts
```

### Response time

The 68000 checks for interrupts between instructions, then takes 44 clocks to save its state and fetch the vector. At 20 MHz that is 2.2 us, plus whatever is left of the instruction it was running: at most about 8 us, for a long divide. The acknowledge itself never adds wait states. `RTE` takes another 20 clocks (1 us).

So an interrupt costs at least 3.2 us before your handler does anything. Keep this in mind when choosing how often a timer interrupts: an interrupt every 10 us leaves the CPU little time for anything else.

### Interrupt sources and vectors

| Source | Name | Vector | Vector address | Default level | Comes from | Cleared in |
|--------|------|--------|----------------|---------------|------------|------------|
| 0 | VBLANK | 64 | `$100` | 5 | Video: start of the frame and of vertical blanking (beam line 0) | VIDSTAT.VBLANK |
| 1 | LINE | 65 | `$104` | 5 | Video: line compare, at the start of beam line LINECMP | VIDSTAT.LINE |
| 2 | COPPER | 66 | `$108` | 5 | The copper wrote COPINT (with COPCON.IRQEN set) | COPSTAT.IRQ (Chapter 5) |
| 3 | VIDERR | 67 | `$10C` | 5 | Video problems, such as a layer OVERRUN | VIDSTAT |
| 4 | BLT | 68 | `$110` | 4 | The blitter: a job with IRQ ended, or the blitter stopped | DMXINT.BLT (with DMXINTEN) |
| 5-7 | – | 69-71 | `$114`-`$11C` | – | Not used | |
| 8 | – | 72 | `$120` | – | Not used in version 1 | |
| 9 | AUDIO | 73 | `$124` | 4 | An audio channel took its registers: started, or reached the end of a block | AUDSTAT (with AUDINTEN) |
| 10 | – | 74 | `$128` | – | Not used in version 1 | |
| 11-14 | TIMER0-TIMER3 | 75-78 | `$12C`-`$138` | 6 | Timer underflow | TMRn STAT.UNDER |
| 15 | SERIAL | 79 | `$13C` | 3 | USB serial link | SERIRQ |
| 16 | SD | 80 | `$140` | 2 | SD card | SDIRQ |
| 17 | KEYB | 81 | `$144` | 2 | Keyboard | KBIRQ |
| 18 | SOFT | 82 | `$148` | 1 | Software interrupt | SOFTINT.CLR |
| 19-23 | (reserved) | 83-87 | `$14C`-`$15C` | 0 (off) | | |
| - | NMI | 31 | `$07C` | 7 | NMI button, USB break | NMISTAT |
| - | spurious | 24 | `$060` | - | No source at acknowledge | (nothing) |

hw.inc names the source numbers `INT_VBLANK` to `INT_SOFT`, and the vectors `VECBASE_DEFAULT`, `VEC_NMI` and `VEC_SPURIOUS`. The vector for a source is `VECBASE_DEFAULT+INT_x`, and its address in the vector table is four times that.

The controller never asks the 68000 for an autovector, so vectors 25-30 are never used.

---

## Setting Up an Interrupt Handler

### The vector table

The 68000 always fetches its vectors from the table at address 0 (the 68000 has no vector base register). By the time your program runs, the boot ROM has turned off the reset overlay, so address 0 is Chip RAM and you can write your own vectors into it. A source's vector is at

```
    address = (VECBASE + source) x 4          = $100 + 4 x source, with VECBASE = 64
```

### Step by step

To make a unit interrupt the CPU:

1. Raise the CPU's mask to 7 (`MOVE.W #$2700,SR`) while you set things up.
2. Write the address of your handler into the vector table.
3. Clear any old flag in the unit, so that you do not get an interrupt at once for something that happened long ago.
4. Turn on the unit's own enable for the flag.
5. Turn on the source's bit in INTENA.
6. Turn on INTCON.MASTER, if it is not on already.
7. Lower the CPU's mask, for example `MOVE.W #$2000,SR`.

After reset, INTCON.MASTER is off, every INTENA bit is off, and every unit enable is off. Only the NMI is on.

### Example: the vertical blank interrupt

This example counts frames. It turns on the vertical blank interrupt (source 0, level 5) and installs a handler that clears the flag and adds 1 to a counter.

```asm
            include "hw.inc"

VECTORS     equ     $000000                 ; the 68000's vector table
frames      equ     $008000                 ; long: frames counted

; Turn on the vertical blank interrupt. a5 = SYSTEM.
vbl_on:     move.w  #$2700,sr               ; 1. no interrupts while setting up
            lea     CUSTOM,a4
            move.l  #vblank,VECTORS+(VECBASE_DEFAULT+INT_VBLANK)*4  ; 2. the vector
            move.l  #0,frames
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)   ; 3. clear any old flag
            move.l  VIDINTEN(a4),d0                 ; 4. the unit's enable
            or.l    #VIDINTEN_VBLANK_M,d0
            move.l  d0,VIDINTEN(a4)
            move.w  #INTENA_SETCLRL_M|(1<<INTB_VBLANK),INTENA+2(a5)                   ; 5. the controller's enable
            move.l  #INTCON_MASTER_M,INTCON(a5)     ; 6. the master enable
            move.w  #$2000,sr                       ; 7. accept levels 1-7
            rts

; The handler: clear the cause, count the frame.
vblank:     move.l  #VIDSTAT_VBLANK_M,CUSTOM+VIDSTAT
            addq.l  #1,frames
            rte
```

### Writing a handler

- **Save what you use.** The 68000 saves only SR and the PC. Save every other register you change, with `MOVEM.L` or `MOVE.L -(SP)`, and restore it before `RTE`.
- **Clear the cause early.** Write the unit's flag near the start of the handler. If the same event happens again while the handler runs, the flag is set again and you get another interrupt after `RTE`, so nothing is missed.
- **Clear only the flags you have dealt with.** Writing 1 to a sticky flag clears it; writing 0 leaves it alone. Write only the bits you handled, for example `move.l #VIDSTAT_VBLANK_M,...`, never the whole register you read back, unless you mean to clear everything in it.
- **Keep it short.** While your handler runs, the CPU's mask is at the handler's level, so everything at that level or below waits. Move long work to the software interrupt (see "The Software Interrupt").
- **End with RTE**, not RTS.
- **Don't assume register contents.** A handler can interrupt any code, so load the addresses you need. The examples in this chapter use full addresses such as `CUSTOM+VIDSTAT` in handlers.

---

## Enabling, Disabling and Clearing

An interrupt reaches the CPU only when four switches are all on: the unit's enable, the source's INTENA bit, INTCON.MASTER and the CPU's mask.

```
    unit enable --- INTENA bit --- INTCON.MASTER --- 68000 SR mask ---> handler
    (per flag)      (per source)   (all but NMI)     (by level)

                 Figure 2: Four switches between an event and its handler
```

Use each for a different job:

- **The unit's enable** chooses which events in a unit matter. Set it once, when you start using the unit.
- **INTENA** turns whole sources on and off.
- **INTCON.MASTER** turns off every interrupt except the NMI with a single write. Pending requests are kept, and are taken when you turn it back on.
- **The CPU's mask** is the quickest way to hold off interrupts for a few instructions, for example around code that must not be interrupted. Use `MOVE.W SR,-(SP)`, `OR.W #$0700,SR`, ... `MOVE.W (SP)+,SR`.

### INTENA is a set/clear register

As on the Amiga, you never read INTENA, change a bit and write it back. You write only the bits you want to change, together with a SET/CLR bit that says whether they are turned on or off. Bits written as 0 are left alone, so two pieces of code can each turn their own sources on and off without getting in each other's way, even from interrupt handlers.

There are 24 sources, more than fit in the Amiga's 15 bits, so INTENA has **two set/clear halves**, each a 16-bit register of its own:

```
  31  30 ... 25  24 ...... 16   15  14 .............. 0
 +---+---------+-------------+ +---+------------------+
 |S/C|  (0)    | sources     | |S/C| sources          |
 | H |         | 23 ..... 15 | | L | 14 ............ 0|
 +---+---------+-------------+ +---+------------------+
        high half (INTENA)           low half (INTENA+2)
```

- In each half, writing with the top bit (SET/CLR) = 1 **sets** the bits written as 1; with it = 0, it **clears** them.
- Sources 0–14 are bits 14–0 of the low half. Sources 15–23 are bits 24–16, in the high half: source n is bit n + 1. `hw.inc` gives every source's bit as `INTB_name` (`INTB_VBLANK` = 0 … `INTB_SERIAL` = 16, `INTB_SOFT` = 19), so you never need to work it out.
- Each half takes effect as soon as it is written, as for every register: you can write either half alone with `MOVE.W`, or both with `MOVE.L`.
- INTPEND and INTRAW use exactly the same bit positions, so a mask built from `INTB_` names works on all three.
- Reading INTENA gives the enables; bits 31 and 15 read as 0.

```asm
            include "hw.inc"

; Sources 0-14: the low half, at INTENA+2
            move.w  #INTENA_SETCLRL_M|(1<<INTB_TIMER0),INTENA+2(a5)  ; turn TIMER0 on
            move.w  #1<<INTB_TIMER0,INTENA+2(a5)                     ; turn TIMER0 off

; Sources 15-23: the high half, at INTENA
            move.w  #(INTENA_SETCLRH_M|(1<<INTB_SOFT))>>16,INTENA(a5)  ; turn SOFT on
            move.w  #(1<<INTB_SOFT)>>16,INTENA(a5)                     ; turn SOFT off

; Both halves at once: VBLANK and SERIAL on, nothing else changed
            move.l  #INTENA_SETCLRH_M|INTENA_SETCLRL_M|(1<<INTB_VBLANK)|(1<<INTB_SERIAL),INTENA(a5)

; Everything off
            move.l  #INTENA_SRCH_M|INTENA_SRCL_M,INTENA(a5)
```

Do not use `BSET` or `BCLR` on INTENA: byte writes are ignored.

### Clearing an interrupt

You clear an interrupt **in the unit that asked for it**, not in the interrupt controller. The controller has no request flags of its own (except for the software interrupt): it only passes on the units' request lines. The last column of the source table above names the register to write. For example:

| Source | To clear |
|--------|----------|
| VBLANK | `move.l #VIDSTAT_VBLANK_M,CUSTOM+VIDSTAT` |
| LINE | `move.l #VIDSTAT_LINE_M,CUSTOM+VIDSTAT` |
| BLT | `move.l #DMXINT_BLT_M,CUSTOM+DMXINT` |
| TIMER0 | `move.l #TMR_STAT_UNDER_M,SYSTEM+TMR0_STAT` |
| SOFT | `move.l #SOFTINT_CLR_M,SYSTEM+SOFTINT` |

Turning a source off in INTENA does not clear it. The unit's flag is still set, and if you turn the source back on later, the interrupt happens at once. If you don't want that, clear the flag before turning the source on, as in step 3 above.

### Seeing what is going on

Three read-only registers show the controller's state. They are useful for debugging, and for polling with interrupts off.

- **INTRAW** shows each source's request line, before INTENA. A bit is 1 when the unit is asking (its flag and its own enable are both on).
- **INTPEND** shows the sources that are both requesting and enabled in INTENA, with INTCON.MASTER on. These are the ones that can interrupt the CPU.
- **INTID** holds the source number given at the last interrupt acknowledge (not counting the NMI). If you suspect the wrong handler is being called, read INTID.

### Interrupt controller registers (part 1)

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| INTCON | `$000` | RW | Bit 0 MASTER: all interrupts except NMI on. Off after reset |
| INTENA | `$004` | Set/clear | Bit 31 SET/CLR for sources 15-23 (bits 24-16); bit 15 SET/CLR for sources 0-14 (bits 14-0). All off after reset |
| INTPEND | `$008` | R | Same bits: sources requesting and enabled |
| INTRAW | `$00C` | R | Same bits: sources requesting, before INTENA |
| INTID | `$024` | R | Bits 4-0: source given at the last acknowledge |

---

## Priorities and Levels

### Levels

Each source has a **level**, 1 to 6, or 0 for off. The level decides which interrupts may interrupt which:

- A handler runs with the CPU's mask at its own level. Only sources at a **higher** level can interrupt it.
- When several sources at the **same** level are pending, the one with the **lowest source number** goes first. The others wait until its handler returns.
- A source at level 0 never interrupts, whatever INTENA says.

The defaults put the timers highest, so that an operating system's tick is never held up by graphics, then video, so that vertical blank and line handlers run on time, then audio and the blitter, the serial link, and the slow devices:

```
   level 7   NMI (button, USB break)          cannot be masked
   level 6   TIMER0  TIMER1  TIMER2  TIMER3
   level 5   VBLANK  LINE  COPPER  VIDERR
   level 4   BLT  AUDIO
   level 3   SERIAL
   level 2   SD  KEYB
   level 1   SOFT
   level 0   sources 19-23 (off)

                 Figure 3: Default interrupt levels
                 (within a level, the leftmost goes first)
```

### Changing a level

The levels are held in three registers, eight sources in each, four bits per source. Source n is in INTPRI(n / 8), in bits 4 x (n mod 8) + 2 to 4 x (n mod 8). The fourth bit of each group is unused.

```
   INTPRI0  ($010)   sources 0-7
    31  28 27  24 23  20 19  16 15  12 11   8 7    4 3    0
   +------+------+------+------+------+------+------+------+
   |  7   |  6   |  5   |  4   |  3   |  2   |  1   |  0   |    source
   +------+------+------+------+------+------+------+------+
   |0|lvl |0|lvl |0|lvl |0|lvl |0|lvl |0|lvl |0|lvl |0|lvl |    after reset: $44445555
   +------+------+------+------+------+------+------+------+

   INTPRI1  ($014)   sources 8-15     after reset: $36666444
   INTPRI2  ($018)   sources 16-23    after reset: $00000122

                 Figure 4: The level registers
```

A new level takes effect at once. Change levels with the CPU's mask raised, so that the controller and the CPU never disagree about a request in the middle of an acknowledge.

For example, a raster effect driven by the LINE interrupt must start on time, even when a timer interrupt is due. Move LINE up to level 6:

```asm
            include "hw.inc"

; Move the LINE interrupt (source 1) to level 6. a5 = SYSTEM.
line_to_6:  move.w  sr,-(sp)
            or.w    #$0700,sr
            move.l  INTPRI0(a5),d0
            and.l   #~($F<<(4*INT_LINE)),d0     ; clear source 1's group
            or.l    #6<<(4*INT_LINE),d0         ; level 6
            move.l  d0,INTPRI0(a5)
            move.w  (sp)+,sr
            rts
```

LINE is now at level 6 with the timers, and goes before them when both are pending, because its source number is lower.

A general routine:

```asm
            include "hw.inc"

; Set the level of source d0 (0-23) to d1 (0-6). a5 = SYSTEM.
set_level:  movem.l d0-d3/a0,-(sp)
            move.w  sr,-(sp)
            or.w    #$0700,sr
            moveq   #0,d2
            move.w  d0,d2
            lsr.w   #3,d2                   ; register: source / 8 ...
            lsl.w   #2,d2                   ; ... times 4 bytes
            lea     INTPRI0(a5,d2.w),a0
            and.w   #7,d0
            lsl.w   #2,d0                   ; bit: (source mod 8) x 4
            and.l   #7,d1
            lsl.l   d0,d1                   ; new level, in place
            moveq   #$F,d3
            lsl.l   d0,d3
            not.l   d3                      ; mask to clear the old level
            move.l  (a0),d2
            and.l   d3,d2
            or.l    d1,d2
            move.l  d2,(a0)
            move.w  (sp)+,sr
            movem.l (sp)+,d0-d3/a0
            rts
```

**Note:** Level 7 is kept for the NMI. If you write 7 into a source's level, that source behaves as if it were off.

### Moving the vectors

VECBASE sets the first vector. Source n uses vector VECBASE + n. After reset VECBASE is 64, the first of the 68000's user vectors, so the sources use vectors 64-87. You can move them anywhere from 64 to 232, for example to leave vectors 64-87 to another use. Write the new vectors into the table before you change VECBASE, with the CPU's mask raised.

### Interrupt controller registers (part 2)

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| INTPRI0 | `$010` | RW | Levels of sources 0-7, 4 bits each (0 = off, 1-6) |
| INTPRI1 | `$014` | RW | Levels of sources 8-15 |
| INTPRI2 | `$018` | RW | Levels of sources 16-23 |
| VECBASE | `$01C` | RW | Bits 7-0: first vector, 64-232. 64 after reset |

---

## The Nonmaskable Interrupt

Level 7 cannot be masked by the 68000. retro68k keeps it for getting control back from a program that has hung or gone wild, for example to enter a debug monitor. Two things raise it:

- **The NMI button** on the KS3 (the one the Spectrum Next uses for its Multiface). The FPGA removes contact bounce, so each press gives exactly one NMI.
- **A USB break**: a BREAK command from the PC over the USB link, so a debugger on the PC can stop the 68000 at any moment.

Both use **vector 31**, the 68000's usual level 7 vector. **NMISTAT** tells you which one it was. **NMICON** turns each one on or off; both are on after reset. INTCON.MASTER and INTENA do not affect the NMI.

The NMI is edge-triggered: each press or break gives exactly one interrupt, and the handler does not have to clear anything for the NMI itself to stop. It should still clear NMISTAT, so that next time it can tell which source it was.

The KS3's third button, DivMMC, is not an interrupt. Software reads it in SYSBTN.

### Example: an NMI handler

This handler records which source it was and where the program was running, then carries on. A debug monitor would show these, and let you look at memory, before returning.

```asm
            include "hw.inc"

VECTORS     equ     $000000
nmi_why     equ     $008010                 ; long: NMISTAT at the last NMI
nmi_pc      equ     $008014                 ; long: the PC at the last NMI

nmi_on:     move.l  #nmi,VECTORS+VEC_NMI*4
            move.l  #NMISTAT_BUTTON_M|NMISTAT_USB_M,NMISTAT(a5)  ; forget old ones
            rts

; The stack on entry: SR (word) at 0(sp), PC (long) at 2(sp).
nmi:        move.l  d0,-(sp)
            move.l  SYSTEM+NMISTAT,d0
            move.l  d0,nmi_why
            move.l  d0,SYSTEM+NMISTAT       ; clear the bits that were set
            move.l  4+2(sp),nmi_pc          ; past d0 (4 bytes) and SR (2 bytes)
            move.l  (sp)+,d0
            rte
```

To let only the button raise an NMI, for example when no debugger is attached:

```asm
            include "hw.inc"

nmi_button_only:
            move.l  #NMICON_BUTTONEN_M,NMICON(a5)   ; button on, USB break off
            rts
```

**Note:** The NMI can interrupt anything, including another NMI handler and code running with the mask at 7. Keep the handler simple, and do not let it depend on any data that the interrupted program might have been half-way through changing.

### NMI registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| NMICON | `$028` | RW | Bit 0 BUTTONEN, bit 1 USBEN: allow each NMI source. Both on after reset |
| NMISTAT | `$02C` | W1C | Bit 0 BUTTON, bit 1 USB: which caused the last NMI. Sticky |

---

## The Software Interrupt

The software interrupt is source 18, SOFT, at level 1 (the lowest). It is raised by the CPU itself, by writing SOFTINT.SET. A typical use is to split the work of a high-priority handler in two: the handler does the urgent part, then raises the software interrupt to do the rest. The rest runs at level 1 once every more important handler has finished, and it can itself be interrupted by anything at level 2 or above.

Raise it by writing `SOFTINT_SET_M` to SOFTINT, and clear it by writing `SOFTINT_CLR_M`. SOFTINT cannot be read; to see whether the software interrupt is raised, read bit 18 of INTRAW. Like any other source, it needs its INTENA bit and INTCON.MASTER on.

### Example: deferred work after the vertical blank

```asm
            include "hw.inc"

VECTORS     equ     $000000

soft_on:    move.w  #$2700,sr
            move.l  #softint,VECTORS+(VECBASE_DEFAULT+INT_SOFT)*4
            move.l  #SOFTINT_CLR_M,SOFTINT(a5)
            move.w  #(INTENA_SETCLRH_M|(1<<INTB_SOFT))>>16,INTENA(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.w  #$2000,sr
            rts

; Vertical blank (level 5): the urgent part now, the rest later.
vblank:     move.l  #VIDSTAT_VBLANK_M,CUSTOM+VIDSTAT
            ; ... set display pointers, move sprites ...
            move.l  #SOFTINT_SET_M,SYSTEM+SOFTINT   ; ask for the rest
            rte

; Software interrupt (level 1): runs when nothing more important is waiting.
softint:    move.l  #SOFTINT_CLR_M,SYSTEM+SOFTINT   ; clear first, so a new
                                                    ; request made meanwhile is kept
            movem.l d0-d7/a0-a6,-(sp)
            bsr     game_logic                      ; long work; can be interrupted
            movem.l (sp)+,d0-d7/a0-a6
            rte

game_logic: rts
```

The software handler clears SOFTINT as its first action. If the vertical blank handler raises it again while `game_logic` is running (because a frame went by), the request is kept, and the software handler runs again as soon as it returns.

If main code at mask 0 raises the software interrupt, the handler runs straight away, after the current instruction. If main code is running with its mask at 1 or above, the handler waits until the mask is lowered.

### Software interrupt register

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| SOFTINT | `$020` | W | Bit 0 SET: raise the software interrupt. Bit 1 CLR: clear it |

---

## Timers

retro68k has three kinds of timer, all in the system block:

- the **time counter**, a 64-bit count of 10 ns steps since power-on;
- four **general timers**, each a 32-bit down-counter with a 16-bit prescaler, which can interrupt, or drive the next timer;
- the **watchdog**, which resets the computer if software stops looking after it (see "The Watchdog").

All of them are driven by the FPGA's 100 MHz clock. Times are exact: a timer set for 1 ms gives 1 ms, not an approximation.

### Comparison with the Amiga CIA timers

| Feature | Amiga (8520 CIA) | retro68k |
|---------|------------------|----------|
| Timers | 4 (A and B in each of two CIAs) | 4 (TMR0-TMR3) |
| Width | 16 bits | 32 bits, plus a 16-bit prescaler |
| Clock | About 0.716 MHz (the E clock) | 100 MHz / (PRESCALE + 1), for example exactly 1 MHz |
| Latch | Timer latch, reloaded at underflow | RELOAD, loaded at underflow |
| Modes | One-shot or continuous | One-shot or repeating |
| Other count sources | CNT pin; timer B counts timer A | Video lines, video frames, the previous timer |
| Interrupts | Shared CIA interrupt (level 2 or 6), read ICR to find the cause | One vector per timer, level 6 |
| Time of day | 24-bit event counter | 64-bit 10 ns time counter |

---

### The Time Counter

**TIME** is a 64-bit counter that adds 1 every 10 ns from power-on. It never stops, and you cannot write it. It would take over 5,800 years to wrap. Use it for timestamps, for measuring how long code takes, and for delays and timeouts that need no setting up.

TIME is two registers: **TIMEHI** (bits 63-32) and **TIMELO** (bits 31-0). The 68000 reads them as four 16-bit halves, and TIME changes between each, so the hardware captures the whole counter at once:

- **Reading TIMEHI captures all 64 bits.** TIMEHI returns the high 32 bits of that moment.
- **Reading TIMELO returns the low 32 bits of the last capture**, not the current time.

So always read TIMEHI first, then TIMELO, each with `MOVE.L`:

```
     MOVE.L TIMEHI(a5),d0   ---> high 32 bits now ----+--- capture: one instant
     MOVE.L TIMELO(a5),d1   ---> low 32 bits, from ---+
                                 the capture

                 Figure 5: Reading the time counter
```

**Warning:** If you read TIMELO without reading TIMEHI first, you get an old value: the low half of whatever was captured last. Even when you need only the low 32 bits, read TIMEHI first and throw its value away.

There is one capture for the whole machine. If an interrupt handler also reads TIMEHI, and it interrupts your code between the TIMEHI and TIMELO reads, your TIMELO read returns the handler's capture. For a full 64-bit value, hold off interrupts around the pair:

```asm
            include "hw.inc"

; Read the 64-bit time counter: d0 = high 32 bits, d1 = low 32 bits.
; a5 = SYSTEM.
read_time:  move.w  sr,-(sp)
            or.w    #$0700,sr               ; no handler may take a capture now
            move.l  TIMEHI(a5),d0           ; captures all 64 bits
            move.l  TIMELO(a5),d1           ; the low half of the same instant
            move.w  (sp)+,sr
            rts
```

### Measuring time

The low 32 bits alone wrap every 42.9 seconds. For anything shorter than that, subtracting two TIMELO values gives the right answer, even across a wrap. This measures how long a routine takes:

```asm
            include "hw.inc"

; How long does 'work' take? Result in d7, in 10 ns ticks. a5 = SYSTEM.
profile:    move.l  TIMEHI(a5),d0           ; capture (value not needed)
            move.l  TIMELO(a5),d6           ; start
            bsr     work
            move.l  TIMEHI(a5),d0
            move.l  TIMELO(a5),d7           ; end
            sub.l   d6,d7                   ; elapsed ticks
            rts

work:       rts
```

The reads themselves take a little time. To measure very short routines, run `profile` once with an empty `work` and subtract that result.

A delay routine needs no timer at all:

```asm
            include "hw.inc"

; Wait d0.w microseconds (0-65535). a5 = SYSTEM.
delay_us:   movem.l d0-d2,-(sp)
            mulu    #100,d0                 ; microseconds -> 10 ns ticks
            move.l  TIMEHI(a5),d1
            move.l  TIMELO(a5),d1           ; start
.wait:      move.l  TIMEHI(a5),d2
            move.l  TIMELO(a5),d2           ; now
            sub.l   d1,d2                   ; ticks so far, right across a wrap
            cmp.l   d0,d2
            blo.s   .wait
            movem.l (sp)+,d0-d2
            rts
```

### Time counter registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| TIMEHI | `$100` | R | TIME bits 63-32. Reading its high half captures all 64 bits |
| TIMELO | `$104` | R | TIME bits 31-0, from the last capture |

---

### The General Timers

There are four general timers, TMR0 to TMR3. Each has five registers, in a block of `$20` bytes starting at `$140 + n x $20`:

```
    TMR0  $140      TMR1  $160      TMR2  $180      TMR3  $1A0

    +$00  CTRL       what to count, mode, what to do at underflow
    +$04  PRESCALE   clock divider
    +$08  RELOAD     value loaded at each underflow
    +$0C  COUNT      the counter itself
    +$10  STAT       UNDER flag (sticky)
```

hw.inc gives both forms: `TMR0+TMR_COUNT` and `TMR0_COUNT` are the same offset.

### How a timer works

Each timer has a **COUNT** that goes down by 1 on each tick of its source. When COUNT is 0 and another tick arrives, the timer **underflows**:

- STAT.UNDER is set.
- If CTRL.IRQ is on, the timer requests an interrupt (TIMER0-TIMER3, sources 11-14, level 6).
- The next timer gets a tick, if it is counting this one (SRC 3).
- In **repeating** mode (CTRL.REPEAT on), COUNT is loaded from **RELOAD** and counting goes on.
- In **one-shot** mode (CTRL.REPEAT off), the timer stops: CTRL.EN clears itself and COUNT stays at 0.

```
                     PRESCALE
                        |
   100 MHz --------> [ divide by    ]--+
                     [ PRESCALE + 1 ]  |      CTRL.SRC
   line start -------------------------+---> [ select ]--- tick ---+
   frame start ------------------------+                           |
   previous timer underflow -----------+                           v
                                                    +----------------------+
              RELOAD ------- (repeating) ---------->|  COUNT  (32 bits)    |
                                                    |  down by 1 per tick  |
                                                    +----------+-----------+
                                                               | tick at 0: underflow
                         +---------------+---------------------+
                         v               v                     v
                  STAT.UNDER set   interrupt if            tick for
                                   CTRL.IRQ                next timer

                 Figure 6: One general timer
```

Because the timer underflows on the tick **after** COUNT reaches 0, a timer with COUNT = n underflows after n + 1 ticks, and a repeating timer with RELOAD = n underflows every n + 1 ticks. This is the same as the Amiga CIA. When the source is the 100 MHz clock, the time between underflows is

```
    period = (PRESCALE + 1) x (RELOAD + 1) x 10 ns
```

Writing COUNT sets it at once. Writing RELOAD changes nothing until the next underflow, so you can change a repeating timer's period while it runs and it never gives one odd-length period. COUNT can be read at any time; `MOVE.L` gets a matching pair of halves.

When CTRL.EN is turned on, the prescaler starts again from the beginning, so the first period is as long as the others.

### What a timer counts

CTRL.SRC chooses the ticks:

| SRC | Ticks on | Use |
|-----|----------|-----|
| 0 | The 100 MHz clock divided by PRESCALE + 1 | Fixed rates. PRESCALE = 99 gives exactly 1 MHz (1 us ticks) |
| 1 | The start of each video line | Timing in lines, e.g. "every 10 lines" |
| 2 | The start of each frame (vertical blanking) | Counting frames, e.g. "every 3 frames" |
| 3 | The underflow of the previous timer (timer 0 counts timer 3) | Chaining timers |

PRESCALE matters only for SRC 0. Lines and frames come from the video timing, so they are counted even while the display is blank, as long as the video timing generator runs.

```
   TMRn CTRL
    31                    5   4   3   2   1   0
   +-----------------------+---+-------+---+---+
   |        (unused)       |IRQ|  SRC  |REP| EN|
   +-----------------------+---+-------+---+---+

   EN      1 = running. Cleared by the timer at underflow in one-shot mode
   REPEAT  1 = repeating, 0 = one-shot
   SRC     0 = prescaled clock, 1 = lines, 2 = frames, 3 = previous timer
   IRQ     1 = interrupt at underflow

                 Figure 7: Timer control register
```

### Choosing the settings

| You want | SRC | PRESCALE | RELOAD (or COUNT) | Mode |
|----------|-----|----------|-------------------|------|
| 1 us ticks | 0 | 99 | | |
| Operating system tick, 1000 Hz | 0 | 99 | 999 | Repeating |
| 100 Hz | 0 | 99 | 9,999 | Repeating |
| Music player, 50 Hz (125 BPM, 24 ticks per beat) | 0 | 99 | 19,999 | Repeating |
| Sample rate 8 kHz (125 us) | 0 | 0 | 12,499 | Repeating |
| 2 second timeout | 0 | 99 | COUNT 1,999,999 | One-shot |
| Every 3 frames | 2 | | 2 | Repeating |
| After n more lines | 1 | | COUNT n - 1 | One-shot |

The finest step is 10 ns (PRESCALE 0), giving times up to 42.9 seconds. The longest single period, with PRESCALE 65,535 and RELOAD `$FFFFFFFF`, is about 32 days.

### Setting up a timer

1. Stop the timer: `move.l #0,TMRn+TMR_CTRL(a5)`.
2. Clear STAT.UNDER, so an old underflow doesn't give an interrupt at once.
3. Write PRESCALE, RELOAD and COUNT.
4. If you want an interrupt, install the vector and turn on the source in INTENA and INTCON.MASTER.
5. Write CTRL with EN and the other bits you want, all in one write.

### Example: a periodic interrupt

This is the tick an operating system needs: timer 0 interrupts 1000 times a second, and the handler counts milliseconds.

```asm
            include "hw.inc"

VECTORS     equ     $000000
ticks       equ     $008000                 ; long: milliseconds since tick_on

; Start a 1000 Hz tick on timer 0. a5 = SYSTEM.
tick_on:    move.w  #$2700,sr
            move.l  #0,TMR0+TMR_CTRL(a5)                ; 1. stop (not CLR.L)
            move.l  #TMR_STAT_UNDER_M,TMR0+TMR_STAT(a5) ; 2. no old underflow
            move.l  #99,TMR0+TMR_PRESCALE(a5)           ; 3. 100 MHz / 100 = 1 MHz
            move.l  #999,TMR0+TMR_RELOAD(a5)            ;    1000 ticks a period
            move.l  #999,TMR0+TMR_COUNT(a5)             ;    the first period too
            move.l  #0,ticks
            move.l  #tick,VECTORS+(VECBASE_DEFAULT+INT_TIMER0)*4  ; 4.
            move.w  #INTENA_SETCLRL_M|(1<<INTB_TIMER0),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|TMR_CTRL_IRQ_M,TMR0+TMR_CTRL(a5)  ; 5.
            move.w  #$2000,sr
            rts

tick:       move.l  #TMR_STAT_UNDER_M,SYSTEM+TMR0_STAT  ; clear the cause
            addq.l  #1,ticks
            rte

; Stop the tick. a5 = SYSTEM.
tick_off:   move.l  #0,TMR0+TMR_CTRL(a5)
            move.l  #TMR_STAT_UNDER_M,TMR0+TMR_STAT(a5)
            rts
```

SRC is 0 because no SRC bits are set in the CTRL value.

### Example: a timeout without interrupts

STAT.UNDER is set at every underflow, even when CTRL.IRQ is off. So a one-shot timer makes a simple timeout that you poll. This waits for a device to become ready, giving up after 2 seconds:

```asm
            include "hw.inc"

; Wait until 'check_ready' returns Z clear, for up to 2 seconds, using timer 1.
; Returns d0 = 0 if ready, -1 on timeout. a5 = SYSTEM.
wait_ready: move.l  #0,TMR1+TMR_CTRL(a5)
            move.l  #TMR_STAT_UNDER_M,TMR1+TMR_STAT(a5)
            move.l  #99,TMR1+TMR_PRESCALE(a5)           ; 1 MHz
            move.l  #1999999,TMR1+TMR_COUNT(a5)         ; 2,000,000 us
            move.l  #TMR_CTRL_EN_M,TMR1+TMR_CTRL(a5)    ; one-shot, no interrupt
.poll:      bsr     check_ready
            bne.s   .ready
            move.l  TMR1+TMR_STAT(a5),d0
            btst    #TMR_STAT_UNDER_B,d0
            beq.s   .poll
            moveq   #-1,d0                              ; timed out
            rts
.ready:     move.l  #0,TMR1+TMR_CTRL(a5)                ; stop the timer
            moveq   #0,d0
            rts

check_ready:
            moveq   #0,d0                               ; (your test here)
            rts
```

---

### Counting Lines and Frames

With SRC 1 a timer counts video lines, and with SRC 2 it counts frames. These are useful for things that must keep in step with the display without using the CPU every frame.

### Example: an interrupt every third frame

```asm
            include "hw.inc"

VECTORS     equ     $000000

; Timer 2: an interrupt every third frame. a5 = SYSTEM.
every3_on:  move.w  #$2700,sr
            move.l  #0,TMR2+TMR_CTRL(a5)
            move.l  #TMR_STAT_UNDER_M,TMR2+TMR_STAT(a5)
            move.l  #2,TMR2+TMR_RELOAD(a5)              ; 3 frames a period
            move.l  #2,TMR2+TMR_COUNT(a5)
            move.l  #every3,VECTORS+(VECBASE_DEFAULT+INT_TIMER2)*4
            move.w  #INTENA_SETCLRL_M|(1<<INTB_TIMER2),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|(2<<TMR_CTRL_SRC_B)|TMR_CTRL_IRQ_M,TMR2+TMR_CTRL(a5)
            move.w  #$2000,sr
            rts

every3:     move.l  #TMR_STAT_UNDER_M,SYSTEM+TMR2_STAT
            ; ... work to do every third frame ...
            rte
```

The timer interrupts at level 6, at the start of vertical blanking. If you also use the vertical blank interrupt (level 5), this handler runs first.

### Example: waiting a number of lines

The first line tick is the start of the next line, which may be almost a whole line away or only a few pixels. So a one-shot timer with COUNT = n - 1 underflows at the start of the nth line from now:

```asm
            include "hw.inc"

; Wait until the start of the d0'th line from now (d0 = 1 or more), with timer 3.
; a5 = SYSTEM.
wait_lines: move.l  #0,TMR3+TMR_CTRL(a5)
            move.l  #TMR_STAT_UNDER_M,TMR3+TMR_STAT(a5)
            subq.l  #1,d0
            move.l  d0,TMR3+TMR_COUNT(a5)
            move.l  #TMR_CTRL_EN_M|(1<<TMR_CTRL_SRC_B),TMR3+TMR_CTRL(a5)  ; one-shot, lines
.wait:      move.l  TMR3+TMR_STAT(a5),d0
            btst    #TMR_STAT_UNDER_B,d0
            beq.s   .wait
            rts
```

For one change at an exact place on the screen, the copper or the LINE interrupt is usually the better tool. A line timer is handy when you want "every 10 lines", or a delay counted in lines.

---

### Chaining Timers

With SRC 3 a timer counts the underflows of the timer before it. The four timers form a ring: timer 1 counts timer 0, timer 2 counts timer 1, timer 3 counts timer 2, and timer 0 counts timer 3.

```
        +---------+      +---------+      +---------+      +---------+
   +--->| TMR0    |----->| TMR1    |----->| TMR2    |----->| TMR3    |---+
   |    +---------+      +---------+      +---------+      +---------+   |
   |       underflow  ->  tick (if SRC 3), and so on round the ring      |
   +---------------------------------------------------------------------+

                 Figure 8: The timer chain
```

A timer counts the previous one's underflows whatever the previous timer's IRQ and DMA settings, but only while the previous timer is running.

### Example: a slow timer counting a fast one

Timer 0 is already giving a 1000 Hz tick (see "Example: a periodic interrupt"). Timer 1 counts its underflows, and interrupts once a second:

```asm
            include "hw.inc"

VECTORS     equ     $000000
seconds     equ     $008004                 ; long: seconds counted

; Timer 1: one interrupt for every 1000 underflows of timer 0. a5 = SYSTEM.
sec_on:     move.w  #$2700,sr
            move.l  #0,TMR1+TMR_CTRL(a5)
            move.l  #TMR_STAT_UNDER_M,TMR1+TMR_STAT(a5)
            move.l  #999,TMR1+TMR_RELOAD(a5)            ; 1000 x 1 ms
            move.l  #999,TMR1+TMR_COUNT(a5)
            move.l  #second,VECTORS+(VECBASE_DEFAULT+INT_TIMER1)*4
            move.w  #INTENA_SETCLRL_M|(1<<INTB_TIMER1),INTENA+2(a5)
            move.l  #INTCON_MASTER_M,INTCON(a5)
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_REPEAT_M|(3<<TMR_CTRL_SRC_B)|TMR_CTRL_IRQ_M,TMR1+TMR_CTRL(a5)
            move.w  #$2000,sr
            rts

second:     move.l  #TMR_STAT_UNDER_M,SYSTEM+TMR1_STAT
            addq.l  #1,seconds
            rte
```

Both handlers are at level 6. When both timers underflow together, timer 0's handler (source 11) goes before timer 1's (source 12).

### A 64-bit timer

Two chained timers make one 64-bit down-counter: the low timer counts the clock with RELOAD `$FFFFFFFF`, and the high timer (SRC 3) counts the low timer's underflows. Read the pair high, low, high again, and try again if the high half changed:

```asm
            include "hw.inc"

; Read timers 1 (high) and 0 (low), chained, as one 64-bit count.
; d0 = high, d1 = low. d2 is changed. a5 = SYSTEM.
read_chain: move.l  TMR1+TMR_COUNT(a5),d0
            move.l  TMR0+TMR_COUNT(a5),d1
            move.l  TMR1+TMR_COUNT(a5),d2
            cmp.l   d0,d2
            bne.s   read_chain              ; timer 0 underflowed meanwhile
            rts
```

For measuring time, the time counter is usually simpler. A chained pair is useful as a very long countdown with an interrupt at the end.

### General timer registers

Timer n at `$140 + n x $20`:

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| TMR_CTRL | `+$00` | RW | EN (0), REPEAT (1), SRC (3-2), IRQ (4). 0 after reset |
| TMR_PRESCALE | `+$04` | RW | Bits 15-0: divide 100 MHz by PRESCALE + 1, for SRC 0 |
| TMR_RELOAD | `+$08` | RW | Loaded into COUNT at each underflow in repeating mode |
| TMR_COUNT | `+$0C` | RW | The count. Goes down by 1 a tick; writing sets it |
| TMR_STAT | `+$10` | W1C | Bit 0 UNDER: the timer has underflowed. Sticky |

---

## The Watchdog

The watchdog resets the computer if software hangs. You give it a time limit, and your program must **kick** it, by writing a special value, before the time runs out. If the program stops kicking it, because it is stuck in a loop or has crashed, the watchdog resets the CPU and all the custom hardware, as at power-on. The FPGA keeps its configuration.

- **WDTIME** sets the time allowed between kicks, in milliseconds, 1 to 65,535.
- **WDCTRL.EN** turns the watchdog on, and starts the time.
- Writing **`$5A5A`** (`WDKICK_MAGIC`) to **WDKICK** kicks it: the time starts again from WDTIME.
- Writing **any other value** to WDKICK resets the computer at once. A program running wild is unlikely to write exactly `$5A5A` to exactly this address, and quite likely to write something else, so a bad program is caught quickly.
- **WDCTRL.LOCK** makes WDCTRL and WDTIME read-only until the next reset, so a program cannot turn the watchdog off by mistake. You set LOCK in the same write as EN.

The watchdog is off after reset, so the boot ROM and simple programs need not know about it.

```
    WDCTRL.EN = 1      kick             kick                       no kick
         |              |                 |                           |
         |<-- WDTIME -->|                 |<--------- WDTIME -------->|
    -----+--------------+-----------------+---------------------------X----
                                                                     reset

                 Figure 9: The watchdog
```

### Example: using the watchdog

```asm
            include "hw.inc"

; Turn the watchdog on with half a second's grace, and lock it. a5 = SYSTEM.
wd_on:      move.l  #500,WDTIME(a5)                         ; 500 ms
            move.l  #WDCTRL_EN_M|WDCTRL_LOCK_M,WDCTRL(a5)   ; on and locked: the time starts
            rts

; Kick the watchdog: once each time round the main loop. a5 = SYSTEM.
wd_kick:    move.l  #WDKICK_MAGIC,WDKICK(a5)
            rts
```

**Kick from the main loop, not from an interrupt handler.** Interrupts usually keep running when the main program hangs, so a handler that kicks the watchdog would keep it happy for ever and the watchdog would never catch the hang. If your main loop sometimes takes longer than WDTIME (loading a file, for example), kick it in the long job too, or choose a longer time.

### Finding out why the computer reset

After any reset, **RESETWHY** in the system control registers says why it happened. Bit `RESETWHY_WATCHDOG_B` is set after a watchdog reset. Check it at start-up, for example to tell the user that the last program hung:

```asm
            include "hw.inc"

; At start-up: was the last reset caused by the watchdog? a5 = SYSTEM.
why_reset:  move.l  RESETWHY(a5),d0
            btst    #RESETWHY_WATCHDOG_B,d0
            beq.s   .normal
            bsr     report_hang                 ; the last program hung
.normal:    rts

report_hang:
            rts
```

### Watchdog details

- Writing WDCTRL also starts the time again from WDTIME, like a kick. A new WDTIME is used from the next kick or WDCTRL write.
- The time is counted in whole milliseconds, so the watchdog fires between WDTIME and WDTIME + 1 ms after the last kick.
- WDKICK is ignored while the watchdog is off, whatever value you write.
- Write WDKICK with `MOVE.L` or with `MOVE.W` to `WDKICK+2`. A byte write is a wrong kick and resets the computer.
- WDTIME is 1000 (1 second) after reset.

### Watchdog registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| WDCTRL | `$1C0` | RW (lockable) | Bit 0 EN: on. Bit 1 LOCK: settings read-only until reset. 0 after reset |
| WDTIME | `$1C4` | RW (lockable) | Bits 15-0: time allowed between kicks, in milliseconds |
| WDKICK | `$1C8` | W | Write `$5A5A` to start the time again; any other value resets at once |

---

## Register Summary

All registers are in the system block. Addresses are `SYSTEM` (`$F00000`) plus the offset. All are 32 bits wide; see "Rules for the registers" at the start of this chapter.

### Interrupt controller

| Address | Name | Access | Function |
|---------|------|--------|----------|
| `$F00000` | INTCON | RW | MASTER (0): all interrupts except NMI on |
| `$F00004` | INTENA | Set/clear | SETCLRH (31), SRCH (24-16) = sources 15-23; SETCLRL (15), SRCL (14-0) = sources 0-14 |
| `$F00008` | INTPEND | R | SRCH (24-16), SRCL (14-0): requesting and enabled |
| `$F0000C` | INTRAW | R | SRCH (24-16), SRCL (14-0): requesting, before INTENA |
| `$F00010` | INTPRI0 | RW | Levels of sources 0-7, 4 bits each |
| `$F00014` | INTPRI1 | RW | Levels of sources 8-15 |
| `$F00018` | INTPRI2 | RW | Levels of sources 16-23 |
| `$F0001C` | VECBASE | RW | VEC (7-0): first vector, 64-232 |
| `$F00020` | SOFTINT | W | SET (0), CLR (1): the software interrupt |
| `$F00024` | INTID | R | SRC (4-0): source at the last acknowledge |
| `$F00028` | NMICON | RW | BUTTONEN (0), USBEN (1) |
| `$F0002C` | NMISTAT | W1C | BUTTON (0), USB (1) |

### Timers and watchdog

| Address | Name | Access | Function |
|---------|------|--------|----------|
| `$F00100` | TIMEHI | R | TIME 63-32; reading captures all 64 bits |
| `$F00104` | TIMELO | R | TIME 31-0, from the capture |
| `$F00140` | TMR0_CTRL | RW | EN (0), REPEAT (1), SRC (3-2), IRQ (4) |
| `$F00144` | TMR0_PRESCALE | RW | DIV (15-0): 100 MHz / (DIV + 1), for SRC 0 |
| `$F00148` | TMR0_RELOAD | RW | Value loaded at each underflow, repeating mode |
| `$F0014C` | TMR0_COUNT | RW | Current count |
| `$F00150` | TMR0_STAT | W1C | UNDER (0) |
| `$F00160`-`$F00170` | TMR1_... | | Timer 1, as timer 0 |
| `$F00180`-`$F00190` | TMR2_... | | Timer 2, as timer 0 |
| `$F001A0`-`$F001B0` | TMR3_... | | Timer 3, as timer 0 |
| `$F001C0` | WDCTRL | RW (lockable) | EN (0), LOCK (1) |
| `$F001C4` | WDTIME | RW (lockable) | MS (15-0): milliseconds between kicks |
| `$F001C8` | WDKICK | W | KEY (15-0): `$5A5A` to kick |

### State after reset

| Register | After reset |
|----------|-------------|
| INTCON | 0: master off |
| INTENA | 0: every source off |
| INTPRI0, 1, 2 | `$44445555`, `$36666444`, `$00000122` (the default levels) |
| VECBASE | 64 |
| SOFTINT | Not raised |
| NMICON | `$3`: button and USB break both on |
| NMISTAT | 0 |
| TIME | Counts on from power-on; not reset by other resets |
| TMRn_CTRL, PRESCALE, RELOAD, COUNT, STAT | 0: every timer stopped |
| WDCTRL | 0: watchdog off, unlocked |
| WDTIME | 1000 |

### Equates in hw.inc

| Name | Value | Meaning |
|------|-------|---------|
| `SYSTEM` | `$F00000` | The system block |
| `INT_VBLANK` ... `INT_SOFT` | 0 ... 18 | Source numbers |
| `VECBASE_DEFAULT` | 64 | VECBASE after reset |
| `VEC_NMI` | 31 | NMI vector |
| `VEC_SPURIOUS` | 24 | Spurious-interrupt vector |
| `TMR0` ... `TMR3` | `$140` ... `$1A0` | Timer blocks; `TMR_NUM` = 4, `TMR_SPAN` = `$20` |
| `TMR_CTRL`, `TMR_PRESCALE`, `TMR_RELOAD`, `TMR_COUNT`, `TMR_STAT` | `$0` ... `$10` | Offsets within a timer block |
| `WDKICK_MAGIC` | `$5A5A` | The kick value |
