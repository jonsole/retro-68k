# Spec 5: Memory architecture and DMA arbitration

Status: **v1 scope**

This spec describes how the CPU, video, audio, the copper, the blitter and the rasteriser share the KS3's fast SRAM. It follows the Amiga's model: memory time is cut into fixed **slots**, and each slot's memory cycles have fixed owners, so every user's bandwidth is guaranteed.

The SRAM is fast enough to give the CPU its own memory cycle in **every** slot, so the CPU normally never waits for the display, audio, copper or blitter, and there is no even/odd alignment to keep. As on the Amiga, the bitplane DMA may take the CPU's cycle when it would otherwise be late (section 6); the CPU then waits one slot. One scheduler, the DMA controller (`dmac.v` in retro-hw, the equivalent of the Amiga's Agnus), gives out every memory cycle, following a slot plan that software can change (section 8.1).

## 1. Summary

| Item | Value |
|------|-------|
| Memory | One IS61WV204816BLL-10 SRAM on the KS3: 2M × 16 bit (4 MB), 10 ns. Some boards may have 2 MB; SYSCFG.CHIPMB reports which |
| Memory cycle | 20 ns = 2 clocks at 100 MHz: one 16-bit read or write at any address (byte writes with /UB and /LB) |
| Slot | 100 ns = 5 memory cycles (numbered 0–4) = 2 CPU clocks at 20 MHz |
| CPU | Cycle 0 of every slot, and any spare cycle ahead of the blitter. Waits only when an urgent display fetch takes cycle 0 (one slot, 2 CPU clocks), or while a nasty copper owns cycle 0 (section 6.3) |
| DMA | Cycles 1 and 3: display fetch, layers first, then sprites (spread out, so a waiting fetch never waits long). Cycle 2: audio and peripherals. Cycle 4: the free pool for the copper and the blitter. A cycle its owner leaves goes to the next requester that asks, by number |
| Slot plan | Who owns each cycle: the MEMSLOT0–4 registers, the plan above after reset (section 8.1) |
| Beam lock | Every scan line is a whole number of slots; the slot counter restarts each line, so DMA happens at the same beam positions on every line |
| Total bandwidth | 100 MB/s (5 × 2 bytes per 100 ns) |
| Refresh | None needed (SRAM) |

## 2. Memory types (Amiga naming)

| Name | Where | Who can access it |
|------|-------|-------------------|
| **Chip RAM** | The 4 MB SRAM | CPU and every DMA user |
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

- **DMA addresses are the same as CPU addresses** (24-bit). Video, audio, the copper and the blitter can all use the whole of Chip RAM.
- **Reset overlay:** after reset the ROM also appears at `0x000000` for CPU reads (writes go to Chip RAM), so the CPU can fetch its stack pointer and start address. The ROM code runs at its real address at `0xF80000`, builds the vector table in RAM, then turns the overlay off (spec 7, section 3).

## 4. Memory cycles and slots

### 4.1 Clocks

The system clocks are whole-number divisions of one 200 MHz master, from the first MMCM. The pixel clock comes from a second MMCM, from the same 50 MHz oscillator (spec 4, section 3.1):

| Clock | Master ÷ | Frequency |
|-------|----------|-----------|
| System / SRAM controller | 2 | 100 MHz |
| fx68k master clock | 5 | 40 MHz with alternating phase enables → **20 MHz 68000** |
| Memory cycle | 4 | 20 ns |
| Slot | 20 | 100 ns = 5 memory cycles |
| Pixel clock | – (MMCM 2: 50 ÷ 5 × 108 ÷ 40) | 27 MHz (576p), asynchronous to the clocks above |

Both MMCMs run from the same oscillator, so the frequencies are exact: every 576p scan line (864 pixels at 27 MHz) is exactly 32 µs, which is **320 slots** (spec 4, section 3.2). Only the phase between the pixel clock and the system clock is unknown, so the video treats them as asynchronous clock domains and crosses between them with synchronisers and handshakes. The slot counter `hslot` restarts at 0 at the start of every line.

### 4.2 One memory cycle

The SRAM is asynchronous: give it an address and it answers within 10 ns. With the FPGA's pin delays, a safe access takes **2 clocks (20 ns)**:

| | Clock 0 (0 ns) | Clock 1 (10 ns) | End (20 ns) |
|---|---|---|---|
| **Read** | Address, /CS, /OE and byte selects out | SRAM drives data | Data captured |
| **Write** | Address, data and byte selects out | /WE pulsed low for about 8–10 ns (timed with the 200 MHz master) | Write done |

