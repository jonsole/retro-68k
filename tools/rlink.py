#!/usr/bin/env python3
"""rlink.py: the PC end of the USB serial link (shared spec "Monitor and
upload protocol", docs/spec/monitor.md, section 8).

The link code is also a library, imported by the debug bridge
(tools/rz80_bridge.py):

- CRC-32 and the 32-byte image header (monitor.md, section 5);
- the control commands BREAK, RESET and UPLOAD, and the escapes on every
  byte sent (serial spec, section 4);
- the upload frames and their replies (monitor.md, section 6);
- the transport frames with a channel byte (debug.md, section 2).

The link functions work on any object with write(bytes) and
read_some(timeout) -> bytes, so the same code runs over a serial port
(SerialLink below), over the bridge's own reader, or against a model.

Needs Python 3.8 or newer, and pyserial for a real port.
"""

import argparse
import os
import struct
import sys
import threading
import time
import zlib

# ---------------------------------------------------------------- constants

MAGIC = b"RIMG"
MACHINES = {"z80": b"Z80 ", "68k": b"68K "}
TARGETS = {"program": 0, "rom": 1, "resident": 2}
TARGET_NAMES = {0: "program", 1: "boot ROM image", 2: "resident image"}
HEADER_LEN = 32
MAX_PAYLOAD = 4096

# The PC's bytes are SLIP-style (serial spec, section 4): C0 c ~c is a
# control command, DB DC a data C0 and DB DD a data DB
CTL_END, CTL_ESC, CTL_ESC_END, CTL_ESC_ESC = 0xC0, 0xDB, 0xDC, 0xDD
CTL_BREAK, CTL_RESET, CTL_UPLOAD = 1, 2, 3

# Upload frames (monitor.md, section 6.2)
PING, HEADER, DATA, END, ABORT = 0, 1, 2, 3, 4
SYNC_PC = b"LF"       # every frame from the PC
SYNC_REPLY = b"LR"    # the loader's 5-byte replies
SYNC_MACHINE = b"LD"  # transport frames from the machine

REFUSALS = {
    1: "the machine is not this machine",
    2: "the header is bad",
    3: "the load address, size or entry is outside what the machine allows",
    4: "the image is too large for this target",
    5: "the target is not allowed now (ROMLOCK?)",
    6: "the image in memory does not match its CRC",
    7: "out of order",
    8: "stopped at the machine (Esc)",
}

READY_WAIT = 3.0
REPLY_WAIT = 2.0
TRIES = 5


class LinkError(Exception):
    """The machine did not answer (exit code 3)."""


class Refused(Exception):
    """The machine refused (exit code 2)."""

    def __init__(self, code, text=None):
        self.code = code
        super().__init__(text or REFUSALS.get(code, "refused, code %d" % code))


# ---------------------------------------------------------------- CRC, header

def crc32(data):
    return zlib.crc32(bytes(data)) & 0xFFFFFFFF


def make_header(image, machine=b"Z80 ", load=0, entry=None, target=0, phys=False):
    if entry is None:
        entry = load
    if isinstance(machine, str):
        machine = MACHINES[machine.lower()]
    body = MAGIC + machine + struct.pack(">BBHIIII", 1, target, 1 if phys else 0,
                                         load, entry, len(image), crc32(image))
    return body + struct.pack(">I", crc32(body))


class Image:
    """An image: the header's fields and the bytes after it."""

    def __init__(self, data, machine=b"Z80 ", load=0, entry=None, target=0, phys=False):
        self.data = bytes(data)
        self.machine = machine if isinstance(machine, bytes) else MACHINES[machine.lower()]
        self.load = load
        self.entry = load if entry is None else entry
        self.target = target
        self.phys = phys

    def header(self):
        return make_header(self.data, self.machine, self.load, self.entry, self.target, self.phys)

    def file_bytes(self):
        return self.header() + self.data

    @classmethod
    def parse(cls, blob):
        """An image file's bytes -> (Image, problems). Problems is a list of text."""
        problems = []
        if len(blob) < HEADER_LEN or blob[:4] != MAGIC:
            raise ValueError("not an image file (no RIMG header)")
        hdr = blob[:HEADER_LEN]
        version, target, flags, load, entry, size, icrc = struct.unpack(">BBHIIII", hdr[8:28])
        hcrc, = struct.unpack(">I", hdr[28:32])
        if version != 1:
            problems.append("version %d" % version)
        if crc32(hdr[:28]) != hcrc:
            problems.append("HCRC %08X bad" % hcrc)
        data = blob[HEADER_LEN:HEADER_LEN + size]
        if len(data) != size:
            problems.append("file has %d bytes of image, header says %d" % (len(data), size))
        elif crc32(data) != icrc:
            problems.append("ICRC %08X bad" % icrc)
        img = cls(data, hdr[4:8], load, entry, target, bool(flags & 1))
        img.hcrc, img.icrc = hcrc, icrc
        return img, problems

    def describe(self):
        mach = self.machine.decode("ascii", "replace").strip()
        if self.target == 1:
            where = "offset %X" % self.load
        else:
            where = "load %s%X, entry %X" % ("P" if self.phys else "", self.load, self.entry)
        return "%s, %s, %s, %d bytes" % (mach, TARGET_NAMES.get(self.target, "target %d" % self.target),
                                         where, len(self.data))


