#!/usr/bin/env python3
"""Reference model of the video (spec 4) and the sprites (spec 9): renders a frame from the video
state the testbench dumped and the Chip RAM contents, and compares it pixel
by pixel with the frame the simulation showed.

    vmodel.py BUILD_DIR RAM.hex [OUT.png]

BUILD_DIR holds frame.ppm, vstate_regs.txt, vstate_spr.txt (every write to
the sprites' registers, with the frame and beam position), vstate_lay.txt
(the same for the layers' registers) and vstate_pal.hex. Exits 1 on any
difference, or if a layer ran out of data (VIDSTAT.OVERRUN).

Writes to the layers' registers while they are drawn (a copper's) are
replayed by their timing in spec 4, section 5.4. Where the spec gives a
range rather than a point, every placement it allows is tried and the line
must match one of them exactly:
  - CTRL's depth and PLANAR, BPLDMA, and a pointer: from the next group the
    fetch starts, which is the next or the one after the next group past
    the one the beam is in (a pointer write is modelled a group at a time,
    exact for 1-word groups);
  - TRANSP and PALOFS: from the next pixel, PIX_EARLY to PIX_LATE pixels
    from the logged beam, with one pixel of any mix of the old and new bits;
  - EN, VSCALE, the window and SCROLLX: from the next line.
A pointer written after the layer's last fetch on a line starts the next
line as written; one written before it gets BPLSTRIDE added at the line's
end (layer_fetch revision 4). HSCALE changed mid-line is not modelled.

    vmodel.py BUILD_DIR RAM.hex [OUT.png] [--live]

--live: the screen must show each kind of live change (the ctl screen).
"""
import sys


def load_ram(path):
    ram, a = {}, 0
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line[0] == "@":
            a = int(line[1:], 16)
        else:
            ram[a] = int(line, 16)
            a += 1
    return ram


def load_state(d):
    regs, layers, bpt, pdma, dat, sprites, lctrl = {}, [], {}, {}, {}, [], {}
    for line in open(d + "/vstate_regs.txt"):
        f = line.split()
        if f[0] == "layer":
            kv = dict(zip(f[2::2], (int(x) for x in f[3::2])))
            layers.append(kv)
        elif f[0] == "bpt":
            bpt[int(f[1])] = int(f[2])
        elif f[0] == "lctrl":
            lctrl[int(f[1])] = int(f[2])
        elif f[0] == "bpldma":
            pdma[int(f[1])] = int(f[2])
        elif f[0] == "dat":
            dat[int(f[1])] = int(f[2])
        elif f[0] == "sprite":
            sprites.append(dict(zip(f[2::2], (int(x) if x.isdigit() else 0 for x in f[3::2]))))
        else:
            regs[f[0]] = int(f[1])
    pal = [int(l, 16) & 0xFFFFFF for l in open(d + "/vstate_pal.hex")]
    regs["pdma"], regs["dat"], regs["sprites"], regs["lctrl"] = pdma, dat, sprites, lctrl
    try:
        regs["sprlog"] = [tuple(int(x) for x in l.split()) for l in open(d + "/vstate_spr.txt") if l.strip()]
    except FileNotFoundError:
        regs["sprlog"] = []
    try:
        regs["laylog"] = [tuple(int(x) for x in l.split()) for l in open(d + "/vstate_lay.txt") if l.strip()]
    except FileNotFoundError:
        regs["laylog"] = []
    return regs, layers, bpt, pal


def load_ppm(path):
    t = open(path).read().split()
    assert t[0] == "P3"
    w, h = int(t[1]), int(t[2])
    v = list(map(int, t[4:]))
    return w, h, [(v[i] << 16) | (v[i + 1] << 8) | v[i + 2] for i in range(0, len(v), 3)]


def widen(v, d):
    top = (v << (8 - d)) & 0xFF
    r, k = top, 1
    while k * d < 8:
        r |= top >> (k * d)
        k += 1
    return r


X0, Y0 = 144, 49                                  # the picture's first pixel and line, in beam coordinates