- Any address, any mix of reads and writes, back to back: there are no rows, banks or bursts to worry about.
- Between a read and a following write, the controller releases /OE early and starts driving data half a clock later, so the SRAM and FPGA never drive the bus at the same time. No gap cycle is needed. This must be checked against the datasheet timings (tHZOE, tPWE, tSD; open point M2).
- Address, data and control outputs come from the FPGA's I/O flip-flops, so their timing is the same every cycle. Those flip-flops add one clock: a cycle issued at a cycle boundary is on the pins from 10 to 30 ns after it, and its read data is captured at 30 ns. The cycle table below is in the controller's terms.

### 4.3 Who owns each cycle

Each 100 ns slot holds 5 memory cycles:

| Cycle | Owner | Notes |
|-------|-------|-------|
| **0** | **CPU** | The Amiga's "even" cycle. If the CPU doesn't need it in this slot, it goes to the free pool |
| 1 | Display fetch | Layers (spec 4, section 5), then sprites (spec 9). If neither needs it, it goes to the free pool |
| 2 | Audio and peripherals | Audio channels (spec 6). In version 1 nothing else uses it; unused cycles go to the free pool |
| 3 | Display fetch | Layers and sprites, as cycle 1. The display's two cycles are 40 and 60 ns apart, not side by side, so a fetch that has just missed one waits at most 60 ns for the next (spec 4, section 5.6) |
| 4 | Free pool | Owned by nobody: the copper, the blitter, the rasteriser and anyone else, by number (section 6) |

This is the default plan, the one the MEMSLOT registers hold after reset. Software can change it (section 8.1).

### 4.4 Bandwidth

- Total: 5 cycles × 2 bytes per 100 ns = **100 MB/s**.
- CPU: a 68000 at 20 MHz makes at most one access per bus cycle (200 ns), so it uses cycle 0 in at most every other slot: up to **10 MB/s**. Its other cycle 0s go to the free pool.
- Display fetch: **40 MB/s** (cycles 1 and 3). There is no wide fetch in version 1.
- Audio and peripherals: **20 MB/s** (cycle 2), far more than 4 channels of 8-bit samples need.
- Free pool (copper, blitter): cycle 4 (20 MB/s), plus the cycle 0s the CPU leaves, the cycle 2s audio leaves and the display cycles no layer needs: typically 50–65 MB/s.

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

- A **read** uses **cycle 0 of slot k+1**, or an earlier cycle nobody else wants (section 6.3). The address and R/W are known since S1–S2. Read data reaches the CPU at 160 ns, 15 ns before it latches it (spec 1, section 4.1).
- A **write** is posted: its byte strobes only appear at S4 (100 ns), so it uses **cycle 0 of slot k+2**, the first slot of the CPU's next bus cycle, where the CPU never makes its own access. /DTACK is given early, so writes have no wait states either.
- Every slot has a cycle 0, so it doesn't matter where in the slot grid a bus cycle starts: **there is no alignment to keep and no realignment wait**.
- Block RAM, registers and ROM don't use SRAM cycles at all.

**The CPU waits for Chip RAM only when the display would otherwise be late, or when software asks for it.** With the default plan, only an urgent display fetch (one whose deadline is about to pass, section 6) can take cycle 0 from the CPU; the CPU's access then waits one slot, and usually less, since the CPU also takes any spare cycle. On screens within the budget this is rare; on heavy screens the CPU slows down on those lines, as on the Amiga.

