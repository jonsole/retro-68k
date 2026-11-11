# Spec 4: Video

Status: **v1 scope**

## 1. Goals

- DVI output over the HDMI connector and, at the same time, 24-bit VGA through the KS3's ADV7125 video DAC.
- **One video mode: 576p**, 720×576 at 50 Hz, exactly as CEA-861 defines it (27 MHz), so every HDMI TV and monitor takes it. It is the digital form of PAL: a normal Amiga-style screen (for example 640×512, PAL 320×256 doubled) sits in a centred window, and overscan uses the whole 720×576. There are no timing registers.
- **Three bitmap layers**, each with its own display window, scroll, scale and 256-colour palette. Each layer is **planar** (1 to 8 Amiga-style bitplanes) or **chunky** (1, 2, 4 or 8 bits per pixel).
- **Amiga-style bitplane DMA:** each plane has a pointer (BPLxPT) that moves through memory as the picture is shown, a stride (BPLSTRIDE) from each line's start to the next, and a data register (BPLxDAT). The copper (or the CPU) resets the pointers every frame.
- **No hidden buffers.** Each plane has just its data register and its shift register, as on the Amiga. The DMA loads the data registers just in time; the copper or CPU can load them too.
- **Fetch is automatic:** the hardware works out when and what to fetch from each layer's window, so there are no fetch start and stop registers (the Amiga's DDFSTRT/DDFSTOP).
- **Direct colour:** the three layers can be joined into one direct-colour picture, one layer per channel (red, green, blue), up to 24 bits per pixel.
- **The video clock is separate from the system clock.** The pixel clock has its own MMCM, and everything between the two sides goes through synchronisers and handshakes, so other video modes need only a different pixel clock. The display uses only its own memory cycles (spec 5), so it never slows the CPU.

## 2. Comparison with the Amiga (OCS/ECS)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Playfields | 1, or 2 in dual-playfield mode | 3 layers, in any order |
| Pixel layout | Planar, 1–6 planes | Per layer: planar with 1–8 planes, or chunky with 1, 2, 4 or 8 bits per pixel |
| Colours | 32 from 4096 (EHB, HAM) | A 256-entry palette of 24-bit colours per layer, and one for the sprites; a layer of up to 4 bits picks a 16-colour block of its palette. Direct colour up to 24 bits |
| Plane pointers | BPLxPT, moved on by the fetch and BPLxMOD; rewritten by the copper each frame | The same, per layer: BPL0PT–BPL7PT. In place of the modulo, BPLSTRIDE: bytes from one line's start to the next, whatever is fetched (no fix-ups for fine scroll) |
| Data registers | BPLxDAT, loaded by DMA; writing BPL1DAT starts the shifters | The same: BPL0DAT–BPL7DAT; writing BPL0DAT completes a group |
| Display window | One per screen (DIWSTRT/DIWSTOP) | One per layer (WINX/WINY) |
| Fetch window | DDFSTRT/DDFSTOP, set by hand | Worked out from each layer's window and scroll |
| Scrolling | Fine scroll 0–15 px via BPLCON1, coarse by pointers | The same: SCROLLX (0–15 px) and pointers |
| Pixel size | Lores/hires, line doubling by copper tricks | 1×, 2×, 4× or 8× per layer, horizontal and vertical separately |
| Video timing | Fixed (PAL or NTSC) | Fixed: 576p, the digital form of PAL |

## 3. Clocks, timing and the beam

### 3.1 Clocks

The KS3 build makes its clocks from the board's 50 MHz oscillator with two MMCMs (the Artix-7's clock generators):

| Clock | Frequency | From | Use |
|-------|-----------|------|-----|
| System / SRAM controller | 100 MHz | MMCM 1 (VCO 1000 MHz) | Memory slots of 100 ns (spec 5) |
| fx68k | 40 MHz | MMCM 1 | 20 MHz 68000 |
| Pixel clock | 27 MHz | MMCM 2 (50 ÷ 5 × 108 = VCO 1080 MHz, ÷ 40) | Video |
| HDMI serialiser | 135 MHz | MMCM 2 (÷ 8) | Double-rate serialisers (OSERDESE2): 10 bits per pixel |

Both MMCMs run from the same oscillator, so the frequencies are exact: one 576p line (864 pixels at 27 MHz) is exactly 32 µs, which is 3200 system clocks or **320 memory slots**. The phase between the pixel clock and the system clock is fixed once the MMCMs have locked, but it is not known, so the design treats them as **asynchronous clock domains**: events cross as toggles through two flip-flops, the data registers cross under the full/taken handshake (section 5.1) with each group's depth, planar mode and scale, the beam position is sampled until two samples agree, the layers' line settings are copied once per line, and CTRL.TRANSP and PALOFS are read raw by the pixel side (section 5.4).