# ---------------------------------------------------------------- control commands

class Control(bytes):
    """A control command's bytes: a link sends them as they are."""


def control(cmd):
    return Control(bytes([CTL_END, cmd, cmd ^ 0xFF]))


def escape(data):
    """The bytes as they go on the wire: a control command as it is, any
    other data with C0 and DB escaped. Every link's write() calls this."""
    if isinstance(data, Control):
        return bytes(data)
    return bytes(data).replace(b"\xdb", b"\xdb\xdd").replace(b"\xc0", b"\xdb\xdc")


class Unescaper:
    """The machine's side, as serial.v does it with recognition on: feed(bytes)
    returns a list of data bytes (bytes) and control commands (int). Nothing
    is held back except a lone DB or a command's bytes."""

    def __init__(self):
        self.state = 0          # 0 data, 1 after DB, 2 after C0, 3 after C0 c
        self.cmd = 0

    def feed(self, data):
        out, run = [], bytearray()
        for b in bytes(data):
            if b == CTL_END:
                self.state = 2
            elif self.state == 0:
                if b == CTL_ESC:
                    self.state = 1
                else:
                    run.append(b)
            elif self.state == 1:
                run.append(0xC0 if b == CTL_ESC_END else 0xDB if b == CTL_ESC_ESC else b)
                self.state = 0
            elif self.state == 2:
                self.cmd = b
                self.state = 3
            else:
                self.state = 0
                if b == self.cmd ^ 0xFF and 1 <= self.cmd <= 3:
                    if run:
                        out.append(bytes(run))
                        run = bytearray()
                    out.append(self.cmd)
        if run:
            out.append(bytes(run))
        return out


# ---------------------------------------------------------------- frames

def upload_frame(ftype, seq, payload=b"", offset=0):
    """An upload frame (monitor.md, section 6.2)."""
    n = len(payload)
    body = struct.pack(">BBIHH", ftype, seq & 0xFF, offset, n, n ^ 0xFFFF) + bytes(payload)
    return SYNC_PC + body + struct.pack(">I", crc32(body))


def transport_frame(ftype, seq, channel, payload=b"", sync=SYNC_PC):
    """A transport frame (debug.md, section 2.1): the CHANNEL byte sits in OFFSET's first byte."""
    n = len(payload)
    body = struct.pack(">BBB3xHH", ftype, seq & 0xFF, channel, n, n ^ 0xFFFF) + bytes(payload)
    return sync + body + struct.pack(">I", crc32(body))


class Frame:
    __slots__ = ("sync", "type", "seq", "channel", "offset", "payload", "error", "raw")

    def __init__(self, sync, ftype, seq, offset, payload, error=None):
        self.sync = sync
        self.type = ftype
        self.seq = seq
        self.offset = offset
        self.channel = (offset >> 24) & 0xFF
        self.payload = payload
        self.error = error   # None, "crc" or "frame"
        self.raw = b""       # the frame's bytes as they came

    def __repr__(self):
        return "Frame(%r, type=%#x, seq=%d, ch=%d, %d bytes%s)" % (
            self.sync, self.type, self.seq, self.channel, len(self.payload),
            ", " + self.error if self.error else "")