# Live layer writes (spec 4, section 5.4). Each write is logged with the
# beam as the memory side saw it (BEAMPOS), about a pixel behind the beam.
LAG = 1
# A TRANSP or PALOFS write shows from the next pixel: from the logged pixel
# + PIX_EARLY to + PIX_LATE (the copper's own delay is in the log; this
# allows for the beam sample's lag and the crossing to the pixel clock).
# The pixel where it changes may show a mix of the old and new bits.
PIX_EARLY, PIX_LATE = -1, 8
# Writes this close to a line's start (beam pixels) are not modelled: the
# line's settings and its first groups are being taken then
START_ZONE = 30

F_GROUP = 0x00F0002E      # CTRL fields a group takes at its start: PLANAR, BPP, PLANES (and WRAP, read on each move)
F_HS = 0x000000C0         # HSCALE: per group as well, but the line's group count is fixed at its start (not modelled)
F_PIX = 0x0000F010        # TRANSP, PALOFS: from the next pixel
F_LINE = 0x00000301       # EN, VSCALE: from the next line


class NotModelled(Exception):
    pass


def depth_of(c):
    """Words a group - 1: planes - 1 (planar), bits a pixel - 1 (chunky)."""
    return ((c >> 16) & 7) if (c >> 1) & 1 else (1 << ((c >> 2) & 3)) - 1


def wmask_of(c):
    wr = (c >> 20) & 15
    return (1 << (wr + 9)) - 1 if wr else 0x7FFFFF        # CTRL.WRAP: only these bits move


def wadd(a, d, m):
    return (a & ~m) | ((a + d) & m)


def submasks(m):
    """Every non-zero subset of the bits of m."""
    s, out = m, []
    while s:
        out.append(s)
        s = (s - 1) & m
    return out


def merge_ptr(old, val, be):
    v = old
    if be & 4:
        v = (v & ~0x7F0000) | (val & 0x7F0000)
    if be & 2:
        v = (v & ~0xFF00) | (val & 0xFF00)
    if be & 1:
        v = (v & ~0xFE) | (val & 0xFE)
    return v & 0x7FFFFE


def layer_events(regs, F, H):
    """The frame's writes to the layers' registers, by picture line: line y
    holds those from its fetch's start (beam line y + Y0) to the next
    line's. Writes before line 0 are in the state the testbench took at
    line 0; those after the picture don't matter."""
    ev = [[] for _ in range(H)]
    for i, (fr, bl, bp, n, off, val, be) in enumerate(regs["laylog"]):
        if fr != F or bl < Y0 or bl >= Y0 + H:
            continue
        if bp < START_ZONE:
            raise NotModelled("a write to layer %d at beam (%d, %d), too close to the line's start" % (n, bl, bp))
        ev[bl - Y0].append((bp - X0, i, n, off, val, be))
    return ev


class LayerState:
    def __init__(self, L, n, regs, bpt, ctrl0):
        self.n = n
        self.ctrl = ctrl0
        self.xs, self.xe, self.ys, self.ye, self.sx = L["xs"], L["xe"], L["ys"], L["ye"], L["sx"] & 15
        self.mod = L["mod"]
        self.pm = regs["pdma"].get(n, 0xFF)
        self.dat = [regs["dat"].get(8 * n + p, 0) for p in range(8)]
        self.start = [bpt[8 * n + p] for p in range(8)]
        self.used = [False] * 8
        self.vsub, self.adv = 0, False

    def copy(self):
        c = LayerState.__new__(LayerState)
        c.__dict__ = dict(self.__dict__)
        c.dat, c.start, c.used = list(self.dat), list(self.start), list(self.used)
        return c

    def key(self):
        return (self.ctrl, self.pm, tuple(self.start), tuple(self.used), tuple(self.dat), self.mod,
                self.xs, self.xe, self.ys, self.ye, self.sx)


