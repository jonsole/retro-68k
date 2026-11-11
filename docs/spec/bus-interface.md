# Spec 1: CPU bus interface

Status: **draft for review**

This spec connects the 68000 to everything else. It covers how the fx68k core is clocked, how its bus signals cross into the 100 MHz memory side, address decoding, /DTACK and wait states, bus errors, interrupt acknowledge and reset.

On the ZX Spectrum Next KS3 board the CPU is always fx68k inside the FPGA. The earlier plan for a real MC68SEC000 on a plug-on CPU board was dropped: the Next has no suitable connector, and its fast SRAM already gives the CPU zero-wait memory.

## 1. Summary

| Item | Value |
|------|-------|
| CPU | fx68k (cycle-exact 68000) inside the Artix-7 FPGA |
| CPU speed | 20 MHz: fx68k clocked at 40 MHz with alternating phase enables |
| Clock crossing | 40 MHz and 100 MHz come from the same MMCM and line up every 50 ns. Signals cross at fixed points with at least 15 ns to settle, so no synchronisers and no uncertainty |
| Bus | 68000 asynchronous bus: /AS, /UDS, /LDS, R/W, /DTACK, /BERR, FC0–2, IPL0–2. /VPA, E, bus arbitration and /HALT input are not used |
| Wait states | None for ROM, block RAM and registers. None for Chip RAM, except when an urgent display fetch takes the CPU's memory cycle, or a nasty copper, a HIGH DMA engine job or a changed slot plan owns it: then 2 or more (spec 5, section 6) |
| Bus errors | Unmapped addresses, writes to ROM, and (optionally) user-mode accesses to hardware |
| Interrupts | Vectored; the interrupt controller answers the acknowledge cycle with no wait states |
| Reset | fx68k reset from the system reset (spec 7); its RESET instruction resets the devices; a halted CPU (double bus fault) is detected |

## 2. Clocking fx68k

### 2.1 Phase enables

fx68k needs a clock at least twice the CPU speed, plus two one-cycle pulses, **enPhi1** and **enPhi2**, which act as clock enables for the two halves of the 68000's clock. "The original clock frequency can be any multiple and it doesn't even need to be regular" (fx68k notes).

- fx68k is clocked at **40 MHz** (the 200 MHz master ÷ 5).
- enPhi1 and enPhi2 alternate on every 40 MHz cycle, so one 68000 clock is two 40 MHz cycles: **20 MHz**.
- Each 68000 bus state (S0–S7) is one 40 MHz cycle, 25 ns. A bus cycle is 8 states, 200 ns. That is 2 memory slots (spec 5, section 5).
- fx68k's outputs change one 40 MHz cycle after the enable that caused them, exactly as the real chip's change on its clock edges.

### 2.2 Meeting timing at 40 MHz

On the KS3's Artix-7 (XC7A35T, speed grade -2), 40 MHz is comfortable. A Yosys trial synthesis puts fx68k at about 3,340 LUTs. On Lattice ECP5, open-source place and route measured fx68k at 62–81 MHz, and the Artix-7 -2 is a faster family than that. The fx68k notes say its microcode lookup is one of the slowest paths but its result isn't needed in the next cycle, and give the matching Vivado **multicycle constraints** (2 cycles from the instruction register to the micro- and nanocode addresses). The Vivado build uses them, for extra margin. Confirming the final figure in Vivado is open point B1.

### 2.3 Pausing the CPU

Because the enables are just clock enables, stopping them freezes fx68k exactly, in the middle of anything, and starting them again carries on as if nothing happened. Version 1 uses this only for reset. It could later support a hardware debugger (open point B3).

## 3. Crossing between 40 MHz and 100 MHz

The bus interface and the slot controller run at 100 MHz, while fx68k runs at 40 MHz. Both come from the 200 MHz master (one MMCM), and their rising edges line up every **50 ns** (one 68000 clock). Within each 50 ns, the edges are:

```
 time (ns):    0    10    20    25    30    40    50
 40 MHz:       ↑                 ↑                ↑
 100 MHz:      ↑     ↑     ↑           ↑     ↑     ↑
```

**From fx68k to 100 MHz** (address, /AS, /UDS, /LDS, R/W, FC, write data): these change only on 40 MHz edges, at 0 or 25 ns. The 100 MHz side captures them only on its edges at **20 and 40 ns**, 20 and 15 ns after any change.

**From 100 MHz to fx68k** (/DTACK, /BERR, IPL, read data): the 100 MHz side changes these only on its edges at **10 and 30 ns**. fx68k samples them on its edges at 25 and 50 ns, 15 and 20 ns later.

Every crossing therefore has **at least 15 ns** to settle. The build tells Vivado so with 15 ns path constraints (multicycle paths between the two clocks), instead of the default worst case (5 ns, from 25 to 30). There are no synchronisers and no random delays, so the CPU's timing against the memory slots is the same every time.


