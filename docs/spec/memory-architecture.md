# Spec 5: Memory architecture and DMA arbitration

Status: **v1 scope**

This spec describes how the CPU, video, audio, the copper and the DMA engine share the KS3's fast SRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, and each slot's memory cycles have fixed owners, so every user's bandwidth is guaranteed.

The SRAM is fast enough to give the CPU its own memory cycle in **every** slot, so the CPU normally never waits for the display, audio, copper or DMA engine, and there is no even/odd alignment to keep. As on the Amiga, the bitplane DMA may take the CPU's cycle when it would otherwise be late (section 6); the CPU then waits one slot. One scheduler, the DMA controller (`dmac.v`, the equivalent of the Amiga's Agnus), gives out every memory cycle.

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One IS61WV204816BLL-10 SRAM on the KS3: 2M × 16 bit (4 MB), 10 ns. Some boards may have 2 MB; SYSCFG.CHIPMB reports which |
| Memory cycle | 20 ns = 2 clocks at 100 MHz: one 16-bit read or write at any address (byte writes with /UB and /LB) |
| Slot | 100 ns = 5 memory cycles (numbered 0–4) = 2 CPU clocks at 20 MHz |
| CPU | Cycle 0 of every slot. Waits only when an urgent display fetch, a nasty copper or a HIGH DMA engine job takes that cycle (one slot, 2 CPU clocks) |
| DMA | Cycles 1 and 3: display fetch (spread out, so a waiting fetch never waits long). Cycle 2: audio and peripherals. Cycle 4: the free pool for the copper and the DMA engine. The free pool also gets cycle 0 whenever the CPU isn't using it |
| Beam lock | Every scan line is a whole number of slots; the slot counter restarts each line, so DMA happens at the same beam positions on every line |
| Total bandwidth | 100 MB/s (5 × 2 bytes per 100 ns) |
| Refresh | None needed (SRAM) |

## 2. Memory types (Amiga naming)

| Name | Where | Who can access it |
|------|-------|-------------------|
| **Chip RAM** | The 4 MB SRAM | CPU and every DMA engine |
| **Block RAM** | Inside the FPGA: boot ROM, palette, FIFOs | CPU through registers/windows; never uses SRAM cycles |

There is no Fast RAM: all RAM is Chip RAM, and the CPU gets it at full speed anyway. On the Amiga, Chip RAM was slowed by display modes that stole CPU cycles; here the display never takes the CPU's cycle.

## 3. Memory map

The full map is in spec 3, section 1. Memory in short:

| Range | Size | Device |
|-------|------|--------|
| `0x000000`–`0x3FFFFF` | 4 MB | Chip RAM (2 MB boards: `0x000000`–`0x1FFFFF`). At reset the boot ROM overlays address 0 for reads |
| `0x400000`–`0xDFFFFF` | | Reserved (bus error) |
| `0xE00000`–`0xE0FFFF` | | Custom registers and palettes (`0xE04000`–`0xE04FFF`) |
| `0xF00000`–`0xF0FFFF` | | System registers |
| `0xF80000`–`0xF87FFF` | 32 KB | Boot ROM |

- **DMA addresses are the same as CPU addresses** (24-bit). Video, audio, the copper and the DMA engine can all use the whole of Chip RAM.
- **Reset overlay:** after reset the ROM also appears at `0x000000` for CPU reads (writes go to Chip RAM), so the CPU can fetch its stack pointer and start address. The ROM code runs at its real address at `0xF80000`, builds the vector table in RAM, then turns the overlay off (spec 7, section 3).

## 4. Memory cycles and slots

### 4.1 Clocks

The system clocks come from the first MMCM, whose VCO runs at 1000 MHz from the 50 MHz oscillator. The pixel clock comes from a second MMCM, from the same oscillator (spec 4, section 3.1):

