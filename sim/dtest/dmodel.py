#!/usr/bin/env python3
"""Reference model of the blitter (spec 11, section 3.3): what a job does
to Chip RAM, pixel by pixel.

Used two ways:
  - as a library: dgen.py builds descriptors with encode();
  - from the command line, to check a simulation:

        dmodel.py JOBS.json RAM_BEFORE.hex RAM_AFTER.hex

    JOBS.json lists the jobs in the order they ran. RAM_BEFORE is the Chip
    RAM given to the simulation, RAM_AFTER what the testbench dumped at the
    end (both $readmemh files of 16-bit words). Exits 1 on any difference.

A job is a dict with the job registers' fields, decoded:
  minterm, mask (0 none, 1 the image at apt, 2 B against key), bpp (1, 2,
  4, 8), rtl, bconst, value (16 bits), key, width, height,
  apt, abit, bpt, bbit, dpt, dbit, astride, bstride, dstride (signed).
With rtl the pointers name each row's last pixel, as the registers do.
"""
import json
import sys

AMASK = 0x3FFFFF                        # jobs reach Chip RAM: 22 address bits


def get_bits(mem, pos, n):
    """n bits at bit position pos: bit 7 - (pos mod 8) of byte pos div 8 is
    the first, so positions run left to right through memory."""
    sh = 8 - (pos & 7) - n
    return (mem[(pos >> 3) & AMASK] >> sh) & ((1 << n) - 1)


def put_bits(mem, pos, n, v):
    sh = 8 - (pos & 7) - n
    m = ((1 << n) - 1) << sh
    a = (pos >> 3) & AMASK
    mem[a] = (mem[a] & ~m & 0xFF) | ((v << sh) & m)


def run_job(mem, j):
    """Apply one job to mem (a bytearray of Chip RAM), in the order the spec
    gives: the rows as the strides take them, each row's pixels left to
    right, or right to left with rtl."""
    bits = j["bpp"]
    for r in range(j["height"]):
        pd = 8 * (j["dpt"] + r * j["dstride"]) + j["dbit"] * bits
        pb = 8 * (j["bpt"] + r * j["bstride"]) + j["bbit"] * bits
        pa = 8 * (j["apt"] + r * j["astride"]) + j["abit"]
        for i in range(j["width"]):
            k = -i if j["rtl"] else i
            pos = pd + k * bits
            c = get_bits(mem, pos, bits)
            if j["bconst"]:
                # VALUE lies over every memory word: the pixel takes the
                # bits at its own place in its word
                b = (j["value"] >> (16 - (pos & 15) - bits)) & ((1 << bits) - 1)
            else:
                b = get_bits(mem, pb + k * bits, bits)
            if j["mask"] == 1:
                a = get_bits(mem, pa + k, 1)
            elif j["mask"] == 2:
                a = int(b != (j["key"] & ((1 << bits) - 1)))
            else:
                a = 1
            d = 0
            for n in range(bits):
                d |= ((j["minterm"] >> (4 * a + 2 * ((b >> n) & 1) + ((c >> n) & 1))) & 1) << n
            put_bits(mem, pos, bits, d)


def encode(j, nxt=0, irq=0):
    """The job as eight descriptor long words (spec 11, section 3)."""
    bppc = {1: 0, 2: 1, 4: 2, 8: 3}[j["bpp"]]
    ctrl = ((j["key"] & 0xFF) | (bppc << 8) | (j["rtl"] << 10) | (irq << 12) | (j["bconst"] << 13)
            | (j["mask"] << 17) | (j["minterm"] << 24))
    return [ctrl,
            (j["bpt"] & 0xFFFFFF) | (j["bbit"] << 24),
            (j["dpt"] & 0xFFFFFF) | (j["dbit"] << 24),
            j["width"] | (j["height"] << 16),
            (j["apt"] & 0xFFFFFF) | (j["abit"] << 24),
            ((j["bstride"] & 0xFFFF) << 16) | (j["dstride"] & 0xFFFF),
            ((j["astride"] & 0xFFFF) << 16) | (j["value"] & 0xFFFF),
            nxt]


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
    for j in jobs["jobs"]:
        run_job(mem, j)
    lo, hi = jobs.get("check", [0, len(mem)])
    errors = 0
    for a in range(lo, hi):
        if mem[a] != got[a]:
            if errors < 10:
                print("dmodel: byte %06x is %02x, expected %02x" % (a, got[a], mem[a]))
            errors += 1
    print("dmodel: %d jobs, %d differences in %06x-%06x" % (len(jobs["jobs"]), errors, lo, hi))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