def line_start(S, y, W, H):
    """The line-end resets (layer_fetch revision 4) and the line's settings."""
    stride = S.mod - 0x10000 if S.mod & 0x8000 else S.mod
    for p in range(8):
        if S.used[p]:
            S.start[p] = wadd(S.start[p], stride if S.adv else 0, wmask_of(S.ctrl))
            S.used[p] = False
    c = S.ctrl
    cx = lambda v: min(max(v - X0, 0), W)
    cy = lambda v: min(max(v - Y0, 0), H)
    xs = cx(S.xs)
    xe = max(cx(S.xe), xs)
    ys, ye = cy(S.ys), cy(S.ye)
    hs, vmax = (c >> 6) & 3, (1 << ((c >> 8) & 3)) - 1
    if ys <= y < ye:
        S.vsub = 0 if (y == ys or S.vsub == vmax) else S.vsub + 1
        S.adv = S.vsub == vmax
    act = (c & 1) and ys <= y < ye
    srcpix = (xe - xs + (1 << hs) - 1) >> hs
    dep = depth_of(c)
    en = (S.pm & ((1 << (dep + 1)) - 1)) if (c >> 1) & 1 else (S.pm & 1)
    ng = ((S.sx + srcpix + 15) >> 4) if act and en else 0
    return dict(xs=xs, xe=xe, hs=hs, act=act, ng=ng, sx=S.sx, ctrl=c,
                ddepth=(((c >> 16) & 7) + 1) if (c >> 1) & 1 else 1 << ((c >> 2) & 3))


def classify(S, LS, evs):
    """A layer's writes on one line, in order: each with its candidates.
    ('g', G list, apply) for a change from group G; ('p', [(j, mask)], old, new) for a change at pixel j."""
    out = []
    ng = LS["ng"]

    def gcands(x):
        if not LS["act"] or ng == 0:
            return [ng]
        x += LAG
        k = 0 if x < LS["xs"] else (LS["sx"] + ((x - LS["xs"]) >> LS["hs"])) >> 4
        return sorted({min(k + 1, ng), min(k + 2, ng)})

    for x, i, n, off, val, be in evs:
        if off == 0x00:
            old = S.ctrl
            new = merge(old, val, be) & 0xFFFFFF
            S.ctrl = new
            d = old ^ new
            if d & F_HS and LS["act"]:
                raise NotModelled("HSCALE changed mid-line")
            if d & F_GROUP:
                out.append(("g", gcands(x), ("ctrl", new), x))
            if d & F_PIX:
                diff = d & F_PIX
                lo, hi = x + PIX_EARLY, x + PIX_LATE
                if hi < LS["xs"] or lo >= LS["xe"] or not LS["act"]:
                    cands = [(lo, diff)]                       # outside the window: where doesn't matter
                else:
                    cands = [(j, m) for j in range(lo, hi + 1) for m in submasks(diff)]
                out.append(("p", cands, old & F_PIX, new & F_PIX, x))
        elif off in (0x04, 0x08, 0x0C):
            if off == 0x04:
                v = merge((S.xs << 16) | S.xe, val, be)
                S.xs, S.xe = (v >> 16) & 0x7FF, v & 0x7FF
            elif off == 0x08:
                v = merge((S.ys << 16) | S.ye, val, be)
                S.ys, S.ye = (v >> 16) & 0x7FF, v & 0x7FF
            elif be & 1:
                S.sx = val & 15
        elif off == 0x10:
            S.mod = merge(S.mod, val, be) & 0xFFFE              # read at the line's end
        elif off == 0x14:
            if be & 3 == 3:
                pm = (S.pm | (val & 0xFF)) if val & 0x8000 else (S.pm & ~val & 0xFF)
                S.pm = pm
                out.append(("g", gcands(x), ("pm", pm), x))
        elif 0x20 <= off < 0x40:
            out.append(("g", gcands(x), ("ptr", (off - 0x20) >> 2, val, be), x))
        elif 0x40 <= off < 0x60:
            if LS["act"] and LS["xs"] - 16 <= x + LAG < LS["xe"]:
                raise NotModelled("BPLxDAT written while the layer is shown")
            r = (off - 0x40) >> 2
            S.dat[r] = merge(S.dat[r], val, be) & 0xFFFF
    return out