Nothing in the design relies on the 320-slot coincidence or on the phase, so a later mode can use any pixel clock MMCM 2 can make (for example 25.175 MHz for exact 640×480, 74.25 MHz for 720p), at build time or through the MMCM's reconfiguration port. The display's bandwidth stays 40 MB/s, so the budget per pixel (section 5.2) scales with the pixel rate: 1.48 bytes per pixel at 27 MHz, about 0.54 at 74.25 MHz. Section 5.6 has the crossing timing.

In simulation the pixel clock is a free-running 27 MHz clock with an odd phase against the system clocks, so the phase sweeps through every value along each line.

**VGA:** the ADV7125 takes 8 bits per colour over 4 pins at double rate. It shows the same picture and timing as HDMI.

### 3.2 The mode: 576p

| Item | Value |
|------|-------|
| Visible | 720 × 576, 50 Hz progressive (CEA-861 formats 17 and 18: 4:3 or 16:9) |
| Pixel clock | 27.000 MHz |
| Horizontal | 720 visible, front porch 12, sync 64, back porch 68: 864 in all (32 µs, 31.25 kHz) |
| Vertical | 576 visible, front porch 5, sync 5, back porch 39: 625 lines (20 ms, 50 Hz) |
| Sync | Both active low |
| Pixels | Not square: on a 4:3 screen each pixel is 16/15 as wide as it is tall, about the Amiga PAL shape |

Positions are in beam coordinates (section 3.3): `hpixel` counts from 0 at the start of the horizontal blank (front porch, sync, back porch: 144 pixels), so the visible pixels are 144–863; `vline` counts from 0 at the start of the vertical blank (49 lines), so the visible lines are 49–624. VIDSIZE reads 720 × 576.

**Normal screens and overscan.** HDMI sends exactly the visible pixels: there is no border beyond them, and a computer monitor shows all of them. A TV may crop a few percent off each edge (open point V2). So the whole 720 × 576 is the overscan area. A normal screen is a centred window, with the background colour round it as the border:

| Screen | Source | Window |
|--------|--------|--------|
| PAL Amiga, normal | 320 × 256, 2× | 640 × 512 at (40, 32) |
| PAL Amiga, overscan | 352–360 × 283, 2× | up to the full 720 × 576 |
| 640 × 480 | 640 × 480, 1× | at (40, 48) |

### 3.3 Beam position

