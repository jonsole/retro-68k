# Spec 10: Copper

Status: **v1 scope**

## 1. Summary

The copper is a small coprocessor that follows the beam, as on the Amiga: it runs a list of instructions from Chip RAM every frame and writes custom registers at chosen beam positions. It changes colours partway down the screen, resets the bitplane pointers for each frame, opens split screens, and so on, without the CPU.

| Item | Value |
|------|-------|
| Program | A list of 32-bit instructions in Chip RAM, restarted from COP1LC at the start of every frame (beam line 0: the start of the vertical blank) |
| Instructions | MOVE, WAIT, SKIP (as the Amiga), plus JUMP and STOP; MOVE through X and Y; ADD, SUB, AND, OR, CMP, LD, ST; SKIP on a condition; CALL and RET |
| Registers | X and Y (16 bits), the flags (Z, N, C), 8 storage registers COPR0–7, a return stack 8 deep. The CPU can read and write all but the stack contents |
| Can write | The custom register block only (`0xE00000`–`0xE07FFF`, the reach of a MOVE's 15-bit offset): every register there and the palette. Not the system block |
| Beam position | Full range (11-bit line and pixel), pixel exact |
| Memory | Its own DMA channel in the scheduler (spec 5, section 6): best effort, cycle 4 and any cycle nobody else wants; COPCON.PRI can raise it (section 5) |
| Prefetch | The next instruction, so the MOVE after a WAIT runs as soon as the WAIT is over |
| Interrupt | A MOVE to COPINT raises the copper's interrupt (source COPPER) |

## 2. Comparison with the Amiga

| | Amiga | retro68k v1 |
|--|-------|-------------|
| Instructions | MOVE, WAIT, SKIP, 32 bits each | The same, plus JUMP and STOP, and the instructions below |
| Registers and arithmetic | None | X and Y: MOVE through them, ADD, SUB, AND, OR, CMP; flags and a conditional SKIP; 8 storage registers (section 4.2) |
| Subroutines | None | CALL and RET, with a stack 8 deep (section 4.4) |
| MOVE | 16-bit data to a custom register | The same: 16-bit data to a register half; a 32-bit register (a BPLxPT) takes two MOVEs, high half first |
| WAIT/SKIP position | 8-bit line (wraps after line 255), horizontal in steps of 4 low-resolution pixels, with compare masks | 11-bit line and pixel, pixel exact. No masks: a **pixel-only** WAIT repeats an effect on every line |
| Waiting for the blitter | BFD bit in WAIT | The same: the BLT bit waits until the DMA engine is idle too |
| Lists | COP1LC, COP2LC; strobes COPJMP1, COPJMP2; list 1 restarts each frame | The same, plus COPCON.RESUME: a list 2 cut off by the vertical blank can carry on where it stopped (section 6.1) |
| Jumping | A MOVE to COPJMP2 | JUMP to any address; the strobes still work |
| End of list | WAIT for an impossible position ($FFFFFFFE) | STOP, or a WAIT for line 2047 (the Amiga's $FFFFFFFE itself is a reserved pattern here: it stops too, but sets COPSTAT.ERR) |
| Interrupt | A MOVE to INTREQ | A MOVE to COPINT |
| Protection | CDANG guards the low registers | The copper can't reach the system block at all |
| Speed | One instruction per 8 low-resolution pixels or so | Waits are pixel exact; a MOVE after a WAIT is prefetched |

## 3. Beam positions

WAIT and SKIP positions are in **beam coordinates** (spec 4, section 3.3): line 0 is the start of the vertical blank and the picture is lines 49–624; pixel 0 is the start of a line's horizontal blank and the picture is pixels 144–863. The list restarts from COP1LC at the start of each frame, beam line 0, pixel 0, so its writes for the coming picture (plane pointers, colours) land in the 49 blank lines before the picture's first line is fetched. Positions only go up through a frame.

- A WAIT for line n, pixel 0 ends at the start of line n's horizontal blank: the place for changes that must be in place before line n's picture (on line n, from pixel 144).
- A position the beam has already passed in this frame satisfies a WAIT at once and makes a SKIP skip.

## 4. Instructions

Every instruction is 32 bits, at a 4-byte-aligned address. Bit 31 says which kind; for bit 31 = 1, bits 30–28 are the operation:

```
 MOVE   0 | register offset (30-16, even)          | data (15-0)
 WAIT   1 | 000 | P | line (26-16)        | B | 0000 | pixel (10-0)
 SKIP   1 | 001 | P | line (26-16)        | 0 | 0000 | pixel (10-0)
 JUMP   1 | 010 | 0000 0 | address (22-2), bits 1-0 = 0
 STOP   1 | 011 | 0 ...
 MOVR   1 | 100 | A | S | I | X | 0000 0000 | data or offset (15-0)       section 4.1
 ALU    1 | 101 | fn (27-25) | d (24-23) | s (22-21) | 0 ... | value or n (15-0)   section 4.2
 SKIPC  1 | 110 | cc (27-24) | 0 ...                                       section 4.3
 CALL   1 | 111 | R | 0000 | address (22-2), bits 1-0 = 0 (R = 1: RET)   section 4.4
```

| Instruction | Does |
|-------------|------|
| **MOVE** | Writes the 16-bit data to the register half at that byte offset in the custom block (`0xE00000` + offset). An offset with bit 1 clear is a high half, with bit 1 set a low half. Each MOVE writes its half at once, keeping the other half (spec 3, section 2), as on the Amiga: a 32-bit register (a BPLxPT) takes two MOVEs, high half first, and holds the new high half and the old low half in between. A palette entry is the exception: its high half is held (one for the copper, apart from the CPU's) until the copper's next MOVE to its low half, so a colour changes all at once. 16-bit registers (BPLxDAT, BPLSTRIDE, DMACON, the strobes) need one MOVE, to their low half |
| **WAIT** | Waits until the beam has reached the position (section 3): it ends on the position itself. A position the beam never reaches (pixel 864 or more, line 625 or more) waits until the next frame. With **P** set (pixel only), the line is ignored: it waits until the pixel position is reached on the current line, or on the next line if it has already passed. With **B** set, it also waits until the DMA engine (spec 11) is idle: no job running or waiting to start, including one a MOVE just before started |
| **SKIP** | If the beam has reached the position, skips the next instruction. With P set, compares the pixel position only |
| **JUMP** | Continues at the address |
| **STOP** | Stops until the next frame (or a COPJMP strobe). A WAIT for line 2047 does the same, as on the Amiga |

Unused bit patterns are reserved; the copper treats them as STOP and sets COPSTAT.ERR. Bits shown as 0 must be 0.

**Loops:** SKIP and JUMP make loops that end at a beam position. For example, to repeat a block of MOVEs on every line until line 400: `loop: WAIT P 0, 0` … MOVEs … `SKIP 400, 0` / `JUMP loop`. Loops that end on a count or a value use the registers and SKIPC (sections 4.2, 4.3).

### 4.1 MOVR: MOVE through X and Y

MOVR is a MOVE whose register offset, or data, or both, come from the copper's registers X and Y (section 4.2):

| Bit | Name | Meaning |
|-----|------|---------|
| 27 | A | The register offset is X (bits 14–1 of X; bits 15 and 0 are ignored) |
| 26 | S | The data is a register: X if bit 24 is set, else Y |
| 25 | I | After the write, X = X + 2 (only with A) |
| 24 | X | With S: the data register is X |

Bits 15–0 hold the data when S is clear, or the register offset (as in MOVE, bits 14–1) when S is set and A clear; with A and S both set they are 0. A and S both clear is reserved. A MOVR follows every MOVE rule: the halves rule, strobes, and the reach (the custom block only).

| Form | Macro | Does |
|------|-------|------|
| A | `CMOVX value` | (X) ← value |
| A, I | `CMOVXP value` | (X) ← value, then X = X + 2 |
| S | `CMOVR reg,CX` / `CMOVR reg,CY` | reg ← X or Y |
| A, S | `CMOVXR CY` | (X) ← Y (or X) |
| A, S, I | `CMOVXRP CY` | (X) ← Y (or X), then X = X + 2 |

With I, a run of MOVRs walks through consecutive register halves: the palette, a layer's pointers, and so on.

### 4.2 Registers and the ALU

The copper has these registers, all 16 bits except the flags and the stack depth. The CPU and the copper can read and write them at their custom-register addresses (section 6); a copper MOVE to COPX loads X, for example.

| Register | Address | |
|----------|---------|--|
| X, Y | COPX, COPY | Working registers: addresses (MOVR) and data |
| Flags | COPFLAGS | Z (0): the result was 0. N (1): bit 15 of the result. C (2): carry out of an ADD, borrow from a SUB or CMP |
| R0–R7 | COPR0–COPR7 | Storage: to save X, Y and the flags, to keep values between frames, and to pass values to and from the CPU |

The **ALU** instruction: `fn` (bits 27–25) is the function, `d` (24–23) the register it works on (0 X, 1 Y, 3 the flags; 2 is reserved), and `s` (22–21) the source: 0 the 16-bit value in bits 15–0, 1 X, 2 Y, 3 Rn with n in bits 2–0.

| fn | Name | Does | Flags |
|----|------|------|-------|
| 0 | LD | d = source. d may be the flags (bits 2–0 of the source) | Only LD to the flags changes them |
| 1 | ST | Rn = d (s must be 3). d may be the flags | Unchanged |
| 2 | ADD | d = d + source | Z, N, C (carry) |
| 3 | SUB | d = d − source | Z, N, C (borrow: d < source, unsigned) |
| 4 | AND | d = d AND source | Z, N; C cleared |
| 5 | OR | d = d OR source | Z, N; C cleared |
| 6 | CMP | d − source, result not kept | Z, N, C as SUB |
| 7 | – | Reserved | |

ADD to CMP work on X or Y only: with d = the flags they are reserved. All arithmetic is 16 bits and wraps. Macros: `CLDI`, `CLD`, `CST`, `CADDI`/`CADD`, `CSUBI`/`CSUB`, `CANDI`/`CAND`, `CORI`/`COR`, `CCMPI`/`CCMP`; the `I` forms take a value, the others a register (`CX`, `CY`, `CR0`–`CR7`).

The vertical blank and the COPJMP strobes never change X, Y, the flags or R0–R7.

### 4.3 SKIPC: SKIP on a condition

Skips the next instruction if the condition `cc` (bits 27–24) holds, as the 68000's conditions:

| cc | Name | Skips if | After `CMP d,source` |
|----|------|----------|----------------------|
| 0 | EQ | Z | d = source |
| 1 | NE | not Z | d ≠ source |
| 2 | LO | C | d < source (unsigned) |
| 3 | HS | not C | d ≥ source |
| 4 | MI | N | bit 15 of d − source set |
| 5 | PL | not N | bit 15 clear |
| 6 | HI | not C and not Z | d > source |
| 7 | LS | C or Z | d ≤ source |

Codes 8–15 are reserved. Macros `CSKIPEQ` … `CSKIPLS`. A loop of N passes: `CLDI CY,N` / `loop:` … `CSUBI CY,1` / `CSKIPEQ` / `CJUMP loop`.

### 4.4 CALL and RET

**CALL** pushes the address of the next instruction onto the copper's stack and continues at the address. **RET** (bit 27 set) pops an address and continues there. The stack is inside the copper (the copper does not write memory), **8 entries** deep; COPSP reads how many are in use. A CALL with the stack full, or a RET with it empty, stops the copper and sets COPSTAT.ERR.

At each vertical blank the stack is emptied, unless **COPCON.STKKEEP** is set: then it is kept as it is, and list 1 starts with it. The COPJMP strobes do not change the stack; a CPU write to COPSP empties it.

Macros `CCALL address`, `CRET`.

## 5. Timing

- **Beam position:** the copper compares against the beam position seen on the memory side (spec 4, section 3.1), a few clocks behind the pixel clock. A WAIT ends within about one pixel of its position.
- **MOVE after a WAIT:** the next instruction is already fetched, so the write happens 10–20 ns after the WAIT ends. Writes that follow need their own fetches.
- **Every instruction is one fetch** (two words), the new ones included; an ALU instruction takes one extra clock. JUMP, CALL, RET and a SKIP or SKIPC that skips throw the prefetched instruction away, so the instruction after them is fetched fresh. A loop therefore costs a fetch for every instruction in it, every pass: unrolled MOVEs are faster, loops are shorter.
- **Fetches:** each instruction is two 16-bit words. At PRI 0 the copper's channel is best effort: it gets cycle 4 and any other cycle nobody else wants (spec 5, section 6), which is usually plenty but not guaranteed on a busy screen. At PRI 1 cycle 4 is its own: at least 20 MB/s, one instruction every 200 ns or better (about 5 pixels at 576p), and faster when the memory is quiet: in simulation, with one word fetched at a time, one instruction every 140 ns (about 4 pixels) in the vertical blank.
- **Priority (COPCON.PRI):** a list that must make many writes quickly can raise the copper's priority:

  | PRI | The copper gets |
  |-----|-----------------|
  | 0, normal | Cycle 4 and the cycles nobody else wants, after audio (the default) |
  | 1, high | Cycle 4 as its own, and first place in the free order: ahead of audio, the DMA engine, and display fetches that are not urgent |
  | 2, nasty | As 1, and it may also take the CPU's cycle 0, like the Amiga's blitter-nasty mode; the CPU's access then waits one slot |

  An urgent display fetch (spec 4, section 5.6) still comes first at every level, so raising the copper never spoils the picture. PRI matters only while the copper has an instruction to fetch: while it waits, it takes nothing.
- **When writes take effect:** as for the CPU (spec 4, section 5.4): the palette at once (a colour change shows within about 1–2 pixels of the WAIT position), layer settings from the next line, BPLxPT, BPLSTRIDE and BPLxDAT at once.
- **Register bus:** the copper and the CPU share the register bus; a CPU access already on the bus goes first, so a copper write may wait one clock (10 ns).

## 6. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x700` | COPCON | RW | EN (0), IRQEN (1), RESUME (2), STKKEEP (3), PRI (5–4) | Copper on (DMACON.DMAEN and COPEN must also be set); COPINT raises the interrupt; the vertical blank saves list 2's place in COP2LC (section 6.1); the vertical blank keeps the stack (section 4.4); priority for memory cycles (section 5): 0 normal, 1 high, 2 nasty |
| `0x704` | COP1LC | RW | 22–2 | First list: restarted at every vertical blank |
| `0x708` | COP2LC | RW | 22–2 | Second list: runs when COPJMP2 is written. The vertical blank reloads the copper from COP1LC only. COP2LC is changed by the hardware only with COPCON.RESUME set (section 6.1) |
| `0x70C` | COPJMP1 | W | – | Strobe: restart at COP1LC now |
| `0x710` | COPJMP2 | W | – | Strobe: continue at COP2LC now |
| `0x714` | COPPC | R | 22–2 | The instruction being run; when stopped, the STOP (or the reserved instruction) that stopped it |
| `0x718` | COPSTAT | RW1C | WAITING (0), STOPPED (1), ERR (2), IRQ (3) | ERR (a reserved instruction) and IRQ (set by COPINT) are sticky: write 1 to clear |
| `0x71C` | COPINT | W | – | Strobe: sets COPSTAT.IRQ. Meant to be written by the copper itself |
| `0x720` | COPX | RW | 15–0 | X (section 4.2) |
| `0x724` | COPY | RW | 15–0 | Y |
| `0x728` | COPFLAGS | RW | Z (0), N (1), C (2) | The flags |
| `0x72C` | COPSP | RW | 3–0 | Read: entries in use on the stack (0–8). Write (any value): empty the stack |
| `0x740`–`0x75C` | COPR0–COPR7 | RW | 15–0 | Storage registers R0–R7 |

**Strobes** (COPJMP1, COPJMP2, COPINT) act on any write that reaches their low half (a MOVE to the low half, or a CPU MOVE.W to address + 2, or MOVE.L).

**The copper's registers from the CPU:** COPX, COPY, COPFLAGS and COPR0–7 are 16-bit registers in the low half. The CPU can write them at any time; a write lands between two copper instructions. To hand values to a running list without a race, write them while the copper is stopped or idle, or use storage registers that only one side writes.

**Restarting** (the vertical blank, COPJMP1, COPJMP2) throws away the prefetched instruction.

**Starting:** after reset COPCON, COP1LC, COP2LC, COPSTAT, X, Y, the flags, R0–R7 and the stack are 0. With COPCON.EN, DMACON.COPEN and DMAEN all set, the copper starts from COP1LC at the next vertical blank; a write to COPJMP1 starts it at once. Clearing any of them stops it at once; setting them again starts it at the next vertical blank (or COPJMP1).

**Interrupt:** source COPPER (2) in the interrupt controller (spec 13) is COPSTAT.IRQ with COPCON.IRQEN, with its own vector; default level 5. The handler clears it by writing 1 to COPSTAT.IRQ.

**Background lists: COPCON.RESUME** (section 6.1, below).

**Double-buffered lists:** build next frame's list in a second buffer, then write its address to COP1LC. The copper picks it up at the next vertical blank, so a half-built list is never run.

### 6.1 Background lists: COPCON.RESUME

The copper can run a long **background** list, such as a queue of DMA engine jobs, that carries on across frames while list 1 still restarts at every vertical blank. On the Amiga, the vertical blank simply cuts list 2 off. Here, with COPCON.RESUME set:

- The copper keeps an **in list 2** flag. A COPJMP2 strobe sets it. A COPJMP1 strobe, a STOP (or a WAIT for line 2047, or a reserved instruction), the vertical blank, and turning the copper off (COPCON.EN, DMACON.COPEN or DMAEN cleared) clear it, so a COP2LC written while the copper is off is never replaced. JUMP, CALL, RET and the SKIPs leave it as it is, so a background list can loop, branch and call subroutines.
- At the vertical blank, if the flag is set, the hardware writes the **resume address** to COP2LC before it reloads from COP1LC. The resume address is the instruction not yet finished: a WAIT still waiting (it runs again, whole), or the next instruction to run. (A palette entry's high half the copper had held stays held across the cut-off, so the pair's low half still writes the whole colour, unless list 1 writes a palette high half first.)
- List 1 ends with a MOVE to COPJMP2, as usual, and list 2 carries on where it was cut off.

Without RESUME (the default), COP2LC is never changed by the hardware, as on the Amiga.

**Only the place is saved.** X, Y, the flags and R0–R7 are never changed by the vertical blank, so a background list finds them as it left them, as long as list 1 does not change them: a list 1 that uses X, Y or the ALU saves what it uses into spare storage registers first (`CST`) and puts it back (`CLD`) before its COPJMP2. The flags are saved the same way (`CST n,CF` … `CLD CF,Rn`), so a cut-off between a CMP and its SKIPC is safe. The stack is emptied at the vertical blank unless COPCON.STKKEEP is set; with STKKEEP, list 1's CALLs must be balanced (each one returned from before its COPJMP2), so that list 2's return addresses stay on top. CALL and RET do not change the "in list 2" flag.

Rules for a background list:

- Its WAITs should be pixel-only, BLT-only (WAITB for a position already passed, such as line 0, pixel 0) or none: after a resume, a beam WAIT would wait for its position in the new frame.
- Some MOVEs may run twice: if the cut-off comes between the two halves of a pair, everything from the high-half MOVE on runs again. Keep the pairs together, and never put a strobe (such as one that starts a DMA engine job) between the halves of a pair, so that a strobe never runs twice.
- When it is done, it should set COP2LC to an idle list (`CMOVEL COP2LC,idle` then `CSTOP`, where `idle` is a STOP), so that the next frame's COPJMP2 does not run it again from the last saved place.
- While RESUME is set and a background list is running, the CPU's writes to COP2LC may be replaced at the next vertical blank. To queue new work, the CPU writes COP2LC only while the copper runs the idle list (COPPC tells it where the copper is), or it adds the work to a queue that the background list reads.

## 7. Examples

Resetting a 4-plane layer's pointers each frame and making a colour bar on lines 100–107 (`L1`, `BPLxPT` and `PALETTE` as in `hw.inc`):

```
    MOVE  L1+L_BPL0PT,   picture>>16          ; high half ...
    MOVE  L1+L_BPL0PT+2, picture & $FFFF      ; ... low half (in the blank: the pointer is not in use)
    ...                                       ; the same for BPL1PT-BPL3PT
    WAIT  100, 0
    MOVE  PALETTE,   $00FF                    ; colour 0, high half: red = $FF (held: a palette entry) ...
    MOVE  PALETTE+2, $0000                    ; ... low half: green, blue = 0: colour 0 is red
    WAIT  108, 0
    MOVE  PALETTE,   $0000                    ; back to black
    MOVE  PALETTE+2, $0000
    STOP
```

A palette entry is a 32-bit register (`0x00RRGGBB`), so a colour change is two MOVEs: the high half (red) first, then the low half (green and blue), which writes the entry at once. To change only green and blue, one MOVE to the low half is enough: it keeps the entry's current red. Because a palette entry's high half is held until its low half, a list can MOVE the high half before a WAIT and the low half after it, so that the whole 24-bit colour changes exactly at the WAIT. (Other registers have no such hold: each MOVE takes effect at once.)

A per-line effect without unrolling (a raster bar that moves one colour per line), using a pixel-only WAIT and a loop:

```
    WAIT  50, 0
loop:
    WAIT  P 0, 700                            ; near the end of every line
    MOVE  BGCOLOR+2, ...                      ; next line's background
    SKIP  300, 0                              ; past line 300: leave the loop
    JUMP  loop
    STOP
```

The assembler macros for these (`CMOVE`, `CWAIT`, `CSKIP`, `CJUMP`, `CSTOP`) are in `firmware/include/copper.inc`.

## 8. FPGA resources

| Item | Resource |
|------|----------|
| Program counter, one prefetched instruction, the high-half latch, beam compare | Logic, about 300–400 LUTs |
| X, Y, the flags, the 16-bit ALU, the conditions | About 150 LUTs, 35 flip-flops |
| R0–R7 and the stack (8 × 21 bits) | Distributed RAM, about 20 LUTs; their register-bus reads about 50 LUTs |
| Total | About 550–650 LUTs estimated; the first build is about 1,100 LUTs and 510 flip-flops (Yosys): R0–R7 have three read ports, so they are flip-flops, not distributed RAM. To be trimmed |

## 9. Open points

| # | Item |
|---|------|
| C1 | Whether a 32-bit MOVEL (an 8-byte instruction) is worth adding, to set a pointer in one instruction |
| C4 | A load of X or Y from Chip RAM (a table), which the arithmetic cannot replace |
| C2 | Exact pixel delay from a WAIT to a palette change. In simulation: the write after a WAIT shows at the WAIT's pixel (0 pixels late); each further write takes a fetch, about 4 pixels. To be confirmed on the board |

## 10. Tests

- **Golden images:** copper lists that change colours mid-line and per line, reset plane pointers, and open a split screen (new BPLxPT at a line), compared with the Python video model extended with a copper model.
- **Beam positions:** WAITs on blanking lines and picture lines; SKIP and JUMP loops ending at a line.
- **Halves:** a 32-bit register written by two MOVEs is never seen half-written; the CPU's own halves are not disturbed.
- **Strobes and lists:** COPJMP1/2 and COP1LC double buffering.
- **COPINT:** raises the interrupt once per write.
- **Registers and ALU:** every ALU function and source, every flag result (carry and borrow at the 16-bit edges), every condition, MOVR in all five forms with X+ across the halves rule, all compared with the copper model.
- **CALL and RET:** nesting to 8, overflow and underflow set ERR; the stack emptied at the vertical blank, or kept with STKKEEP.
- **RESUME:** a background list cut off at the vertical blank, mid-WAITB and between the halves of a MOVE pair, carries on from the right place; without RESUME, COP2LC is never changed; after the copper is turned off while list 2 runs, a COP2LC written meanwhile is kept (`make cresume`).

## 11. Later versions

- MOVEL (open point C1), a load from Chip RAM (open point C4)
- WAIT with compare masks, if anything needs them
- A second copper