def draw_line(S0, LS, ev, choice, word, W):
    """One candidate: the layer's row and its state after the line.
    S0 is the state at the line's start; choice picks one candidate per event."""
    S = S0.copy()
    gev = [(choice[i], e[2]) for i, e in enumerate(ev) if e[0] == "g"]
    pev = [(choice[i], e[2], e[3]) for i, e in enumerate(ev) if e[0] == "p"]
    for a, b in zip(gev, gev[1:]):
        if a[0] > b[0]:
            return None                                       # out of order: not a candidate
    gc, pm, run = LS["ctrl"], S0.pm, list(S.start)

    def apply(what):
        nonlocal gc, pm
        if what[0] == "ctrl":
            gc = what[1]
        elif what[0] == "pm":
            pm = what[1]
        else:
            _, p, val, be = what
            v = merge_ptr(run[p], val, be)                    # merged with the pointer as it is
            run[p] = S.start[p] = v
            S.used[p] = False
    groups, ei = [], 0
    for g in range(LS["ng"]):
        while ei < len(gev) and gev[ei][0] <= g:
            apply(gev[ei][1])
            ei += 1
        dep, planar, wm = depth_of(gc), (gc >> 1) & 1, wmask_of(gc)
        words = []
        if planar:
            for p in range(dep + 1):
                if (pm >> p) & 1:
                    words.append(word(run[p]))
                    run[p] = wadd(run[p], 2, wm)
                    S.used[p] = True
                else:
                    words.append(S.dat[p])
        else:
            for q in range(dep + 1):
                if pm & 1:
                    words.append(word(run[0]))
                    run[0] = wadd(run[0], 2, wm)
                    S.used[0] = True
                else:
                    words.append(S.dat[dep - q])
        groups.append((words, dep, planar))
    while ei < len(gev):
        apply(gev[ei][1])
        ei += 1
    S.pm = pm
    # TRANSP and PALOFS along the line
    pf0 = LS["ctrl"] & F_PIX

    def pfield(x):
        f = pf0
        for (j, m), old, new in pev:
            if x > j:
                f = new
            elif x == j:
                f = (f & ~m) | (new & m)
        return f
    row = [(False, 0, 0)] * W
    xs, xe, hs, sx = LS["xs"], min(LS["xe"], W), LS["hs"], LS["sx"]
    if LS["act"]:
        for x in range(xs, xe):
            s = sx + ((x - xs) >> hs)
            g, i = s >> 4, s & 15
            if g >= len(groups):
                continue
            words, dep, planar = groups[g]
            if planar:
                v = 0
                for p in range(dep + 1):
                    v |= ((words[p] >> (15 - i)) & 1) << p
            else:
                bpp = dep + 1
                bo = i * bpp
                v = (words[bo >> 4] >> (16 - bpp - (bo & 15))) & ((1 << bpp) - 1)
            f = pfield(x)
            idx = v if dep + 1 > 4 else (((f >> 12) & 15) * 16 + (v & 15))
            row[x] = (not ((f >> 4) & 1 and v == 0), idx, v)
    return row, S


