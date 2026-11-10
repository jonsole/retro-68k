#!/usr/bin/env python3
"""Reference model of the rasteriser (spec 17, section 5.3): what a job does
to Chip RAM, pixel by pixel. It follows the core's own definition
(fpga/retro-hw/docs/spec/raster.md, section 4.5).

Used two ways:
  - as a library: rgen.py builds descriptors with encode();
  - from the command line, to check a simulation:

        rmodel.py JOBS.json RAM_BEFORE.hex RAM_AFTER.hex

    JOBS.json lists the jobs in the order they ran. RAM_BEFORE is the Chip
    RAM given to the simulation, RAM_AFTER what the testbench dumped at the
    end (both $readmemh files of 16-bit words). Exits 1 on any difference.

A job is a dict with the job registers' fields, decoded:
  tri (0 LINE, 1 TRI), minterm, bpp (1, 2, 4, 8), value, pattern, nolast,
  p0, p1, p2 ([x, y], signed), dpt, dstride (signed),
and the clip window it ran under: clip = [xmin, ymin, xmax, ymax], signed.
"""
import json
import sys

AMASK = 0x3FFFFF                        # jobs reach Chip RAM: 22 address bits


def plot(mem, j, x, y, a):
    """Pixel (x, y) becomes minterm(a, the colour, the old pixel), if it is
    inside the window. Bit position n is bit 7 - (n mod 8) of byte n div 8."""
    xmin, ymin, xmax, ymax = j["clip"]
    if not (xmin <= x <= xmax and ymin <= y <= ymax):
        return
    bits = j["bpp"]
    pos = 8 * (j["dpt"] + y * j["dstride"]) + x * bits
    addr = (pos >> 3) & AMASK
    sh = 8 - (pos & 7) - bits
    msk = (1 << bits) - 1
    c = (mem[addr] >> sh) & msk
    b = j["value"] & msk
    d = 0
    for n in range(bits):
        d |= ((j["minterm"] >> (4 * a + 2 * ((b >> n) & 1) + ((c >> n) & 1))) & 1) << n
    mem[addr] = (mem[addr] & ~(msk << sh) & 0xFF) | (d << sh)


def line(mem, j):
    (x0, y0), (x1, y1) = j["p0"], j["p1"]
    xmin, ymin, xmax, ymax = j["clip"]
    # both ends beyond the same side: nothing is plotted (and the core skips the stepping)
    if (x0 < xmin and x1 < xmin) or (x0 > xmax and x1 > xmax) or (y0 < ymin and y1 < ymin) or (y0 > ymax and y1 > ymax):
        return
    dx, dy = abs(x1 - x0), abs(y1 - y0)
    sx = 1 if x1 >= x0 else -1
    sy = 1 if y1 >= y0 else -1
    xmajor = dx >= dy
    major, minor = max(dx, dy), min(dx, dy)
    err = major // 2
    x, y = x0, y0
    for i in range(major + 1):
        if not (j["nolast"] and i == major):
            plot(mem, j, x, y, (j["pattern"] >> (15 - (i % 16))) & 1)
        err -= minor
        if err < 0:
            err += major
            if xmajor:
                y += sy
            else:
                x += sx
        if xmajor:
            x += sx
        else:
            y += sy


def tri(mem, j):
    t, m, b = j["p0"], j["p1"], j["p2"]
    if m[1] < t[1]:                     # the core's three compare-and-swaps
        t, m = m, t
    if b[1] < m[1]:
        m, b = b, m
    if m[1] < t[1]:
        t, m = m, t
    (xt, yt), (xm, ym), (xb, yb) = t, m, b

    def slope(xa, ya, xc, yc):          # floor((xc - xa) x 65536 / (yc - ya))
        return ((xc - xa) * 65536) // (yc - ya) if yc > ya else 0

    sl, s1, s2 = slope(xt, yt, xb, yb), slope(xt, yt, xm, ym), slope(xm, ym, xb, yb)
    xmin, ymin, xmax, ymax = j["clip"]
    for y in range(max(yt, ymin), min(yb, ymax + 1)):      # rows outside the window plot nothing
        xl = xt * 65536 + sl * (y - yt)
        xs = xt * 65536 + s1 * (y - yt) if y < ym else xm * 65536 + s2 * (y - ym)
        left = (min(xl, xs) + 65535) >> 16                 # ceil(X / 65536)
        right = (max(xl, xs) + 65535) >> 16
        for x in range(max(left, xmin), min(right, xmax + 1)):
            plot(mem, j, x, y, 1)


def run_job(mem, j):
    """Apply one job to mem (a bytearray of Chip RAM)."""
    if j["tri"]:
        tri(mem, j)
    else:
        line(mem, j)


def encode(j, nxt=0, irq=0, junk=0):
    """The job as eight descriptor long words (spec 17, section 3). junk
    fills the reserved bits the rasteriser ignores (not RASCTRL's, which
    are an error)."""
    bppc = {1: 0, 2: 1, 4: 2, 8: 3}[j["bpp"]]
    ctrl = ((j["value"] & 0xFF) | (bppc << 8) | (irq << 12) | (j["tri"] << 16) | (j["nolast"] << 17)
            | (j["minterm"] << 24))

    def pt(p):
        return ((p[0] & 0xFFFF) << 16) | (p[1] & 0xFFFF)

    return [ctrl, pt(j["p0"]), pt(j["p1"]), pt(j["p2"]),
            (j["dpt"] & 0xFFFFFF) | ((junk & 0xFF) << 24),
            (j["dstride"] & 0xFFFF) | ((junk & 0xFFFF) << 16),
            (j["pattern"] & 0xFFFF) | (((junk >> 8) & 0xFFFF) << 16),
            nxt]


def load_hex(path, size=0x400000):
    mem, a = bytearray(size), 0
    for line_ in open(path):
        line_ = line_.split("//")[0].strip()
        if not line_:
            continue
        if line_[0] == "@":
            a = int(line_[1:], 16) * 2
        else:
            w = int(line_, 16)
            if a + 1 < size:
                mem[a], mem[a + 1] = w >> 8, w & 0xFF
            a += 2
    return mem


def main():
    jobs = json.load(open(sys.argv[1]))
    mem = load_hex(sys.argv[2])
    got = load_hex(sys.argv[3])
    for j in jobs["jobs"]:
        run_job(mem, j)
    lo, hi = jobs.get("check", [0, len(mem)])
    errors = 0
    for a in range(lo, hi):
        if mem[a] != got[a]:
            if errors < 10:
                print("rmodel: byte %06x is %02x, expected %02x" % (a, got[a], mem[a]))
            errors += 1
    print("rmodel: %d jobs, %d differences in %06x-%06x" % (len(jobs["jobs"]), errors, lo, hi))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