## 4. A bus cycle

### 4.1 Timing

For a bus cycle starting at time 0 (state S0), with the slot grid from spec 5:

| Time (ns) | State | What happens |
|-----------|-------|--------------|
| 0 | S0 | Cycle begins; slot k starts |
| 25 | S1 | Address and FC valid |
| 50 | S2 | /AS asserted; R/W valid (for reads, /UDS and /LDS too) |
| 70 | | 100 MHz side captures /AS: the access is known |
| 75 | S3 | Write data valid |
| 100 | S4 | Slot k+1 starts: a read's memory cycle (cycle 0) is issued; for writes, /UDS and /LDS are asserted |
| 110 | | /DTACK asserted (reads and writes) |
| 110–130 | | Read: address on the SRAM pins (the pads add one clock) |
| 120 | | Write: byte strobes captured; the write is posted |
| 125 | S5 | fx68k sees /DTACK: no wait state |
| 140 | | Read data captured from the SRAM |
| 160 | | Read data driven to fx68k |
| 175 | S7 | fx68k latches the read data (end of S6) |
| 200 | | Slot k+2 starts: a posted write uses its cycle 0. Next bus cycle can start |

**Reads** use cycle 0 of the bus cycle's second slot, or an earlier cycle that nobody else wants (the CPU is in the scheduler's spare-cycle order, spec 5, section 6.3). /DTACK goes out as soon as the cycle is issued, because the data is certain to follow 40 ns later.

