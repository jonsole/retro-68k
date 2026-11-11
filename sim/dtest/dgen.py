#!/usr/bin/env python3
"""Random test for the DMA engine (spec 11): Chip RAM contents and job
chains for the 4 channels, for dtest.s to start and dmodel.py to check.

    dgen.py OUTDIR [SEED]

Writes OUTDIR/ram.hex (Chip RAM at the start, $readmemh of 16-bit words)
and OUTDIR/jobs.json (each channel's jobs in order, for dmodel.py).

Each channel works in its own 256 KB of Chip RAM (sources in the first
half: B in the first 64 KB, mask images in the next; destinations in
the second half, except the overlapping copies), so the
channels can run in any order. The control table at 0x0F0000 tells
dtest.s what to start (keep in step with dtest.s):
  +0x00  channel 0's first descriptor (Chip RAM)
  +0x04  channel 1's first descriptor (the descriptor RAM)
  +0x08  channel 2's first descriptor (either)
  +0x0C  the DMXINT bits to expect at the end
  +0x10  channel 3's job registers (8 long words), started with RUN
  +0x40  long words of the descriptor RAM image, then the image
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmodel import encode  # noqa: E402

CTL = 0x0F0000
CHIPDESC = 0x0F1000                  # descriptors in Chip RAM
DESCRAM = 0xE06000
REGION = 0x100000                    # channel n at REGION + n x 0x40000
CHECK = [0x0F0000, 0x200000]


def place(rng, lo, size, rows, stride, rowbytes):
    """A first-row address so every row lies in [lo, lo + size)."""
    span_lo = min(0, (rows - 1) * stride)
    span_hi = max(0, (rows - 1) * stride) + rowbytes
    a_lo = lo - span_lo
    a_hi = lo + size - span_hi
    return rng.randrange(a_lo, a_hi)


MINTERMS = [0xCC, 0xCC, 0xCA, 0xEE, 0x88, 0x66, 0x22, 0x55, 0x00, 0xFF, 0x0A]


def make_job(rng, area, kind=None):
    """A random job. kind: None, 'KEY' (cookie-cut with a key colour),
    'MASK' (a 1 bpp mask image), 'ADD' or 'C' (a minterm that reads C)."""
    b = rng.choice([1, 2, 4, 8, 8])
    ppb = 8 // b
    if b == 8 and rng.random() < 0.25:
        w, h = rng.randrange(1, 700), 1                    # a linear job
    else:
        w = rng.randrange(1, 90 if b == 8 else 200)
        h = rng.randrange(1, 9)
    bbit = rng.randrange(ppb) if b < 8 else 0
    dbit = rng.randrange(ppb) if b < 8 else 0
    abit = rng.randrange(8)
    brow = (bbit * b + w * b + 7) // 8
    drow = (dbit * b + w * b + 7) // 8
    arow = (abit + w + 7) // 8
    j = {"op": "BLIT", "bpp": b, "width": w, "height": h, "abit": abit, "bbit": bbit, "dbit": dbit,
         "desc": int(rng.random() < 0.3), "value": rng.getrandbits(32), "sat": 0, "signed": 0,
         "minterm": rng.choice(MINTERMS) if rng.random() < 0.7 else rng.getrandbits(8),
         "mask": rng.choice([0, 0, 1, 2]), "bkind": "value" if rng.random() < 0.25 else "mem"}
    if kind == "ADD" or (kind is None and rng.random() < 0.15):
        j["op"] = "ADD"
        j["sat"], j["signed"] = rng.randrange(2), rng.randrange(2)
    if kind == "KEY":
        j["mask"], j["minterm"], j["bkind"] = 2, 0xCA, "mem"
    if kind == "MASK":
        j["mask"] = 1
        j["minterm"] = rng.choice([0xCA, 0x0A, 0xE2, rng.getrandbits(8)])
    if kind == "C":
        j["minterm"] = rng.choice([0x66, 0x88, 0xEE, 0x55])
    if j["mask"] == 2:
        j["value"] = 0 if rng.random() < 0.7 else rng.getrandbits(8)
    ss = rng.choice([1, 1, 1, -1]) * (max(brow, arow) + rng.randrange(0, 24))
    if rng.random() < 0.1:
        ss = 0                                             # the same source row every time
    ds = rng.choice([1, 1, 1, -1]) * (drow + rng.randrange(0, 24))
    j["abstride"], j["cdstride"] = ss, ds
    j["bpt"] = place(rng, area, 0x10000, h, ss, brow)
    j["apt"] = place(rng, area + 0x10000, 0x10000, h, ss, arow)
    j["dpt"] = place(rng, area + 0x20000, 0x20000, h, ds, drow)
    return j


def make_overlap(rng, area):
    """A copy whose source and destination overlap: DESC when the
    destination is after the source, forwards when before."""
    b = rng.choice([1, 2, 4, 8])
    ppb = 8 // b
    w = rng.randrange(8, 120)
    h = rng.randrange(1, 6)
    bit = rng.randrange(ppb) if b < 8 else 0
    row = (bit * b + w * b + 7) // 8
    stride = row + rng.randrange(0, 8)
    delta_px = rng.choice([1, 2, 3, 5, 17, 40]) * rng.choice([1, -1])
    src = area + 0x30000 + rng.randrange(0, 0x1000)
    dpix = bit + delta_px
    dst = src + (dpix * b) // 8
    dbit = (dpix * b % 8) // b
    if delta_px > 0 and rng.random() < 0.5:                # a whole row down, too
        dst += stride
    after = (dst, dbit) > (src, bit)
    return {"op": "BLIT", "minterm": 0xCC, "mask": 0, "bpp": b, "width": w, "height": h,
            "abit": 0, "bbit": bit, "dbit": dbit, "desc": int(after), "bkind": "mem", "value": 0,
            "abstride": stride, "cdstride": stride, "apt": 0, "bpt": src, "dpt": dst}


def main():
    out = sys.argv[1]
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 11)
    mem = bytearray(0x200000)
    for a in range(CHECK[0], CHECK[1]):
        mem[a] = 0 if rng.random() < 0.25 else rng.getrandbits(8)
    for a in range(CTL, CHIPDESC + 0x7000):
        mem[a] = 0

    channels = []
    for ch in range(4):
        area = REGION + ch * 0x40000
        jobs = [make_job(rng, area) for _ in range(7)]
        jobs.insert(rng.randrange(1, 7), make_overlap(rng, area))
        for kind in ("KEY", "MASK", "MASK", "ADD", "C"):
            jobs.insert(rng.randrange(1, len(jobs)), make_job(rng, area, kind))
        z = make_job(rng, area)
        z["width"] = 0                                     # a job that does nothing
        jobs.insert(rng.randrange(1, len(jobs)), z)
        channels.append(jobs)

    def wl(a, v):
        mem[a:a + 4] = v.to_bytes(4, "big")

    dram = [0] * 512
    chip_next = [CHIPDESC]
    dram_next = [0]

    def chip_slot():
        a = chip_next[0]
        chip_next[0] += 32
        return a

    def dram_slot(ch):
        i = (0 if ch == 1 else 32) + dram_next[0] % 32
        dram_next[0] += 1
        return DESCRAM + 32 * i

    expect = 0
    for ch, jobs in enumerate(channels):
        if ch == 1:
            dram_next[0] = 0
        if ch == 2:
            dram_next[0] = 0
        # where each job's descriptor goes (channel 3's first is in its registers)
        homes = []
        for i in range(len(jobs)):
            if ch == 3 and i == 0:
                homes.append(None)
            elif ch == 0 or ch == 3:
                homes.append(chip_slot())
            elif ch == 1:
                homes.append(dram_slot(1))
            else:
                homes.append(dram_slot(2) if i % 2 else chip_slot())
        mid = rng.randrange(1, len(jobs) - 1)
        for i, j in enumerate(jobs):
            nxt = homes[i + 1] if i + 1 < len(jobs) else 0
            irq = int(i == len(jobs) - 1 or i == mid)
            words = encode(j, nxt, irq)
            h = homes[i]
            if h is None:
                for k, v in enumerate(words):
                    wl(CTL + 0x10 + 4 * k, v)
            elif h >= DESCRAM:
                for k, v in enumerate(words):
                    dram[(h - DESCRAM) // 4 + k] = v
            else:
                for k, v in enumerate(words):
                    wl(h + 4 * k, v)
        expect |= 1 << ch
        if ch < 3:
            wl(CTL + 4 * ch, homes[0])
    wl(CTL + 0x0C, expect)
    wl(CTL + 0x40, 512)
    for k, v in enumerate(dram):
        wl(CTL + 0x44 + 4 * k, v)

    with open(os.path.join(out, "ram.hex"), "w", newline="\n") as f:
        f.write("@%x\n" % (CTL // 2))
        for a in range(CTL, CHECK[1], 2):
            f.write("%04x\n" % ((mem[a] << 8) | mem[a + 1]))
    with open(os.path.join(out, "jobs.json"), "w", newline="\n") as f:
        json.dump({"check": CHECK, "channels": channels}, f, indent=1)
    print("dgen: %d jobs on 4 channels" % sum(len(c) for c in channels))


if __name__ == "__main__":
    main()