Every position the hardware uses (BEAMPOS, LINECMP, the copper's WAIT and SKIP, layer windows, sprite windows) is in **beam coordinates**, which count the blanking too:

| | Beam pixels (across) | Beam lines (down) |
|--|--|--|
| 0 | The start of the horizontal blank | The start of the vertical blank |
| Blank | 0–143 | 0–48 |
| The picture | 144–863 (720 pixels) | 49–624 (576 lines) |
| Total | 864 per line | 625 per frame |

So a beam line starts with its horizontal blank and then shows its 720 pixels, and a frame starts with its vertical blank (at line 0, pixel 0) and then shows its 576 lines. Positions only go up through a frame: there is no wrap from the end of the picture to the blank. Something can be placed partly off the left or top of the picture (a sprite, a layer's window start) with ordinary unsigned numbers. `hw.inc` gives the picture's corner as VID_X0 = 144 and VID_Y0 = 49, and its size as VID_W = 720 and VID_H = 576.

| Register | Contents |
|----------|----------|
| BEAMPOS (read) | `vline` (bits 26–16) and `hpixel` (bits 10–0), in beam coordinates, as one 32-bit read so they always match |
| FRAMECOUNT (read) | Frame counter, 16 bits, counts up at the start of each frame (beam 0, 0) |

### 3.4 Video interrupts

These reach the CPU through the interrupt controller (spec 13), as the sources VBLANK, LINE and VIDERR. The default level is 5.

| Flag | When |
|------|------|
| VBLANK | The start of the frame: beam line 0, pixel 0 (the start of the vertical blank) |
| LINE | The start of beam line LINECMP (pixel 0, the start of its horizontal blank: 144 pixels before the line's picture), for raster effects without the copper |
| OVERRUN | A layer's next group was not ready when its shifters needed it (section 5.3); goes to VIDERR |

Each flag has an enable bit in VIDINTEN and a sticky flag in VIDSTAT, which is cleared by writing 1.

## 4. Layers

### 4.1 Overview

There are three bitmap layers, L0–L2. For every pixel, the hardware takes the colour of the highest-priority layer whose pixel is not transparent. Where no layer has a pixel, the background colour shows. In direct-colour mode (section 4.9) the three layers make one picture instead.

```
          per layer, per plane
 Chip RAM ──DMA──▶ BPLxDAT ──▶ shifter ──┐
                     ▲                   ├─▶ priority ─▶ palette ─▶ HDMI and VGA
               CPU / copper   L0, L1, L2 ┘     (or direct colour)
```

Each layer runs on its own: its own pointers, data registers, shifters, window, scroll and scale. The layers only meet at the end, where one pixel is picked from them.

### 4.2 Pixel formats

| Format | Layout |
|--------|--------|
| **Planar**, 1–8 planes | As on the Amiga: each plane holds one bit of every pixel, 16 pixels per word, leftmost pixel in bit 15. Plane 0 gives bit 0 of the pixel value, plane 1 bit 1, and so on |
| **Chunky**, 1, 2, 4 or 8 bits per pixel | Pixels packed in words, leftmost pixel in the most significant bits. A chunky layer has one pointer, BPL0PT. Its 16-pixel group is 1, 2, 4 or 8 consecutive words (its bits per pixel), held in that many data registers |

### 4.3 Display window

Each layer has a rectangle `XSTART ≤ x < XEND`, `YSTART ≤ y < YEND` (WINX, WINY) in beam coordinates (section 3.3): the layer's display start and stop. Outside it the layer is transparent. Windows can overlap or sit side by side, so status bars and split screens need no copper. A full-screen layer is 144, 49, 864, 625 (VID_X0, VID_Y0, VID_X0 + VID_W, VID_Y0 + VID_H), which is also the value after reset.

A window is clamped to the picture: a start in the blank counts as the picture's edge, where the layer's first pixel then shows (layers are not clipped as sprites are), and an end past the last pixel or line counts as the picture's end.

### 4.4 Plane pointers, stride and scroll

**Each plane has its own pointer, BPLxPT, which counts up through memory as the plane's words are fetched**, as on the Amiga.

| Register | Bits | Meaning |
|----------|------|---------|
| BPL0PT–BPL7PT | 23 (even) | Byte address in Chip RAM of the plane's next word |
| BPLSTRIDE | 16, signed (even) | Bytes from the start of one line to the start of the next (the row stride), for every pointer of the layer. Unlike the Amiga's BPL1MOD/BPL2MOD, it does not depend on how many words are fetched |
| SCROLLX | 4 | Fine scroll: pixels (0–15) skipped at the start of each line, as the Amiga's BPLCON1 delay |

- **How the pointers move.** Each pointer has a saved line start. Each word fetched moves the pointer on by 2. At the start of the next line's horizontal blank, every pointer a word was fetched from since its last reset or write is reset to **its line start + BPLSTRIDE**, which is also the new line start. So at the start of each line, each pointer the layer uses is at its line's start + BPLSTRIDE, however many words were fetched: whole groups, the extra group of fine scroll, the window width, a depth changed part way along the line and a line that ran short make no difference, and software never adjusts for them. A pointer no word was fetched from (a plane with its DMA off or past the layer's depth, a layer not shown on the line) is left alone.
- **Writes.** A CPU or copper write sets the pointer and its saved line start, and wins over the display's own change in the same clock. A pointer written **after the layer's last fetch on line L** (in the right border or the horizontal blank, before line L + 1's fetch starts) is line L + 1's start, as written: that is how split screens are made. A pointer written **while the layer is still fetching line L** is used from the next word fetched (one or two groups past the beam), and the words fetched after it make it line L + 1's start + BPLSTRIDE, that is, the value written + BPLSTRIDE (on a repeated line of a vertically scaled layer, the value written).
- **Reading a pointer** gives its live value. Between the layer's last fetch on a line and the start of the next line's horizontal blank that is the end of the line's words, not the next line's start. A write of only one half (or byte) of a pointer merges with the live value, so in that gap, or while the layer is fetching, **write both halves**: the copper's `CMOVEL` (two MOVEs, the high half first) and a CPU long-word write do.
- **When BPLSTRIDE is read:** at the start of the next line's horizontal blank, when the pointers are reset. A value written at any time during a line, or in the horizontal blank before it, applies at the end of that line.
- **The pointers are not reset by the hardware.** As on the Amiga, the copper (spec 10) writes them at the start of every frame, normally in the vertical blank (or the CPU does it in its VBLANK interrupt). If nothing rewrites them, the next frame carries on through memory.
- Vertical scrolling and coarse horizontal scrolling are done by changing the pointers. Split screens are done by writing new pointers mid-frame.
- BPLSTRIDE = the row's bytes shows a picture whose lines follow each other, at any window width: a 640-pixel-wide 4bpp chunky picture has 320-byte rows, so BPLSTRIDE = 320 whether the window shows all of it or 320 pixels of it. BPLSTRIDE = 0 shows the same line on every screen line; −(row bytes) steps back one row, showing the picture upside down.
- With vertical scaling, on each copy of a source line except the last, the reset sets the pointers back to the line's start (no stride added).

**Pointer wrap (CTRL.WRAP).** A layer can keep its pointers inside a block of 2^(WRAP + 9) bytes (WRAP 1 = 1 KB, 7 = 64 KB, 13 = 4 MB; 0 = no wrap). Every pointer move, word by word and at the end of each line, changes only the address bits inside the block, so a pointer that runs off the end of the block carries on from its start. The block is the aligned one the pointer is in: a pointer at `0x10000` with a 64 KB wrap stays within `0x10000`–`0x1FFFF`. It applies to every pointer of the layer (each plane can have its own block), and not to the pointer values the CPU or copper write.

This makes **endless vertical scrolling** easy: keep the picture as a ring of lines in a block, add new lines just ahead of the visible ones, and move the pointers on (or back) a line at a time; at the end of the block the display carries on from its start, with no copying and no split screen. (Horizontal wrap within each line is not provided: the end-of-line step wraps too.)

| Layout | Pointers | BPLSTRIDE |
|--------|----------|-----------|
| Chunky 320×240 at 8bpp | BPL0PT = base | 320 |
| Planar 320×256, 5 planes, separate as on the Amiga | BPLpPT = base + p × 10240 | 40 |
| Planar 320×256, 5 planes, interleaved (plane lines next to each other) | BPLpPT = base + p × 40 | 5 × 40 = 200 |

### 4.5 Scaling

CTRL.HSCALE and CTRL.VSCALE each pick 1×, 2×, 4× or 8× (values 0–3). Each source pixel is repeated that many times across and each source line that many times down: 2× shows a 360×288 picture on the full 720×576 screen. There is no fractional scaling or shrinking.

### 4.6 Transparency and palette

- **Palettes:** four palettes of 256 entries of 24-bit RGB, memory-mapped (section 6.3): one for each layer (PALETTE0 for L0, PALETTE1 for L1, PALETTE2 for L2) and one for the sprites (SPRPALETTE, spec 9). A layer's pixels take their colours from its own palette only, so three 8-bit layers can show 765 different colours (plus the background). The CPU and the copper can write any entry at any time; a write takes effect from the next pixel, so mid-line colour changes work. An entry changes all at once: its high half (red) is held, one for each writer, until that writer's next write to the entry's low half (green, blue), which writes both (spec 3, section 2). A low-half write on its own keeps the entry's red.
- For layers of up to 4 bits per pixel (chunky 1, 2 or 4bpp, planar 1–4 planes), the colour index in the layer's palette is `PALOFS × 16 + pixel value`: PALOFS picks one of the palette's 16 blocks, so changing it swaps a layer's colours at once. Deeper layers (chunky 8bpp, planar 5–8 planes) use the pixel value directly and ignore PALOFS.
- **Shared palette:** with VIDCON.SHAREPAL set, every layer and sprite takes its colours from PALETTE0, as on a machine with one palette (layers then share it by PALOFS blocks, as sprites share theirs by PAL). Useful when one palette write should change a colour everywhere, for example copper colour bars across all three layers.
- The background colour (BGCOLOR) is a register of its own, not a palette entry.
- If CTRL.TRANSP is set, pixel value 0 is transparent and lower layers show through. If it is clear, the layer is solid inside its window.

### 4.7 Text

There is no text layer. Text is drawn into a bitmap by software, as on the Amiga; the boot ROM draws its console with an 8×16 font (Spleen, code page 437, BSD licence, `third_party/spleen`) into a 1-plane layer.

### 4.8 Priority

PRIO lists the layer numbers from front to back:

| Bits | Field | Meaning |
|------|-------|---------|
| 1–0 | FRONT | Layer in front |
| 3–2 | MIDDLE | |
| 5–4 | BACK | Layer at the back |

Any order is allowed; the value 3 names no layer. The default is L0 in front, then L1, then L2.

### 4.9 Direct colour

With VIDCON.DIRECT set, the layers' palettes and the priority are not used (sprites still use SPRPALETTE, spec 9). Every visible pixel is made from the three layers' pixel values:

| Channel | From | Depth |
|---------|------|-------|
| Red | L0 | L0's planes (planar) or bits per pixel (chunky) |
| Green | L1 | L1's |
| Blue | L2 | L2's |

- Each channel's value is widened to 8 bits by repeating its bits (a 5-bit value `abcde` becomes `abcdeabc`), so full scale stays full scale.
- One rule covers 24-bit (8/8/8 planes or 8bpp chunky), 16-bit (5/6/5), Amiga 12-bit (4/4/4) and 9-bit (3/3/3) colour. The bandwidth is the total number of planes (section 5.2).
- Software sets the three layers to the same window, scroll and scale. Where a layer has no pixel (outside its window, not enabled, or out of data), its channel is 0.
- Each pixel is widened by the depth of the group it came from, so a depth changed part way along a line (section 5.4) changes the values and their widening together, from the next group fetched.
- CTRL.TRANSP and PALOFS have no effect in direct colour.

## 5. Fetch

### 5.1 Data registers and shifters

- Each layer has 8 data registers **BPL0DAT–BPL7DAT** and 8 16-bit **shift registers**. There is no other storage: the data registers hold the layer's next group of 16 source pixels, while the shifters show the current group.
- **A group is always 16 source pixels.** Planar: one word from each plane, plane p in BPLpDAT. Chunky with b bits per pixel: b consecutive words from BPL0PT; the first (leftmost pixels) goes in BPL(b−1)DAT and the last in BPL0DAT. So every layer has 16 pixels of time in hand, whatever its format.
- **When a group is complete:** the DMA fills a group's data registers from the highest down, and the group is complete when the last of them arrives (BPL0DAT, unless plane 0's DMA is off; section 5.5). For a layer with no DMA, the CPU or copper writes the data registers, and its write of BPL0DAT completes the group.
- The shifters take all of a layer's data registers at once. They take the line's first group as soon as it is complete, in the horizontal blank, so the second group is already in the data registers when the window starts (as the Amiga fetches ahead of the display window). After that they take the next group each time the current one is used up (every 16 source pixels). Each take empties the data registers, and the DMA fetches the next group.
- The display owns **memory cycles 1 and 3 of every slot** (40 and 60 ns apart): 4 bytes every 100 ns (spec 5, section 4.3). It may also use any cycle nobody else wants, including cycle 0 when the CPU leaves it, and, as on the Amiga, an **urgent** fetch (one about to be late) takes the CPU's cycle 0 (spec 5, section 6).
- **Order:** each word goes to the layer whose deadline is nearest (**earliest deadline first**, chosen in the layer fetch, retro-hw's `layer_fetch.v`): when a layer's shifters take a group, its countdown loads the time that group lasts (16 source pixels × its scale). Layers with equal deadlines take turns. A request whose deadline is about to pass is **urgent**. The layers' requests go ahead of the sprites' in the scheduler, by number; only an urgent sprite fetch goes ahead of a layer's that is not urgent (spec 5, section 6.3).
- **Start and stop:** at the start of the horizontal blank, each layer whose window covers the next line gets its first group fetched; the number of groups on the line comes from the window width, scale and fine scroll. Nothing is fetched outside the windows.
- With vertical scaling, each source line is fetched again for every screen line it appears on.

### 5.2 Budget

Data is fetched while it is shown, so the budget is a **rate**: the bytes that can be fetched for each pixel the beam passes. The display has 4 bytes every 100 ns, and a pixel lasts 37 ns: **1.48 bytes per pixel**.

A layer needs `bits per pixel ÷ 8 ÷ HS` bytes per screen pixel (for planar, bits per pixel = planes; count only the planes with DMA on, section 5.5). At every point across the screen, the layers whose windows cover it must add up to no more than the budget.

| Screen setup | Bytes per pixel | Fits? |
|--------------|-----------------|-------|
| One 8bpp layer at 1× | 1.0 | Yes |
| 5 planes at 2× (PAL Amiga 32 colours) | 0.31 | Yes |
| 6 planes + 6 planes at 2× (two 64-colour playfields) + 4 planes at 2× | 1.0 | Yes (16 planes in step, section 5.6) |
| 8bpp layer + 4bpp layer at 1× | 1.5 | **No** (just over) |
| Direct colour 16-bit (5/6/5) at 2× across | 1.0 | Yes |
| Direct colour 24-bit at 1× | 3.0 | **No** |
| Direct colour 24-bit at 2× across, full width | 1.5 | **No** (just over); 21-bit (7/7/7) at 1.31 fits |
| Two 8bpp layers at 1× | 2.0 | **No** |

The 1.48 is what the display's own cycles (1 and 3) guarantee. The DMA scheduler (spec 5, section 6) also gives it any cycle nobody else wants, and lets a fetch that is about to be late take the CPU's cycle 0, so a screen a little over the budget still shows correctly: in simulation, 1.5 bytes per pixel (8 + 8 + 8 planes at 2×, or 8 + 4 planes at 1×) fits with the CPU running. The extra comes out of the CPU's, audio's, the copper's and the blitter's time, so the table's "No" rows are best avoided, not impossible; how far beyond 1.5 a screen can go is not measured yet.

Windows help: a status bar below a game area, not on top of it, adds nothing on the lines where the game area is shown.

Each layer has one group of time in hand (its data registers). Section 5.6 has the timing of each group's fetch and the measured limits.

### 5.3 When a layer runs short

If a layer's next group is not complete when its shifters need it, the layer shows transparent pixels (in direct colour: 0) for that group, and tries again at the next one. Its OVERRUN flag is set, and VIDERR can raise an interrupt. Nothing else on the display goes wrong, and the CPU is never affected.

### 5.4 When register writes take effect

| Registers | Take effect |
|-----------|-------------|
| CTRL.EN, VSCALE; WINX, WINY, SCROLLX | At the start of the horizontal blank before each line. **To change line L, write during the visible part of line L − 1 or earlier** |
| CTRL.BPP, PLANAR, PLANES, HSCALE | From the next group the layer fetches (below) |
| CTRL.TRANSP, PALOFS | From the next pixel (below) |
| CTRL.WRAP | At the pointers' next move |
| BPLxPT, BPLSTRIDE | At once: they are live. The next word fetched uses a new pointer, which also becomes the pointer's saved line start; a CPU or copper write wins over the DMA's own change in the same clock. BPLSTRIDE is used when the pointers are reset at the start of the next line's horizontal blank (section 4.4) |
| BPLxDAT | At once; for a layer with no DMA, a write of BPL0DAT completes the group (write it last). For a plane with DMA off, from the next group |
| BPLDMA | At once: the next group fetched uses the new enables |
| PRIO, BGCOLOR | At the start of each line |
| VIDCON.DIRECT, palette | At once (next pixel) |

**CTRL part way along a line.** A layer's settings are not all taken once a line:

- **Depth, PLANAR and HSCALE** travel with each group: the layer fetch takes them as it starts a group and the shifters use them for that group, so a group is always shown as it was fetched. The fetch works a group ahead, so a write shows from the next or the second group past the one the beam is in: 16–32 source pixels after the beam. A copper placing a change allows for that.
- **HSCALE part way along a line** changes how long each group lasts, but the line's number of groups was worked out at its start (from the window, the scale and SCROLLX then). A wider scale leaves the line's last groups unshown; a narrower one makes the line run out of groups before the window ends, and the rest of the line is transparent (with an OVERRUN for the layer). The next line starts right either way: the pointers are reset at the line's end (section 4.4).
- **TRANSP and PALOFS** are read by the pixel side every pixel, straight from the register: a write shows from the next pixel. They cross from the system clock to the pixel clock with no synchroniser, so the one pixel where they change may show a mix of the old and new bits (one bit of PALOFS old, another new).
- **EN and VSCALE** (and WINX, WINY, SCROLLX) are line settings: from the next line.

### 5.5 DMA per plane (BPLDMA)

As on the Amiga, any plane can be fed by the CPU or copper instead of by DMA, so that one plane costs no memory cycles at all. Each layer's **BPLDMA** register has a DMA enable for each plane (bits 7–0). It is a set/clear register like DMACON: bit 15 = 1 sets the bits written as 1, bit 15 = 0 clears them. All planes are on after reset.

- **A plane with its DMA off** is not fetched, and its pointer stays where it is. Its data register keeps the value the CPU or copper last wrote, and the shifters take that value again with every group (every 16 source pixels). A write takes effect from the next group. So a constant word gives a repeating 16-pixel pattern, and the copper can change it per line, for example to add a colour bar plane or a stripe pattern to a picture without fetching anything.
- The layer's group is complete when the DMA has fetched its last enabled plane. Writes to the data registers of planes with DMA off never complete a group.
- **A layer with no planes on** (or with DMACON.BPLEN or DMAEN off) does no DMA. The CPU or copper writes all its data registers, and a write of BPL0DAT completes each group (section 5.1).
- **Chunky layers:** bit 0 turns the whole layer's DMA on or off; the other bits are ignored.
- With fewer planes fetched, the layer costs less: count only the planes with DMA on in the budget (section 5.2).

### 5.6 Clock crossings and turnaround

The pixel side (27 MHz) and the memory side (100 MHz) are asynchronous (section 3.1). The crossing does not change the display's **bandwidth**: it still owns memory cycles 1 and 3 of every slot, 40 MB/s. What it costs is **latency**, in the handshake that moves each group:

| Step | Time |
|------|------|
| The shifters take a group; the memory side sees "taken" (two flip-flops at 100 MHz, plus the phase) | up to 30 ns |
| The DMA asks, and waits for the next display cycle (cycles 1 and 3, 40 and 60 ns apart) | 10–70 ns |
| The group's words, two per 100 ns slot | about 50 ns each after the first |
| The last word: SRAM read to BPLxDAT | 50 ns |
| "Full" reaches the pixel side: two flip-flops at 135 MHz (the HDMI clock, 5 × the pixel clock, edges lined up), then the pixel side reads it as a related clock | 7–22 ns |
| **Fixed part** | **about 80–170 ns** |

The next group must be complete before the current one is used up: 16 source pixels, which is 593 ns at 1×, 1185 ns at 2×. Two design choices keep the fixed part short: the "full" synchroniser runs at 135 MHz rather than at the 27 MHz pixel clock (two 27 MHz flip-flops would cost up to 111 ns), and the display's two memory cycles are spread out in the slot (cycles 1 and 3) rather than side by side, so a request never waits more than 60 ns for one.

**Turnaround limit.** Layers whose windows start at the same place, with the same scroll and scale, use up their groups at the same pixel, so all their words are wanted at once. The layer fetch serves the earliest deadline first, the DMA scheduler (spec 5, section 6) gives it free cycles 2 and 4 when nobody else wants them, and lets an urgent fetch take the CPU's cycle 0. Measured in simulation at 576p, full width, every layer planar, all in step:

| Layers | Planes in step | Bytes per pixel | Result |
|--------|----------------|-----------------|--------|
| 8 + 3, 8 + 4, 6 + 6 at 1× | 11–12 | 1.38–1.5 | Fits |
| 8 at 1× + 4 or 8 at 2×; 6 or 7 at 1× + 8 at 2× | – | 1.25–1.5 | Fits |
| 8 at 1× + 8 at 4× | – | 1.25 | Fits |
| 6 at 1× + 8 at 2× + 8 at 4× | – | 1.5 | Fits |
| 8 + 8 + 7, 8 + 8 + 8 at 2× | 23–24 | 1.44–1.5 | Fits |

Before the scheduler (display cycles 1 and 3 only, layers taking turns), the limits were 10 planes in step at 1× and 22 at 2×, and a deep 1× layer next to a deep 2× layer ran short. With the scheduler every tested case fits, up to 1.5 bytes per pixel. Beyond that the limit is bandwidth (section 5.2), shared with the CPU, audio, the copper and the blitter: an urgent display fetch always wins, so a screen near the limit slows the CPU and the other channels rather than the picture. Planes with their DMA off (section 5.5) don't count. Layers whose groups start on different pixels (different fine scroll, or windows starting at different x) share the time better still.

## 6. Registers

The offsets are within the custom register block at `0xE00000`. Spec 3 has the full map.

### 6.1 Global

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x000` | VIDCON | EN (0), BLANKALL (2), DIRECT (4), SHAREPAL (5) | Video on; show the background colour only; direct colour; all layers and sprites use PALETTE0 (section 4.6) |
| `0x004` | VIDSTAT | VBLANK (0), LINE (1), OVERRUN L0–L2 (6–4), SPRUNDER (7: a sprite's FIFO ran dry, spec 9), INVBLANK (8, read-only) | Sticky flags, write 1 to clear |
| `0x008` | VIDINTEN | Same layout as VIDSTAT | Interrupt enables |
| `0x00C` | BEAMPOS | `vline` 26–16, `hpixel` 10–0 | Read-only |
| `0x010` | FRAMECOUNT | 15–0 | Read-only |
| `0x014` | LINECMP | `vline` 26–16 | LINE interrupt line |
| `0x018` | BGCOLOR | 23–0 RGB | Background colour |
| `0x01C` | PRIO | See 4.8 | Layer order |
| `0x020` | VIDSIZE | VVISIBLE 26–16, HVISIBLE 10–0 | Read-only: the screen size of the built mode |

For the layers to fetch, DMACON (spec 5, section 8) must also have DMAEN and BPLEN set, and the plane's bit in its layer's BPLDMA.

### 6.2 Per layer

Layer n (0–2) is at `0x100 + n × 0x80`.

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), PLANAR (1), BPP (3–2: chunky 1/2/4/8), TRANSP (4), HSCALE (7–6), VSCALE (9–8), PALOFS (15–12), PLANES (18–16: planes − 1), WRAP (23–20: pointer wrap, 0 off, n = 2^(n+9) bytes) | |
| `+0x04` | WINX | XSTART 26–16, XEND 10–0 | Window, pixels |
| `+0x08` | WINY | YSTART 26–16, YEND 10–0 | Window, lines |
| `+0x0C` | SCROLLX | 3–0 | Fine scroll, pixels |
| `+0x10` | BPLSTRIDE | 15–0, signed, even | Bytes from one line's start to the next (section 4.4) |
| `+0x14` | BPLDMA | SETCLR (15), PLANES (7–0) | DMA enable per plane (chunky: bit 0 for the layer). Set/clear. All on after reset |
| `+0x20`–`+0x3C` | BPL0PT–BPL7PT | 22–0, even | Plane pointers (chunky: BPL0PT only) |
| `+0x40`–`+0x5C` | BPL0DAT–BPL7DAT | 15–0 | Data registers: the next group (chunky with b bits per pixel: BPL0DAT–BPL(b−1)DAT) |

### 6.3 Memory-mapped area

| Area | Location | Contents |
|------|----------|----------|
| PALETTE0 | `0xE04000`–`0xE043FF` | L0's palette: 256 × 32-bit, `0x00RRGGBB` |
| PALETTE1 | `0xE04400`–`0xE047FF` | L1's palette |
| PALETTE2 | `0xE04800`–`0xE04BFF` | L2's palette |
| SPRPALETTE | `0xE04C00`–`0xE04FFF` | The sprites' palette (spec 9) |

Entry i of palette p is at `0xE04000 + p × 0x400 + i × 4`. Bits 31–24 read as 0. After reset the palettes' contents are undefined; the boot ROM sets the colours it uses.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Palettes, 4 × 256 × 24 bits | A RAM of 1024 × 24 (the address is the palette number and the index), kept twice and written together from the CPU side at 100 MHz: one copy is read back by the CPU, the other by the pixel side. Each copy is a simple one-write, one-read RAM, which every tool maps the same way: one RAMB36 each, 2 in all (the single 256-entry palette took one) |
| The pixel pipeline | The priority stage passes on, with the winning pixel's index, which palette it is from (2 bits): a few LUTs |
| 24 pointers, 24 data registers, 24 shift registers | Logic |
| Clocks | One MMCM, shared with the rest of the design |

## 8. Open points

| # | Item |
|---|------|
| V1 | Check in Vivado that the clock-domain crossings are all covered (asynchronous clock groups) and the pixel pipeline meets timing |
| V3 | Done: the layer fetch orders the layers' words by deadline (section 5.6). Since the generic scheduler, the layers go ahead of the sprites by number (spec 5, section 6.3) |
| V2 | Plain DVI has no info packets. Add the HDMI AVI InfoFrame (576p, 4:3, "underscanned", IT content) so TVs neither crop the picture nor treat it as video; needs the HDMI data-island encoder (with HDMI audio, later) |

## 9. Tests

- **Timing:** sync positions, totals and frame rate for both modes in simulation; real monitors lock on to both, on HDMI and VGA.
- **Golden images** (`make vtest` in `sim/`): random pictures in every layer format (chunky and planar, scaling, fine scroll, stride, a flipped layer, transparency, priority, and direct colour), compared pixel by pixel with a Python model of this spec (`sim/vtest/vmodel.py`). No OVERRUN. The `ctl` screen has a copper change CTRL part way along lines (the depth, and PALOFS), write a split screen's pointers after a layer's last fetch on a line, and write half of a pointer while the layer is fetching. Where section 5.4 gives a range (the next group or the one after it; the next pixel, give or take the beam sample's lag, with one mixed pixel), the model tries each placement it allows and the line must match one exactly.
- **Boot ROM:** the console and a 4-plane interleaved picture, checked pixel by pixel.
- **Fetch budget:** for every example in 5.2 that fits, no OVERRUN. For one that does not fit, OVERRUN is set on the right layer only.
- **Register timing:** a CTRL write during line L − 1's visible part changes line L; a depth or PALOFS write part way along a line changes it from the group or pixel section 5.4 says (the `ctl` screen).
- **CPU:** on screens within the 1.48 budget the CPU almost never waits; count the stolen cycle 0s on heavy screens.

## 10. Later versions

- More layers, fractional scaling and shrinking
- More modes (exact 640×480, 720p, 1024×768): a different pixel clock from MMCM 2, at build time or by reconfiguring it; the rest of the design is ready for it
- Wide fetch (memory cycle 3 for the display)
- EHB and HAM modes, tile-map layers
- HDMI audio