**Writes are posted.** On a 68000 write, /UDS and /LDS only appear at S4, too late for slot k+1's cycle 0. The bus interface gives /DTACK early anyway, keeps the address, data and byte strobes, and writes them in cycle 0 of slot k+2. That is the first slot of the CPU's next bus cycle, which the CPU never uses for its own access (that comes in the cycle's second slot), so writes also cost no wait states. A read that follows always comes after the posted write, so it sees the new data.

For block RAM, registers and ROM, the data is ready well before 160 ns. So all targets give zero wait states.

**Checked in simulation** (`sim/`, phase 2): fx68k asserts /AS 50 ns into the slot, as above, and every bus cycle of the boot ROM test runs with no wait states, with or without the DMA port using every other memory cycle. The one exception is the bus cycle straight after a bus error: exception processing starts it 50 ns off the slot grid, it gets one wait state, and the next one is back in step.

### 4.2 Wait states

| Target | Wait |
|--------|------|
| Chip RAM | 0 normally. When an urgent display fetch takes cycle 0, the access takes the next cycle nobody else wants, usually within the slot, and on screens within the budget by the next cycle 0: 2 wait states at most (spec 5, section 6). While a nasty copper or a HIGH DMA engine job owns cycle 0, or with a slot plan that gives cycle 0 to another requester, the access waits for a cycle they leave: a long HIGH job can hold the CPU off for as long as it runs. /DTACK and the data simply come later. A posted write that loses its cycle 0 waits in the same way; the next bus cycle waits for it |
| Boot ROM, block RAM areas, custom registers, system registers | 0 |
| Interrupt acknowledge | 0 |

Since every slot has a CPU cycle (in the default slot plan), there is no alignment to keep: each access simply uses the cycle 0 of its slot.

**Off the grid:** 68000 bus cycles start on even CPU clocks, so they normally start on a slot boundary. If one ever starts 50 ns into a slot, the early /DTACK simply arrives one 68000 clock later: one wait state, after which the bus cycles are back in step with the slots.

## 5. Address decoding

| Address | Target | Notes |
|---------|--------|-------|
| `0x000000`–`0x007FFF` | Boot ROM for reads while the overlay is on; Chip RAM otherwise | Writes always go to Chip RAM (spec 7, section 3.2) |
| `0x000000`–`0x3FFFFF` | Chip RAM (4 MB SRAM) | Through the slot controller. On boards with 2 MB, Chip RAM ends at `0x1FFFFF` and the rest is a bus error |
| `0x400000`–`0xDFFFFF` | Reserved | Bus error |
| `0xE00000`–`0xE0FFFF` | Custom registers and palette | Internal register bus |
| `0xF00000`–`0xF0FFFF` | System registers | Internal register bus |
| `0xF80000`–`0xF87FFF` | Boot ROM | Writes are a bus error unless SYSCON.ROMWE (spec 7, section 3.3) |
| Everything else | Unmapped | Bus error |

Unused addresses inside a block (e.g. a gap in the custom registers) read as 0 and ignore writes. Only whole unmapped regions give bus errors, so the decoder stays small.

**Byte and word access:** /UDS and /LDS give the bytes. Chip RAM passes them to the SRAM's /UB and /LB. A byte write to a register writes that byte and keeps the others. Each 16-bit half is written and read on its own (spec 3, section 2); the register bus carries which half (its byte enables), on reads too, so the units with a read side effect (the FIFO data registers, TIMEHI) can act on the right half.

## 6. Bus errors

/BERR is asserted at S4 instead of /DTACK, and the 68000 takes its bus error exception (vector 2). Causes:

- an unmapped or reserved address,
- a write to the boot ROM while ROMWE is off,
- **optional protection:** with SYSCON.PROTECT set, any user-mode access (FC = 001 or 010) to `0xE00000`–`0xFFFFFF`. An operating system can keep programs away from the hardware with one bit,
- a CPU-space cycle other than interrupt acknowledge (the 68000 has no others in normal use).

The address and the cause of the last bus error are kept in BUSERRADDR and BUSERRWHY for debugging.

## 7. Interrupt acknowledge

The 68000 signals an interrupt acknowledge with FC = 111 and A19–A16 = 1111, with the level on A3–A1. The bus interface passes it to the interrupt controller (spec 13), which puts the vector number on D7–D0. /DTACK follows at the normal time: no wait states, no /VPA, no E-clock cycle.

IPL0–2 come from the interrupt controller through the 100 MHz to 40 MHz crossing (section 3).

## 8. Reset and halt

- **Reset in:** the system reset (spec 7) drives fx68k's extReset, and at power-on also pwrUp (fx68k's "cold reset" input, which it needs once at start). The enables keep running during reset, so the core resets cleanly.
- **First bus cycle:** fx68k leaves reset at a fixed point in the slot grid, so its bus cycles line up with the slots the same way every time (spec 5, section 5).
- **RESET instruction:** fx68k drives its reset output for 124 clocks. The bus interface turns this into the device reset in spec 7, section 2.4.
- **Halt:** a double bus fault halts the 68000 (fx68k's oHALTEDn). This sets SYSSTAT.HALTED and shows an error code as the screen's background colour (spec 7, section 5). With SYSCON.HALTRESET set, the computer also resets itself, with RESETWHY.HALTED. Otherwise the watchdog, a reset button or a USB RESET command recovers it.
- **Not used:** /HALT as an input (fx68k does not implement bus retry), /VPA and E (no 6800 devices), and bus arbitration (/BR, /BG, /BGACK: no other bus master; DMA uses memory slots instead).

## 9. New system registers

Added to the system control registers (spec 7, section 9):

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x810` | SYSCON | adds PROTECT (3), HALTRESET (4) | User-mode accesses to hardware give bus errors; reset automatically when the CPU halts |
| `0x80C` | RESETWHY | adds HALTED (7) | Reset because the CPU halted |
| `0x820` | SYSSTAT | HALTED (0) | Read: the CPU is halted |
| `0x824` | BUSERRADDR | 23–0 | Read: address of the last bus error |
| `0x828` | BUSERRWHY | UNMAPPED (0), ROMWRITE (1), PROTECT (2), CPUSPACE (3) | Read: cause of the last bus error |

## 10. FPGA resources

| Item | Resource |
|------|----------|
| fx68k | ~3,340 LUTs, ~1,440 flip-flops, 3 block RAMs (Yosys estimate for Artix-7; design plan D10) |
| Bus interface: crossing registers, decoder, /DTACK and /BERR logic, register-bus master | Estimate 200–400 LUTs |

## 11. Open points

| # | Item |
|---|------|
| B1 | Confirm fx68k meets 40 MHz in Vivado on the XC7A35T-2, with the multicycle constraints |
| B2 | ~~Confirm in simulation that fx68k's outputs and sampling points match section 4.1~~ Done: /AS at 50 ns into the slot, zero wait states (section 4.1) |
| B3 | A hardware debugger: pause the CPU by stopping its enables, single-step, breakpoints on addresses, all controlled from the PC over USB |
| B4 | Whether a user-mode access to Chip RAM should ever be blocked (memory protection beyond PROTECT): not in version 1 |

## 12. Tests

- **Clock crossing:** in simulation and in a Vivado timing report, every 40 ↔ 100 MHz path meets 15 ns, and captures happen only on the edges in section 3.
- **Bus cycles:** reads and writes of bytes and words to every target, with the timing of section 4.1; zero wait states except where section 4.2 says.
- **Wait states:** with all DMA busy (display, audio, copper and the DMA engine), Chip RAM accesses still have no waits.
- **Bus errors:** each cause raises vector 2 and records BUSERRADDR and BUSERRWHY; PROTECT blocks user mode only.
- **Interrupt acknowledge:** each level returns the right vector with no wait.
- **Reset and halt:** reset at every source; the RESET instruction resets the devices only; a double bus fault sets HALTED and, with HALTRESET, resets with RESETWHY.HALTED.
- **Software:** run a 68000 instruction test suite (for example one of the published exhaustive 68000 test sets) on fx68k through this bus interface, from ROM and from Chip RAM.