| Clock | From | Frequency |
|-------|------|-----------|
| System / SRAM controller | MMCM 1, VCO ÷ 10 | 100 MHz |
| fx68k master clock | MMCM 1, VCO ÷ 25 | 40 MHz with alternating phase enables → **20 MHz 68000** |
| Memory cycle | 2 system clocks | 20 ns |
| Slot | 10 system clocks | 100 ns = 5 memory cycles |
| Pixel clock | MMCM 2 (VCO 1080 MHz ÷ 40) | 27 MHz (576p), asynchronous to the clocks above |

Both MMCMs run from the same oscillator, so the frequencies are exact: every 576p scan line (864 pixels at 27 MHz) is exactly 32 µs, which is **320 slots** (spec 4, section 3.2). Only the phase between the pixel clock and the system clock is unknown, so the video treats them as asynchronous clock domains and crosses between them with synchronisers and handshakes. The slot counter `hslot` restarts at 0 at the start of every line.

### 4.2 One memory cycle

The SRAM is asynchronous: give it an address and it answers within 10 ns. With the FPGA's pin delays, a safe access takes **2 clocks (20 ns)**:

Times are from when the cycle reaches the pins (see the last point below). The half-clock edges come from ODDR output registers on the 100 MHz clock, so no faster clock is needed:

| | 0 ns | 5 ns | 15 ns | 20 ns |
|---|---|---|---|---|
| **Read** | Address, /CS and byte selects out | /OE low | | Data captured |
| **Write** | Address and byte selects out | Data driven, /WE low | /WE high (a 10 ns pulse, with 5 ns of address setup and hold) | Write done |

- Any address, any mix of reads and writes, back to back: there are no rows, banks or bursts to worry about.
- Between a read and a following write, the controller releases /OE early and starts driving data half a clock later, so the SRAM and FPGA never drive the bus at the same time. No gap cycle is needed. This must be checked against the datasheet timings (tHZOE, tPWE, tSD; open point M2).
- Address, data and control outputs come from the FPGA's I/O flip-flops, so their timing is the same every cycle. Those flip-flops add one clock: a cycle issued at a cycle boundary is on the pins from 10 to 30 ns after it, and its read data is captured at 30 ns. The cycle table below is in the controller's terms.

### 4.3 Who owns each cycle

Each 100 ns slot holds 5 memory cycles:

| Cycle | Owner | Notes |
|-------|-------|-------|
| **0** | **CPU** | The Amiga's "even" cycle. If the CPU doesn't need it in this slot, it goes to the free pool |
| 1 | Display fetch | Layers (spec 4, section 5). If no layer needs it, it goes to the free pool |
| 2 | Audio and peripherals | Audio channels (spec 6). In version 1 nothing else uses it; unused cycles go to the free pool |
| 3 | Display fetch | Layers, as cycle 1. The display's two cycles are 40 and 60 ns apart, not side by side, so a fetch that has just missed one waits at most 60 ns for the next (spec 4, section 5.6) |
| 4 | Free pool | Copper and DMA engine (section 6) |

### 4.4 Bandwidth

- Total: 5 cycles × 2 bytes per 100 ns = **100 MB/s**.
- CPU: a 68000 at 20 MHz makes at most one access per bus cycle (200 ns), so it uses cycle 0 in at most every other slot: up to **10 MB/s**. Its other cycle 0s go to the free pool.
- Display fetch: **40 MB/s** (cycles 1 and 3). There is no wide fetch in version 1.
- Audio and peripherals: **20 MB/s** (cycle 2), far more than 4 channels of 8-bit samples need.
- Free pool (copper, DMA engine): cycle 4 (20 MB/s), plus the cycle 0s the CPU leaves, the cycle 2s audio leaves and the display cycles no layer needs: typically 50–65 MB/s.

## 5. CPU access

A 20 MHz 68000 bus cycle takes 4 CPU clocks = 2 slots. For a cycle starting in slot *k*:

