# Shared spec: Monitor and upload protocol

Status: **draft**

This spec is shared by retro-z80 and retro68k. It is kept **word for word the same** in both repos, at `docs/spec/monitor.md`. It covers what both machines' boot ROMs do the same way: the monitor's commands and syntax, the upload protocol over the USB serial link, the image header used by uploads and by the boot file on the SD card, and the PC tool `tools/rlink.py`. What differs between the two CPUs (registers, address ranges, how a program calls the ROM, what a program inherits) is listed here in tables with a column for each machine, and given in full in each machine's own boot ROM spec (section 11).

retro-z80 wrote the first draft (its design plan, branch 16); retro68k reviews and adopts it.

## 1. Summary

| Item | Value |
|------|-------|
| Monitor | One-letter commands with hex arguments, on the screen and keyboard and on the USB serial console at once |
| Addresses | Hex, 1–8 digits. A plain address is a CPU address; a `P` in front makes it a physical address (section 3.2) |
| Access size | `.B`, `.W` or `.L` after the command letter; byte by default. Word and long accesses are checked for alignment where the CPU needs it, so the monitor never faults (section 3.3) |
| Commands | Dump, enter, fill, copy, compare, search, go, step, registers, ports, disassemble, memory test, upload, load and boot from SD, resident image, help (section 4) |
| Upload | Binary frames over the USB serial link, each with a length and a **CRC-32**; a reply to each frame: ok, CRC error, frame error or refused (section 6) |
| Image header | 32 bytes, big-endian: magic `RIMG`, machine (`Z80 ` or `68K `), target, flags, load address, entry point, size, image CRC-32, header CRC-32 (section 5) |
| Targets | 0 a program; 1 a **new boot ROM image** (written to the boot ROM with SYSCON.ROMWE, then a reset); 2 a resident image (a ROM image kept in RAM, for BASIC) |
| Boot file | The same header and image in a file on the SD card's FAT32 partition: `BOOT.Z80` or `BOOT.68K` (section 7) |
| Into the loader | The UPLOAD control command (each machine's serial spec) resets with RESETWHY.UPLOAD, and the loader then waits; or the `U` command; or the U key held at reset |
| Long reset press | Does nothing more than a short one on both machines: UPLOAD comes only from the PC |
| Start-up keys | M monitor, U upload, D development (boot ROM left writable) |
| PC tool | `tools/rlink.py`, the same file in both repos: uploads, makes image files, sends RESET, BREAK and UPLOAD, and is a terminal that types into the console (section 8) |

## 2. The monitor

### 2.1 Where it runs

- The monitor uses the boot console on the screen (80 × 30 text) and the USB serial console **at the same time**. Everything it prints goes to both. It reads keys from the machine's keyboards and bytes from the serial link, whichever comes first.
- Without a PC on the link, nothing waits: serial output is dropped (SERCON.TXDROP), and the screen and keyboard work alone.
- It runs with interrupts off and polls everything, so it works whatever state a stopped program left the interrupt controller in.
- If a watchdog is running (and locked on), the monitor kicks it while it waits and during long commands.

### 2.2 How it is entered

| Way in | The monitor says | Then |
|--------|------------------|------|
| Start-up: M (or the DivMMC button) held, or nothing else to start (section 9) | The sign-on lines | Prompt |
| A program returns, or calls the ROM's "exit" | `Program ended.` | Registers, prompt |
| A program calls the ROM's "break" | `Break at <addr>` | Registers, prompt; `G` goes on after the call |
| A breakpoint set by `G` is reached | `Breakpoint at <addr>` | Registers, prompt |
| A step by `N` is done | `Step at <addr>` | Registers, prompt; Enter steps again |
| NMI: the Multiface button, or BREAK from the PC | `NMI (button) at <addr>` or `NMI (USB) at <addr>` | Registers, prompt; `G` goes on where the program was |
| A trap: a CPU exception or a runaway program caught by the machine | `Trap <what> at <addr>` | Registers, prompt |

Each machine's spec says which instructions and exceptions make "break" and "trap" (section 11).

### 2.3 Sign-on, prompt and lines

```
retro-z80 boot ROM <version>  Z80 at 20 MHz, 4 MB SRAM
Reset: power-on.  Self-test ok.
Monitor.  H for help.
>
```

- The first line names the machine, the ROM version, the CPU, its speed and the RAM size. The second gives the reset cause (RESETWHY) and the self-test result.
- The prompt is `> ` at the start of a line.
- **Line editing:** typed characters are echoed; Backspace (or Delete from a terminal) rubs out; Enter runs the line; Esc drops it; Up brings back the last line.
- **Enter on an empty line** after `D`, `I`, `S` or `N` carries on from where the last one stopped: after `D`, another 80 (hex) bytes at the same size; after `I`, another 16 instructions; after `S`, the next 16 places, until the range has been searched to its end; after `N`, one more step. After any other command, or after an `S` that has reached the end, it does nothing.
- Upper or lower case, as you like. Spaces separate arguments; a comma also works.
- Output lines end with CR LF.
- An error prints `? ` and a short reason on its own line, and nothing is changed:

| Message | Meaning |
|---------|---------|
| `? syntax` | The line could not be read |
| `? address` | The address is outside what this machine allows for this command |
| `? alignment` | A word or long access at an odd address on a CPU that needs even ones |
| `? size` | A size this command or this address does not take |
| `? not on this machine` | A command or register this machine does not have |
| `? no link` | The command needs the USB serial link (only where the machine can tell) |
| `? no card`, `? no file`, `? bad image` | The SD card or file could not be used (section 7) |
| `? locked` | The boot ROM is write-protected (ROMLOCK) |
| `? not yet` | A command this machine's monitor does not have yet. Allowed only while a machine's monitor is incomplete; this line is removed once both monitors are complete |

## 3. Numbers, addresses and sizes

### 3.1 Numbers

- Numbers are **hex**, 1 to 8 digits, with no prefix: `8000`, `1F`, `00F80000`.
- A string in double quotes gives its bytes, for `E`, `F` and `S`: `"Hello"`.
- A count is a number of **bytes**, whatever the access size, and must be a whole number of items: `D.W 8000 20` shows 16 words.

### 3.2 Addresses

| Form | Meaning | retro-z80 | retro68k |
|------|---------|-----------|----------|
| `8000` | A **CPU address** | `0000`–`FFFF`, through the MMU windows the program had (each machine's spec) | `000000`–`FFFFFF`; up to 8 digits are accepted and bits 31–24 are ignored |
| `P1FC000` | A **physical address**: a `P` in front | The MMU's page space, `P000000`–`P7FFFFF` = page × `0x2000` + offset: SRAM `P000000`–`P3FFFFF`, the register page `P7F0000`–`P7F1FFF`, boot ROM `P7F8000`–`P7FFFFF` | The same as the CPU address (there is no MMU) |

- Addresses are shown with as many digits as the machine needs: 4 for a Z80 CPU address, 6 for a physical address or a 68000 address.
- Memory the machine forbids (where an access would hang or fault) gives `? address`.
- **Registers whose reads have side effects.** Each machine's spec lists the registers whose reads have side effects; D, S and V show `--` for them and C refuses them (`? address`). E and an explicit single read still reach them.

### 3.3 Access sizes

| Suffix | Size | retro-z80 | retro68k |
|--------|------|-----------|----------|
| none, `.B` | Byte | One byte access | One byte access |
| `.W` | Word, 2 bytes | Two byte accesses, low byte first; the value is little-endian, as the Z80 keeps it. Any address | One word access; the address must be even |
| `.L` | Long, 4 bytes | Four byte accesses, lowest first; little-endian. Any address | One long access (the 68000 makes it two word cycles, high word first); the address must be even |

- The monitor checks alignment **before** it touches memory, so an odd word or long address on the 68000 gives `? alignment` and never an address error.
- Values are shown and entered as numbers in the machine's own byte order: on both machines `E.W 8000 1234` makes the word at `8000` read back as `1234`.
- **Wide registers.** Each machine's registers have their own rules for wide values; the size picks the accesses that suit them:
  - retro-z80: a wide register's bytes are written low first, and an MMU page commits on its high byte, so `E.W` and `E.L` write registers as they need. Ports take only `.B`.
  - retro68k: a custom register is 32 bits, written as two 16-bit halves, high first, so changing one needs a long write: `E.L`.

## 4. Commands

### 4.1 The commands

`s` is an optional size (`.B`, `.W`, `.L`); square brackets mark optional arguments.

| Command | Syntax | What it does | retro-z80 | retro68k |
|---------|--------|--------------|-----------|----------|
| **D** dump | `Ds [addr [count]]` | Show memory, 16 bytes a line, as hex items and then as characters (`.` for codes below 32 and above 126). Count 80 (hex) bytes by default. No address: carry on | Yes | Yes |
| **E** enter | `Es addr [value ...]` | Write the values from addr on. With no values: step through, showing `addr: old` and reading a new value; Enter keeps the old one, `-` goes back one item, `.` or Esc ends | Yes | Yes |
| **F** fill | `Fs addr count value` | Fill count bytes with the value (or with a quoted string, repeated) | Yes | Yes |
| **C** copy | `C addr count dest` | Copy count bytes; overlapping ranges are copied correctly | Yes | Yes |
| **V** compare | `V addr count addr2` | Compare two ranges; list the first 16 differences, then how many there were | Yes | Yes |
| **S** search | `Ss addr count value ...` | Find a string of values or a quoted string; list the first 16 places. Enter carries on | Yes | Yes |
| **G** go | `G [addr [break]]` | Run from addr, or from PC as `R` shows it. With break, a breakpoint at that address (section 4.3) | Yes | Yes |
| **N** step | `N` | Run one instruction, then say `Step at <addr>` and show the registers and the prompt. Enter steps again | Yes | Yes |
| **R** registers | `R [name [value]]` | Show the program's registers; with a name, show that one; with a name and value, set it (section 4.2) | Yes | Yes |
| **P** ports | `P port [value]` | Read an I/O port, or write a byte to it | Yes: 16-bit ports, register (high byte) : page (low byte) | `? not on this machine` (no I/O space) |
| **I** disassemble | `I [addr [count]]` | Show count instructions (16 by default) from addr. No address: carry on | Yes | Optional (retro68k decides) |
| **T** memory test | `T [addr count]` | Test RAM with patterns, **destroying** its contents. No range: all RAM the monitor does not use itself (section 4.4) | Yes | Yes |
| **U** upload | `U` | Wait for an upload over the USB serial link (section 6). Esc on the keyboard goes back to the monitor | Yes | Yes |
| **L** load | `L [name]` | Load an image file from the SD card (section 7) without running it; PC is set to its entry point | Yes | Yes |
| **B** boot | `B [name]` | Load an image file from the SD card and run it. No name: the boot file | Yes | Yes |
| **X** resident | `X` | Start the resident image (BASIC), loading it from the SD card first if it is not in RAM (section 5.3) | Yes | Optional |
| **H**, **?** help | `H` | List the commands, one line each | Yes | Yes |

**What D, V and S print.** Addresses are shown at the machine's width (section 3.2: 4 or 6 digits, after a `P` for a physical address).

- **D** prints a line for each 16 bytes: the address, two spaces, the items, then the characters. Each item is 2, 4 or 8 hex digits (`.B`, `.W`, `.L`) and a space, with one more space after the eighth byte. The characters start **two spaces after the last item of a full line**, whatever the size. A shorter line (the last of a dump) is padded with spaces, so the characters are in the same column on every line of a dump.
- **V** prints each difference on a line of its own, `addr: xx  addr2: yy` (the byte in each range), for the first 16 differences; then `Differences: n`, the count in hex with at least 4 digits.
- **S** prints the places it finds, 8 to a line, each address followed by two spaces. After 16 places it prints `Enter for more.` and stops; Enter on an empty line goes on with the next 16 (section 2.3). If it reaches the end of the range without finding a place since the command or the last Enter, it prints `Not found.`

Letters not in the table (A, J, K, M, O, Q, W, Y, Z) are kept free. A command that only one machine needs takes one of them, and is listed in this table first, so the two monitors never give a letter two meanings.

### 4.2 Registers

`R` shows the **program's** registers: those of the program that was stopped, or those the next `G` will start with. Loading a program sets PC to its entry point and the other registers to the machine's defaults (each machine's spec). `R name` shows that one register, as the full display shows it. `R name value` sets one; `G` uses them all.

| | retro-z80 | retro68k |
|---|-----------|----------|
| Shown | AF BC DE HL IX IY SP PC, AF' BC' DE' HL', I R, IFF, IM, and the flags decoded | D0–D7, A0–A7, SR (and its flags decoded), PC, USP, SSP |
| Shown one at a time | `R HL` gives `HL=1234`; `R AF` also shows the flags decoded, as the full display does | `R D0` gives `D0=00001234`; `R SR` also shows the flags decoded, as the full display does |
| Set with | `R HL 1234`, `R AF' 0`, `R IFF 1`, `R IM 2` | `R D0 1234`, `R SR 2700`, `R PC 1000` |
| Limits | R is only roughly kept (it counts as the monitor runs). The Z80 cannot read its interrupt mode, so IM shows the mode the program was started in, with a `?` once the program has run (each machine's spec) | A7 is USP or SSP, as SR's S bit says |

### 4.3 Breakpoints

`G addr break` sets a breakpoint at break, then runs from addr. Each machine's spec says how (a break instruction written in, or a hardware breakpoint) and whether a breakpoint in ROM works; where it cannot, or the address cannot be written, `G` gives `? address`. When the program reaches it, the monitor takes the breakpoint away (putting back the old instruction if one was written) and says `Breakpoint at <break>`, with PC at break. One breakpoint at a time. retro-z80 uses a hardware breakpoint of its debug unit, so ROM works; retro68k writes its break instruction (`ILLEGAL`), so ROM gives `? address` (section 11).

Code addresses (ENTRY, G, break): any on retro-z80; even on retro68k (`? alignment`; an odd ENTRY is refused with code 3).

### 4.4 Memory test

`T addr count` tests count bytes of RAM from addr; `T` alone tests all the RAM the monitor does not use itself, and first prints the ranges it will test, at the machine's address width (retro-z80: `Testing P000000-P1FBFFF`; retro68k: `Testing 000000-1FFFFF` less the monitor's own RAM). A range that takes in ROM, registers, the monitor's own RAM or memory the board does not have gives `? address` before anything is written.

- **Passes:** four, each writing the whole range and then reading it all back: `55`, `AA`, a pattern made from each byte's physical address (address bits 7–0 XOR 15–8 XOR 23–16), then that pattern inverted.
- **Access width:** a machine may write and read in wider accesses for speed, as long as at least one pass is by bytes and every error is reported for a byte (on the 68000 the byte passes exercise the upper and lower byte strobes separately).
- **What it prints:** the number of each pass as it finishes, after `Pass`; a line `addr: wrote xx read yy` for each of the first 16 bad bytes; then `Errors: nnnn`: the count of bad bytes in all passes, in hex, 4 digits or more when it needs them.
- **Stopping:** Esc (BREAK) stops it with `Stopped.`.

```
> T 9000 1000
Pass 1 2 3 4
Errors: 0000
```

### 4.5 Example sessions

A program typed in by hand on retro-z80 (`RST 18h` prints the string at HL; spec 16 there):

```
> E 8000 21 06 80 DF C9 00
> E 8006 "Hello" 0D 0A 00
> I 8000 3
8000  21 06 80     LD   HL,8006
8003  DF           RST  18h
8004  C9           RET
> G 8000
Hello
Program ended.
AF=0044 BC=0000 DE=0000 HL=800E IX=0000 IY=0000 SP=0000 PC=0040
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=1F R=12 IFF=0 IM=2?  Z P
>
```

Memory, sizes and physical addresses:

```
> D 8000 10
8000  21 06 80 DF C9 00 48 65  6C 6C 6F 0D 0A 00 FF FF  !.....Hello.....
> D.W 8000 8
8000  0621 DF80 00C9 6548                       !.....He
> D P1FC000 8
P1FC000  72 02 65 02 74 02 72 02                           r.e.t.r.
> F.W 9000 100 E5E5
> P 7000
7000: 5A
```

A break from the PC, then going on:

```
NMI (USB) at 812C
AF=1A80 BC=0010 DE=4000 HL=C123 IX=0000 IY=5C3A SP=FFE8 PC=812C
AF'=0000 BC'=0000 DE'=0000 HL'=0000 I=80 R=5B IFF=1 IM=2?  S
> D C120 10
C120  00 00 00 2A 2A 00 00 00  00 00 00 00 00 00 00 00  ...**...........
> G
```

The same on retro68k, with sizes checked:

```
> D.W 1001 10
? alignment
> E.L E00020 00012345
```

## 5. The image header

### 5.1 Layout

Every upload and every boot file starts with this 32-byte header. All fields are **big-endian** (the high byte first), and each field is aligned to its own size within the header.

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 4 | MAGIC | ASCII `RIMG` (`0x52 0x49 0x4D 0x47`) |
| 4 | 4 | MACHINE | ASCII `Z80 ` (`0x5A 0x38 0x30 0x20`) for retro-z80, `68K ` (`0x36 0x38 0x4B 0x20`) for retro68k |
| 8 | 1 | VERSION | 1 |
| 9 | 1 | TARGET | 0 program, 1 boot ROM image, 2 resident image (section 5.2) |
| 10 | 2 | FLAGS | Bit 0 PHYS: LOAD is a physical address (section 3.2). Bits 15–1 are 0 |
| 12 | 4 | LOAD | Where the first image byte goes |
| 16 | 4 | ENTRY | Where the program starts: a CPU address. Ignored for TARGET 1 |
| 20 | 4 | SIZE | Bytes of image after the header, 1 or more |
| 24 | 4 | ICRC | CRC-32 of the SIZE image bytes |
| 28 | 4 | HCRC | CRC-32 of header bytes 0–27 |

**Why big-endian:** the Z80 reads the header a byte at a time, so the order costs it nothing; the 68000 can read each aligned field with one MOVE. Addresses then read in a hex dump as the monitor prints them.

**The CRC** is CRC-32 as in zlib, Ethernet and PNG: polynomial `0x04C11DB7`, bits reflected, start value `0xFFFFFFFF`, result inverted. Python's `zlib.crc32` gives it. The CRC of the ASCII bytes `123456789` is `0xCBF43926`.

**Why CRC-32 and not CRC-16:** the same check guards a 4 KB frame and a whole image of up to 32 KB or more, on the link and on the SD card. CRC-32 misses a random error once in 4 × 10^9; CRC-16 once in 65,536, which is too weak for whole images. It costs a 1 KB table in each boot ROM and about 4 µs a byte on a 20 MHz Z80 (a 48 KB program in about 0.2 s), and nothing extra on the PC.

### 5.2 Targets

| TARGET | Meaning | What the loader does with it |
|--------|---------|------------------------------|
| 0 | **Program** | Loads it at LOAD and, if asked, runs it at ENTRY (section 6.5) with the environment each machine's spec gives |
| 1 | **Boot ROM image** | Checks it, keeps it in RAM until it is all in, writes it to the boot ROM with SYSCON.ROMWE, reads it back, then resets. LOAD is the offset in the boot ROM (0 for a whole image). Refused while SYSCON.ROMLOCK is set (`? locked`, refusal code 5). The new ROM runs until the FPGA is reloaded (each machine's system spec) |
| 2 | **Resident image** | A ROM image kept in write-protected RAM (BASIC): loaded into the RAM the machine keeps for it and protected; started by `X` and at start-up (section 9) |

Each machine's spec gives the address ranges it accepts for each target, and refuses others (refusal code 3).

### 5.3 Resident images

A resident image stays in RAM across resets other than power-on, so a warm reset does not load it again. The boot ROM keeps a record of it (its header and where it is) and checks the image against ICRC before starting it. If the check fails, it loads the image again from the SD card (`BASIC.Z80` or `BASIC.68K`), or reports `? bad image`.

## 6. The upload protocol

### 6.1 Getting the loader ready

1. The PC tool sends the **UPLOAD** control command (each machine's serial spec, section 4). The machine resets with RESETWHY.UPLOAD set; the boot ROM sets up the console and the link and starts the loader. The `U` command, or U held at reset, starts the same loader without the control command.
2. The loader shows `Waiting for upload.  BREAK for the monitor.` on the screen, and sends this ready line on the serial link:

   ```
   LOAD Z80 1<CR><LF>          (retro68k: LOAD 68K 1)
   ```

   The machine's name and the protocol version (1). The tool waits for it, so it knows which machine it is talking to.
3. The loader then waits for frames for as long as it takes. Bytes that are not part of a frame are ignored. Esc on the machine's keyboard goes back to the monitor.

While the loader runs it prints nothing on the serial link except the ready line and replies; its progress goes to the screen only.

### 6.2 Frames

Everything the PC sends to the loader is a frame:

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 2 | SYNC | ASCII `LF` (`0x4C 0x46`) |
| 2 | 1 | TYPE | 0 PING, 1 HEADER, 2 DATA, 3 END, 4 ABORT |
| 3 | 1 | SEQ | Frame number: HEADER is 0, then 1, 2 … (after 255 comes 0) |
| 4 | 4 | OFFSET | DATA: where the payload goes, as an offset into the image. Otherwise 0 |
| 8 | 2 | LENGTH | n, the payload's length, 0–4096 |
| 10 | 2 | NLENGTH | LENGTH with every bit inverted |
| 12 | n | PAYLOAD | HEADER: the 32-byte image header. DATA: image bytes. END: one ACTION byte. PING and ABORT: none |
| 12 + n | 4 | CRC | CRC-32 of bytes 2 to 11 + n (from TYPE to the end of the payload) |

- Big-endian, as the header.
- NLENGTH lets the loader throw out a frame with a damaged length at once, instead of waiting for up to 4,096 bytes that never come.
- The loader hunts for SYNC, so a frame can follow stray bytes. If the bytes of a frame stop for more than 1 second, the loader drops the frame and hunts again.

### 6.3 Replies

The loader answers every frame it has read whole with a 5-byte reply:

| Offset | Size | Field | Value |
|--------|------|-------|-------|
| 0 | 2 | SYNC | ASCII `LR` (`0x4C 0x52`) |
| 2 | 1 | STATUS | `K` ok, `C` CRC error, `F` frame error, `R` refused |
| 3 | 1 | SEQ | The SEQ of the frame it answers |
| 4 | 1 | CODE | `K`: 0, or for PING the protocol version. `R`: why (below). Otherwise 0 |

| STATUS | Meaning | The tool |
|--------|---------|----------|
| `K` ok | Frame taken | Sends the next one |
| `C` CRC error | The CRC did not match; nothing was kept | Sends the same frame again |
| `F` frame error | NLENGTH did not match, LENGTH was over 4096, or the TYPE is unknown | Sends the same frame again |
| `R` refused | The upload cannot go on (CODE) | Stops and reports the reason |

| CODE | Refused because |
|------|-----------------|
| 1 | MACHINE is not this machine |
| 2 | The header is bad: MAGIC, VERSION, HCRC, or a reserved FLAGS bit |
| 3 | LOAD to LOAD + SIZE, or ENTRY, is outside what this machine allows for this target; on retro68k, ENTRY is odd (section 4.3) |
| 4 | SIZE is too large for this target |
| 5 | The target is not allowed now (TARGET 1 while ROMLOCK is set; a target this machine does not have) |
| 6 | At END, the image in memory does not match ICRC |
| 7 | Out of order: DATA before HEADER, or past SIZE; END before every byte has come |
| 8 | Stopped at the machine (Esc) |

A frame whose SEQ is that of the last frame taken is answered `K` again and not used twice, so a lost reply only costs a resend.

### 6.4 An upload

```
PC                                         Loader
UPLOAD control command          ──►        (reset; console up)
                                ◄──        LOAD Z80 1
HEADER  SEQ 0  (the 32-byte header)  ──►   checks MACHINE, HCRC, target, range
                                ◄──        LR K 0
DATA    SEQ 1  OFFSET 0     4096 bytes ──► CRC ok: bytes written at LOAD + 0
                                ◄──        LR K 1
DATA    SEQ 2  OFFSET 4096  4096 bytes ──► CRC bad
                                ◄──        LR C 2
DATA    SEQ 2  OFFSET 4096  4096 bytes ──► (sent again) ok
                                ◄──        LR K 2
…
END     SEQ n  ACTION 1                ──► ICRC checked over memory
                                ◄──        LR K n
                                           runs the program
```

- **PING** can be sent at any time. The loader answers `K` with CODE = the protocol version and sends the ready line again. The tool uses it when it starts after the loader is already waiting.
- **HEADER** starts an upload (and drops any upload under way). The loader checks the header and the target and replies `K` or `R`.
- **DATA** frames carry the image, normally in order and in 4,096-byte pieces (the last one shorter). The loader writes each payload to LOAD + OFFSET as soon as its CRC is right; TARGET 1 goes to a buffer first.
- **END** finishes. The loader computes ICRC **from memory**, so the check also covers the RAM the image went into. Then it replies and does the ACTION.
- **ABORT** drops the upload; the loader replies `K` and waits again.

### 6.5 ACTION

| ACTION | TARGET 0 program | TARGET 1 boot ROM image | TARGET 2 resident image |
|--------|------------------|-------------------------|-------------------------|
| 0 | Back to the monitor, with PC = ENTRY and the other registers at their defaults; `G` runs it | Checked only, not written; back to the monitor | Kept and protected; back to the monitor |
| 1 | Run it at ENTRY | Write it to the boot ROM, read it back, reset | Kept and protected, then started |

The loader sends the reply to END **before** it acts, so the tool does not send END twice: with no reply to END it reports that the program may already be running.

### 6.6 Timing

| Step | Time |
|------|------|
| Tool waits for the ready line after UPLOAD | 3 s, then one PING; then gives up |
| Tool waits for a reply | 2 s, then sends the frame again |
| Tries per frame | 5, then the tool stops (exit code 3) |
| Loader drops a frame whose bytes stop | After 1 s |

## 7. The boot file and other image files

- The SD card holds a **FAT32** file system in its first partition (each machine's SD spec covers the card itself). The boot ROM reads files from the root directory, with 8.3 names.
- A file is an image header (section 5) followed by the image: exactly what an upload sends. `rlink.py image` makes one (section 8).
- **The boot file** is `BOOT.Z80` on retro-z80 and `BOOT.68K` on retro68k, so one card can hold both. At start-up the boot ROM loads and runs it (section 9).
- **The resident image** (BASIC) is `BASIC.Z80` or `BASIC.68K`.
- `L name` and `B name` load any image file: `B GAME.Z80`. A name without a dot gets the machine's extension: `B GAME` is `GAME.Z80` on retro-z80.
- The boot ROM checks the file as the loader checks an upload: MAGIC, MACHINE, VERSION, HCRC, the target and the range, and ICRC once it is loaded. A failure prints `? bad image` and the reason, and the file is not run.
- TARGET 1 files are accepted only by `L` and `B`, never as the boot file at start-up, and only while ROMLOCK is clear.

## 8. The PC tool: `tools/rlink.py`

One Python 3 script, the same file in both repos. It needs Python 3.8 or newer and the `pyserial` package; nothing else.

### 8.1 Command line

```
python3 tools/rlink.py [-p PORT] COMMAND [options]
```

`-p PORT` names the serial port (`COM5`, `/dev/ttyUSB1`); without it the tool uses the environment variable `RLINK_PORT`. The baud rate does not matter (each machine's serial spec).

| Command | What it does |
|---------|--------------|
| `upload FILE [--no-run] [--no-reset] [--term]` | Sends UPLOAD, waits for the ready line, checks the machine against the file's header, sends the image, and runs it (ACTION 1) unless `--no-run`. `--no-reset` skips UPLOAD, for a loader already waiting (`U`). `--term` stays on as a terminal afterwards |
| `upload BIN --load ADDR [--entry ADDR] [--machine z80\|68k] [--target program\|rom\|resident] [--phys] …` | The same for a raw binary: the tool makes the header on the fly. `--entry` defaults to `--load`. The machine defaults to the one in the ready line |
| `image BIN -o FILE --machine z80\|68k --load ADDR [--entry ADDR] [--target …] [--phys]` | Makes an image file (header and image) for the SD card or a later upload |
| `show FILE` | Prints an image file's header and checks HCRC and ICRC |
| `reset`, `break`, `uploadmode` | Sends one control command: RESET, BREAK or UPLOAD |
| `term` | A terminal: shows what the machine sends and sends what is typed, so the monitor and programs can be used from the PC. Ctrl-] then a key: `r` RESET, `b` BREAK, `u` upload a file (asks for its name), `q` quit |
| `type TEXT` or `type -f FILE` | Types the text into the console, as if typed at the terminal; LF is sent as CR. With `-f`, a file, line by line: for example a monitor session or a BASIC program |

- Addresses on the command line are hex, as in the monitor; `ADDR` may have the `P` prefix with `--phys`.
- Exit codes: 0 done, 1 bad command line or file, 2 refused (the reason is printed), 3 no answer from the machine.
- **Typing** goes over the serial console (each machine's serial input). retro-z80 later adds key injection (its design plan, branch 15): `type --keys` will send key-down and key-up codes through control commands, so they look like a real keyboard to the program.

### 8.2 Examples

```
$ sjasmplus --raw=hello.bin hello.asm
$ python3 tools/rlink.py image hello.bin -o HELLO.Z80 --machine z80 --load 8000
$ python3 tools/rlink.py -p COM5 upload HELLO.Z80 --term
rlink: UPLOAD sent on COM5
rlink: loader ready: Z80, protocol 1
rlink: header ok: program, load 8000, entry 8000, 14 bytes
rlink: 14 bytes in 1 frame, 0 sent again
rlink: running at 8000 (Ctrl-] q to quit)
Hello
```

```
$ python3 tools/rlink.py show BOOT.Z80
BOOT.Z80: RIMG v1, Z80, program, load 2000, entry 2000, 49152 bytes
HCRC 8A41C2F0 ok, ICRC 0D3E91B7 ok
```

A new boot ROM image while developing (the machine started with D held, so ROMLOCK is clear):

```
$ python3 tools/rlink.py upload boot.bin --load 0 --target rom
rlink: loader ready: Z80, protocol 1
rlink: header ok: boot ROM image, offset 0, 32768 bytes
rlink: 32768 bytes in 8 frames, 0 sent again
rlink: written; the machine resets
```

### 8.3 Tests of the tool

`tools/test/test_rlink.py` runs the tool against a Python model of the loader (in the same file), with no hardware: frames, replies, resends after injected CRC errors and lost replies, every refusal code, headers made by `image` and checked by `show`, and the CRC check value.

## 9. Start-up

Both boot ROMs start in this order, after their own hardware set-up and (at power-on) RAM test:

| Step | Condition | Action |
|------|-----------|--------|
| 1 | Always | Console on the screen and the serial link; the sign-on lines (section 2.3) |
| 2 | Always | Read the start-up keys (below) and RESETWHY |
| 3 | RESETWHY.UPLOAD, or U held | The loader (section 6) |
| 4 | M held, or the DivMMC button | The monitor |
| 5 | A card with the boot file | Load and run it (section 7) |
| 6 | A resident image in RAM, or `BASIC.Z80` / `BASIC.68K` on the card | Start BASIC |
| 7 | Otherwise | The monitor |

**Start-up keys**, held while the machine resets:

| Key | Effect |
|-----|--------|
| M, or the DivMMC button | Go straight to the monitor |
| U | Wait for an upload |
| D | Development: leave the boot ROM writable (do not set ROMLOCK). Counts at power-on only |

They are read from the machine's keyboards; each machine's spec says which and how long it looks.

**ROMLOCK.** The boot ROM decides ROMLOCK at power-on only (RESETWHY.POWER): with D held it leaves it clear; otherwise it sets it. ROMLOCK then stays as it is until the next power-on.

**A long press of the reset button** does nothing more than a short one, on both machines (decided; retro68k's SY3). The way into the loader from the PC is the UPLOAD control command.

If the boot file or BASIC fails (a bad image, a read error), the boot ROM reports it and goes to the monitor.

## 10. What a program inherits

A program started by the boot ROM (from an upload, the boot file, `B` or `G`) finds the machine in a known state. The shape is shared; the content is each machine's:

| Item | retro-z80 (its spec 16) | retro68k (its boot ROM spec) |
|------|-------------------------|------------------------------|
| CPU mode | Z80, IM 2, interrupts disabled (DI) | Supervisor mode, SR = `0x2700` |
| Speed | 20 MHz (CPUSPEED 0) | 20 MHz |
| ROM | Boot ROM page 0 in window 0 (`0x0000`–`0x1FFF`), with RST entry points to the console routines | At `0xF80000`; how a program calls it is retro68k's choice |
| Memory | Windows 1–7 = SRAM pages 1–7: 56 KB for the program | Chip RAM; vectors in Chip RAM at 0 with the overlay off |
| Stack | SP = `0xFFFE`, with the address of the ROM's exit at the top: a RET ends the program | Set by the boot ROM (retro68k gives the address) |
| Vectors | I and VECBASE point at the ROM's table; a program that uses interrupts makes its own | The vector table in Chip RAM, filled with the ROM's handlers |
| Interrupts | Off at the controller (INTENA all clear, INTCON.MASTER clear) | Off at the controller |
| Console | On: L0 shows the 80 × 30 text console; the ROM calls print to it | On: the console layer shows the text console |
| Boot ROM | ROMLOCK set (unless D was held) | ROMLOCK set (unless D was held) |
| Other units | Timers and watchdog off; copper, sprites, DMA engine stopped; serial link on with TXDROP; PS/2 receiving | retro68k gives the list |
| Back to the monitor | RET from the entry point, the exit call, the break call, NMI | retro68k gives them |

## 11. Machine parts

Each machine's own boot ROM spec covers what this spec leaves to it:

| Part | retro-z80 | retro68k |
|------|-----------|----------|
| Its spec | Spec 16, `docs/spec/boot-rom.md` | Its boot ROM spec (number and file named by retro68k) |
| The ROM's own layout and start-up details | ROM pages, the boot sequence, background colours | The same |
| How a program calls the ROM | RST entry points and `RST 28h` functions | retro68k's choice |
| Break, breakpoint and trap | Break call `RST 30h`; `G` breakpoints by the debug unit (ROM works); trap `RST 38h` (a fetch of `0xFF`) | retro68k's (exceptions, its break instruction) |
| Address ranges for each command and each target | Sections 8.1 and 9 of its spec | retro68k's |
| Registers shown, and what IM and IFF mean | Section 8.3 of its spec | retro68k's |
| What a program inherits | Section 6 of its spec | retro68k's |
| Disassembler | In the boot ROM | Optional |
| Resident image (BASIC) | BBC BASIC (Z80), section 10 of its spec | Later (its BASIC phase) |
| Extras | The NMI monitor paging (a Spectrum extra) | – |

## 12. Keeping the two copies the same

- This file is the same in both repos. A change is agreed for both machines and made in both, in one commit each, with the same text.
- Something that only one machine needs goes into its own boot ROM spec, or into a table here with a column for each machine.
- `rlink.py` is the same file in both repos too.

## 13. Test plan

- **Commands:** each command and size on both machines, in simulation, typed on the keyboard and over the serial link; the dumps match the examples' format, with the characters two spaces after a full line's last item at every size and address width; V and S print as section 4.1 says; `R name` shows one register; Enter after `D`, `I`, `S` and `N` carries on; Up brings back the last line; Esc drops it.
- **Sizes:** `.W` and `.L` give the machine's byte order; on the 68000 an odd word or long address gives `? alignment` and no address error; on the Z80 any address works.
- **Addresses:** plain and `P` addresses reach the same memory where they should; forbidden ranges give `? address`.
- **Registers:** `R` shows and sets every register of each machine; `G` starts with them.
- **Memory test:** `T` on a range and alone prints as section 4.4 says, finds a byte forced bad in simulation, refuses forbidden ranges before writing, and stops on Esc.
- **Breakpoints:** `G addr break` stops at break with the program's memory as it was; a breakpoint in ROM works on retro-z80 and is refused on retro68k.
- **Upload:** a program, a resident image and a boot ROM image, each with ACTION 0 and 1; resends after CRC and frame errors; a lost reply; every refusal code; PING before and after HEADER; ABORT; a frame cut short (the 1 s drop); ICRC wrong in memory at END (code 6). In simulation against the FT232H model, and on the board.
- **Boot file:** `BOOT.Z80` and `BOOT.68K` on one card, each machine starting its own; a bad header, a bad ICRC and a missing file go to the monitor with a message; a TARGET 1 boot file is not run at start-up.
- **Start-up:** each start-up key; RESETWHY.UPLOAD reaches the loader; D at power-on leaves ROMLOCK clear across later resets, and D at a later reset changes nothing; on both machines, a long reset press is a plain reset.
- **Tool:** `tools/test/test_rlink.py` (section 8.3); `rlink.py upload` works the same against both machines' simulations.
- **The two copies:** a check in each repo's CI compares this file and `rlink.py` with the other repo's latest copy (open point M6).

## 14. Open points

| # | Item |
|---|------|
| M1 | retro68k reviews and adopts this draft; until then it is retro-z80's proposal |
| M2 | retro68k's break instruction, its traps, how a program calls its ROM, and its own address limits, in its boot ROM spec |
| M3 | 4,096-byte frames with a reply each: about 1 ms of turn-around a frame, so a 32 KB image costs 8 ms of waiting. Larger frames, or several frames in flight, only if uploads are too slow |
| M4 | The 1 KB CRC table in each boot ROM, or built in RAM at start-up to save ROM space |
| M5 | FAT16 cards as well as FAT32; long file names are not planned |
| M6 | How the copies are kept in step: by hand, or a CI check against the other repo. A cross-repo check needs read access to the other repo; if either repo is private, a token stored as a secret |
| M7 | Symbols (names for addresses) in the monitor and the disassembler: not planned for version 1 |
| M8 | `pyserial` is the tool's only package outside the standard library; both repos' tool READMEs say so |
