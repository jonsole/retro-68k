# Chapter 8: SD Card and Keyboard

## Introduction

This chapter covers the two devices a home computer needs besides the screen: **storage**, an SD card, and **input**, a PS/2 keyboard. Both are kept simple in the hardware and leave the protocol work to software, so a small amount of logic does the job.

- The **SD card** controller clocks bytes to and from the card at up to 25 MHz. Software sends the card's commands and reads its answers; the DMA engine moves the 512 data bytes of each block, so loading a file costs the CPU almost nothing.
- The **keyboard** controller receives the keyboard's bytes, checks them and keeps them in a small FIFO; software decodes the scan codes. It can also send bytes to the keyboard, to set its lights or its repeat rate.

You should have read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter, and the DMA Engine and Blitter Hardware chapter (for loading blocks by DMA).

**Note:** Both are built in the FPGA design (`fpga/rtl/sdspi.v`, `fpga/rtl/ps2kb.v`) and tested in simulation against models of a card and a keyboard (`make -C sim iotest`), but not yet on the board.

### Conventions

Examples are 68000 assembly language for vasm, starting with `include "hw.inc"`. **a5 holds SYSTEM** (`$F00000`), where both devices' registers are, and **a4 holds CUSTOM** (`$E00000`).

---

## The SD Card

The KS3's SD slot is wired for **SPI mode**, in which the card talks a byte at a time over one line each way. Everything is bytes: a command is 6 bytes, an answer 1 to 5, a data block a start byte, 512 data bytes and 2 check bytes.

### The registers

| Name | Offset | Function |
|------|--------|----------|
| SDCON | `$300` | EN (0): on. CS0 (1), CS1 (2): select the card (1 = selected). CLKDIV (15–8): SPI clock = 100 MHz ÷ (2 × CLKDIV) |
| SDDATA | `$304` | Write: send a byte (7–0). Read: the last byte received (7–0), and BUSY (8) while a byte is going |
| SDCOUNT | `$308` | Write N: read N bytes for the DMA engine. Read: bytes still to read |

### Sending and receiving a byte

Writing SDDATA sends a byte and, at the same time, receives one. Wait for BUSY to clear, then read the byte that came back. To read from the card, send `$FF`:

```asm
; spi: send d0.b, return the byte received in d0
spi:        and.l   #$FF,d0
            move.l  d0,SDDATA(a5)
.w:         move.l  SDDATA(a5),d0
            btst    #SDDATA_BUSY_B,d0
            bne.s   .w
            and.l   #$FF,d0
            rts
```

At 25 MHz a byte takes 320 ns, so the loop above is limited by the CPU, at a few hundred KB/s. That is fine for commands; data blocks go by DMA (below).

### Commands

A command is the byte `$40` + the command number, a 32-bit argument (most significant byte first) and a check byte. In SPI mode the card checks it only on CMD0 and CMD8, whose check bytes are fixed (`$95` and `$87` with the arguments below); the others can send `$FF`. The card answers within 8 bytes: keep sending `$FF` until a byte with its top bit clear arrives. That is the **R1** status: 0 = all well, `$01` = the card is still starting.

```asm
; cmd: command d1, argument d2, check byte d3; d0 = R1 ($FF: no answer)
cmd:        move.l  d1,d0
            or.b    #$40,d0
            bsr     spi
            moveq   #4-1,d5
.arg:       rol.l   #8,d2
            move.l  d2,d0
            bsr     spi
            dbra    d5,.arg
            move.l  d3,d0
            bsr     spi
            moveq   #10,d5
.r1:        moveq   #-1,d0
            bsr     spi
            btst    #7,d0
            beq.s   .got
            subq.l  #1,d5
            bne.s   .r1
.got:       rts
```

Some commands send more after R1: CMD8 and CMD58 send 4 more bytes; read them with four more `$FF` bytes.

### Starting the card

Select the card for each command and its answer and data, and deselect it afterwards, followed by one more `$FF` byte so it lets go of the line.

```asm
            move.l  #SDCON_EN_M|(125<<SDCON_CLKDIV_B),SDCON(a5)    ; 400 kHz, not selected
            moveq   #10-1,d4                                       ; at least 74 clocks first
.clk:       moveq   #-1,d0
            bsr     spi
            dbra    d4,.clk
            move.l  #SDCON_EN_M|SDCON_CS0_M|(125<<SDCON_CLKDIV_B),SDCON(a5)
```