def render(regs, layers, bpt, pal, ram, got):
    W, H = regs["hvis"], regs["vvis"]
    direct = (regs["vidcon"] >> 4) & 1
    share = (regs["vidcon"] >> 5) & 1
    # palette p's entry i (spec 4, section 4.6): p 0-2 a layer's, 3 the sprites';
    # with VIDCON.SHAREPAL everything uses PALETTE0
    col_of = lambda p, i: pal[(0 if share else p) * 256 + i]
    blankall = (regs["vidcon"] >> 2) & 1
    prio = regs["prio"]
    word = lambda a: ram.get((a & 0x7FFFFF) >> 1, 0)
    F = regs.get("frame", 0)
    events = layer_events(regs, F, H)
    st = [LayerState(L, n, regs, bpt, regs["lctrl"].get(n, L["ctrl"])) for n, L in enumerate(layers)]
    spr = render_sprites(regs, ram, W, H)        # [y][x] = list of (n, idx, depth), front first
    stats = regs["live"] = {"g": [], "p": [], "split": 0}

    def compose(y, rows):
        """The line's colours, and its collisions (spec 9, section 6)."""
        line, coll = [], 0
        for x in range(W):
            here = spr[y][x]
            if len(here) > 1:
                for n, _, _ in here:
                    coll |= 1 << n
            for l in range(3):
                if rows[l][0][x][0]:
                    for n, _, _ in here:
                        coll |= 1 << (8 * (l + 1) + n)
            if blankall and not direct:
                line.append(regs["bg"])
            elif direct:
                if here:
                    line.append(col_of(3, here[0][1]))    # sprites in front, SPRPALETTE colours
                    continue
                rgb = 0
                for n in range(3):
                    row, d = rows[n]
                    rgb = (rgb << 8) | widen(row[x][2], d)
                line.append(rgb)
            else:
                # back to front: DEPTH 3 sprites, back layer, DEPTH 2, middle, DEPTH 1, front, DEPTH 0
                col = regs["bg"]
                for p in (3, 2, 1, 0):
                    for n, idx, dep in reversed(here):
                        if dep == p:
                            col = col_of(3, idx)
                    if p > 0:
                        l = (prio >> (2 * (p - 1))) & 3
                        if l < 3:
                            op, idx, _ = rows[l][0][x]
                            if op:
                                col = col_of(l, idx)
                line.append(col)
        return line, coll

    coll, img = 0, []
    for y in range(H):
        cands = []                                   # per layer: [(row, depth, state, choice, ev)]
        for n, S in enumerate(st):
            LS = line_start(S, y, W, H)
            S0 = S.copy()
            ev = classify(S, LS, [e for e in events[y] if e[2] == n])
            lists = [[None]]
            for e in ev:
                lists = [c + [x] for c in lists for x in e[1]]
            opts = []
            for ch in lists:
                r = draw_line(S0, LS, ev, ch[1:], word, W)
                if r is not None:
                    # the registers as written (the pointers and their flags are the candidate's)
                    r[1].ctrl, r[1].xs, r[1].xe, r[1].ys, r[1].ye, r[1].sx, r[1].mod = \
                        S.ctrl, S.xs, S.xe, S.ys, S.ye, S.sx, S.mod
                    r[1].dat = list(S.dat)
                    opts.append((r[0], LS["ddepth"], r[1], ch[1:], ev, LS))
            cands.append(opts)
        # the candidate that matches the frame's line (the closest, if none does)
        want = got[y * W:(y + 1) * W]
        best, same = None, []
        for trio in ((c0, c1, c2) for c0 in cands[0] for c1 in cands[1] for c2 in cands[2]):
            line, lc = compose(y, [(c[0], c[1]) for c in trio])
            bad = sum(a != b for a, b in zip(line, want)) if len(want) == W else 0
            if best is None or bad < best[0]:
                best, same = (bad, line, lc, trio), [trio]
            elif bad == best[0]:
                same.append(trio)
        bad, line, lc, trio = best
        if bad == 0 and len({tuple(c[2].key() for c in t) for t in same}) > 1:
            raise NotModelled("line %d: candidates that look the same leave different pointers" % y)
        for n in range(3):
            st[n] = trio[n][2]
            ch, ev, LS = trio[n][3], trio[n][4], trio[n][5]
            for e, c in zip(ev, ch):
                if e[0] == "g" and LS["act"] and LS["ng"] > 0:
                    if c < LS["ng"]:                       # mid-line: 0 the next group, 1 the one after
                        stats["g"].append((y, n, e[2][0], c - e[1][0]))
                    elif e[2][0] == "ptr":
                        stats["split"] += 1
                elif e[0] == "p" and LS["act"] and len(e[1]) > 1:
                    stats["p"].append((y, n, c[0] - e[4]))
        coll |= lc
        img += line
    regs["coll_model"] = coll
    return W, H, img


