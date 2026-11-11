#!/usr/bin/env python3
"""Reference model of the DMA engine and blitter (spec 11): what a job does
to Chip RAM, pixel by pixel.

Used two ways:
  - as a library: dgen.py builds tests with run_job();
  - from the command line, to check a simulation:

        dmodel.py JOBS.json RAM_BEFORE.hex RAM_AFTER.hex

    JOBS.json lists each channel's jobs in order (the channels use separate
    memory, so the order between channels does not matter). RAM_BEFORE is
    the Chip RAM given to the simulation, RAM_AFTER what the testbench
    dumped at the end (both $readmemh files of 16-bit words). Exits 1 on any
    difference.

A job is a dict with the descriptor's fields, decoded:
  op ('BLIT', 'ADD'), minterm, mask (0 none, 1 image at apt, 2 key compare),
  sat, signed (ADD), bpp (1, 2, 4, 8), desc, bkind ('mem', 'value'),
  apt, abit, bpt, bbit, dpt, dbit, width, height, abstride, cdstride
  (signed), value.
Only Chip RAM sources and destinations are modelled here.
"""
import json
import sys

OPS = {"BLIT": 0, "ADD": 1}
KINDS = {"mem": 0, "port": 1, "value": 3}


def get_pix(mem, addr, pos, b):
    """Pixel pos (0 = most significant) of the byte at addr, b bits wide."""
    sh = 8 - b * (pos + 1)
    return (mem[addr] >> sh) & ((1 << b) - 1)


def put_pix(mem, addr, pos, b, v):
    sh = 8 - b * (pos + 1)
    m = ((1 << b) - 1) << sh
    mem[addr] = (mem[addr] & ~m & 0xFF) | ((v << sh) & m)


def locate(base, bit, i, b):
    """Byte address and pixel position of pixel i of a row starting at
    (base, bit)."""
    off = bit * b + i * b               # bits from the row's first byte
    return base + (off >> 3), (off & 7) // b


def value_pix(value, addr, b):
    """FILL's value (and the VALUE source) for the pixel at addr: at 8 bpp
    VALUE's byte addr mod 4, most significant first; below, its low b bits."""
    if b == 8:
        return (value >> (24 - 8 * (addr & 3))) & 0xFF
    return value & ((1 << b) - 1)


def add_pix(d, s, b, sat, signed):
    top = (1 << b) - 1
    if not sat:
        return (d + s) & top
    if not signed:
        return min(d + s, top)
    sx = lambda v: v - (1 << b) if v >> (b - 1) else v
    r = sx(d) + sx(s)
    r = max(-(1 << (b - 1)), min((1 << (b - 1)) - 1, r))
    return r & top


def minterm_pix(m, a, bv, c, b):
    """BLIT: each bit of the result is MINTERM's bit a*4 + b*2 + c, where a
    (the mask) is the same for every bit of the pixel."""
    r = 0
    for k in range(b):
        r |= ((m >> (a * 4 + ((bv >> k) & 1) * 2 + ((c >> k) & 1))) & 1) << k
    return r


def run_job(mem, j):
    """Apply one job to mem (a bytearray of Chip RAM), in the engine's order:
    forwards, or with DESC from the last pixel of the last row back to the
    first. Each source pixel is read just before its destination pixel is
    written, which is what the hardware gives for every overlap a job is
    allowed (spec 11, section 3: DESC when the destination is after the
    source)."""
    b, w, h = j["bpp"], j["width"], j["height"]
    if w == 0 or h == 0:
        return
    rows = range(h - 1, -1, -1) if j["desc"] else range(h)
    cols = range(w - 1, -1, -1) if j["desc"] else range(w)
    key = j["value"] & ((1 << b) - 1)
    for r in rows:
        arow = j["apt"] + r * j["abstride"]
        brow = j["bpt"] + r * j["abstride"]
        drow = j["dpt"] + r * j["cdstride"]
        for i in cols:
            da, dp = locate(drow, j["dbit"], i, b)
            if j["bkind"] == "mem":
                sa, sp = locate(brow, j["bbit"], i, b)
                s = get_pix(mem, sa, sp, b)
            else:                                       # VALUE
                s = value_pix(j["value"], da, b)
            if j["mask"] == 1:
                aa, ap = locate(arow, j["abit"], i, 1)
                a = get_pix(mem, aa, ap, 1)
            elif j["mask"] == 2:
                a = int(s != key)
            else:
                a = 1
            c = get_pix(mem, da, dp, b)
            if j["op"] == "ADD":
                v = add_pix(c, s, b, j["sat"], j["signed"]) if a else c
            else:
                v = minterm_pix(j["minterm"], a, s, c, b)
            put_pix(mem, da, dp, b, v)


def encode(j, nxt=0, irq=0):
    """The job as eight descriptor long words (spec 11, section 3)."""
    bppc = {1: 0, 2: 1, 4: 2, 8: 3}[j["bpp"]]
    ctrl = (OPS[j["op"]] | (j.get("sat", 0) << 4) | (j.get("signed", 0) << 5) | (bppc << 8)
            | (j["desc"] << 10) | (irq << 12) | (KINDS[j["bkind"]] << 13) | (j["mask"] << 17)
            | (j.get("minterm", 0) << 24))
    bpt = (j["bpt"] | (j["bbit"] << 24)) if j["bkind"] == "mem" else 0
    apt = (j["apt"] | (j["abit"] << 24)) if j["mask"] == 1 else 0
    return [ctrl, bpt, j["dpt"] | (j["dbit"] << 24), j["width"] | (j["height"] << 16), apt,
            ((j["abstride"] & 0xFFFF) << 16) | (j["cdstride"] & 0xFFFF),
            j.get("value", 0), nxt]


def load_hex(path, size=0x400000):
    mem, a = bytearray(size), 0
    for line in open(path):
        line = line.split("//")[0].strip()
        if not line:
            continue
        if line[0] == "@":
            a = int(line[1:], 16) * 2
        else:
            w = int(line, 16)
            if a + 1 < size:
                mem[a], mem[a + 1] = w >> 8, w & 0xFF
            a += 2
    return mem


def main():
    jobs = json.load(open(sys.argv[1]))
    mem = load_hex(sys.argv[2])
    got = load_hex(sys.argv[3])
    for ch in jobs["channels"]:
        for j in ch:
            run_job(mem, j)
    lo, hi = jobs.get("check", [0, len(mem)])
    errors = 0
    for a in range(lo, hi):
        if mem[a] != got[a]:
            if errors < 10:
                print("dmodel: byte %06x is %02x, expected %02x" % (a, got[a], mem[a]))
            errors += 1
    print("dmodel: %d jobs, %d differences in %06x-%06x"
          % (sum(len(c) for c in jobs["channels"]), errors, lo, hi))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
