#!/usr/bin/env python3
"""Random test for the rasteriser (spec 17): Chip RAM contents and chains of
LINE and TRI jobs, for rastest.s to start and rmodel.py to check.

    rgen.py OUTDIR [SEED]

Writes OUTDIR/ram.hex (Chip RAM at the start, $readmemh of 16-bit words)
and OUTDIR/jobs.json (the jobs in the order they run, for rmodel.py).

The jobs: one LINE and one TRI for every depth, stride sign and minterm
class (plain, through the pattern, with the old pixel, both, random); and
random ones. Points lie inside the window, just outside it, and far away.
They are shuffled into chains, which run one after another. A chain has
one clip window (the window is a register, not part of a descriptor) and
64 KB of Chip RAM; each job places its bitmap so the window lies inside
that area, at any byte address, with a stride of either sign. Some
windows reach into negative coordinates.

The control table at 0x0F0000 tells rastest.s what to start (keep in step
with rastest.s):
  +0x00  the number of chains
  +0x04  for each chain, 11 long words: RASCLIPMIN, RASCLIPMAX, then the
         first descriptor's address (START), or 0 and the first job's 8
         long words for the job registers (RUN)
"""
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from rmodel import encode  # noqa: E402

CTL = 0x0F0000
CHIPDESC = 0x0F1000                  # descriptors in Chip RAM
REGION = 0x100000                    # chain n's bitmaps in REGION + n x 0x10000
AREA = 0x10000
CHECK = [0x0F0000, 0x200000]
NCHAINS = 12

# minterm classes: D = B; A ? B : C (the pattern); B xor C (the old pixel);
# A ? 0 : C; anything
CLASSES = [lambda r: 0xCC, lambda r: 0xCA, lambda r: 0x66, lambda r: 0x0A, lambda r: r.getrandbits(8)]


def make_window(rng):
    """A chain's coordinate space (x0 .. x0 + w - 1, y0 .. y0 + h - 1) and
    its clip window inside it."""
    w, h = rng.randrange(40, 321), rng.randrange(20, 61)
    x0 = -rng.randrange(0, w + 50) if rng.random() < 0.3 else 0     # some windows at negative coordinates
    y0 = -rng.randrange(0, h + 20) if rng.random() < 0.3 else 0
    if rng.random() < 0.25:
        xa, xb, ya, yb = 0, w - 1, 0, h - 1                        # the whole space
    else:
        xa, xb = sorted((rng.randrange(w), rng.randrange(w)))
        ya, yb = sorted((rng.randrange(h), rng.randrange(h)))
    return {"x0": x0, "y0": y0, "w": w, "h": h,
            "clip": [x0 + xa, y0 + ya, x0 + xb, y0 + yb]}


def make_job(rng, area, win, tri=None, bpp=None, neg=None, cls=None):
    b = bpp or rng.choice([1, 2, 4, 8])
    xmin, ymin, xmax, ymax = win["clip"]
    far = rng.random() < 0.1

    def point(far_):
        if far_:
            return [rng.randrange(-3000, 3000), rng.randrange(-3000, 3000)]
        if rng.random() < 0.4:                             # inside the window
            return [rng.randrange(xmin, xmax + 1), rng.randrange(ymin, ymax + 1)]
        return [win["x0"] + rng.randrange(-20, win["w"] + 20), win["y0"] + rng.randrange(-20, win["h"] + 20)]

    j = {"tri": rng.randrange(2) if tri is None else tri,
         "bpp": b,
         "minterm": (rng.choice(CLASSES) if cls is None else CLASSES[cls])(rng),
         "value": rng.getrandbits(8),
         "pattern": 0xFFFF if rng.random() < 0.33 else rng.getrandbits(16),
         "nolast": rng.randrange(2),
         "p0": point(far), "p1": point(far), "p2": point(False),
         "clip": win["clip"]}
    if rng.random() < 0.08:                                # flat and tiny shapes
        j["p1"] = list(j["p0"]) if rng.random() < 0.5 else [j["p1"][0], j["p0"][1]]
    # the bitmap: rows at least as long as the coordinate space, either way up
    sign = rng.choice([1, 1, -1]) if neg is None else (-1 if neg else 1)
    stride = sign * ((win["w"] * b + 7) // 8 + rng.randrange(0, 24))
    offs = [y * stride + ((x * b) >> 3) for y in (ymin, ymax) for x in (xmin, xmax)]
    lo, hi = min(offs), max(offs) + 1                      # the window's bytes, from pixel (0, 0)'s
    j["dstride"] = stride
    j["dpt"] = rng.randrange(area - lo, area + AREA - hi + 1)
    return j


def main():
    out = sys.argv[1]
    rng = random.Random(int(sys.argv[2]) if len(sys.argv) > 2 else 17)
    mem = bytearray(0x200000)
    for a in range(CHECK[0], CHECK[1]):
        mem[a] = 0 if rng.random() < 0.25 else rng.getrandbits(8)
    for a in range(CTL, CHIPDESC + 0x7000):
        mem[a] = 0

    makers = []
    for tri in (0, 1):
        for b in (1, 2, 4, 8):
            for neg in (0, 1):
                for cls in range(len(CLASSES)):
                    makers.append((tri, b, neg, cls))
    makers += [()] * 136
    rng.shuffle(makers)

    wins = [make_window(rng) for _ in range(NCHAINS)]
    chains = [[] for _ in range(NCHAINS)]
    for i, args in enumerate(makers):
        n = i % NCHAINS
        chains[n].append(make_job(rng, REGION + n * AREA, wins[n], *args))

    # The first job after reset reads the old pixels and plots some. The
    # core does not reset the register that holds them, and a job that
    # never reads (a plain 8-bit line, say) would write unknown bits in
    # simulation (in hardware the bits cancel): the SRAM model counts those
    # as errors.
    first = chains[0][0]
    first.update(tri=0, minterm=0x66, nolast=0, p0=wins[0]["clip"][0:2], p1=wins[0]["clip"][2:4])

    def wl(a, v):
        mem[a:a + 4] = (v & 0xFFFFFFFF).to_bytes(4, "big")

    def pt(x, y):
        return ((x & 0xFFFF) << 16) | (y & 0xFFFF)

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
        ent = CTL + 4 + 44 * n
        c = wins[n]["clip"]
        wl(ent, pt(c[0], c[1]))
        wl(ent + 4, pt(c[2], c[3]))
        wl(ent + 8, 0 if run else homes[0])
        for i, j in enumerate(jobs):
            nxt = homes[i + 1] if i + 1 < len(jobs) else 0
            words = encode(j, nxt, int(rng.random() < 0.3), rng.getrandbits(24))
            h = ent + 12 if homes[i] is None else homes[i]
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
    print("rgen: %d jobs (%d lines, %d triangles) in %d chains"
          % (len(jobs), sum(1 - j["tri"] for j in jobs), sum(j["tri"] for j in jobs), NCHAINS))


if __name__ == "__main__":
    main()
