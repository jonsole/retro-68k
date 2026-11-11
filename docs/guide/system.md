# Introduction and System Control Hardware

This chapter introduces the retro68k computer and the parts of it that every program meets first. It covers:

- the machine at a glance and how this guide is laid out,
- the memory map,
- Chip RAM, and how the CPU and DMA share it in memory slots,
- the rules that every hardware register follows,
- reset, the boot ROM and its overlay at address 0,
- what happens at start-up, and how to write your own start-up code,
- the system control registers: identification, configuration, reset cause, buttons and bus errors.

The other chapters each describe one hardware block. You should read this one first, because the register rules and the memory layout apply to all of them.

## About retro68k

retro68k is a 68000 computer built inside the FPGA of a ZX Spectrum Next KS3 board. Its design follows the Amiga: a 68000 shares one block of fast memory, called Chip RAM, with the display and other DMA hardware, and a set of custom registers controls the video, sound and DMA. If you have programmed the Amiga's hardware directly, most of what follows will feel familiar.

There are a few differences worth knowing from the start:

- **The CPU has its own memory cycle in every slot.** It waits only when the display would otherwise be late: then, as on the Amiga, the bitplane DMA takes the CPU's cycle and the CPU waits one slot.
- **There is no Fast RAM.** All RAM is Chip RAM, and the CPU gets it at full speed.
- **Registers are 32 bits wide**, written and read as two 16-bit halves. The rules for this are in "Working with the Hardware Registers" below.
- **Interrupts are vectored.** Each interrupt source has its own vector, so a handler never needs to find out who interrupted.
- **Console and uploads go over USB.** A small FT232H module gives a fast serial link to a PC. It has its own chapter, "The USB Serial Link".

### The Machine at a Glance