```
 slot:            k                   k+1
 state:   S0   S1   S2   S3   |  S4   S5   S6   S7
 time:    0    25   50   75   | 100  125  150  175  200 ns
 address:      valid ->
 /AS:               asserted ------------------------>
 SRAM:                        | cycle 0: read (pins 110-130)
 /DTACK:                      | asserted (110) ------>
 CPU latches read data:                      end of S6 (175 ns)
```

- A **read** uses **cycle 0 of slot k+1**. The address and R/W are known since S1–S2. Read data reaches the CPU at 160 ns, 15 ns before it latches it (spec 1, section 4.1).
- A **write** is posted: its byte strobes only appear at S4 (100 ns), so it uses **cycle 0 of slot k+2**, the first slot of the CPU's next bus cycle, where the CPU never makes its own access. /DTACK is given early, so writes have no wait states either.
- Every slot has a cycle 0, so it doesn't matter where in the slot grid a bus cycle starts: **there is no alignment to keep and no realignment wait**.
- Block RAM, registers and ROM don't use SRAM cycles at all.

**The CPU waits for Chip RAM only when the display would otherwise be late, or when software asks for it.** Only an urgent display fetch (one whose deadline is about to pass, section 6), a copper at PRI 2 (nasty) or a DMA engine job with HIGH set (which leaves the CPU a share, spec 11, section 5) can take cycle 0 from the CPU; the CPU's access then waits one slot. On screens within the budget this is rare; on heavy screens the CPU slows down on those lines, as on the Amiga.

**Interrupts** stay vectored (design plan D8): the 6800-style /VPA cycle is not used.

## 6. The DMA scheduler

One block, the DMA controller (`fpga/rtl/dmac.v`, the equivalent of the Amiga's Agnus), decides who gets every memory cycle. Each DMA user is a **channel** that holds a request (address, read or write, data) until it is granted; the read data comes back 40 ns later. The bitplane DMA and, later, sprites are **hard-deadline** channels: with each request they give the time left until the data is needed, and say when it is **urgent** (about to be late).

| Channel | What | Kind |
|---------|------|------|
| CPU | The 68000 | Only ever uses cycle 0 |
| BPL | Bitplane DMA (spec 4, section 5) | Hard deadline |
| SPR | Sprites (spec 9): the 8 sprite FIFOs | Hard deadline |
| AUD | Audio (spec 6) | Soft: has microseconds to spare |
| COP | Copper (spec 10) | Best effort; COPCON.PRI can raise it to high (ahead of audio and non-urgent display) or nasty (may also take cycle 0) |
| BLT | DMA engine / blitter (spec 11): its 4 channels take turns inside the engine | Best effort; a job with HIGH set may also take cycle 0 (below) |
| PORT | The DMA port: peripherals later; the tests use it now | Best effort |

For each cycle, the first rule that finds a request wins:

1. **An urgent hard-deadline request** gets the cycle, whatever it is, even the CPU's cycle 0 (the CPU's access then waits one slot). Earliest deadline first.
   Then, **a copper at PRI 2 (nasty)** gets the cycle, cycle 0 included.
