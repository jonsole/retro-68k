# Spec 6: Audio

Status: **v1 scope**

Four sample channels, in the spirit of the Amiga's Paula. Each plays a sample from Chip RAM by itself, at any pitch, with its own left and right volume, and needs no CPU work while it plays. A sample can loop, or the next one can be queued, exactly as on the Amiga.

(The larger draft, with 16 channels, a 16-tap resampling filter and a stereo stream, is in git history before this version. It may come back later.)

## 1. Summary

| Item | Value |
|------|-------|
| Channels | 4, all alike |
| Output rate | 100 MHz ÷ AUDRATE. Default 2083: 48.008 kHz. 2268: 44.092 kHz |
| Sample formats | 8-bit or 16-bit signed PCM, per channel |
| Pitch | A step per output sample, 4.16 fixed point: 1/65536 to just under 16 samples per output sample |
| Resampling | Linear interpolation between neighbouring samples; or "nearest" (no interpolation), per channel, for the raw Amiga sound |
| Volume and pan | Left and right volume per channel, 0–64 each (64 = full). Software sets them: there are no reset values |
| Loops and queues | As the Amiga: a channel takes its address and length registers when it starts and again at the end of each block, and interrupts each time |
| Starting and stopping | Easier than the Amiga: AUDSTART and AUDSTOP start, restart or stop channels with one write, with no waiting; a one-shot mode stops a channel by itself at the end of its block; AUDSTAT shows which channels are playing |
| Memory | One or two 16-bit reads per channel per output sample, at most 8 per output sample: under 1 MB/s. Its own channel in the scheduler (spec 5, section 6) |
| Mixer | The four channels summed; no clipping is possible |
| Output | Second-order sigma-delta DAC at 100 MHz on the KS3's audio pins: `audioext_l`, `audioext_r` (the jack) and `audioint` (the internal speaker, mono) |
| Interrupt | AUDIO (source 9): a channel took its registers (AUDSTAT) |

## 2. Comparison with the Amiga (Paula)

| Feature | Amiga | retro68k v1 |
|---------|-------|-------------|
| Channels | 4 | 4 |
| Sample size | 8-bit | 8- or 16-bit, per channel |
| Pitch | Each channel's DAC runs at the sample's own rate (AUDxPER) | All channels resampled to one output rate (AUDxSTEP); linear interpolation, or nearest for the Amiga sound |
| Volume | 0–64 per channel | 0–64 left and 0–64 right per channel |
| Stereo | Hard-panned: 0 and 3 left, 1 and 2 right | Any pan, set by software |
| Starting, looping, queuing | AUDxLC and AUDxLEN taken at the start and at the end of each block; an interrupt each time | The same |
| Enables | DMACON.AUD0EN–AUD3EN | The same, and they act at once: off then on again restarts the channel, with no wait in between |
| Starting and stopping | DMACON only; to restart, turn off, wait, turn on; a one-shot sample needs an interrupt handler (or a silent block) to stop it | Also AUDSTART (start or restart, even while playing) and AUDSTOP (stop at once); ONESHOT stops a channel by itself at the end of its block; AUDSTAT.ACTIVE shows which channels play |
| Interrupts | One per channel (AUD0–AUD3) | One source, AUDIO, with a bit per channel in AUDSTAT |
| Output | 8-bit DACs, analogue filter | 16-bit mix, sigma-delta DAC |

**Periods:** an Amiga period P (in 3,546,895 Hz ticks, PAL) gives a sample rate of 3,546,895 ÷ P. At the default 48.008 kHz the matching step is

```
   STEP = 3,546,895 × 65536 ÷ (P × 48,008)   ≈  4,841,856 ÷ P
```

so an Amiga MOD player needs only a table from periods to steps.

## 3. Output

### 3.1 Output rate

Every AUDRATE clocks of 100 MHz the audio unit makes one stereo output sample: it works out each channel's sample, mixes them, and hands the result to the DAC. AUDRATE is 16 bits, at least 200. The default, 2083, gives 48.008 kHz.

The unit is retro-hw's `audio_engine` (its `docs/spec/audio_engine.md` has the exact rules, clock by clock); `audio.v` adds the registers' bus, AUDRATE's floor, the starts and stops, AUDSTAT, the interrupt and the DACs.

### 3.2 Mixer

```
   left  = Σ (channel sample × channel left volume)  ÷ 256
   right = Σ (channel sample × channel right volume) ÷ 256
```

A channel sample is 16 bits signed (an 8-bit sample is shifted up by 8), a volume 0–64, so each product fits in 22 bits, and four of them in 24: the result always fits in 16 bits. As on the Amiga, one channel at full volume uses a quarter of the output range, and nothing can clip.

### 3.3 DAC

A second-order sigma-delta modulator at 100 MHz turns each 16-bit output into a 1-bit stream on each pin; the board's filter turns that back into sound. `audioint` gets the mono mix, (left + right) ÷ 2. The input is scaled to half the modulator's range, which keeps it stable at full scale. The real quality depends on the board's filter and has to be measured (open point A1).

