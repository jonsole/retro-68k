# Spec 12: Timers

Status: **draft for review**

Timers give software a sense of time: a steady tick for the operating system, tempo for music players, timeouts, delays and measuring how long code takes. They live in the **system area** at `0xF00000` (with the interrupt controller and serial port), so the copper cannot change them.

## 1. Summary

| Item | Value |
|------|-------|
| Time counter | 64-bit, counts at 100 MHz (10 ns), never stops or wraps in practice (over 5,800 years) |
| General timers | 4, each with a 32-bit counter and a 16-bit prescaler |
| What they count | Prescaled 100 MHz clock, video lines, video frames, or another timer running out (to chain timers) |
| Modes | One-shot or repeating |
| When a timer runs out | Interrupt (level 6, vectored) |
| Watchdog | Resets the computer if software stops kicking it in time; a register says why the last reset happened |

## 2. Comparison with the Amiga

| Feature | Amiga (two CIA 8520 chips) | retro68k |
|---------|----------------------------|----------|
| Timers | 4 (2 per CIA), 16-bit | 4, 32-bit, with a 16-bit prescaler each |
| Timer clock | Fixed, about 0.7 MHz | 100 MHz ÷ (1 to 65,536), e.g. exactly 1 MHz |
| Chaining | Timer B can count timer A | Any timer can count the one before it |
| Other count sources | CNT pin | Video lines and frames |
| Time of day | 24-bit counter of frames or mains cycles | 64-bit 10 ns time counter |
| Watchdog | No | Yes |

## 3. Time counter

- **TIME** is a 64-bit counter that adds 1 every 10 ns from power-on. It cannot be written.
- Reading it as 16-bit halves (as the 68000 does) could catch it half-way through a carry. So **reading the highest 16 bits captures all 64 bits at that instant**, and the next three reads return the captured rest. Reading TIMEHI then TIMELO with MOVE.L, high first, gives one consistent value. There is one capture for the whole machine, and every read of TIMEHI's upper half takes a new one: an interrupt handler that reads the time between another program's TIMEHI and TIMELO reads breaks that program's pair. Read the time with interrupts masked, or only in one place.
- Uses: timestamps, profiling ("how many 10 ns ticks did this routine take"), timeouts that never need resetting.

## 4. General timers

### 4.1 How a timer works

Each timer has a **COUNT** that goes down by 1 on each tick of its source. When it would go below 0 (**underflow**):

- **Repeating mode:** COUNT is reloaded from **RELOAD** and counting goes on. A timer with RELOAD = n fires every n + 1 ticks.
- **One-shot mode:** the timer stops (EN clears itself).
- In either mode, the timer can raise an **interrupt**, and count as a tick for the next timer.

Writing COUNT sets it directly. Writing RELOAD takes effect at the next underflow, so a repeating timer's period can be changed without a glitch.

### 4.2 What a timer counts

| SRC | Ticks on | Use |
|-----|----------|-----|
| 0 | The 100 MHz clock divided by (PRESCALE + 1) | Fixed rates. PRESCALE = 99 gives exactly 1 MHz (1 µs ticks) |
| 1 | The start of each video line | Line-based timing, e.g. "every 10 lines" |
| 2 | The start of each frame (vertical blanking) | Frame counting, e.g. "every 3 frames" |
| 3 | The previous timer's underflow (timer 0 counts timer 3) | Chaining: two timers make a 64-bit timer, or a slow timer counts a fast one |

PRESCALE only applies to SRC 0.

### 4.3 Examples

| Want | Setting |
|------|---------|
| Operating system tick, 1000 Hz | SRC 0, PRESCALE 99 (1 MHz), RELOAD 999, repeating, interrupt |
| Music at 125 BPM with 24 ticks per beat (50 Hz) | SRC 0, PRESCALE 99, RELOAD 19,999, repeating, interrupt |
| Timeout of 2 seconds | SRC 0, PRESCALE 99, COUNT 1,999,999, one-shot, interrupt |
| Exact delay in video lines | SRC 1, COUNT n, one-shot |

Video lines and frames are counted from the video timing (spec 4), so they tick even when video output is blank, as long as the timing generator runs.

## 5. Watchdog