class FrameParser:
    """Hunts for frames in a byte stream (debug.md 2.1, monitor.md 6.2).

    feed(data, now) returns a list of items: Frame objects for whole frames
    (with .error set for a bad CRC or a bad length field), and bytes for
    everything that was not part of a frame. A frame whose bytes stop for
    more than `timeout` seconds is dropped and its bytes given back as
    stray bytes. `syncs` are the SYNC values this parser takes; `replies`
    adds the loader's 5-byte LR reply, given as a tuple ("reply", status, seq, code).
    """

    def __init__(self, syncs=(SYNC_MACHINE,), replies=False, timeout=1.0, check_reserved=True):
        self.syncs = set(syncs)
        self.replies = replies
        self.timeout = timeout
        self.check_reserved = check_reserved
        self.buf = bytearray()
        self.last = 0.0

    def feed(self, data, now=None):
        now = time.monotonic() if now is None else now
        out = []
        if self.buf and now - self.last > self.timeout:
            # a frame cut short: give its first byte back and hunt again
            self._flush_partial(out)
        self.buf += data
        if data:
            self.last = now
        self._scan(out)
        return out

    def poll(self, now=None):
        """Drops a frame cut short once its time is up."""
        now = time.monotonic() if now is None else now
        out = []
        if self.buf and now - self.last > self.timeout:
            self._flush_partial(out)
            self._scan(out)
        return out

    def _flush_partial(self, out):
        # Everything held is stray: the partial frame was never finished.
        out.append(bytes(self.buf))
        self.buf.clear()

    def _could_start(self, i):
        """Is buf[i:] the start of a frame, as far as it goes?"""
        rest = self.buf[i:i + 2]
        if len(rest) == 1:
            return rest[0] == 0x4C
        return bytes(rest) in self.syncs or (self.replies and bytes(rest) == SYNC_REPLY)

    def _scan(self, out):
        buf = self.buf
        stray_from = 0
        i = 0
        while i < len(buf):
            if buf[i] != 0x4C or not self._could_start(i):
                i += 1
                continue
            if len(buf) - i < 2:
                break
            sync = bytes(buf[i:i + 2])
            if sync == SYNC_REPLY and self.replies:
                if len(buf) - i < 5:
                    break
                if i > stray_from:
                    out.append(bytes(buf[stray_from:i]))
                out.append(("reply", chr(buf[i + 2]), buf[i + 3], buf[i + 4]))
                i += 5
                stray_from = i
                continue
            if len(buf) - i < 12:
                break
            ftype, seq, offset, length, nlength = struct.unpack(">BBIHH", buf[i + 2:i + 12])
            bad_len = (length ^ 0xFFFF) != nlength or length > MAX_PAYLOAD
            if bad_len:
                if i > stray_from:
                    out.append(bytes(buf[stray_from:i]))
                fr = Frame(sync, ftype, seq, offset, b"", "frame")
                fr.raw = bytes(buf[i:i + 12])
                out.append(fr)
                i += 12
                stray_from = i
                continue
            total = 12 + length + 4
            if len(buf) - i < total:
                break
            body = bytes(buf[i + 2:i + 12 + length])
            crc, = struct.unpack(">I", buf[i + 12 + length:i + total])
            if i > stray_from:
                out.append(bytes(buf[stray_from:i]))
            err = None
            if crc32(body) != crc:
                err = "crc"
            elif self.check_reserved and ftype >= 0x10 and (offset & 0x00FFFFFF):
                err = "frame"
            fr = Frame(sync, ftype, seq, offset, body[10:], err)
            fr.raw = bytes(buf[i:i + total])
            out.append(fr)
            i += total
            stray_from = i
        # keep what may still become a frame; give back the rest
        keep_from = i if i < len(buf) else len(buf)
        if keep_from > stray_from:
            out.append(bytes(buf[stray_from:keep_from]))
        del buf[:keep_from]


# ---------------------------------------------------------------- links

class SerialLink:
    """A serial port as a link: write(bytes), read_some(timeout)."""

    def __init__(self, port):
        try:
            import serial  # pyserial
        except ImportError:
            raise SystemExit("rlink: pyserial is needed (pip install pyserial)")
        self.port = serial.Serial(port, 3000000, timeout=0.05)
        self.lock = threading.Lock()

    def write(self, data):
        with self.lock:
            self.port.write(escape(data))
            self.port.flush()

    def read_some(self, timeout):
        self.port.timeout = max(0.001, timeout)
        first = self.port.read(1)
        if not first:
            return b""
        waiting = self.port.in_waiting
        return first + (self.port.read(waiting) if waiting else b"")

    def close(self):
        self.port.close()


class TcpLink:
    """A raw byte stream over TCP as a link, for a simulation's FT232H model:
    exactly the bytes of the USB serial link, both ways, no framing."""

    def __init__(self, host, port):
        import socket
        self.sock = socket.create_connection((host, port), timeout=10)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        self.lock = threading.Lock()

    def write(self, data):
        with self.lock:
            self.sock.sendall(escape(data))

    def read_some(self, timeout):
        import socket
        self.sock.settimeout(max(0.001, timeout))
        try:
            data = self.sock.recv(65536)
        except socket.timeout:
            return b""
        if not data:
            raise OSError("the simulation closed the link")
        return data

    def close(self):
        self.sock.close()


