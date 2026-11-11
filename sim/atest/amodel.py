#!/usr/bin/env python3
"""Check the audio test (atest.s) against a model of spec 6.

    amodel.py DIR RAM.hex

Reads DIR/audio.txt (one line per output sample, from the testbench with
+audio: left, right, and the number of 1s each DAC stream gave during the
sample before) and works out every output sample from the same channel
set-ups and sample data. They must match exactly. The DAC streams must
follow the output: averaged over 16 samples, within 1%.
"""
import sys

RATE = 250
S8, S16 = 0x40000, 0x41000
# channel: ctrl (bits16, nearest, oneshot), step, vol L, vol R, queue of (lc, len); the last block loops
CH = [
    dict(b16=0, nearest=0, oneshot=0, step=0x0B400, vl=64, vr=10, q=[(S8 + 1, 300), (S8 + 0x203, 61)]),
    dict(b16=1, nearest=0, oneshot=0, step=0x2C000, vl=20, vr=64, q=[(S16, 700), (S16 + 40, 600), (S16 + 200, 7)]),
    dict(b16=0, nearest=1, oneshot=1, step=0x10000, vl=64, vr=64, q=[(S8 + 0x100, 300)]),
    dict(b16=1, nearest=1, oneshot=0, step=0xFE666, vl=33, vr=64, q=[(S16 + 2, 1900), (S16 + 0x800, 900)]),
]


def load(path):
    mem, a = {}, 0
    for line in open(path):
        line = line.strip()
        if line.startswith("@"):
            a = int(line[1:], 16)
        elif line:
            mem[a] = int(line, 16)
            a += 1
    return mem


def s16(v):
    return v - 65536 if v & 0x8000 else v


def main():
    d, ram = sys.argv[1], load(sys.argv[2])
    word = lambda byte: ram.get((byte >> 1) & 0x1FFFFF, 0)

    def sample(ch, a):
        w = word(a)
        if ch["b16"]:
            return s16(w)
        return s16(((w >> 8) if a % 2 == 0 else (w & 255)) << 8)

    # The CPU's restarts (atest.s): channel 0's second start takes a new block
    RESTART = {0: (S8 + 0x400, 500)}
    STOPPABLE = (1, 3)              # AUDSTOP (1); DMACON off and on (3)
    for c in CH:
        c["qi"], c["starts"], c["on"] = 0, 0, False
        c["regs"], c["pos"] = c["q"][0], 0

    got = [tuple(map(int, l.split())) for l in open(d + "/audio.txt")]
    errors, outs = 0, []

    def err(msg):
        nonlocal errors
        if errors < 10:
            print("amodel: " + msg)
        errors += 1

    for t, (gl, gr, ol, orr, started, incl) in enumerate(got):
        accl = accr = 0
        for n, c in enumerate(CH):
            if started >> n & 1:
                if c["starts"] >= 1 and n in RESTART:
                    c["regs"] = RESTART[n]
                c["start"], c["len"] = c["regs"]
                c["pos"], c["on"] = 0, c["len"] != 0
                if c["starts"] == 0 and len(c["q"]) > 1:
                    c["regs"] = c["q"][1]       # the CPU queues the next block at once
                c["starts"] += 1
            played = bool(incl >> n & 1)
            if c["on"] and not played:
                if n in STOPPABLE:
                    c["on"] = False             # stopped by the CPU
                else:
                    err(f"sample {t}: channel {n} not played")
            if played and not c["on"]:
                err(f"sample {t}: channel {n} played after it stopped")
            if not c["on"]:
                continue
            ip, frac = c["pos"] >> 16, c["pos"] & 0xFFFF
            k = 2 if c["b16"] else 1
            s0 = sample(c, c["start"] + k * ip)
            if ip + 1 < c["len"]:
                s1 = sample(c, c["start"] + k * (ip + 1))
            elif c["oneshot"] or c["regs"][1] == 0:
                s1 = s0                         # no block to come
            else:
                s1 = sample(c, c["regs"][0])    # the join: the first sample of the block to come
            s = s0 if c["nearest"] else s0 + (((s1 - s0) * frac) >> 16)
            s = ((s + 32768) & 0xFFFF) - 32768
            accl += s * c["vl"]
            accr += s * c["vr"]
            # move on
            p = c["pos"] + c["step"]
            if (p >> 16) >= c["len"]:
                if c["oneshot"]:
                    c["on"] = False
                else:
                    p -= c["len"] << 16
                    c["start"], c["len"] = c["regs"]
                    if (p >> 16) >= c["len"]:
                        p &= 0xFFFF
                    c["on"] = c["len"] != 0
                    c["qi"] += 1
                    nxt = c["qi"] + 1
                    if nxt < len(c["q"]):
                        c["regs"] = c["q"][nxt]
            c["pos"] = p
        el, er = accl >> 8, accr >> 8
        outs.append((gl, gr, ol, orr))
        if (el, er) != (gl, gr):
            err(f"sample {t}: got ({gl}, {gr}), expected ({el}, {er})")

    for n, c in enumerate(CH):
        print(f"amodel: channel {n}: started {c['starts']} times, {c['qi']} block ends, "
              f"{'playing' if c['on'] else 'stopped'} at the end")
    if [c["starts"] for c in CH] != [2, 1, 1, 2] or CH[2]["on"] or CH[1]["on"]:
        err("the starts and stops are not the ones atest.s makes")

    # DAC: the 1s during sample t come from output t - 1; average 1/2 + x / 2^17
    dac_bad = 0
    for t in range(17, len(outs), 16):
        for side in (0, 1):
            x = sum(outs[u - 1][side] for u in range(t - 16, t)) / 16
            ones = sum(outs[u][2 + side] for u in range(t - 16, t)) / (16 * RATE)
            if abs(ones - (0.5 + x / 131072)) > 0.01:
                if dac_bad < 5:
                    print(f"amodel: DAC {'LR'[side]} at sample {t}: {ones:.4f} of 1s, expected {0.5 + x / 131072:.4f}")
                dac_bad += 1
    print(f"amodel: {len(got)} output samples, {errors} wrong; DAC: {dac_bad} bad windows")
    sys.exit(1 if errors or dac_bad or len(got) < 1000 else 0)


if __name__ == "__main__":
    main()