The watchdog resets the computer if software hangs.

- Software sets a time (WDTIME, in milliseconds, 1–65,535; 1000 after reset) and turns it on (WDCTRL.EN). The time counts in whole milliseconds, so the watchdog fires between WDTIME and WDTIME + 1 ms after the last kick. A new WDTIME takes effect at the next kick or WDCTRL write; writing WDCTRL also restarts the count, like a kick.
- Software must **kick** it before the time runs out, by writing `0x5A5A` to WDKICK (as a 16-bit or 32-bit write). Any other value, or a byte write, counts as a failed kick and resets at once, so a program running wild is unlikely to keep it alive by accident. While the watchdog is off, WDKICK writes are ignored.
- If it runs out, it **resets the computer**: the CPU and all the custom hardware restart, as at power-on, but the FPGA keeps its configuration.
- **LOCK:** writing WDCTRL with LOCK set makes the watchdog settings read-only until the next reset, so software cannot turn it off by mistake.
- **RESETWHY** (spec 7, section 7) tells software after starting up why the last reset happened.

The watchdog is off after reset, so the boot ROM and simple programs need not know about it.

## 6. Registers

In the system area at `0xF00000`. Spec 3 sets the final addresses. All registers are 32-bit and follow the 16-bit-halves rules (spec 3, section 2): each half is written on its own. Write COUNT and RELOAD while the timer is stopped, or write COUNT's low half only, so a running timer never counts from half a new value.

**Time counter:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x100` | TIMEHI | 31–0 | Upper 32 bits of TIME. Reading its upper half captures all 64 bits |
| `0x104` | TIMELO | 31–0 | Lower 32 bits (from the capture) |

**General timers** (timer n = 0–3 at `0x140 + n × 0x20`):

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `+0x00` | CTRL | EN (0), REPEAT (1), SRC (3–2), IRQ (4) | Running; repeating; source (4.2); interrupt on underflow. (Bits 7–5 were DMA and DMACH, a timer starting a DMA engine channel; they went with the engine's channels, spec 11, and read as 0) |
| `+0x04` | PRESCALE | 15–0 | Clock divider for SRC 0: 100 MHz ÷ (PRESCALE + 1) |
| `+0x08` | RELOAD | 31–0 | Value loaded at each underflow in repeating mode |
| `+0x0C` | COUNT | 31–0 | Current count; writing sets it |
| `+0x10` | STAT | UNDER (0) | Underflowed; sticky, write 1 to clear |

**Watchdog:**

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x1C0` | WDCTRL | EN (0), LOCK (1) | On; lock settings until reset |
| `0x1C4` | WDTIME | 15–0 | Time allowed between kicks, in milliseconds |
| `0x1C8` | WDKICK | 15–0 | Write `0x5A5A` to restart the time; any other value resets at once |

**Interrupts:** each timer is its own source in the interrupt controller (spec 13), TIMER0–TIMER3, with its own vector. Default level 6.

## 7. FPGA resources

| Item | Resource |
|------|----------|
| 64-bit time counter, 4 timers with prescalers, watchdog | Estimate 350–500 LUTs |
| Block RAM, DSP | None |

## 8. Open points

| # | Item |
|---|------|
| T1 | ~~A real-time clock that survives power-off.~~ Resolved: the KS3 has a battery-backed real-time clock on its I2C bus. Software reads and sets the date and time through the system I2C master (spec 7), and can then keep time with the 64-bit counter |
| T2 | Capture mode (save COUNT when an external pin changes), e.g. for measuring pulses on spare header pins |
| T3 | Should timers be able to start the copper (COPJMP), a sound channel or a blitter job? (Version 1 could start a DMA engine channel; that went with the channels, spec 11) |

## 9. Tests

- **Time counter:** reading during a carry from the low to the high half always gives a consistent value.
- **Rates:** each source and several PRESCALE values; repeating and one-shot; RELOAD changes take effect at the next underflow only.
- **Chaining:** timers 0 and 1 chained as a 64-bit timer.
- **Interrupts:** each timer raises its own vector.
- **Watchdog:** expiry resets and sets RESETWHY.WATCHDOG; a wrong kick value resets at once; LOCK blocks changes until reset; the watchdog is off after reset.
