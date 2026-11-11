# Spec 15: SD card

Status: **version 1, for review**

The SD card is the computer's storage: programs, data, music, pictures. On the ZX Spectrum Next KS3 the SD slot is wired for **SPI mode** only. Version 1's controller is a plain **SPI byte master**: the hardware clocks bytes to and from the card at up to 25 MHz, and software builds the commands, waits for the card's answers and handles the data blocks. Bulk data does not need the CPU: the DMA engine streams a block's bytes between the card and Chip RAM through its port 0 (spec 11).

(An earlier draft, with a host controller doing commands, CRCs and blocks in hardware and a 2 KB FIFO, is in the history of this file. It was dropped for size; it is open point SD4.)

## 1. Summary

| Item | Value |
|------|-------|
| Slot | The KS3's SD slot: `sd_sclk`, `sd_mosi`, `sd_miso`, `sd_cs0`. `sd_cs1` (a second card select) is wired and driven, but nothing uses it yet |
| Cards | SD, SDHC and SDXC (any size), at 3.3 V |
| Bus | SPI mode 0, 1 bit each way, most significant bit first |
| Speed | SPI clock 100 MHz ÷ (2 × CLKDIV): 400 kHz for start-up (CLKDIV 125), 25 MHz after (CLKDIV 2): about 3 MB/s |
| Hardware does | Clocks a byte out and a byte in at the same time; drives the two select lines as software says; reads a counted run of bytes for the DMA engine |
| Software does | Card start-up, commands and their checksums, waiting for answers, tokens and busy, data block framing, timeouts, the file system |
| DMA | Port 0 of the DMA engine: reading N bytes from the card into memory, or writing bytes to it, with no CPU work per byte |
| Card detect | None on the KS3; software notices cards by sending commands (section 5) |
| Interrupt | None: software polls (source 16 of the interrupt controller is unused) |

## 2. Why SPI mode, and why a byte master

SD cards have two ways to talk: the native bus (1 or 4 data lines, up to 25 MB/s) and the simpler SPI mode (1 line each way). The KS3 board only wires the SPI signals. SPI mode is slower, about 3 MB/s, but still plenty for loading programs and files: a 1 MB file loads in about a third of a second.

In SPI mode everything is bytes: a command is 6 bytes, an answer a few bytes, a data block a start token, 512 bytes and 2 checksum bytes. A byte master is enough to do all of it from software, at little cost in logic; the DMA engine takes the one part where speed matters, the 512 data bytes of each block.

## 3. How it works

### 3.1 A byte

Writing a byte to **SDDATA** sends it on MOSI, most significant bit first, while the byte the card sends on MISO is clocked in. **BUSY** (SDDATA bit 8) is set until all 8 bits have gone; then SDDATA's bits 7–0 hold the byte received. To read a byte from the card, send `0xFF`. A write while BUSY is ignored.

At 25 MHz a byte takes 320 ns. The 68000 polling BUSY moves about 0.3–0.5 MB/s; the DMA engine moves a block at the card's full speed.

### 3.2 Select lines

**SDCON.CS0** and **SDCON.CS1** drive the two select lines: 1 = selected (the line low). Software selects the card for each command and its answer and data, and deselects it afterwards, followed by one more byte (`0xFF`) so the card releases MISO, as SPI-mode cards expect. Change the select lines only while not BUSY.

**Start-up clocks:** cards need at least 74 clocks with the select line high before the first command: send 10 bytes of `0xFF` with both CS bits clear.

### 3.3 Commands, by software

A command is 6 bytes: `0x40 | index`, the 32-bit argument (most significant byte first), and `CRC7 << 1 | 1`. In SPI mode the card checks the CRC only for CMD0 and CMD8 unless told to with CMD59, so those two use fixed values (`0x95` for CMD0 with argument 0, `0x87` for CMD8 with argument `0x1AA`) and the rest can send `0xFF`.

After the command, the card answers within 8 bytes: software sends `0xFF` until a byte with its top bit clear arrives, the R1 status. Some commands send more bytes after it (R3 and R7: 4 more; R1b: the card then holds MISO low, so reads give `0x00`, until it is ready).

### 3.4 Data blocks

- **Reading** (CMD17 one block, CMD18 several): after the command's R1, software sends `0xFF` until the card's start token `0xFE` arrives (or an error token, `0b000xxxxx`), then reads 512 data bytes and 2 CRC bytes. With the DMA engine (section 3.5) the 512 bytes go straight into memory.
- **Writing** (CMD24, CMD25): software sends a start token (`0xFE` for one block, `0xFC` for each block of CMD25), 512 bytes (by DMA or the CPU), 2 CRC bytes (`0xFF 0xFF` unless CRCs are on), then reads the data-response token (`xxx00101` = accepted) and waits while the card is busy (reads `0x00`). CMD25 ends with the stop token `0xFD` and another busy wait; CMD18 ends with CMD12.

### 3.5 With the DMA engine

