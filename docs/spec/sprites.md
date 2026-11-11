# Spec 9: Sprites

Status: **v1 scope**

Sprites are small images drawn over (or between) the layers at any position, without touching the layers' memory. Version 1 has eight sprites. As on the Amiga, each has a pointer into Chip RAM for its image (SPRxPT), and its window and settings are plain registers (SPRxH, SPRxV, SPRxCTL, SPRxSTEP) that the CPU or copper writes. A write to SPRxCTL starts a sprite; the vertical blank stops them all, so each frame the copper writes each sprite's registers, CTL last. The others can be changed while a sprite is being drawn, from one line to the next, for effects such as wobbling, zooming and switching images, and the copper can reuse a sprite further down the screen by starting it again. The images are bigger and more colourful than the Amiga's, and their data is fetched just in time, through the same scheduler as the bitplanes, into a FIFO per sprite.

(An earlier design, with a 64-entry sprite table, is in git history at commit 7df97fd. It was dropped for size.)

## 1. Summary

| Item | Value |
|------|-------|
| Sprites | 8 (SPR0–SPR7). Each can be reused further down the screen by the copper rewriting its registers |
| Window | HSTART–HSTOP across, VSTART–VSTOP down, like a layer's window. The image's size follows from the window and the scale |
| Size | Any, as a layer's: set by the window. Only the memory budget limits it (section 5) |
| Colours | 2, 4 or 8 bits per pixel. 2 and 4 bpp: 3 or 15 colours + transparent, from any 16-colour block of the sprite palette; 8 bpp: 255 colours + transparent, the whole sprite palette. The sprites have a 256-colour palette of their own, separate from the layers' |
| Position | Any pixel; clipped at the left, right and bottom edges by the hardware, at the top by software (section 3) |
| Scaling | Fractional, across and down separately: a 16-bit step per axis, in source pixels per screen pixel (5.11 fixed point), from 16× bigger (`0x0080`) through normal size (`0x0800`) to 1/16× (`0x8000`) |
| Depth | Per sprite: in front of all layers, between any two (in PRIO order), or behind all |
| Collisions | Sprite–sprite and sprite–layer, per pixel, latched (as the Amiga's CLXDAT) |
| Data registers | A 32-word FIFO per sprite, streaming: lines of any length pass through it |
| Fetch | Just in time, the sprite due first first. Shared with the bitplanes, which go first unless a sprite's fetch is urgent (spec 4, section 5; spec 5, section 6). Each line's words are fetched during that line, from its start (the horizontal blank), as soon as the sprite's FIFO has room and a memory cycle is free |
| Starting | A write to SPRxCTL starts a sprite; the vertical blank stops every sprite. The other registers act on a running sprite from the next line |

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Sprites | 8 | 8 |
| Pointers | SPRxPT, rewritten by the copper each frame | The same |
| Position and settings | SPRxPOS, SPRxCTL (HSTART, VSTART, VSTOP): fetched by the DMA from control words in the sprite's data, or written by the CPU/copper | SPRxH, SPRxV (start and stop across and down: a window, as a layer has), SPRxCTL, SPRxSTEP: plain registers, written by the CPU or copper only; the data in memory is image only. Writing SPRxCTL starts the sprite, as writing SPRxCTL arms the Amiga's |
| Reuse down the screen | The data holds more control words after each sprite | The copper writes the sprite's registers again after a WAIT, CTL last |
| Settings | Position, height | A window (any size), bits per pixel, scale, depth among the layers, palette block |
| Width | 16 pixels (lores) | Any: set by the window |
| Colours | 3 + transparent; 15 with two attached sprites | 3, 15 or 255 + transparent, every sprite |
| Pixel format | Two bitplanes | Chunky: 2, 4 or 8 bits per pixel, first pixel in the high bits |
| Data registers | SPRxDATA, SPRxDATB: one line of 16 pixels | A 32-word FIFO, streaming: lines of any length pass through it |
| Fetch | Two words per sprite per line, in fixed slots in the horizontal blank | Just in time, after the layers unless urgent; early when cycles are free |
| Manual mode | Write SPRxDATA/B with DMA off | Push words into SPRxDAT with the sprite's DMA off |
| Priority | Fixed in pairs against the playfields | Per sprite, any depth among the layers |
| Scaling | None | Fractional, 16× bigger to 1/16×, across and down separately |
| Collision | CLXDAT | SPRCOLL: per sprite, against the other sprites and each layer |

## 3. Sprites: pointer, position and settings

Each sprite has four registers (section 6):

- **SPRxPT** points at the sprite's image in Chip RAM: its lines one after another, top line first, each in whole words (section 3, below). It moves on through the image line by line as the sprite is drawn, so the hardware does not reset it: the copper (or the CPU) writes it every frame, before CTL.
- **SPRxH** and **SPRxV** give the sprite's window, **SPRxCTL** its settings and **SPRxSTEP** its scale. They are plain registers: the CPU or copper writes them, and they stay as written until written again. The image in memory is pixels only.

**The window** (SPRxH, SPRxV), as a layer's (spec 4, section 4.3), in beam coordinates (spec 4, section 3.3: the picture is pixels 144–863, lines 49–624):

| Register | Bits | Field | Meaning |
|----------|------|-------|---------|
| SPRxH | 10–0 | HSTART | First beam pixel of the sprite (0–863; 864 or more: not shown). Pixels before 144 are in the horizontal blank: fetched, not shown |
| SPRxH | 26–16 | HSTOP | Beam pixel just after the sprite (no higher than 864 counts) |
| SPRxV | 10–0 | VSTART | First beam line of the sprite (0–624; 625 or more: not shown). Lines before 49 are in the vertical blank: fetched, not shown |
| SPRxV | 26–16 | VSTOP | Beam line just after the sprite (no higher than 625 counts) |

The image's size follows from the window and the scale (section 3.2): **source width** = ⌈(HSTOP − HSTART) × XSTEP ÷ 2048⌉ pixels and **source height** = ⌈(VSTOP − VSTART) × YSTEP ÷ 2048⌉ lines. At normal size (step `0x0800`) the image is the window's size. A source line is stored in whole words, ⌈source width × BPP ÷ 16⌉ of them. These sizes are worked out for each line from the settings at its start (below), so a window or scale changed while a sprite is drawn changes the size of its lines from there on. There is no size limit: lines of any length stream through the FIFO (section 4); only the memory budget (section 5) limits how big and how many sprites can be.

**Clipping:** the hardware clips at all four edges. A sprite's line is a beam line, and its frame the beam's frame, so a sprite can start left of the picture and above it: those pixels and lines are fetched and used up, but not shown. Pixels past the right edge and lines past the bottom are neither fetched nor shown. A line's words are fetched during the line, from its start, so the DMA needs a few pixels before the sprite's first pixel: **HSTART must be 16 or more** (up to 128 pixels left of the picture). A sprite cannot show on beam line 0, where the vertical blank stops every sprite.

**SPRxCTL:**

| Bits | Field | Meaning |
|------|-------|---------|
| 13–12 | BPP | 0 = 2, 1 = 4, 2 = 8 bits per pixel |
| 21–20 | DEPTH | 0 = in front of all layers; 1 = behind the front layer; 2 = behind the middle layer; 3 = behind all layers (in PRIO order) |
| 27–24 | PAL | 2 and 4 bpp: the 16-colour block of the sprite palette (colour = PAL × 16 + value). Not used at 8 bpp |

**Starting and stopping.**

- **A write to SPRxCTL starts the sprite** (any write: the CTL value may be the same as before). Its FIFO is emptied and reads still on their way are dropped. Its first line is the next beam line, after the write, that is inside its window; that line shows the image line at SPRxPT. (It is the copper's job to point SPRxPT at the image's first line, as for bitplanes, before it writes CTL.)
- **The vertical blank stops every sprite** (beam line 0, pixel 0), in manual mode too: its FIFO is emptied and nothing is fetched or shown until its CTL is written again. So each frame the copper (or the CPU, in its VBLANK interrupt) writes each sprite's registers, CTL last.
- A sprite whose CTL is written after its VSTART has gone by shows the image from its first line, from the next line, down to VSTOP.
- To hide a sprite, don't write its CTL this frame, turn its DMA off before writing its CTL (its FIFO is then empty, so it shows nothing), or set VSTART to 625 or more.

**Each line.** At the start of every beam line (pixel 0, the start of its horizontal blank) each running sprite takes the line's settings: its window, its scale, its CTL settings. If the line is inside the window (VSTART ≤ line < VSTOP), the sprite shows on it, and the DMA fetches the line's words during the line. The window is checked on every line: a VSTOP made later lets the sprite go on, one made earlier ends it; a VSTART moved later leaves the sprite off until the window reaches it again.

**Which image line.** The sprite's first line shows the image line at SPRxPT. Each further line it shows moves on by the source lines YSTEP gives (section 3.2): k lines, k × ⌈source width × BPP ÷ 16⌉ words, with the source width of that line's settings. When the sprite is bigger down (YSTEP below `0x0800`), k is often 0 and the line is fetched again; when it is smaller, lines in between are skipped: neither fetched nor shown. **A write to SPRxPT** while the sprite runs sets exactly where its next image line starts (not moved on by YSTEP that time); the lines after it move on from there. So an image can be switched from one line to the next. Reading SPRxPT gives the start of the image line being drawn (or the value just written).

**Changing a sprite while it is drawn.** Writes to SPRxH, SPRxV, SPRxSTEP and SPRxPT act on a running sprite from the next line that starts after the write; CTL's settings (BPP, DEPTH, PAL) likewise, but a CTL write also starts the sprite again. So a copper list can move a sprite across on every line (a wobble), change XSTEP and the window on every line (a zoom, perspective), or switch its image part way down. **Reusing a sprite further down the screen**, as Amiga programs do with their control words: after the sprite's last line, the copper WAITs, then writes the sprite's PT, window and STEP for its next use, and CTL last.

### 3.1 Pixels and colours

Image lines are **chunky**, as chunky layers are: 2, 4 or 8 bits per pixel, packed in words, the first pixel in the highest bits. A value of 0 is transparent. Other values are entries of the **sprite palette**, SPRPALETTE (`0xE04C00`–`0xE04FFF`, spec 4, section 6.3), which the sprites share and the layers do not use: at 8 bpp the value itself; at 2 and 4 bpp, PAL × 16 + the value. With VIDCON.SHAREPAL set, sprites use PALETTE0 instead, as the layers then do.

### 3.2 Scaling

**SPRxSTEP** holds two steps, **XSTEP** (bits 15–0) and **YSTEP** (31–16): source pixels (or lines) per screen pixel (or line), in 5.11 fixed point.

| Step | Size |
|------|------|
| `0x0080` | 16× bigger |
| `0x0200` | 4× bigger |
| `0x0400` | 2× bigger |
| `0x0800` | Normal |
| `0x0C00` | 2/3 |
| `0x1000` | Half |
| `0x8000` | 1/16 |

- **Which source pixel:** screen pixel i of the window (i = 0 at HSTART) shows source pixel ⌊i × XSTEP ÷ 2048⌋ of its line; screen line j of the sprite (j = 0 at its first line) shows source line ⌊j × YSTEP ÷ 2048⌋, while YSTEP and SPRxPT are left alone. So the first pixel and line always show the image's first, and every step works the same, with no rounding to pick. (A YSTEP changed part way down carries on from the fraction reached; a PT written part way down starts again from there.)
- **Limits:** steps below `0x0080` count as `0x0080`, steps above `0x8000` as `0x8000`. A step of 0 counts as `0x0800`, so a sprite whose SPRxSTEP was never written is normal size.
- **Cost** (section 5): bigger across, a word lasts more screen pixels; smaller across, fewer, since every source pixel of a line is fetched, the skipped ones too (they stream through the FIFO). Bigger down, a line is fetched again for each screen line it shows on (the FIFO cannot replay a line); smaller down, the lines skipped are not fetched at all.

There is no flip: for an object that faces either way, store both images.

### 3.3 Depth and priority

Each sprite's DEPTH puts it in front of all three layers, between any two in their PRIO order, or behind all of them (in front of the background colour). Where two sprites overlap, the lower-numbered channel is in front. A layer's transparent pixels (TRANSP, value 0) show the sprites and layers behind them.

In direct-colour mode (VIDCON.DIRECT, spec 4, section 4.9) sprites are drawn in front of the picture in their colours from the sprite palette, and DEPTH is not used.

## 4. Data registers: the FIFO

Each sprite has a **FIFO of 32 words**, its data registers. The DMA pushes the image's words in at the back; the sprite takes them from the front as it is drawn, a line's worth per screen line (⌈source width × BPP ÷ 16⌉ words). The FIFO streams: a line can be longer than the FIFO, as long as the DMA keeps it from running dry.

- **Fetching within the line.** A line's words are fetched during that line, from its start: never ahead into the next line, since the next line's settings are not known until it starts. The DMA pushes the line's words whenever the FIFO has room, up to 30 words ahead of the beam (it keeps two of the 32 places for words still on their way). Fetching becomes urgent only when the FIFO is about to run out: then the sprite goes ahead of everything but an urgent layer fetch, and may take the CPU's cycle (spec 5, section 6). Otherwise the layers go first: the sprites get the display's cycles the layers leave, and spare cycles after them.
- **The lead** is the time from the line's start to the sprite's first pixel: at least 16 pixels (HSTART 16), and the whole horizontal blank, 144 pixels (5.3 µs), for a sprite at the picture's left edge.
- **Manual mode.** With a sprite's DMA off (SPRDMA), the CPU or copper pushes the image's words into its FIFO by writing SPRxDAT. The sprite shows as its window and CTL say, taking a line's words from the FIFO on each line it shows. If the FIFO is empty when a word is needed, the sprite waits for it: it is transparent until a word is written, and the rest of the line follows from there. SPRUNDER is not set in manual mode. Push the frame's words after the CTL write: the FIFO takes a moment to empty (about 20 clocks), and words pushed meanwhile are dropped. A sprite in manual mode should not be shrunk across (XSTEP above `0x0800`): words would be skipped before they are written.
- **Underrun.** If the DMA cannot keep a sprite's FIFO filled (section 5), VIDSTAT.SPRUNDER (bit 7) is set, and the sprite shows nothing more until its CTL is written again: its words would no longer line up with its lines. SPRUNDER can raise the VIDERR interrupt like OVERRUN.

## 5. Memory budget

Sprites and layers share one budget. The layers go first, and only an urgent sprite fetch goes ahead of a layer's (spec 5, section 6.3), so sprites live on what the layers leave, plus their FIFOs' lead. The display's own memory cycles (1 and 3 of each slot, spec 5) give about **12 words per 16 screen pixels** for certain; cycles the CPU, audio and copper leave free give more.

- A **layer** needs, per 16 source pixels, 1 word per plane (planar) or b words at b bpp (chunky); at 2× scale across, half that per 16 screen pixels.
- A **sprite** needs BPP words per 16 source pixels while the beam is over it (2, 4 or 8): BPP × XSTEP ÷ 2048 words per 16 screen pixels. Twice as big across (`0x0400`), half that; half size across (`0x1000`), twice.
- Sprites side by side do not add up; sprites over the same pixels at the same time do. Within a line, each FIFO (30 words ahead) lets a sprite fetch ahead into quieter stretches before its pixels, so short overlaps (up to about 60 pixels at 8 bpp, 240 at 2 bpp) are smoothed out; longer overlaps of wide sprites are limited by the budget at that moment, as the table shows. A sprite near the left of a line has less time to fetch ahead (as little as 16 pixels at HSTART 16).

Sprites stacked over the same 16 screen pixels, guaranteed (more when cycles are free):

| Layers | Words per 16 pixels | 8 bpp | 8 bpp, ×2 across | 4 bpp | 2 bpp |
|--------|--------------------|-------|------------------|-------|-------|
| None | 0 | 1 | 3 | 3 | 6 |
| One 8 bpp layer at 2× | 4 | 1 | 2 | 2 | 4 |
| Two 5-plane layers at 2× (Amiga style) | 5 | 0 | 1 | 1 | 3 |
| Two 4-plane layers at 1× | 8 | 0 | 1 | 1 | 2 |
| Three 4-plane layers at 1× | 12 | 0 | 0 | 0 | 0 |

Fetching ahead within the line lets sprites go beyond these figures for short overlaps, and where the line has quieter parts before the sprites. The figures are worked out, not measured; to be measured in simulation (open point S1).

## 6. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x500` | SPRDMA | Set/clear | SPR (7–0), SETCLR (15) | DMA on for sprite n (bit n). Set/clear, as DMACON. Default all on. A sprite fetches only while SPRDMA bit n, DMACON.SPREN and DMACON.DMAEN are all set |
| `0x504` | SPRCOLL | RW1C | SPR (7–0), L0 (15–8), L1 (23–16), L2 (31–24) | Collisions, sticky until cleared by writing 1. SPR bit n: an opaque pixel of sprite n was on the same screen pixel as another sprite's opaque pixel. Ln bit n: sprite n was on an opaque pixel of layer n (a pixel the layer draws: not transparent). Only pixels on the screen count, not those clipped |

Sprite n (0–7) at `0x520 + n × 0x20`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | SPRxPT | RW | 22–1 | Where the sprite's next image line starts. Read: the start of the line being drawn (it moves on line by line), or the value written. Written each frame before CTL |
| `+0x04` | SPRxH | RW | HSTART (10–0), HSTOP (26–16), unsigned | The window across (section 3). Written by the CPU or copper |
| `+0x08` | SPRxV | RW | VSTART (10–0), VSTOP (26–16) | The window down |
| `+0x0C` | SPRxCTL | RW | as section 3 | Settings. Any write starts the sprite (section 3) |
| `+0x14` | SPRxSTEP | RW | XSTEP (15–0), YSTEP (31–16) | Scale (section 3.2). 0 counts as `0x0800` (normal) |
| `+0x10` | SPRxDAT | W, R | write: 15–0; read: COUNT (5–0) | Write: push a word into the FIFO (manual mode). Read: words in the FIFO (0–32) |

VIDSTAT bit 7, **SPRUNDER** (spec 4, section 6.1): a sprite's FIFO ran dry while it was being drawn. Sticky, with an enable in VIDINTEN; raises VIDERR like OVERRUN.

DMACON bit 5, **SPREN**: sprite DMA on (spec 5, section 8).

**When writes take effect:** a write to SPRxCTL starts the sprite (section 3). Writes to SPRxPT, SPRxH, SPRxV and SPRxSTEP act on a running sprite from the next line that starts after the write; a stopped sprite takes them when it is started. SPRDMA acts at once and does not start or stop a sprite: off pauses its fetching (the sprite keeps what is in its FIFO), on lets it carry on.

## 7. Examples

A 32 × 24 sprite at 4 bpp, in colours 32–47, behind the front layer, on sprite 0 at picture line 100, pixel 200 (beam coordinates add VID_X0 = 144 and VID_Y0 = 49). The image is 24 lines of 8 words in Chip RAM at `ship`. Once, from the CPU:

```
    move.l  #((VID_X0+200+32)<<16)|(VID_X0+200),SPR0+SPR_H(a4)  ; picture pixels 200-231
    move.l  #((VID_Y0+100+24)<<16)|(VID_Y0+100),SPR0+SPR_V(a4)  ; picture lines 100-123
    move.l  #(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_DEPTH_B)|(2<<SPR_CTL_PAL_B),SPR0+SPR_CTL(a4)
```

In the copper list, every frame (in the vertical blank): the pointer, then CTL, which starts the sprite:

```
    CMOVEL  SPR0+SPR_PT,ship
    CMOVEL  SPR0+SPR_CTL,(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_DEPTH_B)|(2<<SPR_CTL_PAL_B)
```

To move the ship, write SPR0H and SPR0V (from the CPU, or with copper MOVEs) before the CTL write; or, while it is drawn, at any time: each write acts from the next line.

A wobble: the copper moves sprite 0 two pixels further right on each of its lines (a list can step through a table of positions with CMOVR, spec 10):

```
    CWAIT   VID_Y0+100,0
    CMOVEL  SPR0+SPR_H,((VID_X0+202+32)<<16)|(VID_X0+202)  ; for line 101
    CWAIT   VID_Y0+101,0
    CMOVEL  SPR0+SPR_H,((VID_X0+204+32)<<16)|(VID_X0+204)  ; for line 102
    ...
```

The same ship at 1.5× its size: a 48 × 36 window, and steps of 2048 ÷ 1.5 = `0x0555` across and down (the image is still 32 × 24: ⌈48 × 0x555 ÷ 2048⌉ = 32):

```
    move.l  #((VID_X0+200+48)<<16)|(VID_X0+200),SPR0+SPR_H(a4)
    move.l  #((VID_Y0+100+36)<<16)|(VID_Y0+100),SPR0+SPR_V(a4)
    move.l  #($0555<<16)|$0555,SPR0+SPR_STEP(a4)
```

Reusing sprite 0 for a second ship lower down, from line 300: after the first ship's last line (123), the copper writes sprite 0 again, CTL last:

```
    CWAIT   VID_Y0+200,0
    CMOVEL  SPR0+SPR_H,((VID_X0+400+32)<<16)|(VID_X0+400)
    CMOVEL  SPR0+SPR_V,((VID_Y0+300+24)<<16)|(VID_Y0+300)
    CMOVEL  SPR0+SPR_PT,ship2
    CMOVEL  SPR0+SPR_CTL,(1<<SPR_CTL_BPP_B)|(1<<SPR_CTL_DEPTH_B)|(2<<SPR_CTL_PAL_B)
```

## 8. FPGA resources

Measured with Vivado (XC7A35T, with fractional scaling):

| Item | LUTs |
|------|------|
| sprites.v: registers, sizes, fetcher, line advance, deadlines, 8 FIFOs of 32 × 16 bits (distributed RAM) | About 1,800, and 3 DSP slices (the size calculator's two multiplies, the line advance) |
| 8 pixel units (sprite_pix.v) | About 100 each, 780 in all |
| Mixing with the layers (depth), collisions (video.v) | A few hundred |
| Total | About 3,000; no block RAM |

To keep it small, the per-sprite state lives in distributed RAM, worked on one sprite a clock: the registers as written, the place in the image (pointer, line start, words and lines left), and the sizes worked out from the window (one shared calculator visits a sprite each clock). Only what the pixel side needs all at once at a line's start is in flip-flops.

## 9. Open points

| # | Item |
|---|------|
| S1 | Measure how many stacked sprites each layer set-up allows (section 5), in simulation |
| S2 | Whether the sprites' share of the free cycles should be limited, so that a screen full of sprites cannot starve the CPU |

## 10. Tests

- **Golden images:** sprites of many window sizes, at every depth and many scales (bigger, smaller, odd steps, different across and down, the limits), clipped at all four edges, changed while they are drawn (a copper list moving one across on every line, changing another's XSTEP and window, switching an image part way down, moving a VSTOP), reused down the screen, at every DEPTH against layers in different PRIO orders, over transparent layer pixels, compared pixel by pixel with the Python video model extended with sprites.
- **Collisions:** known overlaps set exactly the expected SPRCOLL bits.
- **Manual mode:** a sprite reused part way down the frame with its DMA off, fed by the copper through SPRxDAT with a pattern that changes on every line, checked against the model; an empty FIFO makes it wait, without SPRUNDER.
- **Stress:** sprites stacked over the same pixels with layers of each depth, to measure section 5's table.

## 11. Later versions

- A sprite table, so that the copper need not rewrite sprites to reuse them
- Sprites in direct-colour mode at any depth