| Item | Value |
|------|-------|
| CPU | 68000 (the fx68k core inside the FPGA) at 20 MHz |
| Chip RAM | 4 MB of 10 ns SRAM, shared by the CPU and DMA (some boards: 2 MB) |
| Boot ROM | 32 KB at `$F80000`, in FPGA block RAM, loaded with the FPGA |
| Memory bandwidth | 100 MB/s in total; the CPU can use up to 10 MB/s, with no wait states unless the display needs its cycle |
| Video | HDMI and VGA at once; one mode, 576p: 720 × 576 at 50 Hz, the digital form of PAL; three bitmap layers; a 256-colour palette of 24-bit colours |
| Serial | USB link to a PC through an FT232H module: several MB/s, hardware flow control |
| Interrupts | 24 sources, each with its own vector and a programmable level; NMI from a button or from the PC |
| Timers | A 64-bit time counter, four 32-bit timers and a watchdog |
| Buttons | Reset, NMI (the board's Multiface button) and a "monitor" button (the DivMMC button) |

The board has no LEDs or switches for the computer to use. Start-up progress is shown on the serial console and, as on the Amiga, as the screen's background colour.

### The Hardware Chapters

| Chapter | Covers |
|---------|--------|
| Introduction and System Control Hardware | This chapter |
| The USB Serial Link | Console text, uploads, and commands from the PC |
| Video | Bitmap layers, palette, background colour, beam position, video interrupts |
| Interrupts | The interrupt controller, levels, vectors, NMI, the software interrupt |
| Timers | The time counter, the four timers and the watchdog |

The **copper** has its own chapter (Chapter 5), written against its spec ahead of the hardware. The **blitter** (Chapter 6), and the **SD card** and **keyboard** (Chapter 8), have theirs. **Audio** is specified and built, and will get its chapter; this guide does not describe its registers yet. You will see their names in a few places, such as the DMACON register, so that you know where they will fit.

### Conventions in This Guide

- Numbers starting with `$` are hexadecimal, as in 68000 assembly language.
- Examples are in Motorola syntax for the vasm assembler. They start with `include "hw.inc"`, the file of equates generated from the register map (`firmware/include/hw.inc`).
- In `hw.inc`, a register name is its **offset** from its block, not its full address. You reach it through an address register that holds the block's base:

  ```asm
          lea     SYSTEM,a5               ; $F00000, the system block
          move.l  SYSID(a5),d0            ; SYSID is $800, so this reads $F00800
  ```

  The custom block is `CUSTOM` (`$E00000`) and the system block is `SYSTEM` (`$F00000`). The examples keep `a5` pointing at `SYSTEM` and `a4` at `CUSTOM`.
- Each bit field has three names: `NAME_B` is its lowest bit number, `NAME_M` is its mask in place, and `NAME_W` is its width (for fields wider than one bit). For example, `SYSCON_OVERLAY_B` is 0 and `SYSCON_OVERLAY_M` is `$1`.
- The Access column in the register tables uses: **R** read only, **W** write only, **RW** read and write, **W1C** sticky flags cleared by writing 1, **RW1C** a mix of the two, **SC** set/clear.

## The Memory Map

The 68000 has a 24-bit address bus, giving 16 MB of address space. retro68k uses it like this:

```
   $FFFFFF  +--------------------------------+
            |   unmapped (bus error)         |
   $F88000  +--------------------------------+
            |   Boot ROM, 32 KB              |  read only (writable with ROMWE)
   $F80000  +--------------------------------+
            |   unmapped (bus error)         |
   $F10000  +--------------------------------+
            |   System block, 64 KB          |  interrupts, timers, USB serial,
            |                                |  system control (SD card and
            |                                |  keyboard later)
   $F00000  +--------------------------------+
            |   unmapped (bus error)         |
   $E10000  +--------------------------------+
            |   Custom block, 64 KB          |  video, DMACON, palettes, copper,
            |                                |  blitter, audio
   $E00000  +--------------------------------+
            |                                |
            |   reserved (bus error)         |
            |                                |
   $400000  +--------------------------------+
            |                                |
            |   Chip RAM, 4 MB               |  shared by the CPU and DMA
            |                                |
   $008000  + - - - - - - - - - - - - - - - -+
            |   boot ROM overlay for reads   |  only until SYSCON.OVERLAY
            |   (writes go to Chip RAM)      |  is cleared
   $000000  +--------------------------------+

                  Figure 1-1: The Memory Map
```

| Range | Size | Contents |
|-------|------|----------|
| `$000000`–`$3FFFFF` | 4 MB | Chip RAM. On 2 MB boards, `$000000`–`$1FFFFF`, and `$200000`–`$3FFFFF` gives a bus error |
| `$000000`–`$007FFF` | 32 KB | After reset, CPU reads here come from the boot ROM (the overlay) |
| `$400000`–`$DFFFFF` | 10 MB | Reserved: bus error |
| `$E00000`–`$E0FFFF` | 64 KB | Custom block: video registers, DMACON, palette |
| `$F00000`–`$F0FFFF` | 64 KB | System block: interrupts, timers, USB serial, system control |
| `$F80000`–`$F87FFF` | 32 KB | Boot ROM |
| All other addresses | | Unmapped: bus error |

Inside the custom and system blocks, addresses that hold no register read as 0 and ignore writes. Only the unmapped regions give bus errors.

### The Custom Block

| Offset | Contents |
|--------|----------|
| `$0000`–`$00FF` | Video registers and DMACON (Video chapter) |
| `$0100`–`$027F` | Bitmap layers 0–2 (Video chapter) |
| `$0300`–`$07FF` | The blitter, audio and the copper |
| `$4000`–`$43FF` | Palette: 256 colours, one long word each, `$00RRGGBB` |

### The System Block

| Offset | Contents |
|--------|----------|
| `$000`–`$0FF` | Interrupt controller (Interrupts chapter) |
| `$100`–`$1FF` | Timers and watchdog (Timers chapter) |
| `$200`–`$2FF` | USB serial (The USB Serial Link chapter) |
| `$300`–`$4FF` | Reserved for the SD card and keyboard |
| `$800`–`$8FF` | System control (this chapter) |

### Who Can Reach What

The CPU reaches everything. DMA hardware (the display, audio, the blitter) sees Chip RAM only; the copper also writes the custom block. The system block, where the interrupt controller and the system control registers live, is out of reach of both, so a runaway copper list or blitter job cannot change them.

With **SYSCON.PROTECT** set, a CPU access in user mode to anything from `$E00000` upwards, including the boot ROM, gives a bus error. An operating system can use this one bit to keep user programs away from the hardware. Chip RAM is always open to user mode.

## Chip RAM and the Memory Slots

All of the computer's RAM is one 4 MB static RAM chip, called **Chip RAM** after the Amiga's. The CPU runs its programs from it, and the display and other DMA hardware read and write it. This section explains how they share it, so you know what to expect from the CPU's speed and from DMA.

### Memory Cycles and Slots

The memory chip can do one 16-bit read or write every 20 ns. That is one **memory cycle**. Memory time is cut into **slots** of 100 ns, five memory cycles each, numbered 0 to 4. A slot is two clocks of the 20 MHz CPU.

```
              one slot = 100 ns = 2 CPU clocks
     |<------------------------------------------------->|
     +----------+----------+----------+----------+----------+
     | cycle 0  | cycle 1  | cycle 2  | cycle 3  | cycle 4  |
     |   CPU    | display  |   DMA    | display  |   DMA    |
     +----------+----------+----------+----------+----------+
     0         20         40         60         80        100 ns

                Figure 1-2: Memory Cycles in One Slot
```

| Cycle | Owner |
|-------|-------|
| 0 | The CPU. If the CPU does not need it, other DMA may use it |
| 1, 3 | Display fetch for the bitmap layers, spread out across the slot. If the display does not need them, other DMA may use them |
| 2, 4 | Other DMA: audio (2), the copper and the blitter (4) |

Every scan line is a whole number of slots, and the slot count starts again at each line. So every DMA user gets its cycles at the same beam position on every line, as on the Amiga.

### The CPU's Cycle 0

A 68000 bus cycle takes 4 CPU clocks, 200 ns: two slots. The CPU needs at most one memory cycle per bus cycle, and **cycle 0 of every slot belongs to it**, so it always finds a cycle ready:

```
 time (ns)  0        50       100      150      200      250      300
            |        |        |        |        |        |        |
 slot       |<---- slot k --->|<--- slot k+1 -->|<--- slot k+2 -->|
 cycle 0    [0]               [0]               [0]
 68000      S0  S1   S2  S3   S4  S5   S6  S7   S0  S1   S2  S3 ...
                              ^                 ^
                              a read uses       a write is posted
                              this cycle 0      to this cycle 0

             Figure 1-3: A CPU Bus Cycle and the Slots
```

- A **read** uses cycle 0 of the bus cycle's second slot. The data reaches the CPU before it needs it.
- A **write** is posted: the CPU is told it is done at once, and the memory write happens in cycle 0 of the next slot, which is the first slot of the CPU's next bus cycle. The CPU never uses that cycle 0 for itself, so nothing is held up. A read that follows a write always sees the new data.
- The boot ROM, the palette and all registers are not in Chip RAM and use no memory cycles at all.

So the CPU normally runs **with no wait states** from Chip RAM, ROM and registers alike. The display, and later the audio and normal DMA, use their own cycles and any the CPU leaves. As on the Amiga, a bitplane fetch that would otherwise be late takes the CPU's cycle 0 (and a copper set to "nasty" priority may too); that Chip RAM access then waits one slot, 2 CPU clocks. Screens well inside the budget almost never do this; heavy ones slow the CPU a little on the lines that need it. ROM and register accesses never wait.

Software can add more: a copper set to "nasty" priority (COPCON.PRI = 2) owns cycle 0 while it asks, and the CPU then waits for the cycles it leaves.

### The Slot Plan

Who owns each of the 5 cycles is set by five registers, **MEMSLOT0–MEMSLOT4** (`$E00098`–`$E000A8`), one per cycle. Bits 0–6 of each are its owners, one bit per user: BPL (layers), SPR (sprites), AUD, COP, CPU, BLT (the blitter) and RAS (the rasteriser). Bit 7, LOCK, stops an urgent display fetch from taking that cycle. After reset they hold the plan above: `$10` (CPU), `$03` (layers and sprites), `$04` (audio), `$03`, `$00`.

A cycle whose owners don't want it goes to whoever does, so owning a cycle costs nobody bandwidth, only their place in the queue. Users without a cycle of their own take turns in a fixed order: high-priority requests first (a copper at PRI 1 or 2), then the layers, sprites, audio, copper, CPU, blitter and port.

```asm
            move.b  #MEMSLOT0_BLT_M,MEMSLOT0+3(a4)      ; a big blit: the blitter owns cycle 0
            ; ... the blit runs; the CPU gets only the cycles it leaves ...
            move.b  #MEMSLOT0_CPU_M,MEMSLOT0+3(a4)      ; the CPU back
```

Keep the display's two cycles (1 and 3), or a heavy screen runs short, and leave LOCK clear: the 68000 waits for its data, so nothing here needs a locked cycle.

### Bandwidth

| User | Bandwidth |
|------|-----------|
| All memory cycles | 100 MB/s (5 × 2 bytes per 100 ns) |
| CPU | Up to 10 MB/s: one 16-bit access per 200 ns bus cycle |
| Display (cycles 1 and 3) | Up to 40 MB/s |
| Everything else | The rest: cycles 3 and 4, and any cycle its owner leaves unused |

Static RAM needs no refresh, so no cycles are lost to it.

### DMACON, the DMA Control Register

DMACON turns DMA on and off, as on the Amiga. Its 16-bit value is in the low half of a 32-bit register, at `$E00096`, the same address as the Amiga's DMACON. It is a **set/clear** register:

- Write with bit 15 (SETCLR) = 1 to **set** the other bits you write as 1.
- Write with bit 15 = 0 to **clear** the other bits you write as 1.
- Bits you write as 0 are left alone either way.

| Bit | Name | Enables |
|-----|------|---------|
| 15 | SETCLR | Set or clear the bits written as 1 |
| 9 | DMAEN | Master enable for all the DMA below |
| 8 | BPLEN | Bitplane DMA for the layers |
| 7 | COPEN | Copper (later) |
| 6 | BLTEN | The blitter (Chapter 6) |
| 5 | SPREN | Sprite DMA (see the Sprite Hardware chapter) |
| 3–0 | AUD3EN–AUD0EN | Audio channels 3–0 (later) |

The bits are where the Amiga has them. A DMA user works only when both its own bit and DMAEN are set. For finer control, each layer's BPLDMA register turns bitplane DMA on and off plane by plane (see the playfield chapter), so any one plane, or one audio channel, can be left to the CPU or copper. DMACON is cleared at every reset.

To turn on the display fetch:

```asm
        include "hw.inc"

        lea     CUSTOM,a4
        move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M,DMACON+2(a4)
```

To stop it again, leaving DMAEN on for other users:

```asm
        move.w  #DMACON_BPLEN_M,DMACON+2(a4)    ; SETCLR = 0: clear BPLEN
```

Write DMACON with `MOVE.W` to `DMACON+2` or with `MOVE.L` to `DMACON`. A byte write to DMACON is ignored. Reading DMACON gives the current enables in the low half, with bit 15 reading as 0.

## Working with the Hardware Registers

Every register in the custom and system blocks follows the same rules. They are simple, as on the Amiga: the 68000 reads and writes a 32-bit register as two 16-bit halves, and each half is a write or read of its own.

### Rule 1: Registers Are 32 Bits, in Two Halves

Each register is a long word at an address that is a multiple of 4. As always on the 68000, the **high half** (bits 31–16) is at the register's address and the **low half** (bits 15–0) at the address + 2.

### Rule 2: Each Half Is Written on Its Own

The 68000 moves a long word as two 16-bit bus cycles, the high word first (in every addressing mode except `-(An)`). Each half goes into the register as soon as it is written, keeping the other half; a byte write keeps the other byte:

```asm
        lea     SYSTEM,a5
        move.l  #(64<<SERLEVEL_RXLEVEL_B)|256,SERLEVEL(a5)  ; the high half, then the low half
```

So between the two writes of a `MOVE.L`, the register holds the new high half and the old low half, for about 200 ns. That does not matter for most registers. For one the hardware is using as you write it, such as a plane pointer or a sprite pointer, write it where the hardware is not using it: in the vertical blank, or from the copper, as on the Amiga.

**Palette entries are the exception.** A colour must change all at once, even in the middle of a line, so a write to an entry's high half (red) is held until the next write to the same entry's low half (green and blue), which writes the whole colour. A `MOVE.L` to a palette entry is always seen whole. The CPU and the copper each have their own hold, so they cannot mix up each other's colours.

**Do not use CLR.L on a FIFO data register** such as SERDATA: the 68000's CLR.L reads the register before writing it, which takes a byte out. `MOVE.L #0` is always safe.

### Rule 3: 16-Bit Registers Live in the Low Half

Registers with 16 or fewer bits, such as DMACON, keep their value in the low half. Write them with `MOVE.W` to the register's address + 2, or with `MOVE.L` to the register's address.

### Rule 4: Each Half Is Read on Its Own

Each half read returns that half as it is at that moment:

```asm
        move.l  SYSID(a5),d0            ; the whole register (two reads)
        move.w  SERSTAT+2(a5),d1        ; just the low half: TXSPACE
```

So a `MOVE.L` of a register that is changing, such as BEAMPOS or a timer's COUNT, can catch the two halves at different moments: BEAMPOS's line from one moment and its pixel from the next. Read such a register twice and check, or read only the half you need. **TIME** is the exception: reading TIMEHI's high half captures all 64 bits, so `MOVE.L TIMEHI` then `MOVE.L TIMELO` always gives one moment (Interrupts and Timers chapter).

### Rule 5: Reading Has No Side Effects, Except for FIFOs

Reading a register does not change it, with a few exceptions in the system block: reading the **low half** of a FIFO data register (SERDATA, KBDATA) takes a byte out, reading SERDROP's low half clears it, and reading TIMEHI's high half captures TIME. A `MOVE.L` of SERDATA (the high half, then the low) takes exactly one byte. None of these are in the custom block.

### Rule 6: Sticky Flags Are Cleared by Writing 1

Status flags marked W1C stay set until you clear them. Write 1 to the flags you want to clear; flags written as 0 are left alone. So you can clear exactly the flags you have dealt with:

```asm
        move.l  #NMISTAT_USB_M,NMISTAT(a5)      ; clear the USB flag only
```

### Rule 7: Set/Clear Registers

DMACON uses bit 15 to choose between setting and clearing, as described above.

### Rule 8: Unused Bits and Addresses

Unused bits read as 0; write them as 0. Unused addresses inside a block read as 0 and ignore writes.

### Changing Some Bits of a Register

To change some bits and keep the others, copy the register to a data register, change it there, and write it back with `MOVE.L`:

```asm
        move.l  SERCON(a5),d0
        bset    #SERCON_TXDROP_B,d0
        move.l  d0,SERCON(a5)
```

If an interrupt handler also changes the same register, turn interrupts off around the three instructions.

## Reset and the Boot ROM Overlay

### What Resets the Computer

| Source | How | RESETWHY bit |
|--------|-----|--------------|
| Power-on | The FPGA has just been loaded | POWER (0) |
| Watchdog | Not kicked in time (Timers chapter) | WATCHDOG (1) |
| Reset button | The board's reset button | BUTTON (2) |
| Software | Writing `$A55A` to SYSRESET | SOFTWARE (3) |
| USB RESET | A command from the PC (The USB Serial Link chapter) | USB (4) |
| USB UPLOAD | A command from the PC: reset and wait for a program | UPLOAD (5) |
| Keyboard | Ctrl + Alt + Delete (when the keyboard is built) | KEYBOARD (6) |
| CPU halted | A double bus fault, if SYSCON.HALTRESET is set | HALTED (7) |

### What a Reset Does

Every source gives the same full reset:

- The 68000 restarts from the vectors at address 0.
- Every custom register and system device goes back to its reset value: video and DMA off, all interrupts off, timers and watchdog stopped.
- The boot ROM overlay is turned on.
- **Chip RAM keeps its contents.** Static RAM holds its data while the board has power, so after any reset except power-on, memory still holds what it held before. A debugger can look at what a crashed program left behind, and a program can keep data across a reset on purpose (see "Warm Starts" below).
- **The boot ROM keeps its contents,** including changes made while it was writable. Only loading the FPGA again restores the original.
- **The USB link stays connected,** so a terminal on the PC does not notice the reset. Do not count on what the serial FIFOs or SERCON hold after a reset; set SERCON in full at start-up.

The reset lasts about 5 microseconds. At power-on, loading the FPGA itself takes a fraction of a second before that.

### The RESET Instruction

The 68000's RESET instruction is meant to reset the hardware without restarting the CPU: the custom hardware, interrupt controller, timers (but not the watchdog or the time counter) and the other devices, but not the overlay, memory, RESETWHY or the USB link. An operating system can use it to put the hardware into a known state.

Note: in the current FPGA build, the RESET instruction does not reset anything yet. Set the hardware up register by register instead.

### The Boot ROM

The boot ROM is 32 KB at `$F80000`, as the Amiga's Kickstart was. It is block RAM inside the FPGA, filled with the boot code when the FPGA is loaded. Reading it costs no memory cycles and no wait states. Writing to it gives a bus error unless SYSCON.ROMWE is set (see "Writable Boot ROM" below).

### The Overlay

After any reset, the 68000 reads its initial stack pointer from address 0 and its start address from address 4. Address 0 is Chip RAM, so the hardware makes the boot ROM appear there too. This is the **overlay**:

| While SYSCON.OVERLAY is 1 | Effect |
|---------------------------|--------|
| CPU reads from `$000000`–`$007FFF` | Come from the boot ROM |
| CPU writes to `$000000`–`$007FFF` | Go to Chip RAM underneath |
| DMA | Always sees Chip RAM |

The boot ROM's first long words are therefore its stack pointer and its start address, and the start address points at the ROM's real address in `$F80000`. The start-up code then:

1. runs from the ROM at its real address,
2. builds the 68000's vector table in Chip RAM at address 0 (writes already go to RAM),
3. turns the overlay off by clearing SYSCON.OVERLAY.

From then on, address 0 is Chip RAM for reading and writing. The overlay comes back at every reset.

**Keep your stack and variables above `$8000` until the overlay is off.** While it is on, reading anything in the first 32 KB gives you ROM, not what you wrote.

## Start-Up

### What the Boot ROM Does

The boot ROM in the current build checks the machine and reports over the USB serial link and on the screen:

1. It turns on the USB serial link and an 80 × 30 text console, drawn into a 1-plane 640 × 480 bitmap layer centred in the 720 × 576 picture, 40 pixels in and 48 lines down, with the background colour as a border.
2. It prints a banner and checks SYSID.
3. It builds the vector table in Chip RAM and turns the overlay off.
4. It tests Chip RAM, from `$040000` to the end of RAM.
5. It makes a deliberate bus error and checks BUSERRADDR and BUSERRWHY.
6. It checks the software interrupt, a timer interrupt and the vertical blank interrupt.
7. It prints `PASS` or `FAIL`, then echoes everything that arrives over USB.

Later versions will read RESETWHY and the keys held during reset, wait for a program over USB after an UPLOAD reset, load a program from the SD card, and start a monitor, with progress shown as the screen's background colour.

### Writing Your Own Start-Up Code

When you write a program that starts from reset, such as a new boot ROM, follow these steps.

1. Put the initial stack pointer and start address in the first two long words of the ROM. Fill the rest of the 256 vectors with the address of a default handler.
2. At the start address, set the status register to `$2700`: supervisor mode, all interrupts masked.
3. Load the base addresses of the hardware blocks into address registers.
4. Turn on the USB serial link, so you can report what happens next.
5. Build the vector table in Chip RAM at address 0.
6. Turn off the overlay.
7. From here on, the whole of Chip RAM is yours. Set up the devices you need, then lower the interrupt mask.

The following is a complete boot ROM that does just this and says hello over USB. It assembles to a 32 KB-or-smaller binary at `$F80000`.

```asm
; A minimal boot ROM: vector table, overlay off, "hello" over USB.
        include "hw.inc"

VECTORS     equ $000000             ; 256 vectors, 1 KB
STACK_TOP   equ $010000             ; above the overlay ($0000-$7FFF)

        org     ROM                     ; $F80000, also seen at 0 after reset
        dc.l    STACK_TOP               ; vector 0: initial stack pointer
        dc.l    start                   ; vector 1: initial program counter
        dcb.l   254,unhandled           ; vectors 2-255

start:  move.w  #$2700,sr               ; supervisor mode, interrupts off
        lea     SYSTEM,a5

        ; USB serial on, PC commands on, drop old output if nobody listens
        move.l  #SERCON_EN_M|SERCON_CTLEN_M|SERCON_TXDROP_M,SERCON(a5)

        ; the vector table in Chip RAM (writes reach RAM under the overlay)
        lea     VECTORS,a0
        move.l  #STACK_TOP,(a0)+
        move.l  #start,(a0)+
        move.w  #254-1,d0
.vec:   move.l  #unhandled,(a0)+
        dbra    d0,.vec

        ; overlay off: address 0 is now Chip RAM for reads too
        move.l  SYSCON(a5),d0
        bclr    #SYSCON_OVERLAY_B,d0
        move.l  d0,SYSCON(a5)

        lea     hello(pc),a0
        bsr.s   puts
.idle:  bra.s   .idle

; send the zero-terminated string at a0
puts:   move.b  (a0)+,d0
        beq.s   .done
        bsr.s   putc
        bra.s   puts
.done:  rts

; send d0.b over USB (a5 = SYSTEM; d1 is changed)
putc:   move.w  SERSTAT+2(a5),d1        ; low half: TXSPACE
        and.w   #SERSTAT_TXSPACE_M,d1
        beq.s   putc                    ; no room yet
        move.b  d0,SERDATA+3(a5)        ; send one byte
        rts

unhandled:
        bra.s   unhandled

hello:  dc.b    "Hello from retro68k",13,10,0
        even
```

Assemble it with:

```
vasmm68k_mot -Fbin -I firmware/include -o hello.bin hello.s
```

### Exception Vectors

Once the vector table is in RAM, these are the vectors you will meet most often:

| Vector | Address | Use |
|--------|---------|-----|
| 0 | `$000` | Initial stack pointer (read only at reset) |
| 1 | `$004` | Initial program counter (read only at reset) |
| 2 | `$008` | Bus error |
| 3 | `$00C` | Address error (word or long access at an odd address) |
| 24 | `$060` | Spurious interrupt |
| 31 | `$07C` | NMI: the NMI button, or BREAK from the PC |
| 64–87 | `$100`–`$15C` | Interrupt sources 0–23 (VECBASE + source; Interrupts chapter) |

## The System Control Registers

The system control registers are in the system block at `$F00800`. They identify the machine, describe its hardware, tell you why it was last reset, control the overlay and the boot ROM, and record bus errors.

### Identifying the Machine: SYSID, SYSVER and SYSCFG

**SYSID** always reads `$5236384B`, the characters "R68K" (`SYSID_MAGIC` in `hw.inc`). **SYSVER** gives the version of the FPGA build.

**SYSCFG** describes the hardware, so one program can run on different builds:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | CPU | 0: the fx68k core inside the FPGA |
| 9–2 | CPUMHZ | CPU clock in MHz: 20 |
| 15–10 | CHIPMB | Chip RAM size in MB: 4, or 2 on boards with 2 MB |
| 21–16 | FASTMB | 0: no Fast RAM |

To check that you are on a retro68k and find the end of Chip RAM:

```asm
; d0 = first address after Chip RAM, or 0 if this is not a retro68k
memtop: lea     SYSTEM,a5
        cmp.l   #SYSID_MAGIC,SYSID(a5)
        bne.s   .notours
        move.l  SYSCFG(a5),d0
        and.l   #SYSCFG_CHIPMB_M,d0
        moveq   #SYSCFG_CHIPMB_B,d1
        lsr.l   d1,d0                   ; size in MB
        moveq   #20,d1
        lsl.l   d1,d0                   ; MB to bytes
        rts
.notours:
        moveq   #0,d0
        rts
```

### Why Was I Reset? RESETWHY

RESETWHY tells you what caused the last reset, using the bits in the table under "What Resets the Computer". After power-on it reads `$01` (POWER). Use it to decide what your start-up code should do:

- After **power-on**, Chip RAM holds random data: test it and clear it.
- After **UPLOAD**, wait for a program over USB.
- After anything else, Chip RAM holds what it held before the reset: you can offer to keep it, or look at it for debugging.

An UPLOAD reset may also show the USB bit, so test UPLOAD before USB:

```asm
        move.l  RESETWHY(a5),d0
        btst    #RESETWHY_UPLOAD_B,d0
        bne     upload                  ; the PC wants to send a program
        btst    #RESETWHY_POWER_B,d0
        bne     coldstart               ; RAM holds nothing useful
        bra     warmstart               ; RAM still holds what it held
```

### Warm Starts

Because Chip RAM survives every reset except power-on, a program can leave itself a note. Before using it, always check RESETWHY: after power-on, RAM holds random values that could look like your note.

```asm
WARMFLAG    equ $008000             ; a long word in Chip RAM
WARMMAGIC   equ 'WARM'

        move.l  RESETWHY(a5),d0
        btst    #RESETWHY_POWER_B,d0
        bne.s   .cold                   ; power-on: ignore whatever is in RAM
        cmp.l   #WARMMAGIC,WARMFLAG
        beq     warmstart               ; our data is still there
.cold:  move.l  #WARMMAGIC,WARMFLAG     ; set up from scratch
        ; ...
```

### SYSCON, the System Control Register

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | OVERLAY | 1: the boot ROM overlays `$000000`–`$007FFF` for CPU reads. Set at every reset |
| 1 | ROMWE | 1: the boot ROM can be written |
| 2 | ROMLOCK | Writing 1 locks ROMWE off until the next power-on. Writing 0 does nothing |
| 3 | PROTECT | 1: user-mode accesses to `$E00000`–`$FFFFFF` give a bus error |
| 4 | HALTRESET | 1: reset the computer when the CPU halts after a double bus fault |

After a reset SYSCON reads `$01`: the overlay on, and everything else off (except ROMLOCK, which stays set until power-on). Change SYSCON by reading it, changing the bits you want and writing it back, as shown under "Changing Some Bits of a Register".

### Writable Boot ROM

Rebuilding the FPGA takes minutes. To try new boot code quickly, you can write a new image into the boot ROM and reset:

1. Load the new image into Chip RAM, for example over USB.
2. Run the code that installs it from Chip RAM, not from the ROM, because the ROM is about to change under it.
3. Set SYSCON.ROMWE.
4. Copy the image to `$F80000`.
5. Reset the computer through SYSRESET. The new ROM runs from this reset on, until the FPGA is loaded again.

```asm
; Install a 32 KB boot ROM image from Chip RAM, then reset into it.
; a0 = the image. Run this from Chip RAM. Returns only if ROMLOCK is set.
newrom: lea     SYSTEM,a5
        move.w  #$2700,sr
        move.l  SYSCON(a5),d0
        btst    #SYSCON_ROMLOCK_B,d0
        bne.s   .locked
        bset    #SYSCON_ROMWE_B,d0
        move.l  d0,SYSCON(a5)           ; the ROM can be written now
        lea     ROM,a1
        move.w  #ROM_SIZE/4-1,d1
.copy:  move.l  (a0)+,(a1)+
        dbra    d1,.copy
        move.l  #SYSRESET_MAGIC,SYSRESET(a5)    ; reset into the new ROM
.wait:  bra.s   .wait
.locked:
        rts
```

To make sure nothing can change the boot ROM by accident, set **ROMLOCK**. From then until the next power-on, ROMWE has no effect. The boot ROM is meant to set ROMLOCK at start-up unless you hold the development key (D) during reset; the current boot ROM does not yet.

### Resetting from Software: SYSRESET

Writing `$A55A` (`SYSRESET_MAGIC`) to the low half of SYSRESET resets the computer, with RESETWHY.SOFTWARE set. Any other value is ignored, so a stray write cannot reset the machine.

```asm
        move.w  #SYSRESET_MAGIC,SYSRESET+2(a5)
.wait:  bra.s   .wait                   ; the reset happens at once
```

### The Buttons: SYSBTN

The board has three buttons:

| Button | What it does |
|--------|--------------|
| Reset | Resets the computer (RESETWHY.BUTTON) |
| Multiface | The NMI button: a level 7 interrupt through vector 31 (Interrupts chapter). Also readable in SYSBTN |
| DivMMC | Not an interrupt. Software reads it in SYSBTN; the boot ROM will use it as the "monitor" button |

SYSBTN reads 1 in a bit while its button is held down: MULTIFACE (bit 0) and DIVMMC (bit 1). The buttons are debounced in hardware. To wait for a press and release of the DivMMC button:

```asm
.down:  move.l  SYSBTN(a5),d0
        btst    #SYSBTN_DIVMMC_B,d0
        beq.s   .down                   ; wait for it to be pressed
.up:    move.l  SYSBTN(a5),d0
        btst    #SYSBTN_DIVMMC_B,d0
        bne.s   .up                     ; and released
```

### Bus Errors: BUSERRADDR and BUSERRWHY

When the CPU makes an access that nothing answers, the hardware signals a bus error instead, and the 68000 takes its bus error exception through vector 2. The causes are:

| BUSERRWHY bit | Name | Cause |
|---------------|------|-------|
| 0 | UNMAPPED | An unmapped or reserved address, including Chip RAM above 2 MB on a 2 MB board |
| 1 | ROMWRITE | A write to the boot ROM while ROMWE is off |
| 2 | PROTECT | A user-mode access to `$E00000`–`$FFFFFF` while SYSCON.PROTECT is set |
| 3 | CPUSPACE | A CPU-space cycle other than an interrupt acknowledge |

Unused addresses inside the custom and system blocks do not give bus errors: they read as 0.

The hardware keeps the **address** of the last bus error in **BUSERRADDR** (bits 23–0; bit 0 is always 0, since it is the address of the word accessed) and its **cause** in **BUSERRWHY** (one bit set). They hold their values until the next bus error, and survive a reset, so a debugger can read them afterwards.

The 68000 leaves 7 words on the supervisor stack for a bus error:

| Offset | Size | Contents |
|--------|------|----------|
| 0 | Word | Access type: R/W (bit 4, 1 = read), I/N (bit 3, 1 = not an instruction fetch), function code (bits 2–0) |
| 2 | Long | Access address |
| 6 | Word | Instruction register |
| 8 | Word | Status register |
| 10 | Long | Program counter (near the faulting instruction) |

A 68000 cannot always carry on after a bus error, because the saved program counter is only near the instruction that failed. Most handlers report the error and stop, or restart the program. This handler reports over USB:

```asm
; Bus error (vector 2): report address, cause and PC, then stop.
; Uses puts and puthex8 (print d0.l as 8 hex digits) from the boot ROM.
buserr: move.w  #$2700,sr
        lea     SYSTEM,a5
        lea     s_berr(pc),a0
        bsr     puts
        move.l  BUSERRADDR(a5),d0
        bsr     puthex8
        lea     s_why(pc),a0
        bsr     puts
        move.l  BUSERRWHY(a5),d0
        bsr     puthex8
        lea     s_pc(pc),a0
        bsr     puts
        move.l  10(sp),d0               ; PC from the exception frame
        bsr     puthex8
.stop:  bra.s   .stop

s_berr: dc.b    13,10,"Bus error at ",0
s_why:  dc.b    " why ",0
s_pc:   dc.b    " PC ",0
        even
```

A bus error can also be used on purpose, to find out whether an address exists: the boot ROM reads `$400000`, catches the bus error and checks BUSERRADDR and BUSERRWHY. To do this, save the stack pointer before the access, and have the handler restore it and jump to a known address, since it cannot simply return.

### The Halted CPU: SYSSTAT

If a bus error or address error happens while the 68000 is already handling one (a **double bus fault**), the 68000 stops and does nothing more until it is reset. **SYSSTAT.HALTED** reads 1 while the CPU is halted, which a debugger on the PC could see. With **SYSCON.HALTRESET** set, the computer resets itself instead, with RESETWHY.HALTED set. Otherwise the reset button, the watchdog or a RESET command from the PC brings it back.

## Summary of System Control Registers

| Name | Address | Access | Function |
|------|---------|--------|----------|
| SYSID | `$F00800` | R | Reads `$5236384B`, "R68K" |
| SYSVER | `$F00804` | R | FPGA build version |
| SYSCFG | `$F00808` | R | Hardware: CPU (1–0), CPUMHZ (9–2), CHIPMB (15–10), FASTMB (21–16) |
| RESETWHY | `$F0080C` | R | Cause of the last reset: POWER (0), WATCHDOG (1), BUTTON (2), SOFTWARE (3), USB (4), UPLOAD (5), KEYBOARD (6), HALTED (7) |
| SYSCON | `$F00810` | RW | OVERLAY (0), ROMWE (1), ROMLOCK (2), PROTECT (3), HALTRESET (4) |
| SYSRESET | `$F00814` | W | Write `$A55A` to the low half to reset |
| SYSBTN | `$F00818` | R | Buttons held: MULTIFACE (0), DIVMMC (1) |
| SYSSTAT | `$F00820` | R | HALTED (0): the CPU is halted |
| BUSERRADDR | `$F00824` | R | Address of the last bus error (23–0) |
| BUSERRWHY | `$F00828` | R | Cause of the last bus error: UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3) |