Then:

1. **CMD0**, argument 0, check `$95`: the card goes into SPI mode and answers `$01`. No answer at all (every byte `$FF`) means there is no card.
2. **CMD8**, argument `$1AA`, check `$87`: a modern card answers `$01` and then `00 00 01 AA`.
3. **CMD55** then **ACMD41** (CMD41 sent after CMD55), argument `$40000000`, repeated until R1 is 0. A card can take up to a second.
4. **CMD58**: R1, then the card's OCR. If bit 30 is set the card is SDHC or SDXC, and addresses blocks by number; if not, it is an old SDSC card, which takes byte addresses (block number × 512), and needs **CMD16** with 512 to set the block size.
5. Speed up: CLKDIV = 2 (25 MHz).

There is no card-detect switch. To find out whether a card is there, or has been changed, start it again.

### Reading a block by DMA

**CMD17** reads one block (its number, or for SDSC its byte address, as the argument). After R1, keep sending `$FF` until the card's start byte `$FE` arrives; then come 512 data bytes and 2 check bytes. To have the DMA engine take the data bytes:

1. Write 512 to **SDCOUNT**: the controller now reads 512 bytes on its own, each as soon as the DMA engine has taken the last;
2. run a DMA job copying 512 bytes from **port 0** to your buffer;
3. read the 2 check bytes yourself, deselect, and send one more `$FF`.

```asm
; Example 8-1: read block d2 into BUF, by DMA (the card started, and selected)
COPY8       equ     ($CC<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)  ; BLIT D = B, 8 bpp
readblk:    moveq   #17,d1
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            bne     error
.tok:       moveq   #-1,d0              ; wait for the start byte
            bsr     spi
            cmp.b   #$FF,d0
            beq.s   .tok
            cmp.b   #$FE,d0
            bne     error               ; an error token
            move.l  #512,SDCOUNT(a5)
            lea     DMX0(a4),a0
            move.l  #COPY8|(1<<DMX_CTRL_BKIND_B),DMX_CTRL(a0)     ; B from a port ...
            move.l  #0,DMX_BPT(a0)                                ; ... port 0, the card
            move.l  #BUF,DMX_DPT(a0)
            move.l  #(1<<16)|512,DMX_SIZE(a0)                     ; 1 row of 512 bytes
            move.l  #0,DMX_NEXT(a0)
            move.l  #DMX_CHCTRL_RUN_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX_CHCTRL(a0)
.w:         btst    #DMX_CHSTAT_BUSY_B,DMX_CHSTAT+3(a0)
            bne.s   .w
            moveq   #-1,d0              ; the 2 check bytes
            bsr     spi
            moveq   #-1,d0
            bsr     spi
            rts
```

SDCOUNT stops the controller at the end of the data, so the check bytes are left for you. Instead of waiting, you can let the DMA channel interrupt when it is done.

### Writing a block

**CMD24** writes one block. After R1, send the start byte `$FE`, the 512 data bytes (by a DMA job copying from your buffer to port 0, or by the CPU), and 2 check bytes (`$FF $FF`). The card then answers with a byte whose low 5 bits are `00101` if it took the block; then it is busy, and reads as `$00`, until the write is done. Wait for a byte other than `$00` before the next command.

For many blocks, CMD18 (read) and CMD25 (write) are faster: see the SD card spec (spec 15, section 3.4).

---

## The Keyboard

Any PS/2 keyboard plugs into the KS3's PS/2 socket. It sends **scan codes** (set 2): a byte or two when a key goes down, and the same with `$F0` in front when it comes up.

### The registers

| Name | Offset | Function |
|------|--------|----------|
| KBCON | `$400` | EN (0): on. Off empties the FIFO |
| KBSTAT | `$404` | COUNT (4–0): bytes waiting (0–16). TXBUSY (8): a byte is going to the keyboard |
| KBDATA | `$408` | Reading the low half takes a byte (7–0); `MOVE.L` takes one. EMPTY (8): there was none |
| KBSEND | `$40C` | Write a byte (7–0) to send it to the keyboard |
| KBIRQ | `$410` | DATA (0): bytes waiting. PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4): errors, sticky, write 1 to clear |
| KBIRQEN | `$414` | Interrupt enables, as KBIRQ |

