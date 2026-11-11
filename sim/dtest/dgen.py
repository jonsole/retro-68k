#!/usr/bin/env python3
"""Random test for the blitter (spec 11): Chip RAM contents and chains of
jobs, for dtest.s to start and dmodel.py to check.

    dgen.py OUTDIR [SEED]

Writes OUTDIR/ram.hex (Chip RAM at the start, $readmemh of 16-bit words)
and OUTDIR/jobs.json (the jobs in the order they run, for dmodel.py).

The jobs: one for every depth, mask kind, row direction (RTL) and stride
sign; random ones; copies whose source and destination overlap, in every
direction; and jobs of no width or height. They are shuffled into chains,
which run one after another. Sources are in the first half of a chain's
256 KB (B in the first 64 KB, mask images in the next) and destinations in
the second half, except for the overlapping copies.

The control table at 0x0F0000 tells dtest.s what to start (keep in step
with dtest.s):
  +0x00  the number of chains
  +0x04  for each chain, 9 long words: the first descriptor's address
         (START), or 0 and the first job's 8 long words for the job
         registers (RUN)
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from dmodel import encode  # noqa: E402

CTL = 0x0F0000
CHIPDESC = 0x0F1000                  # descriptors in Chip RAM
REGION = 0x100000                    # chain n's data at REGION + n x 0x40000
CHECK = [0x0F0000, 0x200000]
NCHAINS = 4

MINTERMS = [0xCC, 0xCC, 0xCA, 0xEE, 0x88, 0x66, 0x22, 0x55, 0x00, 0xFF, 0x0A]


def place(rng, lo, size, rows, stride, rowbytes):
    """A first-row address so every row lies in [lo, lo + size)."""
    span_lo = min(0, (rows - 1) * stride)
    span_hi = max(0, (rows - 1) * stride) + rowbytes
    return rng.randrange(lo - span_lo, lo + size - span_hi)


def last_pixel(addr, bit, w, b):
    """The row's last pixel, from its first at (addr, bit)."""
    off = (bit + w - 1) * b
    return addr + (off >> 3), (off & 7) // b