## Chapter Summary

| Name | Address | Access | Function |
|------|---------|--------|----------|
| DMACON | `$E00094` (value at `$E00096`) | SC | DMA enables: SETCLR (15), DMAEN (9), BPLEN (8); COPEN (7), BLTEN (6), SPREN (5), AUD3EN–AUD0EN (3–0) for later blocks |
| SYSID | `$F00800` | R | Machine identity, "R68K" |
| SYSVER | `$F00804` | R | FPGA build version |
| SYSCFG | `$F00808` | R | CPU type and speed, Chip RAM size |
| RESETWHY | `$F0080C` | R | Cause of the last reset |
| SYSCON | `$F00810` | RW | Overlay, writable ROM, ROM lock, user-mode protection, reset on halt |
| SYSRESET | `$F00814` | W | Software reset (`$A55A`) |
| SYSBTN | `$F00818` | R | Multiface and DivMMC buttons |
| SYSSTAT | `$F00820` | R | CPU halted |
| BUSERRADDR | `$F00824` | R | Address of the last bus error |
| BUSERRWHY | `$F00828` | R | Cause of the last bus error |

| Address range | Contents |
|---------------|----------|
| `$000000`–`$3FFFFF` | Chip RAM (boot ROM overlay at `$000000`–`$007FFF` for reads after reset) |
| `$E00000`–`$E0FFFF` | Custom block |
| `$F00000`–`$F0FFFF` | System block |
| `$F80000`–`$F87FFF` | Boot ROM |