## 4. Channels

### 4.1 Blocks: starting, looping and queuing

A channel plays **blocks**. A block is a sample in Chip RAM: an address (AUDxLC) and a length in samples (AUDxLEN).

- When a channel is **started**, it takes AUDxLC and AUDxLEN, starts at the first sample of the block, and sets its bit in AUDSTAT. It starts at the next output sample after its AUDnEN bit in DMACON is set (with DMAEN), or after a write to AUDSTART.
- When it plays past the end of the block, it takes AUDxLC and AUDxLEN **again**, carries on from the start of that block, and sets its bit in AUDSTAT again. With AUDxCTRL.ONESHOT set, it stops instead (section 4.2).

So:

- **A loop:** write AUDxLC and AUDxLEN once and turn the channel on. It plays the block over and over.
- **A sample with a loop:** write the whole sample, turn the channel on, and when AUDSTAT says the channel has taken it, write the loop part. The whole sample plays once, then the loop part for ever.
- **A queue:** each time the channel takes its registers, write the next block. It plays the blocks one after another with no gap.
- **A one-shot sound:** set AUDxCTRL.ONESHOT and start the channel: it plays the block once and stops. To play it again, write AUDSTART.
- **A sound effect that cuts off the one playing:** write the new sample's AUDxLC and AUDxLEN, then AUDSTART: the channel starts it at the next output sample, whatever it was doing.

The registers can be written at any time; the channel only takes them when it starts a block. A block of length 0 stops the channel, as AUDSTOP does.

### 4.2 Starting and stopping

| To | Write | Takes effect |
|----|-------|--------------|
| Start a channel, or restart it from its registers even while it plays | AUDSTART bit n (DMACON.AUDnEN must be set), or set AUDnEN in DMACON | At the next output sample |
| Stop a channel | AUDSTOP bit n, or clear AUDnEN in DMACON | At once: AUDSTAT.ACTIVE clears straight away, and the channel is left out of the next output sample. If the unit is working on the channel at that moment, it finishes it for this output sample: a block's end there still takes the registers and sets the AUDSTAT bit, but the channel stays stopped |
| Play a block once and stop | AUDxCTRL.ONESHOT, then start the channel | It stops by itself at the end of the block, and sets its AUDSTAT bit |

All of them act as soon as they are written: there is never a need to wait between stopping and starting a channel, as there is on the Amiga (where DMA changes are only seen once per line). Clearing AUDnEN and setting it again straight away restarts the channel. AUDSTAT.ACTIVE (bits 7–4) shows which channels are playing; a stopped channel is silent.

DMACON.AUDnEN stays the master switch: while it is clear, the channel is stopped and AUDSTART does nothing to it.

### 4.3 Pitch

Each output sample, a channel's position moves on by AUDxSTEP, 4.16 fixed point: `$10000` plays one sample per output sample (the sample's own rate is the output rate), `$8000` half that (an octave down), `$20000` twice (an octave up). The largest step is just under 16. A step past the end of a block carries on into the next block by the amount left over (if that is past the end of the next block too, it starts at its first sample). A one-shot channel stops instead.

### 4.4 Interpolation

The channel's sample is worked out from the two samples around its position:

```
   s = s0 + (s1 − s0) × frac ÷ 65536
```

where s0 is the sample at the position, s1 the one after it, and frac the position's fraction. At the last sample of a block, s1 is the first sample of the block to come: the one at AUDxLC as the register then stands. So a loop is smooth round its join, and a queued block joins the one before. A one-shot channel, or one whose AUDxLEN is then 0, has no block to come: its s1 is s0. With AUDxCTRL.NEAREST set, s = s0: each sample is held until the next, as on the Amiga.

### 4.5 Sample formats

- **8-bit** (CTRL.BITS16 = 0): signed bytes, two to a word, the first in the high byte. AUDxLC can be any byte address.
- **16-bit** (CTRL.BITS16 = 1): signed big-endian words. AUDxLC must be even.

### 4.6 Memory

For each output sample, each playing channel reads the word holding s0, and, unless NEAREST is set, the word holding s1 if that is a different one: at most 8 reads per output sample, 384,000 a second at 48 kHz, under 1 MB/s. The audio channel owns memory cycle 2 of every slot (spec 5, section 6), 20 MB/s, so it is never short. Reads happen just before they are needed; there are no sample caches.

## 5. Registers

Offsets in the custom register block at `0xE00000`.

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `0x404` | AUDRATE | RW | 15–0 | Output rate = 100 MHz ÷ AUDRATE. Default 2083 (48.008 kHz). Values below 200 act as 200 |
| `0x40C` | AUDSTAT | W1C, R | CH (3–0), ACTIVE (7–4) | CH bit n: channel n started a block (it was started, or reached the end of a block), or a one-shot block ended. Sticky; write 1 to clear. ACTIVE bit 4 + n: channel n is playing (read only, live) |
| `0x410` | AUDINTEN | RW | CH (3–0) | Bit n: AUDSTAT bit n raises the AUDIO interrupt |
| `0x414` | AUDSTART | W | CH (3–0) | Strobe: bit n starts channel n from its registers at the next output sample, even while it plays (if DMACON.AUDnEN is set) |
| `0x418` | AUDSTOP | W | CH (3–0) | Strobe: bit n stops channel n at once |