def make_job(rng, area, bpp=None, mask=None, rtl=None, neg=None):
    """A job with its source, mask and destination apart. bpp, mask, rtl and
    neg (rows bottom-up: negative strides) are random unless given."""
    b = bpp or rng.choice([1, 2, 4, 8, 8])
    ppb = 8 // b
    if b == 8 and rng.random() < 0.2:
        w, h = rng.randrange(1, 700), 1                    # one long row
    else:
        w = rng.randrange(1, 90 if b == 8 else 200)
        h = rng.randrange(1, 9)
    bbit, dbit, abit = rng.randrange(ppb), rng.randrange(ppb), rng.randrange(8)
    brow = (bbit * b + w * b + 7) // 8
    drow = (dbit * b + w * b + 7) // 8
    arow = (abit + w + 7) // 8
    j = {"bpp": b, "width": w, "height": h,
         "mask": rng.choice([0, 0, 1, 2]) if mask is None else mask,
         "rtl": rng.randrange(2) if rtl is None else rtl,
         "bconst": int(rng.random() < 0.25),
         "minterm": rng.choice(MINTERMS) if rng.random() < 0.7 else rng.getrandbits(8),
         "key": 0 if rng.random() < 0.7 else rng.getrandbits(8)}
    if mask:                                               # asked for: mostly a cut-out
        j["minterm"] = rng.choice([0xCA, 0xCA, 0x0A, 0xE2, rng.getrandbits(8)])
    if mask == 2:
        j["bconst"] = 0
    # the constant: a plain colour in every pixel, or a pattern
    j["value"] = rng.getrandbits(b) * (0xFFFF // ((1 << b) - 1)) if rng.random() < 0.5 else rng.getrandbits(16)
    sign = rng.choice([1, 1, 1, -1]) if neg is None else (-1 if neg else 1)
    j["bstride"] = sign * (brow + rng.randrange(0, 24))
    j["astride"] = sign * (arow + rng.randrange(0, 24))
    j["dstride"] = (rng.choice([1, 1, 1, -1]) if neg is None else sign) * (drow + rng.randrange(0, 24))
    if neg is None and rng.random() < 0.1:
        j["bstride"] = 0                                   # the same source row every time
    if neg is None and rng.random() < 0.1:
        j["astride"] = 0
    ba = place(rng, area, 0x10000, h, j["bstride"], brow)
    aa = place(rng, area + 0x10000, 0x10000, h, j["astride"], arow)
    da = place(rng, area + 0x20000, 0x20000, h, j["dstride"], drow)
    if j["rtl"]:
        ba, bbit = last_pixel(ba, bbit, w, b)
        da, dbit = last_pixel(da, dbit, w, b)
        aa, abit = last_pixel(aa, abit, w, 1)
    j.update(bpt=ba, bbit=bbit, apt=aa, abit=abit, dpt=da, dbit=dbit)
    return j


def make_overlap(rng, area, dx, dy):
    """A copy within one picture, the destination dx pixels to the right
    and dy rows below the source, worked in the direction that needs
    (spec 11, section 3.4): rows bottom-up when the destination is below,
    right to left when it is to the right in the same rows."""
    b = rng.choice([1, 2, 4, 8])
    w = rng.randrange(8, 120)
    h = rng.randrange(1, 6)
    sx = 64 + rng.randrange(8 // b)                         # the source's first pixel in its row
    stride = ((64 + 8 + w + 40) * b + 7) // 8 + 1 + rng.randrange(0, 8)
    base = area + 0x30000 + rng.randrange(0, 0x1000) + 2 * stride
    up = dy > 0 if dy else bool(rng.randrange(2))           # rows bottom-up
    rtl = dx > 0 if dy == 0 else bool(rng.randrange(2))
    row0 = h - 1 if up else 0
    px = w - 1 if rtl else 0

    def at(row, pix):
        return base + row * stride + ((pix * b) >> 3), ((pix * b) & 7) // b

    ba, bbit = at(row0, sx + px)
    da, dbit = at(row0 + dy, sx + dx + px)
    s = -stride if up else stride
    return {"minterm": 0xCC, "mask": 0, "bpp": b, "width": w, "height": h, "rtl": int(rtl), "bconst": 0,
            "value": 0, "key": 0, "astride": 0, "bstride": s, "dstride": s,
            "apt": 0, "abit": 0, "bpt": ba, "bbit": bbit, "dpt": da, "dbit": dbit}


def main():
    out = sys.argv[1]
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 11)
    mem = bytearray(0x200000)
    for a in range(CHECK[0], CHECK[1]):
        mem[a] = 0 if rng.random() < 0.25 else rng.getrandbits(8)
    for a in range(CTL, CHIPDESC + 0x7000):
        mem[a] = 0

    # (job maker, its arguments after the area)
    makers = []
    for b in (1, 2, 4, 8):
        for mask in (0, 1, 2):
            for rtl in (0, 1):
                for neg in (0, 1):
                    makers.append((make_job, (b, mask, rtl, neg)))
    makers += [(make_job, ())] * 40
    for dx, dy in ((1, 0), (-1, 0), (3, 0), (-5, 0), (17, 0), (-40, 0), (40, 0), (-17, 0),
                   (0, 1), (0, -1), (2, 2), (-3, 1), (5, -2), (-1, -1)):
        makers.append((make_overlap, (dx, dy)))
    rng.shuffle(makers)

    chains = [[] for _ in range(NCHAINS)]
    for i, (fn, args) in enumerate(makers):
        n = i % NCHAINS
        chains[n].append(fn(rng, REGION + n * 0x40000, *args))
    for n, (zw, zh) in enumerate(((1, 0), (0, 1), (1, 1))):  # jobs that do nothing, inside chains
        z = make_job(rng, REGION + n * 0x40000)
        if zw:
            z["width"] = 0
        if zh:
            z["height"] = 0
        chains[n].insert(rng.randrange(1, len(chains[n])), z)

    def wl(a, v):
        mem[a:a + 4] = v.to_bytes(4, "big")

    slot = CHIPDESC
    wl(CTL, NCHAINS)
    for n, jobs in enumerate(chains):
        run = n % 2 == 1                                   # odd chains: the first job by RUN
        homes = []
        for i in range(len(jobs)):
            if run and i == 0:
                homes.append(None)
            else:
                homes.append(slot)
                slot += 32 if rng.random() < 0.7 else 32 + 2 * rng.randrange(1, 9)   # even addresses
        ent = CTL + 4 + 36 * n
        wl(ent, 0 if run else homes[0])
        for i, j in enumerate(jobs):
            nxt = homes[i + 1] if i + 1 < len(jobs) else 0
            words = encode(j, nxt, int(rng.random() < 0.3))
            h = ent + 4 if homes[i] is None else homes[i]
            for k, v in enumerate(words):
                wl(h + 4 * k, v)
    assert slot < CHIPDESC + 0x7000

    with open(os.path.join(out, "ram.hex"), "w", newline="\n") as f:
        f.write("@%x\n" % (CTL // 2))
        for a in range(CTL, CHECK[1], 2):
            f.write("%04x\n" % ((mem[a] << 8) | mem[a + 1]))
    jobs = [j for c in chains for j in c]
    with open(os.path.join(out, "jobs.json"), "w", newline="\n") as f:
        json.dump({"check": CHECK, "jobs": jobs}, f, indent=1)
    print("dgen: %d jobs in %d chains" % (len(jobs), NCHAINS))


if __name__ == "__main__":
    main()