### Reading keys

Turn the keyboard on, and read KBDATA whenever COUNT is not 0, or take the keyboard's interrupt (source KEYB, level 2 by default) with KBIRQEN.DATA set. A byte with a bad check bit or frame is dropped and flagged; up to 16 bytes wait in the FIFO.

```asm
            move.l  #KBCON_EN_M,KBCON(a5)
            move.l  #KBIRQ_DATA_M,KBIRQEN(a5)

; Example 8-2: the keyboard's interrupt: decode presses and releases
kb_int:     movem.l d0/a0,-(sp)
.next:      move.l  KBDATA(a5),d0
            btst    #KBDATA_EMPTY_B,d0
            bne.s   .done
            cmp.b   #$F0,d0             ; a release follows
            bne.s   .key
            st      kb_release
            bra.s   .next
.key:       cmp.b   #$E0,d0             ; an extended key follows
            beq.s   .next               ; (a real decoder remembers it)
            ; d0 = a scan code: pressed, or released if kb_release is set
            ; ... look it up in the layout table, queue it for the program
            sf      kb_release
            bra.s   .next
.done:      movem.l (sp)+,d0/a0
            rte
```

The DATA bit follows the FIFO, so the interrupt stays on until the handler has read every byte.

Some codes to know:

| The keyboard sends | Meaning |
|--------------------|---------|
| `$1C` | A pressed |
| `$F0 $1C` | A released |
| `$E0 $75` | Cursor up pressed |
| `$E0 $F0 $75` | Cursor up released |
| `$AA` | Self-test passed: sent when the keyboard powers up or is reset |
| `$FA` | Acknowledge, after a byte sent to it |

### Sending to the keyboard

Write a byte to KBSEND when TXBUSY is 0. The controller holds the keyboard's clock for 100 µs, then sends the byte on the keyboard's own clock; TXBUSY goes back to 0 when the keyboard has taken it, or after 15 ms with KBIRQ.TIMEOUT set if it never does. The keyboard answers `$FA` through the FIFO; wait for it before the next byte.

```asm
; set the keyboard's lights: d1 = Scroll (bit 0), Num (1), Caps (2)
lights:     move.l  #$ED,d0
            bsr.s   kbsend
            move.l  d1,d0
kbsend:     btst    #KBSTAT_TXBUSY_B-8,KBSTAT+2(a5)
            bne.s   kbsend
            move.l  d0,KBSEND(a5)
.ack:       move.l  KBDATA(a5),d0       ; wait for $FA
            btst    #KBDATA_EMPTY_B,d0
            bne.s   .ack
            rts
```

(If the keyboard's interrupt is on, its handler will take the `$FA` instead; send from the handler's side, or turn DATA's enable off while sending.)

---

## Summary of Registers

| Name | Offset | Access | Function |
|------|--------|--------|----------|
| SDCON | `$300` | RW | EN (0), CS0 (1), CS1 (2), CLKDIV (15–8). After reset: off, CLKDIV 125 (400 kHz) |
| SDDATA | `$304` | RW | Write: send BYTE (7–0). Read: BYTE (7–0), BUSY (8) |
| SDCOUNT | `$308` | RW | COUNT (15–0): bytes to read for DMA port 0 |
| KBCON | `$400` | RW | EN (0) |
| KBSTAT | `$404` | R | COUNT (4–0), TXBUSY (8) |
| KBDATA | `$408` | R | BYTE (7–0), EMPTY (8); reading takes a byte |
| KBSEND | `$40C` | W | BYTE (7–0) |
| KBIRQ | `$410` | RW1C | DATA (0, live), PARITY (1), FRAME (2), OVERFLOW (3), TIMEOUT (4) |
| KBIRQEN | `$414` | RW | As KBIRQ |

All in the system block at `$F00000`. Related: DMA engine port 0 (the SD card; DMA Engine and Blitter Hardware chapter), interrupt source KEYB (17, Interrupts and Timers chapter).
