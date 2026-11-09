# Spec 11: DMA engine and blitter

Status: **version 1, for review**; BLIT replaced COPY, FILL, KEYCOPY and LOGIC on 29 October 2026 (shared with retro-z80)

One engine moves data for the CPU: copying and filling memory, feeding peripherals, writing hardware registers, and drawing graphics (the blitter). The CPU describes jobs in memory, starts a channel, and carries on with other work while the engine runs them.

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, running at the same time and taking turns, a group of memory cycles each |
| Programming | A job written straight into a channel's registers, or chains of 32-byte **descriptors** (job descriptions, laid out as those registers) in Chip RAM or in a 2 KB descriptor RAM inside the FPGA |
| Jobs | **BLIT**, as the Amiga's blitter: each pixel any logic function (minterm) of a mask A, an image B and the destination's old contents C; copies, fills, cookie-cut drawing with a colour key or a 1 bpp mask, and logic all come from it. **ADD** per pixel. In 1D (linear) or 2D (rectangles with a stride). MIX (audio voices) is on hold |
| Pixel formats | 1, 2, 4 or 8 bits per pixel, positioned to the pixel: chunky layers directly, planar layers one plane at a time (section 6.1) |
| Sources and destinations | Chip RAM, the custom registers and palettes, the descriptor RAM, the boot ROM (read only), or a peripheral port (USB serial; the SD card later) |
| Memory cycles | Normally only free ones, so the CPU is never slowed. A **HIGH** bit per job lets it take the CPU's cycles, like the Amiga's "blitter nasty" |
| Speed at 576p | Copy about 25–38 MB/s, fill 50–77 MB/s, depending on the screen and how busy the CPU is (section 7). A 68000 at 20 MHz copies about 4 MB/s |
| Finishing | An interrupt per descriptor if asked, status flags per channel |

## 2. Comparison with the Amiga