2. **The cycle's default owner:**

   | Cycle | Default owner |
   |-------|---------------|
   | 0 | CPU; but a DMA engine job with HIGH set takes it, except for every 2nd, 4th or 8th time both want it (the channel's CPUSHARE), which the CPU keeps |
   | 1, 3 | Hard-deadline channels, earliest deadline first |
   | 2 | Audio |
   | 4 | – (the copper at PRI 1 or 2) |

3. **The free order:** hard-deadline channels (earliest deadline first), audio, copper, DMA engine, the DMA port. A copper at PRI 1 or 2 moves to the front of this order.

So no cycle is wasted: whatever its owner leaves goes to the next channel that wants one. In particular the display can use cycle 0 when the CPU is not using it (at least every other one, since a 68000 bus cycle is two slots), and cycles 2 and 4 when audio, the copper and the DMA engine leave them.

## 7. Fixed allocation per line

Every slot of every line has the same owners (section 4.3), so the allocation per line is simply the number of slots:

| Owner | Cycle | Cycles per line (576p, 320 slots) | Bandwidth |
|-------|-------|-----------------------------------|-----------|
| CPU | 0 | 320 | 20 MB/s of cycles; the CPU uses at most 10 MB/s |
| Display fetch | 1, 3 | 640 | 40 MB/s |
| Audio and peripherals | 2 | 320 | 20 MB/s |
| Free pool | 4 | 320 | 20 MB/s, plus the cycles other owners leave |

If an owner doesn't need its cycle (the CPU is between accesses, no layer is fetching, no audio channel needs a word), the cycle goes to the free pool.

### 7.1 What each owner gets

| Owner | Needs | Gets |
|-------|-------|------|
| Display (layers) | Depends on the layers | 1280 bytes per line: 1.48 bytes per pixel (864 pixels per line, spec 4, section 5.2) |
| Audio, 4 channels of 8-bit samples | One word (2 samples) per channel at a time, as on the Amiga | Cycle 2: 20 MB/s |
| Copper | 2 cycles per instruction | The free pool, first |
| DMA engine | – | The rest of the free pool: about 50–65 MB/s of memory cycles, depending on the screen (spec 11) |

During vertical blanking (49 of the 625 lines) there is no display fetch, so cycles 1 and 3 go to the free pool too. In the horizontal blank (144 of the 864 pixels) the display fetches only the first two groups of each layer's next line.

### 7.2 No line buffers

Display data is fetched just in time into each plane's data register (BPLxDAT), as on the Amiga (spec 4, section 5). There are no hidden buffers. Nothing is stored for a whole line.

## 8. DMA control register (Amiga DMACON style)

One register, **DMACON**, at `0xE00094` (spec 3). Its 16-bit value is in the low half at `0xE00096`, the same offset as the Amiga's DMACON. Writes use set/clear:

The bits are where the Amiga has them:

| Bit | Name | Enables |
|-----|------|---------|
| 15 | SETCLR | 1 = set the bits written as 1, 0 = clear them |
| 9 | DMAEN | Master enable for everything below |
| 8 | BPLEN | Bitplane DMA for all layers (each plane also has its own enable in its layer's BPLDMA; spec 4, section 5.5) |
| 7 | COPEN | Copper |
| 6 | BLTEN | DMA engine / blitter (spec 11) |
| 5 | SPREN | Sprite DMA (spec 9) |
| 4 | – | Unused |
| 3–0 | AUD3EN–AUD0EN | Audio channels 3–0 (spec 6) |

Together with BPLDMA, every DMA user can be turned off on its own (one audio channel, one bitplane of one layer), so that the CPU or copper can do its job instead by writing its data registers.

## 9. Open points

| # | Item |
|---|------|
| M1 | ~~Confirm fx68k's exact bus timing in simulation~~ Done: it matches the real 68000; writes are posted (section 5) |
| M2 | Check the 20 ns read and write cycles, and read-to-write turnaround, against the IS61WV204816BLL-10 datasheet and the KS3's board timing |
| M3 | Is the KS3 fitted with 4 MB or 2 MB? Check, and test both settings |
| M4 | A faster memory cycle (e.g. 15 ns with careful pin timing) would give 6–7 cycles per slot; not needed for version 1 |

## 10. Tests

- **Cycle table:** check each owner gets its cycles at the same `hslot` on every line, and that unused cycles go to the free pool.
- **CPU waits:** run fx68k from Chip RAM with the display, audio, copper and DMA engine all busy; check that /DTACK is delayed only by stolen cycle 0s (urgent display, nasty copper), each by exactly one slot.
- **SRAM model:** run the controller against an SRAM simulation model with the datasheet timing checks on (setup, hold, pulse widths, bus turnaround). Done in `sim/` for version 1.
- **Board test:** a full 4 MB pattern test from the CPU and from the DMA engine at once, with the display busy.