Channel n (0–3) at `0x440 + n × 0x20`:

| Offset | Name | Access | Bits | Description |
|--------|------|--------|------|-------------|
| `+0x00` | AUDxCTRL | RW | BITS16 (1), NEAREST (2), ONESHOT (3) | Sample format; no interpolation; play one block, then stop |
| `+0x04` | AUDxLC | RW | 21–0 | Block address, in bytes (even for 16-bit). Taken at the start of each block |
| `+0x08` | AUDxLEN | RW | 21–0 | Block length, in samples. Taken at the start of each block. 0 stops the channel |
| `+0x0C` | AUDxSTEP | RW | 19–0 | Pitch: samples per output sample, 4.16 |
| `+0x10` | AUDxVOL | RW | L (22–16), R (6–0) | Left and right volume, 0–64; above 64 acts as 64 |
| `+0x14` | AUDxPOS | R | 21–0 | The sample the channel is playing, in the block |

A channel can only play while DMACON.DMAEN and DMACON.AUDnEN (bit n) are both set (spec 5, section 8). CTRL, STEP and VOL take effect from the next output sample; LC and LEN when the channel next starts a block (and LC for the join at the end of the block before, section 4.4).

**The channel registers have no reset values.** They are kept in a small RAM that a reset does not clear: after power-on they are CTRL 0, LC 0, LEN 0, STEP `$10000` and VOL 0, and after a later reset whatever was last written. Write all five before starting a channel. Write LC and LEN just after the channel's AUDSTAT bit sets: a block's end that comes between the two writes would take one old and one new.

**Interrupt:** source 9, AUDIO, in the interrupt controller (spec 13): any AUDSTAT bit with its AUDINTEN bit set. Default level 4. The handler reads AUDSTAT to see which channels, writes their next blocks if any, and clears their bits.

## 6. Examples

Playing a looped 8-bit sample on channel 1 at 22,050 Hz, centre:

```
    move.l  #sample,AUD1+AUD_LC(a4)
    move.l  #samplelen,AUD1+AUD_LEN(a4)
    move.l  #(22050*65536)/48008,AUD1+AUD_STEP(a4)    ; $7596
    move.l  #(32<<16)|32,AUD1+AUD_VOL(a4)            ; centre
    move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_AUD1EN_M,DMACON+2(a4)
```

A sample with a loop: as above, then, when AUDSTAT bit 1 is set (the channel has taken the whole sample), write the loop part:

```
    move.l  #sample+loopstart,AUD1+AUD_LC(a4)
    move.l  #looplen,AUD1+AUD_LEN(a4)
    move.l  #2,AUDSTAT(a4)                           ; clear bit 1
```

A one-shot sound effect on channel 3, cutting off whatever it was playing:

```
    move.l  #AUD_CTRL_ONESHOT_M,AUD3+AUD_CTRL(a4)
    move.l  #bang,AUD3+AUD_LC(a4)
    move.l  #banglen,AUD3+AUD_LEN(a4)
    move.l  #8,AUDSTART(a4)                          ; bit 3: (re)start channel 3
```

## 7. FPGA resources

| Item | Resource |
|------|----------|
| `audio_engine` (4 channels, with read-back), out of context | 666 LUTs (122 of them LUT RAM), 423 flip-flops, 1 DSP block |
| Three sigma-delta modulators | About 230 LUTs |
| The whole machine with it (Vivado, KS3) | 15,128 LUTs (72.7%), 10,303 flip-flops; worst setup slack +0.557 ns. The unit before it, with the channel registers in flip-flops and three multipliers, made the machine 15,580 LUTs |

## 8. Open points

| # | Item |
|---|------|
| A1 | The KS3's audio filter, and the real quality of the sigma-delta output, measured on the board |
| A2 | Closed: the interpolation carries across a block's end (section 4.4) |
| A3 | Sound over HDMI |
| A4 | Closed: the engine is retro-hw's `audio_engine`, with the channels' settings in LUT RAM and one multiplier used in turn |

## 9. Tests

- **Golden output:** a test ROM plays all four channels at once, 8- and 16-bit, nearest and interpolated, steps below and above 1, odd addresses, queued blocks of different lengths, a one-shot block, a restart with AUDSTART while playing, and DMACON turned off and on again with no wait; the testbench records every output sample (and when each channel started), and a Python model of sections 3 and 4 must give exactly the same numbers.
- **DAC:** the sigma-delta streams, averaged over each output sample, follow the output samples.

## 10. Later versions

- More channels; the resampling filter and the stereo stream of the earlier draft
- A master volume; modulation (the Amiga's ADKCON)
- Sound over HDMI (A3)