def open_link(name):
    """`COM5` or `/dev/ttyUSB1` (a serial port), or `tcp:HOST:PORT` (a simulation)."""
    if name.startswith("tcp:"):
        host, _, port = name[4:].rpartition(":")
        return TcpLink(host or "127.0.0.1", int(port))
    return SerialLink(name)


def wait_ready(link, timeout=READY_WAIT, log=None):
    """Waits for the loader's ready line, `LOAD Z80 1`. Returns (machine, version)."""
    deadline = time.monotonic() + timeout
    text = b""
    while time.monotonic() < deadline:
        text += link.read_some(deadline - time.monotonic())
        while b"\n" in text:
            line, text = text.split(b"\n", 1)
            line = line.strip(b"\r ")
            at = line.find(b"LOAD ")
            parts = line[at:].split() if at >= 0 else []
            if len(parts) == 3 and parts[0] == b"LOAD" and parts[1] in (b"Z80", b"68K"):
                return (parts[1] + b" ")[:4], int(parts[2])
            if log and line:
                log(line.decode("ascii", "replace"))
    return None


def _reply(link, parser, seq, timeout):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        data = link.read_some(deadline - time.monotonic())
        for item in parser.feed(data):
            if isinstance(item, tuple) and item[0] == "reply" and item[2] == (seq & 0xFF):
                return item[1], item[3]
    return None


def send_frame(link, parser, frame, seq, tries=TRIES, wait=REPLY_WAIT):
    """Sends an upload frame until it is answered. Returns (status, code, resends)."""
    resends = 0
    for _ in range(tries):
        link.write(frame)
        r = _reply(link, parser, seq, wait)
        if r is None or r[0] in "CF":
            resends += 1
            continue
        return r[0], r[1], resends
    raise LinkError("no answer from the machine after %d tries" % tries)


def upload(link, image, action=1, reset=True, log=None):
    """Uploads an Image (monitor.md, section 6.4). Returns the frames sent again.

    reset: send UPLOAD first and wait for the ready line (with one PING after 3 s).
    Raises Refused or LinkError.
    """
    log = log or (lambda s: None)
    parser = FrameParser(syncs=(), replies=True)
    if reset:
        link.write(control(CTL_UPLOAD))
        log("UPLOAD sent")
    ready = wait_ready(link)
    if ready is None:
        link.write(upload_frame(PING, 0))
        ready = wait_ready(link)
    if ready is None:
        raise LinkError("the loader did not answer")
    machine, version = ready
    log("loader ready: %s, protocol %d" % (machine.decode().strip(), version))
    if machine != image.machine:
        raise Refused(1, "the image is for %s, the machine is %s" % (
            image.machine.decode().strip(), machine.decode().strip()))
    resends = 0
    status, code, n = send_frame(link, parser, upload_frame(HEADER, 0, image.header()), 0)
    resends += n
    if status == "R":
        raise Refused(code)
    log("header ok: " + image.describe())
    seq = 1
    for off in range(0, len(image.data), MAX_PAYLOAD):
        chunk = image.data[off:off + MAX_PAYLOAD]
        status, code, n = send_frame(link, parser, upload_frame(DATA, seq, chunk, off), seq)
        resends += n
        if status == "R":
            raise Refused(code)
        seq = (seq + 1) & 0xFF
    frames = (len(image.data) + MAX_PAYLOAD - 1) // MAX_PAYLOAD
    log("%d bytes in %d frame%s, %d sent again" % (len(image.data), frames, "" if frames == 1 else "s", resends))
    try:
        status, code, n = send_frame(link, parser, upload_frame(END, seq, bytes([action])), seq)
    except LinkError:
        raise LinkError("no answer to END: the program may already be running")
    if status == "R":
        raise Refused(code)
    return resends


# ---------------------------------------------------------------- command line

def _hex(s):
    s = s.strip()
    phys = s[:1] in "pP"
    if phys:
        s = s[1:]
    for p in ("0x", "0X", "$", "&"):
        if s.startswith(p):
            s = s[len(p):]
    return int(s, 16), phys


def _load_image(args, machine_default=None):
    with open(args.file, "rb") as f:
        blob = f.read()
    if blob[:4] == MAGIC and args.load is None:
        img, problems = Image.parse(blob)
        if problems:
            raise SystemExit("rlink: %s: %s" % (args.file, "; ".join(problems)))
        return img
    if args.load is None:
        raise SystemExit("rlink: %s is a raw binary: give --load" % args.file)
    load, phys = _hex(args.load)
    entry = _hex(args.entry)[0] if args.entry else load
    machine = getattr(args, "machine", None) or machine_default or "z80"
    return Image(blob, machine, load, entry, TARGETS[args.target], phys or args.phys)