| Feature | Amiga blitter | retro68k DMA engine |
|---------|---------------|---------------------|
| Jobs at once | 1 | 4 channels |
| Starting jobs | CPU or copper writes registers, then waits for the blitter to finish before the next job | The same (a channel's job registers), or a chain of jobs the engine works through alone |
| Pixel layout | Bitplanes: one blit per plane, with shifts and masks | Chunky pixels at any depth: one blit for all colour depths. Planar layers: one blit per plane, as on the Amiga (section 6.1) |
| Masked (cookie-cut) drawing | Uses a separate mask plane and the minterm logic | The same minterms and a 1 bpp mask, at any colour depth; or a colour-key compare, which needs no mask in memory |
| Logic | Any function of 3 sources (minterms) | The same: the minterm, in the Amiga's numbering, of the mask A, the image B and the destination C |
| Arithmetic | None | ADD per pixel, wrapping or saturating, signed or unsigned |
| Edge masks | First-word and last-word mask registers | Automatic, from the starting pixel and the width |
| Register writes | Copper only | Copper, and DMA jobs: block copies and fills into registers |
| Peripherals | Separate disk DMA | The same engine, through peripheral ports |
| Priority | BLTPRI ("blitter nasty") for all blits | HIGH bit per job |
| Line drawing, area fill | Yes | Not in version 1 (open point D3) |

## 3. Descriptors

A job is described by eight long words: a channel's job registers (section 8), or a 32-byte descriptor in memory, long-word aligned, which the channel loads into them. Each job can point to the next descriptor, so a chain of jobs runs without the CPU.

The jobs are shared with retro-z80's DMA engine (its spec 14): the same operations, minterm numbering and mask modes, so a blit means the same on both machines. retro68k keeps its own long-word layout, its HIGH mode, and its custom block, boot ROM and port targets.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00` | CTRL | see below | Operation, options and MINTERM |
| `+0x04` | BPT | ADDR 23–0, BIT 26–24 | The image B: address (section 4) of the first pixel, or port number. BIT (BBIT): the first pixel's position within its byte, in pixels from the most significant end, at 1, 2 and 4 bpp (0–7, 0–3, 0–1); 0 at 8 bpp |
| `+0x08` | DPT | ADDR 23–0, BIT 26–24 | The destination D, which is also where C is read: address of the first pixel, or port number. BIT (DBIT) as BPT's |
| `+0x0C` | SIZE | WIDTH 15–0, HEIGHT 31–16 | Pixels per row (bytes when BPP = 8), and rows (1 for a linear job) |
| `+0x10` | APT | ADDR 23–0, BIT 26–24 | The mask A, a 1 bpp image (MASK = 1): address of the first byte. BIT (ABIT): the first pixel's bit, from the most significant end (0–7) |
| `+0x14` | STRIDE | ABSTRIDE 31–16, CDSTRIDE 15–0, both signed | Bytes from the start of one row to the start of the next: of A and B (shared), and of C and D |
| `+0x18` | VALUE | 31–0 | B's constant when BKIND = VALUE (a fill), and the key colour for a compare mask (MASK = 2) |
| `+0x1C` | NEXT | 23–0 | Address of the next descriptor; 0 = end of chain |

A WIDTH or HEIGHT of 0 makes the job do nothing; the chain carries on with NEXT. Bits not listed are reserved: write 0.

**CTRL bits:**

| Bits | Name | Meaning |
|------|------|---------|
| 2–0 | OP | 0 BLIT, 1 ADD, 2–4 reserved, 5 MIX (on hold), 6 span fill and 7 triangle (reserved for 3D, open point D5). All but 0 and 1 are an error in version 1 |
| 4 | SAT | ADD: saturate instead of wrapping |
| 5 | SIGNED | ADD: pixels are two's complement |
| 9–8 | BPP | 0 = 1, 1 = 2, 2 = 4, 3 = 8 bits per pixel |
| 10 | DESC | Run backwards: from the last pixel of the last row to the first pixel of the first row, for overlapping copies where the destination is after the source. The addresses still give the first pixel |
| 11 | HIGH | May take the CPU's memory cycles (section 5) |
| 12 | IRQ | Raise the channel's interrupt when this descriptor finishes |
| 14–13 | BKIND | Where B comes from: 0 = memory, 1 = port, 2 = reserved (an error), 3 = VALUE (a constant: a fill) |
| 16–15 | DKIND | Where D goes: 0 = memory, 1 = port; 2 and 3 reserved (an error) |
| 18–17 | MASK | Where A comes from: 0 none (every pixel 1), 1 the 1 bpp image at APT, 2 a compare of B with the key colour, 3 reserved (an error) |
| 31–24 | MINTERM | BLIT's logic function of A, B and C (section 3.1) |

### 3.1 BLIT

For each pixel of the job, BLIT works out D from three inputs, bit by bit, as the Amiga's blitter does:

- **A, the mask.** One bit per pixel, widened to all of the pixel's bits. From the 1 bpp image at APT (MASK = 1), bits from the most significant end of each byte; or 1 where B's pixel differs from the key colour, VALUE's low BPP bits, and 0 where it matches (MASK = 2); or 1 everywhere (MASK = 0).
- **B, the image.** Read from BPT, or VALUE when BKIND = VALUE (as for a fill, below).
- **C, the background:** the destination's old contents, read from DPT.

Each bit of D is MINTERM's bit number A × 4 + B × 2 + C, as the Amiga's minterm (LF7–LF0). So A = `0xF0`, B = `0xCC` and C = `0xAA`, and any expression of them gives its minterm (for example A ? B : C is (`0xF0` AND `0xCC`) OR (NOT `0xF0` AND `0xAA`) = `0xCA`):

| MINTERM | D = | Use |
|---------|-----|-----|
| `0xCC` | B | Copy; with BKIND = VALUE, fill |
| `0xCA` | A ? B : C | Cookie-cut: draw B where the mask is 1, leave the background where it is 0 |
| `0xEE` | B OR C | Set bits |
| `0x88` | B AND C | Keep only the bits B has |
| `0x66` | B XOR C | Draw and undraw with the same job |
| `0x22` | C AND NOT B | Clear where B is set |
| `0x55` | NOT C | Invert an area |
| `0x00`, `0xFF` | 0, all ones | Clear or set an area |
| `0x0A` | A ? 0 : C | Clear through the mask (a shape's hole) |

**Reads are only made when needed:**

- A is read only with MASK = 1. A compare mask costs no memory cycles.
- B is read unless BKIND = VALUE.
- C is read when D depends on it: when MINTERM's high four bits (A = 1) depend on C, or, with a mask, its low four bits (A = 0) do, except when they are `0xA` at 8 bpp (next point). C is also read for bytes the job covers only in part, at 1, 2 and 4 bpp.
- **Where A is 0 and MINTERM leaves C alone** (its low four bits are `0xA`, as in cookie-cut), D keeps its old pixel. At 8 bpp the byte is simply not written, so C is not needed for it. So at 8 bpp a cookie-cut with a compare mask costs the same as a copy. At 1, 2 and 4 bpp other pixels share the byte, so C is read.

**The old operations as BLITs** (version 1 before the change; the same table is in retro-z80's spec):

| Old job | CTRL | MINTERM |
|---------|------|---------|
| COPY | BPP | `0xCC` |
| FILL | BPP, BKIND = VALUE | `0xCC` |
| KEYCOPY (key in VALUE) | BPP, MASK = 2 | `0xCA` |
| LOGIC with FN (bit src × 2 + dst) | BPP | FN's 4 bits twice: `FN × 0x11` |
| LOGIC with VALUE as the source | BPP, BKIND = VALUE | `FN × 0x11` |

**A constant B** (BKIND = VALUE, for BLIT and ADD alike): at 8 bpp it repeats all four bytes of VALUE, by address: the byte at address a gets VALUE's byte a mod 4, most significant first. So a fill that starts on a long word writes VALUE exactly (into memory or registers), and a fill of single bytes repeats VALUE's low byte if all four bytes are the same. At 1, 2 and 4 bpp every pixel gets VALUE's low BPP bits. (retro-z80's VALUE is least significant first, as its memory is little-endian.)

### 3.2 ADD

- D = C + B, each pixel added separately, at the job's colour depth (1, 2, 4 or 8 bits). Carries never spill into the next pixel. MINTERM is ignored.
- **Wrap** (SAT = 0): the result wraps round, e.g. 250 + 10 = 4 at 8 bpp.
- **Saturate** (SAT = 1): the result sticks at the limit instead. Unsigned (SIGNED = 0): 0 to the top value, e.g. 250 + 10 = 255. Signed (SIGNED = 1): pixels are two's complement, e.g. −128 to +127 at 8 bpp.
- B can be memory or VALUE. The mask works as for BLIT: where A is 0, D keeps C.
- Uses:
  - Shading and lighting with palettes laid out as ramps: add a constant to darken or brighten an area, or add a light map image.
  - Moving an area to another palette block by adding 16, 32 and so on.
  - Additive effects such as glows and explosions.
  - Mixing 8-bit signed audio samples with signed saturation (linear job, BPP = 8).
- To subtract, add the two's complement, e.g. add 0xFF to subtract 1 at 8 bpp with wrap.

### 3.3 Shapes of jobs

**Linear jobs** (memcpy, memset, port transfers): BPP = 8, HEIGHT = 1, WIDTH = length in bytes, up to 65,535. A longer memory copy is a 2D job with equal widths and strides (for example WIDTH = STRIDE = 16 KB, HEIGHT = the number of 16 KB blocks), or a chain; a longer port transfer is a chain.

**2D jobs** (blits): WIDTH × HEIGHT pixels, with each row starting a stride after the last. B and D have their own strides, so an image can be copied out of a sprite sheet into a screen. A stride of 0 repeats the same row; a negative stride runs up the screen (an image drawn upside down).

**The mask shares B's stride** (ABSTRIDE). A 1 bpp mask has 8 pixels a byte, so at 2, 4 and 8 bpp its rows are shorter than B's, and each is padded to B's stride. For a sheet of 8 bpp sprites, keep the masks in a sheet of their own with the same row length, or use a compare mask, which needs no memory at all.

**Clipping is done by software, with no extra hardware.** To draw only part of an image (for example an object partly off the screen), trim the job before starting it, keeping the strides the same:

- **Left edge:** skip k pixels: move BPT and DPT on by k pixels (bytes, plus BBIT and DBIT at 1, 2 and 4 bpp), APT by k bits (bytes plus ABIT), and subtract k from WIDTH.
- **Right edge:** subtract the pixels past the edge from WIDTH.
- **Top edge:** skip r rows: add r × ABSTRIDE to APT and BPT and r × CDSTRIDE to DPT, and subtract r from HEIGHT.
- **Bottom edge:** subtract the rows past the edge from HEIGHT.
- If WIDTH or HEIGHT reaches 0, the object is fully off the screen: the job does nothing.

Because the stride is separate from the width, the trimmed rows still line up with the image and the screen.

**Which kinds go together:** B from memory or VALUE, D to memory, with any OP, MINTERM and MASK. (A compare mask with a constant B is allowed; it compares VALUE's bytes with the key, as for an image.) A **port job** is a plain copy (BLIT, MINTERM `0xCC`, MASK = 0) between a port and memory, a byte at a time: linear, BPP = 8, HEIGHT = 1, no DESC, BKIND or DKIND a port but not both, and its memory side not registers. Any other combination stops the channel with an error.

### 3.4 MIX: one audio voice

> **On hold.** Stepping through a sample and taking the nearest value sounds poor when mixing at a fixed rate (a metallic buzz when pitched down, off-key aliasing when pitched up). MIX needs proper resampling, for example 8-tap windowed-sinc interpolation with pre-filtered octave copies, before it is worth building; and the audio unit (spec 6) now plays four channels with interpolation by itself. OP 5 stops the channel with an error in version 1. The previous design is kept in the history of this file.

## 4. Where data can come from and go to

**DMA addresses are CPU addresses** (24-bit). A job sees memory as the CPU does:

| Address | Area | Read | Write | Uses Chip RAM cycles? |
|---------|------|------|-------|-----------------------|
| `0x000000`–`0x3FFFFF` | **Chip RAM** (4 MB; 2 MB boards: `0x000000`–`0x1FFFFF`) | Yes | Yes | Yes |
| `0xE00000`–`0xE0FFFF` | Custom registers (video, sprites, audio, DMA engine, copper), the palettes at `0xE04000` and the descriptor RAM at `0xE06000` | Yes | Yes | No |
| `0xF80000`–`0xF87FFF` | Boot ROM | Yes | No | No |

Anything else, including Chip RAM past the end on a 2 MB board and the system area at `0xF00000` (interrupt controller, timers, serial, SD card), stops the channel with an error. The system area is left out so a runaway job cannot disturb interrupts or the serial console; its devices are reached through ports instead.

**The custom block** (registers, palettes, descriptor RAM) is reached a 16-bit word at a time, as memory: any operation can use it, at any alignment. Each word written is a write of that register half (with byte selects for single bytes), exactly as a CPU or copper write of the same half (spec 3, section 2), including its timing rules (for example, layer settings for line n must be written before line n starts, spec 4, section 5.4):

- A copy (MINTERM `0xCC`) from memory into a block of registers sets up a whole layer, or several, in one job; a copy into another channel's CHCTRL starts that channel, just as a CPU write does, so one chain can start others. A copy can also read registers into memory, for example to save a screen setup or keep a log of beam positions (a 32-bit register is read as two halves, which can come from different moments if it is changing).
- Palette entries keep their halves rule: the engine's high-half write is held until its low-half write to the same entry. So a job writing palette entries must run forwards (DESC clear), and cover whole entries.
- Reading a register never changes anything, by design, so a DMA read is always safe. Sticky flags are cleared only by writing 1.
- Each word takes one 100 MHz clock on the FPGA's internal register bus. The CPU goes first, then the copper, then the engine: a job waits a clock when either is using the bus. The boot ROM is read through a port of its own.

**Ports:**

| Port | Device |
|------|--------|
| 0 | The SD card (spec 15): a source reads the run of bytes SDCOUNT asked for, a destination sends bytes to the card; paced by the SPI clock |
| 1 | USB serial FIFOs (spec 14), paced by the link: a source reads the receive FIFO, a destination writes the transmit FIFO |
| 2–7 | Reserved |

When a port isn't ready, that channel waits and the other channels keep running. Port addresses don't move on.

## 5. Memory cycles and priority

The engine is requester 5 (BLT) of the memory scheduler (spec 5, section 6): in the spare-cycle order after the display, audio, the copper and the CPU, ahead of the DMA port.

- **One memory cycle** (20 ns) reads or writes 2 bytes at any even address, with byte selects for single bytes (spec 5, section 4.2). A copy costs 2 cycles per 2 bytes (one read, one write); a fill costs 1; a job that reads the destination costs 3.
- **Normal jobs** use cycles nobody else wants: cycle 4, cycle 2 when audio isn't using it, display cycles (1 and 3) no layer or sprite needs (all of them in the vertical blank), and cycle 0 whenever the CPU isn't using it. **The CPU is never slowed** (with the default slot plan, spec 5, section 8.1).
- **HIGH jobs** (CTRL.HIGH) own the CPU's cycle 0 while they ask, and go first for every cycle its owners leave, ahead of the CPU, the copper at PRI 0, audio and the display's fetches that are not urgent. The display keeps its own cycles 1 and 3 and its urgent fetches, and audio its cycle 2. **The CPU gets only the cycles a HIGH job leaves, so a long HIGH job can hold the CPU off, interrupts included, for as long as it runs**; with one channel running, the engine leaves about 1 cycle in 10 (between its groups of 8 words), which the CPU then takes. There is no CPU share: use HIGH when the CPU would only be waiting for the job anyway, and keep HIGH jobs short when interrupts must be served quickly.
- **The slot plan** (MEMSLOT0–4, spec 5, section 8.1) can also make the engine the owner of cycles, for every job: `0x20` in MEMSLOT0 gives it cycle 0 in place of the CPU.
- **Between channels:** channels with work to do take turns, a group of up to 8 destination words (or 8 bytes of a port job) each, so a long blit can't hold up a peripheral transfer for more than a fraction of a microsecond. A channel waiting for its port gives up its turn.
- **Descriptors** in Chip RAM take 16 read cycles (32 bytes) to load. Descriptors in the descriptor RAM take none, which suits short, frequent jobs.

## 6. How a blit works

The engine works through each row in groups of up to 8 words (16 bytes). Each group goes through the same five steps:

1. **Read:** up to 16 bytes of B into the engine's buffer, one word per memory cycle; the matching words of the mask image A (MASK = 1); and the matching words of C when they are needed (section 3.1).
2. **Shift:** B is shifted into line with D when they start at different pixels within a word (by bytes and pixels); A is lined up with D's pixels and each of its bits widened to the pixel depth. Bits carry from one word into the next, as in the Amiga's barrel shifter.
3. **Mask:** A from the mask image, from comparing each pixel of B with the key colour, or all ones.
4. **Combine:** the minterm, bit by bit (BLIT), or the per-pixel add (ADD), with the mask.
5. **Write:** one word per memory cycle, using the SRAM's byte selects to leave an untouched byte alone.

**Edge masks are automatic.** The engine works out which pixels of the first and last bytes of each row belong to the job from DBIT and WIDTH. There are no mask registers to set, unlike the Amiga's first-word and last-word masks.

**Read-modify-write:** the SRAM can only skip whole bytes when writing. When a write would change only some pixels in a byte, the engine reads the destination, merges, and writes it back. This happens:

- at the row edges of 1, 2 and 4 bpp jobs that don't start or end on a byte,
- with a mask at 1, 2 and 4 bpp, when MINTERM keeps C where A is 0 (two or more pixels share a byte),
- for minterms that use C (section 3.1), and for ADD.

At 8 bpp, a copy, a fill and a cookie-cut never need it: a pixel the mask leaves alone is a byte not written. **8 bpp chunky is the fastest format for game graphics.**

### 6.1 Planar layers

A planar layer (spec 4, section 4.2) is several 1 bpp pictures, one per plane. The engine draws into it at BPP = 0, a plane at a time, positioned to the pixel:

- **Separate planes:** one job per plane, chained, with BPT and DPT moved on by a plane each time.
- **Interleaved planes** (each row of each plane next to the row of the next plane): one job does all the planes, if the source is interleaved the same way: HEIGHT = rows × planes, and each stride = one plane row's bytes.
- **Transparent drawing (cookie cut)**, as on the Amiga: keep a 1 bpp mask of the object (1 where it has a pixel). For each plane, one BLIT with MINTERM `0xCA`, MASK = 1, APT the mask and BPT the object's plane: the object's bits where the mask is 1, the background's elsewhere. The same mask serves every plane. A compare mask is for chunky layers: in a planar layer, a colour is spread over the planes.

## 7. Speed

A 576p line is 32 µs: 320 slots, 1,600 memory cycles. The engine gets what the other users leave:

| Cycles per line | Free for the engine |
|-----------------|---------------------|
| Cycle 4 | 320, less the copper's |
| Cycle 2 | 320, less audio's (a few: 4 channels of 8-bit samples need about 2 words per line) |
| Cycle 0 | The CPU's leftovers: at least 160 when the 68000 runs flat out from Chip RAM (a bus cycle is two slots), 320 when it runs from ROM or waits. The CPU also takes spare cycles ahead of the engine when it misses its cycle 0, so in practice it takes about one cycle in 10 wherever it falls |
| Cycles 1 and 3 | 640 less the layers' fetches (spec 4, section 5.2), less sprites' |

Some screens, before the copper and sprites take their (usually small) share:

| Situation (normal job) | Free cycles per line | Copy | Fill |
|------------------------|----------------------|------|------|
| CPU busy, one full-screen 8 bpp chunky layer (about 370 words a line) | about 1,070 | 33 MB/s | 67 MB/s |
| CPU busy, layers using the whole display budget (640 words a line) | about 800 | 25 MB/s | 50 MB/s |
| CPU idle, one full-screen 8 bpp chunky layer | about 1,230 | 38 MB/s | 77 MB/s |
| Vertical blank (49 lines a frame), CPU busy | about 1,440 | 45 MB/s | 90 MB/s |

A HIGH job gets the cycles a busy CPU would use (up to 160 a line, about 5 MB/s more copy speed), and goes ahead of the display's fetches that are not urgent in the cycles their owners leave. It gains less than that: with one channel running, the engine leaves about 1 cycle in 10 between its groups, and the CPU takes those instead (in simulation, an 8 KB FILL, 4,096 writes, with the CPU reading Chip RAM took 4,617 memory cycles as a HIGH job, 485 of them idle, and 4,649 as a normal one, 517 idle). Its main effect is on the CPU, which waits for those gaps.

Jobs that read the destination (a minterm that uses C, ADD) need 3 cycles per 2 bytes instead of 2, so they run at about two thirds of the copy speed. Jobs at 1, 2 or 4 bpp that are not byte-aligned add a read at each row edge.

For comparison, a 68000 at 20 MHz copies about 4 MB/s (`MOVE.L (A0)+,(A1)+` or `MOVEM.L`). Clearing a full-screen 720 × 576 8 bpp picture (405 KB) takes about 6–8 ms with the engine, well within one 50 Hz frame (20 ms), with the CPU busy.

These figures are worked out from the slot rules; open point D2 is to measure them in simulation. They are probably optimistic. retro-z80 measured its port of this engine on its KS2 board: fills and copies took 25–35% longer than its own estimates, turning layer DMA off sped jobs up by only 8–13%, and a job reading C cost only 5% more than a copy. So the engine does not use every free cycle it is offered, and its own pipeline, not the memory, sets the speed.

## 8. Channels and registers

Offsets in the custom register block at `0xE00000` (spec 3, section 3.5).

**Per channel** (channel n at `0x300 + n × 0x40`). The first eight are the **job registers**, laid out exactly as a descriptor (section 3): a job can be set up by writing them directly, or loaded into them from a descriptor in memory.

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `+0x00`–`+0x1C` | CTRL, BPT, DPT, SIZE, APT, STRIDE, VALUE, NEXT | As in section 3 | The job to run, or running. Writes are ignored while the channel is BUSY |
| `+0x20` | CHDESC | 23–0 | The descriptor START loads (long-word aligned). Read: the descriptor now running, or the last one loaded. Writes are ignored while the channel is BUSY |
| `+0x24` | CHCTRL | START (0), RUN (1), STOP (2), PAUSE (3) | START (strobe): load the descriptor at CHDESC into the job registers and run it. RUN (strobe): run the job already in the job registers. Either way, at the end of the job the channel loads the descriptor at NEXT and runs it, until NEXT is 0. Both are ignored while BUSY. STOP (strobe) ends the chain after the current group of cycles. PAUSE holds it while set. (Bits 5–4 were CPUSHARE; they are gone, and read as 0) |
| `+0x28` | CHSTAT | BUSY (0), DONE (1), ERR (2), PAUSED (3) | BUSY: a chain is running (or paused). DONE: a chain reached its end (NEXT = 0) or was stopped. ERR: a job stopped with an error (DONE stays clear). DONE and ERR are sticky, write 1 to clear |
| `+0x2C` | CHERR | 23–0 | The address that caused the error, or the descriptor's address (CHDESC) for a bad descriptor. A job started with RUN has no descriptor, so a bad CTRL then gives whatever CHDESC holds (0 after reset) |

The job registers keep the values of the last job loaded or written: the engine's progress through a job is kept inside it, not in them. So after a job, writing only the fields that change (for example BPT and DPT) and RUN starts a similar one, which suits the copper: a few MOVEs set up and start a blit with nothing in memory.

**Global** (in the space after channel 3's registers):

| Offset | Name | Bits | Meaning |
|--------|------|------|---------|
| `0x3F0` | DMXINT | CH 3–0 | A channel's interrupt is pending (a job with IRQ finished, or an error); write 1 to clear. A bit that comes due in the same clock as the write stays set, so no interrupt is lost (as retro-z80) |
| `0x3F4` | DMXINTEN | CH 3–0 | Interrupt enables per channel |

**Descriptor RAM:** 2 KB at `0xE06000`–`0xE067FF`, room for 64 descriptors (or small buffers). One block RAM. Its contents are undefined after reset.

**DMACON** (spec 5, section 8): bit 6, **BLTEN**, with DMAEN, lets the engine use memory cycles. While it is clear, running channels wait (CHSTAT.BUSY stays set). Register and port transfers that need no memory cycles also wait, so clearing BLTEN holds the whole engine.

**Interrupts:** each channel is its own source in the interrupt controller (spec 13), DMA0–DMA3 (sources 4–7), default level 4. A channel requests its interrupt while its DMXINT bit and DMXINTEN bit are both set.

**Errors:** a bad address (section 4), a reserved OP, MASK = 3, BKIND = 2, DKIND = 2 or 3, or kinds that don't go together (section 3.3) stops the channel: ERR is set, CHERR holds the address, CHDESC the descriptor, and the channel's DMXINT bit is set. The other channels carry on.

**Typical use:**

1. One job: write the job registers (NEXT = 0), then RUN to CHCTRL.
2. A chain: write descriptors to the descriptor RAM (`0xE06000`) or Chip RAM, the first one's address to CHDESC, then START to CHCTRL. (Or write the first job into the job registers, with NEXT pointing at the rest, and RUN.)
3. Carry on. Take the interrupt, or poll CHSTAT.BUSY.

The copper can also start channels, for example to change a screen area at a set beam position, and its WAIT with the B bit waits until every channel is idle (spec 10).

## 9. Suggested channel use

Software decides, but a sensible default:

| Channel | Use |
|---------|-----|
| 0 | SD card |
| 1 | USB serial |
| 2 | General memory copies and fills |
| 3 | Graphics (blits) |

## 10. FPGA resources

| Item | Resource |
|------|----------|
| Descriptor RAM, 2 KB | 1 block RAM |
| Per-channel state (the running descriptor's fields and positions) | Distributed RAM, one channel worked on at a time (as in the layer fetch and `sprites.v`) |
| Data buffer between reads and writes (16 bytes and the shifter's carry) | Logic |
| The shared datapath: 2D address units, pixel shifter, the mask's shift register, edge masks, colour key compare, minterm, per-pixel adder, the access unit, ports | About 2,300 LUTs in all, and 2 DSP slices (a backwards job's start: rows × stride) (Vivado). Timing met at 100 MHz |

## 11. Open points

| # | Item |
|---|------|
| D1 | Check the engine fits and meets timing at 100 MHz |
| D2 | Measure the speed figures of section 7 in simulation; retro-z80's board measurements (section 7) suggest they are 25–35% optimistic |
| D3 | Line drawing and area fill (Amiga blitter features), and scaling or rotating blits: version 2. retro-z80 plans a line job next (its spec 15, G1); the starting sketch is OP 2 LINE, with software working out the octant and Bresenham terms, the pixel going through the minterm, and a per-pixel clip rectangle. Nothing is decided. The line job and the triangle job (D5) are separate jobs with their own layouts, sharing the engine's address units, minterm and memory access (agreed with retro-z80, 30 October 2026) |
| D4 | MIX (section 3.4): on hold until it has proper resampling |
| D5 | OP 6 span fill and OP 7 triangle, for flat-shaded 3D: the codes are agreed with retro-z80 (28 October 2026, its D6), and neither project gives them another meaning without asking the other. Their layouts come with a 3D design |
| D6 | The mask shares B's stride (section 3.3), to keep the descriptor at eight long words: at 8 bpp seven eighths of a mask sheet with B's row length is unused. As retro-z80's D13 |

## 12. Tests

- **BLIT:** linear and 2D, every BPP, starting and ending part-way through a byte, every ABIT, BBIT and DBIT, positive, zero and negative strides, forwards and backwards (DESC) with overlapping areas, common and random minterms, every MASK. Compare with a Python reference model.
- **Masks:** a 1 bpp mask image against every BPP, forwards and backwards; a compare mask with key pixels at the edges; cookie-cut (`0xCA`) and clear-through-mask (`0x0A`).
- **ADD:** every BPP, wrap and saturate, signed and unsigned, memory and constant sources, with and without a mask; check carries never cross pixels.
- **Chains:** a chain of mixed jobs in Chip RAM and in the descriptor RAM; IRQ only on the marked ones; jobs of zero width or height.
- **Direct jobs:** a job written into the job registers and started with RUN, with and without a NEXT chain after it; job register writes ignored while BUSY; the job registers read back as loaded.
- **Channels:** all 4 running at once; a stalled port channel does not hold up the others; STOP and PAUSE.
- **Priority:** normal jobs never delay the CPU; a HIGH job, or a slot plan that makes the engine owner of every cycle, does (`dtest` T18, T19: 32 CPU reads of Chip RAM timed during a job).
- **Errors:** a bad address (including the system area and past the end of a 2 MB board's RAM), a reserved OP, MASK = 3 and a bad combination stop only that channel, set ERR and CHERR, and raise its interrupt.
- **Registers:** a block copy into a layer's registers gives exactly the same result as CPU writes; a copy into CHCTRL that starts another channel works; register reads into memory; a palette written by a job changes each entry whole; a CPU register access is never delayed by the engine.
- **Ports:** a USB serial transfer each way, paced by the FIFOs (with the FT232H model in `sim/`).
- **Speed:** the figures in section 7.