Software asks for it in two ways: a copper at PRI 2 (nasty), which owns cycle 0 while it asks (section 6.3), or a slot plan that takes cycle 0 from the CPU (section 8.1). (The DMA engine's HIGH jobs were a third; they went with the engine, spec 11.)

**Interrupts** stay vectored (design plan D8): the 6800-style /VPA cycle is not used.

## 6. The DMA scheduler

One block, the DMA controller (`dmac.v` in retro-hw, the equivalent of the Amiga's Agnus; its spec is `fpga/retro-hw/docs/spec/dmac.md`), decides who gets every memory cycle. Each DMA user is a **requester** that holds a request (address, read or write, data) until it is granted; the read data comes back 40 ns later. The bitplane DMA and the sprites have deadlines: each raises **urgent** with a request that is about to be late.

### 6.1 Requesters

A requester's number is its priority: wherever two meet in the same rule, the lower number wins.

| Number | Requester | What | Urgent | High |
|--------|-----------|------|--------|------|
| 0 | BPL | Bitplane DMA (spec 4, section 5) | When a layer's deadline is close | – |
| 1 | SPR | Sprites (spec 9): the 8 sprite FIFOs | When a FIFO is about to run dry | – |
| 2 | AUD | Audio (spec 6): has microseconds to spare | – | – |
| 3 | COP | Copper (spec 10) | – | COPCON.PRI 1 or more |
| 4 | CPU | The 68000 | – | – |
| 5 | BLT | The blitter (spec 11) | – | – |
| 6 | RAS | The rasteriser (spec 17) | – | – |
| 7 | PORT | The DMA port: peripherals later; the tests use it now. It has no owner bit in the slot plan, so it gets spare cycles only | – | – |

### 6.2 The slot plan

Each of the 5 cycles of a slot has a set of **owners** (any number of requesters, or none) and a **lock** bit. The plan is in the MEMSLOT0–4 registers (section 8.1). After reset it is the plan of section 4.3: cycle 0 the CPU, cycles 1 and 3 the layers and sprites, cycle 2 audio, cycle 4 nobody, nothing locked.

### 6.3 Who gets each cycle

For each cycle, the first rule that finds a request wins, and within a rule the lowest number wins:

1. **A locked cycle's owner.** In a locked cycle, an owner that asks gets it.
2. **An urgent request** (the layers before the sprites). It may take any cycle that is not locked, the CPU's cycle 0 included; the CPU's access then waits.
3. **The cycle's owner.** In cycles 1 and 3 of the default plan the layers go before the sprites.
4. **The spare cycles:** first a **high** request (a copper at PRI 1 or 2), then **anyone** who asks: layers, sprites, audio, copper, CPU, blitter, rasteriser, DMA port.

So no cycle is wasted: whatever its owners leave goes to the next requester that wants one. The display can use cycle 0 when the CPU is not using it, and cycles 2 and 4 when audio leaves them. The CPU can use any cycle its turn in rule 4 gives it, so a read that misses its cycle 0 often gets a later cycle of the same slot.

**Nasty copper.** While a copper at PRI 2 (nasty) asks for a cycle, it owns cycle 0 *in place of the CPU*. The rule is the same whatever the plan: the CPU's owner bit in cycle 0 is cleared, and the copper's is set; the rest of MEMSLOT0 (its other owners and its lock) stands. A plan that already leaves the CPU out of cycle 0 is changed only by the added owner. This is done outside the scheduler, in `retro68k.v`, so MEMSLOT0 reads back as written.

Unlike the first scheduler, the display's requesters are not ordered by deadline: the layers and the sprites meet by number, so the layers go first, and only `urgent` saves a late sprite. Each still uses its own deadline to decide when to raise `urgent`. There is no CPU share: a nasty copper owns cycle 0 for as long as it asks.

### 6.4 How long an urgent request waits

An urgent request loses a cycle only to the owner of a locked cycle that asks, or to an urgent request from a lower number. From the clock in which it is first raised to the clock its data arrives, the worst case is **6 + 2W clocks**, where W is the longest run of cycles in a row (round the slot) that holds at most U unlocked cycles, and U is the number of urgent requesters with lower numbers (retro-hw's dmac spec, section 4.6):

| Plan | Layers (U = 0) | Sprites (U = 1) |
|------|----------------|-----------------|
| Default, or any plan with nothing locked | W = 0: 6 clocks (60 ns) | W = 1: 8 clocks (80 ns) |
| One locked cycle | W = 1: 8 clocks | W = 2 or more: 10 clocks or more |

The layers' and the sprites' urgent marks (spec 4, section 5.6; spec 9, section 4) are set for the default plan. **A plan that locks cycles lengthens these waits**: lock only what must be locked, and check the display at its budget with that plan.

## 7. Allocation per line

Every slot of every line has the same owners (section 4.3), so the allocation per line is simply the number of slots. For the default plan:

| Owner | Cycle | Cycles per line (576p, 320 slots) | Bandwidth |
|-------|-------|-----------------------------------|-----------|
| CPU | 0 | 320 | 20 MB/s of cycles; the CPU uses at most 10 MB/s |
| Display fetch (layers, sprites) | 1, 3 | 640 | 40 MB/s |
| Audio and peripherals | 2 | 320 | 20 MB/s |
| Free pool | 4 | 320 | 20 MB/s, plus the cycles other owners leave |

If an owner doesn't need its cycle (the CPU is between accesses, no layer is fetching, no audio channel needs a word), the cycle goes to the free pool.

### 7.1 What each owner gets

| Owner | Needs | Gets |
|-------|-------|------|
| Display (layers) | Depends on the layers | 1280 bytes per line: 1.48 bytes per pixel (864 pixels per line, spec 4, section 5.2) |
| Audio, 4 channels of 8-bit samples | One word (2 samples) per channel at a time, as on the Amiga | Cycle 2: 20 MB/s |
| Copper | 2 cycles per instruction | The free pool, first |
| Blitter | – | The rest of the free pool: about 50–65 MB/s of memory cycles, depending on the screen. It uses a quarter to a third of them (spec 11, section 8) |
| Rasteriser | – | What the blitter leaves. It asks for a cycle only now and then (spec 17, section 6), so the two run side by side |

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
| 6 | BLTEN | The blitter (spec 11) and the rasteriser (spec 17) |
| 5 | SPREN | Sprite DMA (spec 9) |
| 4 | – | Unused |
| 3–0 | AUD3EN–AUD0EN | Audio channels 3–0 (spec 6) |

Together with BPLDMA, every DMA user can be turned off on its own (one audio channel, one bitplane of one layer), so that the CPU or copper can do its job instead by writing its data registers.

### 8.1 The slot plan (MEMSLOT0–4)

Five registers, **MEMSLOT0–MEMSLOT4** at `0xE00098`–`0xE000A8`, one per cycle of the slot, hold the plan the scheduler follows (section 6.2). Each is read and write; only its low byte is used (`MOVE.B` to the register's address + 3, `MOVE.W` to + 2, or `MOVE.L`):

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | BPL | The layers own this cycle |
| 1 | SPR | The sprites own it |
| 2 | AUD | Audio owns it |
| 3 | COP | The copper owns it |
| 4 | CPU | The CPU owns it |
| 5 | BLT | The blitter owns it |
| 6 | RAS | The rasteriser owns it |
| 7 | LOCK | An urgent request may not take this cycle from an owner that asks |

The bits are the requesters' numbers (section 6.1). Requester 7, the DMA port, has no bit: it never owns a cycle. (Until the rasteriser came, bit 6 was the port's.) After a reset (and the 68000's RESET instruction, which resets the custom hardware) they hold the default plan:

| Register | Value | Owners |
|----------|-------|--------|
| MEMSLOT0 | `0x10` | CPU |
| MEMSLOT1 | `0x03` | Layers, sprites |
| MEMSLOT2 | `0x04` | Audio |
| MEMSLOT3 | `0x03` | Layers, sprites |
| MEMSLOT4 | `0x00` | Nobody |

- A write takes effect from the next cycle the scheduler gives out; one in the middle of a slot or a line is safe. The CPU and the copper can both write them, so a copper list can change the plan at a given line.
- **Owning a cycle never costs bandwidth, only priority**: an owned cycle its owners don't use goes to the spare-cycle order. So, for example, `0x20` in MEMSLOT0 (the blitter instead of the CPU) is a "big blit" plan: the CPU gets spare cycles only. (The blitter asks for one cycle in three or four, so in simulation the CPU still never waits under such a plan: `dtest` T19.)
- **Keep the display's cycles.** The layers and sprites need the bandwidth of two owned cycles for the budgets of spec 4, section 5.2 and spec 9, section 5; with fewer, a heavy screen runs short.
- **Locks** lengthen the urgent waits (section 6.4). Nothing in this machine needs them: the 68000 waits for its data (spec 1), so it can lose its cycle.
- A nasty copper changes the plan seen by the scheduler only in cycle 0, and only while it asks (section 6.3).

## 9. Open points

| # | Item |
|---|------|
| M1 | ~~Confirm fx68k's exact bus timing in simulation~~ Done: it matches the real 68000; writes are posted (section 5) |
| M2 | Check the 20 ns read and write cycles, and read-to-write turnaround, against the IS61WV204816BLL-10 datasheet and the KS3's board timing |
| M3 | Is the KS3 fitted with 4 MB or 2 MB? Check, and test both settings |
| M4 | A faster memory cycle (e.g. 15 ns with careful pin timing) would give 6–7 cycles per slot; not needed for version 1 |

## 10. Tests

- **Cycle table:** check each owner gets its cycles at the same `hslot` on every line, and that unused cycles go to the free pool.
- **CPU waits:** run fx68k from Chip RAM with the display, audio, copper and blitter all busy; check that /DTACK is delayed only by stolen cycle 0s (urgent display, nasty copper).
- **The rules:** retro-hw's own tests check the scheduler against a model of the rules, with random requests and random plans (`fpga/retro-hw/test/dmac`).
- **The slot plan** (`dtest`, T17–T19): MEMSLOT0–4 read back the default plan; the CPU times 32 Chip RAM reads while an 8 KB fill runs, and they take no longer than with no job; with a plan that makes the blitter owner of every cycle the job and the CPU both still run; the default plan is written back and read back. (With version 1's DMA engine, which asked for nearly every cycle, that plan made the reads at least 500 ns longer. The new blitter asks for too few cycles to show it: the owner rule itself is tested in retro-hw's `test/dmac`.)
- **SRAM model:** run the controller against an SRAM simulation model with the datasheet timing checks on (setup, hold, pulse widths, bus turnaround). Done in `sim/` for version 1.
- **Board test:** a full 4 MB pattern test from the CPU and from the blitter at once, with the display busy.