def _terminal(link):
    """A plain terminal: Ctrl-] then r, b, q."""
    print("rlink: terminal (Ctrl-] then r RESET, b BREAK, q quit)", file=sys.stderr)
    stop = threading.Event()

    def reader():
        while not stop.is_set():
            data = link.read_some(0.1)
            if data:
                sys.stdout.write(data.decode("latin-1"))
                sys.stdout.flush()

    t = threading.Thread(target=reader, daemon=True)
    t.start()
    escape = False
    try:
        for ch in iter(lambda: sys.stdin.read(1), ""):
            if escape:
                escape = False
                if ch == "q":
                    break
                if ch == "r":
                    link.write(control(CTL_RESET))
                elif ch == "b":
                    link.write(control(CTL_BREAK))
                continue
            if ch == "\x1d":
                escape = True
                continue
            link.write(b"\r" if ch == "\n" else ch.encode("latin-1"))
    except KeyboardInterrupt:
        pass
    stop.set()


def main(argv=None):
    ap = argparse.ArgumentParser(prog="rlink.py", description="The USB serial link: upload, image files, control commands, terminal.")
    ap.add_argument("-p", "--port", default=os.environ.get("RLINK_PORT"))
    sub = ap.add_subparsers(dest="cmd", required=True)

    def image_opts(p, need_out=False):
        p.add_argument("file")
        p.add_argument("--load")
        p.add_argument("--entry")
        p.add_argument("--machine", choices=["z80", "68k"])
        p.add_argument("--target", choices=list(TARGETS), default="program")
        p.add_argument("--phys", action="store_true")
        if need_out:
            p.add_argument("-o", "--output", required=True)

    p = sub.add_parser("upload")
    image_opts(p)
    p.add_argument("--no-run", action="store_true")
    p.add_argument("--no-reset", action="store_true")
    p.add_argument("--term", action="store_true")
    p = sub.add_parser("image")
    image_opts(p, need_out=True)
    p = sub.add_parser("show")
    p.add_argument("file")
    for name in ("reset", "break", "uploadmode", "term"):
        sub.add_parser(name)
    p = sub.add_parser("type")
    p.add_argument("text", nargs="?")
    p.add_argument("-f", "--file")
    args = ap.parse_args(argv)

    try:
        if args.cmd == "show":
            with open(args.file, "rb") as f:
                img, problems = Image.parse(f.read())
            print("%s: RIMG v1, %s" % (args.file, img.describe()))
            print("HCRC %08X %s, ICRC %08X %s" % (
                img.hcrc, "bad" if any("HCRC" in p for p in problems) else "ok",
                img.icrc, "bad" if any("ICRC" in p or "file has" in p for p in problems) else "ok"))
            return 1 if problems else 0
        if args.cmd == "image":
            if args.load is None:
                raise SystemExit("rlink: image needs --load")
            if not args.machine:
                raise SystemExit("rlink: image needs --machine")
            img = _load_image(args)
            with open(args.output, "wb") as f:
                f.write(img.file_bytes())
            print("rlink: %s: %s" % (args.output, img.describe()))
            return 0
        if not args.port:
            raise SystemExit("rlink: no port: give -p PORT or set RLINK_PORT")
        link = open_link(args.port)
        if args.cmd in ("reset", "break", "uploadmode"):
            link.write(control({"reset": CTL_RESET, "break": CTL_BREAK, "uploadmode": CTL_UPLOAD}[args.cmd]))
            return 0
        if args.cmd == "term":
            _terminal(link)
            return 0
        if args.cmd == "type":
            text = open(args.file).read() if args.file else (args.text or "")
            link.write(text.replace("\r\n", "\n").replace("\n", "\r").encode("latin-1"))
            return 0
        if args.cmd == "upload":
            img = _load_image(args)
            log = lambda s: print("rlink: " + s, file=sys.stderr)
            if not args.no_reset:
                log("UPLOAD sent on %s" % args.port)
            upload(link, img, action=0 if args.no_run else 1, reset=not args.no_reset,
                   log=lambda s: None if s == "UPLOAD sent" else log(s))
            log("running at %X" % img.entry if not args.no_run else "loaded; at the monitor")
            if args.term:
                _terminal(link)
            return 0
    except Refused as e:
        print("rlink: refused: %s" % e, file=sys.stderr)
        return 2
    except LinkError as e:
        print("rlink: %s" % e, file=sys.stderr)
        return 3
    except (OSError, ValueError) as e:
        print("rlink: %s" % e, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