def merge(old, new, be):
    """A write by bytes (spec 3, section 2)."""
    return sum((new if (be >> b) & 1 else old) & (0xFF << (8 * b)) for b in range(4))


def render_sprites(regs, ram, W, H):
    """Each visible pixel: the opaque sprites there, lowest number first.

    Replays the frame's writes to the sprites' registers (spec 9, section 3):
    a write acts from the next line (the line after next if it came at the
    very end of a line, after the settings were taken); a CTL write starts
    the sprite; the vertical blank stops every sprite. At the start of each
    line a running sprite whose window covers it shows, its image line
    moved on by YSTEP (not on its first line, or after a PT write). A
    sprite whose DMA is off (SPRDMA, logged as sprite 8) takes each line's
    words from those pushed through SPRxDAT since its CTL write, in order
    (the test keeps them ahead of the beam)."""
    word = lambda a: ram.get((a & 0x7FFFFF) >> 1, 0)
    grid = [[[] for _ in range(W)] for _ in range(H)]
    F = regs.get("frame", 0)
    R = [[0] * 6 for _ in range(8)]                # as written: PT, H, V, CTL, DAT, STEP
    sprdma = 0xFF                                   # after reset: all on
    def dma_write(cur, val, be):
        if be & 3 != 3:
            return cur
        return (cur | (val & 0xFF)) if val & 0x8000 else (cur & ~val & 0xFF)
    ev = []
    for i, (fr, line, h, n, r, val, be) in enumerate(regs["sprlog"]):
        if fr < F:
            if n == 8:
                sprdma = dma_write(sprdma, val, be)
            elif r != 4:
                R[n][r] = merge(R[n][r], val, be)
        elif fr == F:
            # all from the next line, so they stay in order (pushes after the CTL that empties the FIFO)
            ev.append((line + 1 if h < 836 else line + 2, i, n, r, val, be))
    ev.sort()
    run, pend, yf = [False] * 8, [False] * 8, [0] * 8
    fifo = [[] for _ in range(8)]                   # words pushed by hand, in order
    lst = [R[n][0] & 0x7FFFFE for n in range(8)]
    lim = lambda s: 0x800 if s == 0 else max(0x80, min(0x8000, s))
    j = 0
    for y in range(1, 625):                         # beam lines (the vertical blank stops every sprite at line 0)
        while j < len(ev) and ev[j][0] <= y:
            _, _, n, r, val, be = ev[j]
            j += 1
            if n == 8:
                sprdma = dma_write(sprdma, val, be)
                continue
            if r == 4:
                if be & 3 == 3 and not (sprdma >> n) & 1 and len(fifo[n]) < 32:
                    fifo[n].append(val & 0xFFFF)
                continue
            if r == 0:
                lst[n] = merge(lst[n], val, be) & 0x7FFFFE
                pend[n] = False
            else:
                R[n][r] = merge(R[n][r], val, be)
            if r == 3:
                run[n], pend[n] = True, False
                fifo[n] = []
        for n in range(8):
            if not run[n]:
                continue
            manual = not (sprdma >> n) & 1
            Hr, Vr, Cr, Sr = R[n][1], R[n][2], R[n][3], R[n][5]
            # beam coordinates: the line is beam pixels 0-863, the picture 144-863
            hs, he = min(Hr & 0x7FF, 864) - X0, ((Hr >> 16) & 0x7FF) - X0
            hs_c, xe = hs, max(min(he, 720), hs)
            vs, ve = Vr & 0x7FF, min((Vr >> 16) & 0x7FF, 625)
            b = (Cr >> 12) & 3
            lb = (2 if b == 3 else b) + 1
            bpp, ppw = 1 << lb, 16 >> lb
            depth, pal = (Cr >> 20) & 3, (Cr >> 24) & 15
            # the scale (spec 9, section 3.2): 5.11 source pixels per screen pixel
            xs, ys = lim(Sr & 0xFFFF), lim(Sr >> 16)
            srcf = -(-(he - hs) * xs // 2048) if he > hs else 0
            srcs = -(-(xe - hs_c) * xs // 2048) if xe > hs_c else 0
            wf = (srcf * bpp + 15) // 16
            wv = min((srcs * bpp + 15) // 16, wf) if srcs else 0
            if wv == 0 or not (vs <= y < ve):
                continue
            if pend[n]:
                s = yf[n] + (ys & 0x7FF)
                yf[n] = s & 0x7FF
                lst[n] = (lst[n] + ((ys >> 11) + (s >> 11)) * 2 * wf) & 0x7FFFFF
            else:
                yf[n] = 0
            pend[n] = True
            if y < Y0:
                continue
            if manual:
                words = fifo[n][:wv]
                del fifo[n][:wv]
            else:
                words = [word(lst[n] + 2 * k) for k in range(wv)]
            seq = []
            for w in words:
                seq += [(w >> (16 - bpp * (i + 1))) & bpp_mask(bpp) for i in range(ppw)]
            for x in range(max(hs_c, 0), min(xe, W)):
                i = (x - hs_c) * xs >> 11
                v = seq[i] if i < len(seq) else 0
                if v:
                    idx = v if bpp == 8 else (pal << 4) | (v & 15)
                    grid[y - Y0][x].append((n, idx, depth))
    return grid


def bpp_mask(b):
    return (1 << b) - 1


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    d, ramfile = args[0], args[1]
    regs, layers, bpt, pal = load_state(d)
    fw, fh, got = load_ppm(d + "/frame.ppm")
    try:
        W, H, want = render(regs, layers, bpt, pal, load_ram(ramfile), got)
    except NotModelled as e:
        print("vmodel: not modelled: %s" % e)
        sys.exit(1)
    errors = 0
    live = regs["live"]
    if live["g"] or live["p"] or live["split"]:
        offs = lambda l: ", ".join("%+d: %d" % (o, sum(1 for e in l if e[-1] == o)) for o in sorted({e[-1] for e in l}))
        print("vmodel: live writes: %d group changes mid-line (groups after the next: %s), %d pixel changes "
              "(pixels from the logged beam: %s), %d pointers written after the last fetch"
              % (len(live["g"]), offs(live["g"]), len(live["p"]), offs(live["p"]), live["split"]))
    if "--live" in sys.argv:
        kinds = {k for _, _, k, _ in live["g"]}
        if not ("ctrl" in kinds and "ptr" in kinds and live["p"] and live["split"]):
            print("vmodel: --live: a kind of live change is missing (the copper list went astray?)")
            errors += 1
    if (fw, fh) != (W, H):
        print("vmodel: frame is %dx%d, expected %dx%d" % (fw, fh, W, H))
        errors += 1
    else:
        for i in range(W * H):
            if got[i] != want[i]:
                if errors < 10:
                    print("vmodel: pixel (%d, %d) is %06x, expected %06x" % (i % W, i // W, got[i], want[i]))
                errors += 1
    if (regs["vidstat"] >> 4) & 15:
        print("vmodel: OVERRUN or SPRUNDER set: VIDSTAT %x" % regs["vidstat"])
        errors += 1
    # the sprite test's copper list ends by writing 0xC0DE to SPR7DAT: if the grabbed frame lacks it, the list went astray
    if regs["sprlog"] and not any(e[0] == regs.get("frame") and e[3] == 7 and e[4] == 4 and (e[5] & 0xFFFF) == 0xC0DE for e in regs["sprlog"]):
        print("vmodel: the copper list's end marker is missing from the frame")
        errors += 1
    if "sprcoll" in regs and regs["sprites"] and regs["sprcoll"] != regs["coll_model"]:
        print("vmodel: SPRCOLL is %08x, expected %08x" % (regs["sprcoll"], regs["coll_model"]))
        errors += 1
    if len(args) > 2:
        try:
            from PIL import Image
            im = Image.new("RGB", (W, H))
            im.putdata([((c >> 16) & 255, (c >> 8) & 255, c & 255) for c in want])
            im.save(args[2])
        except ImportError:
            pass
    print("vmodel: %d differences in %d x %d" % (errors, W, H))
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
