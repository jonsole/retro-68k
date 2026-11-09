#!/usr/bin/env python3
"""Picture data for the video test (vtest.s): random words in Chip RAM.

    vgen.py OUT.hex [--direct | --sprites | --ctl]

Writes a $readmemh file of 16-bit words (with @word-address lines) for the
testbench's +ram= option. The data is random, so every pixel of every layer
is a fresh test; the 8 bpp layer of the palette screen has many zero bytes,
to test transparency.
"""
import random
import sys


def main():
    out = sys.argv[1]
    direct = "--direct" in sys.argv
    sprites = "--sprites" in sys.argv
    ctl = "--ctl" in sys.argv
    rnd = random.Random(68000 + direct + 2 * sprites + 4 * ctl)
    mem = {}                                   # word address -> value

    def fill(start, nbytes, zero_bytes=0.0):
        for a in range(start, start + nbytes, 2):
            b = []
            for _ in range(2):
                b.append(0 if rnd.random() < zero_bytes else rnd.randrange(256))
            mem[a // 2] = (b[0] << 8) | b[1]

    if ctl:
        fill(0x100000, 328 * 576 + 64, 0.3)    # L0: 4 bpp, rows of 328 bytes
        fill(0x140000, 2 * 20 * 576 + 64, 0.3) # L1: 2 planes of 576 rows of 20 bytes ...
        fill(0x150000, 2 * 20 * 576 + 64, 0.3) # ... and the second picture, after the split
        fill(0x180000, 0x16000)                # L2: 1 bpp, rows of 96 bytes, and from L2_ALT ($18E000)
    elif sprites:
        fill(0x100000, 180 * 288 + 64, 0.3)    # L0: 4 bpp, rows of 180 bytes
        fill(0x140000, 3 * 40 * 300 + 64, 0.3) # L1: 3 planes of 300 rows of 40 bytes
        fill(0x180000, 0x9000, 0.3)            # the sprite images
    elif not direct:
        fill(0x100000, 0x10000)                # L0: 4 bpp, rows of 200 bytes, wrapping in this 64 KB block
        fill(0x140000, 5 * 48 * 300 + 64)      # L1: 5 planes of 300 rows of 48 bytes
        fill(0x1A0000, 96 * 33 + 64, 0.3)      # L2: 8 bpp, 33 rows of 96 bytes, 30% zeros
    else:
        fill(0x100000, 5 * 32 * 200 + 64)      # L0 red: 5 planes
        fill(0x140000, 256 * 200 + 64)         # L1 green: 8 bpp
        fill(0x180000, 4 * 22 * 200 + 64)      # L2 blue: 4 planes

    with open(out, "w") as f:
        last = None
        for wa in sorted(mem):
            if last is None or wa != last + 1:
                f.write("@%06x\n" % wa)
            f.write("%04x\n" % mem[wa])
            last = wa


if __name__ == "__main__":
    main()