**SDCOUNT** gives the controller a run of bytes to read for the DMA engine: writing N (1–65535) starts it. The controller clocks in byte after byte, sending `0xFF`, and hands each to DMA port 0; it starts the next as soon as the engine has taken the last, until N bytes have been read. Reading SDCOUNT gives the bytes still to read. So the controller never reads past the end of the block: it stops before the CRC bytes, which software then reads itself.

As a destination, port 0 sends each byte the engine gives it, as soon as the last has gone (the bytes received are dropped).

Reading a block into memory:

1. Send CMD17 and wait for R1 and the start token `0xFE`, as in 3.4.
2. Write 512 to SDCOUNT.
3. Run a DMA job: a copy (BLIT, MINTERM `0xCC`), from port 0 (BKIND port, BPT = 0) to the buffer, 512 bytes (spec 11, section 4).
4. When the job is done, read the 2 CRC bytes, deselect, send one more `0xFF`.

Writing a block is the same the other way: the start token from the CPU, the 512 bytes by a DMA job to port 0, then the CRC bytes, the response token and the busy wait from the CPU. While SDCOUNT is not 0, or a DMA job sends to port 0, the CPU should not write SDDATA.

## 4. Starting a card

Software runs the standard SPI-mode start-up sequence (the boot ROM will have it, with a small FAT32 reader, so programs can be loaded from the card):

1. CLKDIV = 125 (400 kHz). 10 bytes of `0xFF` with the select lines high.
2. Select; CMD0 (go idle, CRC `0x95`): the card enters SPI mode and answers R1 = `0x01` (idle).
3. CMD8 with argument `0x1AA` (CRC `0x87`), R7: new cards echo `0x1AA`; old SDv1 cards answer "illegal command".
4. CMD55 then ACMD41 (argument bit 30 set for SDHC/SDXC), repeated until R1 = `0x00` (ready). Allow about a second.
5. CMD58 (read OCR, R3): bit 30 (CCS) set means SDHC/SDXC, which use block numbers; clear means SDSC, which uses byte addresses.
6. For SDSC cards, CMD16 with 512 sets the block length.
7. CLKDIV = 2 (25 MHz).

## 5. No card detect

The KS3 has no card-detect switch, and in SPI mode the card's DAT3 pin is its select line, so it cannot be used for detection either. Software finds out about the card by talking to it:

- **Is there a card?** Run the start-up sequence. If CMD0 gets no answer (MISO stays high: every byte reads `0xFF`), there is no card, or it is not working.
- **Was it removed?** Answers stop coming: bytes read `0xFF` where an R1 or token was due.
- **Was it swapped?** A new card answers CMD0 and needs starting again. A file system can read the card's ID (CMD10, CID) after start-up and compare it with the one it had.

## 6. Registers

In the system block at `0xF00000` (spec 3, section 4.5).

| Offset | Name | Bits | Description |
|--------|------|------|-------------|
| `0x300` | SDCON | EN (0), CS0 (1), CS1 (2), CLKDIV (15–8) | On (off: no clock, select lines high); select lines (1 = selected, the line low); SPI clock = 100 MHz ÷ (2 × CLKDIV), CLKDIV 0 and 1 count as 2. After reset: off, CLKDIV 125 |
| `0x304` | SDDATA | Write: BYTE (7–0). Read: BYTE (7–0), BUSY (8) | Write: send a byte (ignored while BUSY). Read: the last byte received, and BUSY while a byte is being clocked |
| `0x308` | SDCOUNT | COUNT (15–0) | Write N (a 16-bit or 32-bit write, while on): read N bytes for DMA port 0 (section 3.5). Read: bytes still to read. Turning SDCON.EN off clears it |

## 7. FPGA resources

| Item | Resource |
|------|----------|
| Clock divider, shift register, counters | About 70 LUTs (Vivado); no block RAM |
| Pins | 5 on the KS3: `sd_sclk` (M1), `sd_mosi` (M2), `sd_miso` (L1, pulled up), `sd_cs0` (N1), `sd_cs1` (K2) |

## 8. Open points

| # | Item |
|---|------|
| SD1 | Is 25 MHz SPI reliable on the KS3's wiring with all cards? Test with several brands; fall back to 12.5 MHz (CLKDIV = 4) if not |
| SD2 | Some cards accept faster SPI clocks after CMD6 "high speed": worth trying later for about 5 MB/s |
| SD3 | What `sd_cs1` is meant for on the board (a second card on an expansion?), and whether to use it |
| SD4 | A hardware host controller (commands, CRCs, blocks, a FIFO), if software turns out too slow: see the earlier draft |
| SD5 | Card power is always on (no switch), so a crashed card can only be reset with CMD0, not by cycling power |

## 9. Tests

- **Simulation:** an SPI-mode SD card model in the testbench, answering bytes: start-up clocks with the select high, CMD0, CMD8, ACMD41, CMD58, a block read through the DMA engine with SDCOUNT (the CRC bytes not read by it), a block written by DMA; SPI mode 0 timing at several CLKDIV values; writes while BUSY ignored.
- **No card:** every byte reads `0xFF`.
- **Real cards:** several brands and sizes (SDSC, SDHC, SDXC) at 400 kHz and 25 MHz; read speed into Chip RAM with the DMA engine; write and read back a pattern.
