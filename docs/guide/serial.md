# The USB Serial Link

This chapter describes the link between retro68k and a PC: a small FT232H USB module plugged onto the board's accelerator port. The link carries the console (text in and out), program uploads and debugging, and it is the first thing the boot ROM turns on. This chapter covers:

- how the link works, and how it compares with the Amiga's serial port,
- turning it on,
- sending and receiving bytes,
- flow control, and what happens when nobody is listening on the PC,
- serial interrupts, with a complete interrupt-driven console driver,
- the BREAK, RESET and UPLOAD commands the PC can send, even to a crashed machine.

Read "Working with the Hardware Registers" in the Introduction and System Control Hardware chapter first. The serial registers follow those rules.

## Introduction

On the PC, the link appears as an ordinary serial port, such as `/dev/ttyUSB1` on Linux or `COM5` on Windows, so any terminal program can use it. Underneath, it is not a serial line at all: the FT232H passes bytes to the FPGA eight bits at a time through a FIFO interface, at several megabytes per second each way. The baud rate you set on the PC is ignored.

```
      PC                   FT232H module                     FPGA
 +-----------+   USB   +----------------+   8-bit FIFO   +-----------------------+
 | terminal  |<------->| 1 KB buffer    |<-------------->| command recogniser    |
 | or upload |         | each way       |   D7-D0        |          |            |
 | tool      |         |                |   RXF# RD#     | receive FIFO, 2 KB    |---> SERDATA (read)
 +-----------+         +----------------+   TXE# WR#     | transmit FIFO, 2 KB   |<--- SERDATA (write)
                                            SIWU#        +-----------------------+

                  Figure 2-1: The USB Serial Link
```

Each direction has a 2 KB FIFO in the FPGA and another 1 KB in the FT232H. The hardware moves bytes between them by itself. Your program only reads and writes the FIFOs, through one data register, SERDATA.

### Comparison with the Amiga's Serial Port

| Feature | Amiga | retro68k |
|---------|-------|----------|
| Line | RS-232 UART | USB, through an FT232H in FIFO mode |
| Speed | Set by SERPER, up to about 30 KB/s in practice | Several MB/s; no speed to set |
| Buffering | One byte each way | 2 KB FIFOs each way, plus the FT232H's own 1 KB |
| Flow control | Software (XON/XOFF) or none | Automatic in hardware: nothing is ever lost |
| Data register | SERDAT (write), SERDATR (read) | SERDATA (read and write) |
| Interrupts | RBF (level 5) and TBE (level 1), one byte at a time | One source, level 3, with thresholds and a timeout |
| Break | A long space on the line | A 3-byte command in the data, recognised by hardware |

## Turning the Link On

The link is controlled by SERCON:

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | EN | 1: the link moves data. While EN is 0, nothing is sent or received, and bytes you write are thrown away |
| 1 | CTLEN | 1: recognise commands from the PC ("Commands from the PC" below). On after power-on |
| 2 | CTLLOCK | 1: keep RESET and UPLOAD working even while CTLEN is 0. Once set, software cannot clear it |
| 3 | TXDROP | 1: when the transmit FIFO is full, drop the oldest byte to make room, instead of filling up |

To turn the link on:

1. Write SERCON with EN set, and CTLEN set so the PC can always reach the machine.
2. If your program must never wait for the PC, for example because it may run with no PC attached, set TXDROP too.

```asm
        include "hw.inc"

        lea     SYSTEM,a5
        move.l  #SERCON_EN_M|SERCON_CTLEN_M|SERCON_TXDROP_M,SERCON(a5)
```

The link is not disturbed by a reset, so a terminal on the PC stays connected while the computer restarts. Do not rely on SERCON or the FIFOs holding anything in particular after a reset: write SERCON in full at start-up, as above.

### On the PC

Open the port in raw mode, so the PC does not change the bytes you send. On Linux:

```
stty -F /dev/ttyUSB1 raw -echo
```

Then use any terminal program, such as `picocom /dev/ttyUSB1` or `screen /dev/ttyUSB1`. The FT232H module's EEPROM must be set to 245 FIFO mode once before first use, with FTDI's FT_Prog tool.

## Sending Bytes

To send a byte, write it to the low byte of SERDATA. It goes into the transmit FIFO and the hardware sends it on. SERSTAT.TXSPACE (bits 11–0) tells you how many bytes of room are left in the FIFO, from 0 to 2048. Writing when TXSPACE is 0 loses the byte (and sets the TXOVF flag), unless TXDROP is set.

To send one byte:

1. Read the low half of SERSTAT and mask TXSPACE.
2. If it is 0, go back to step 1.
3. Write the byte to `SERDATA+3`.

```asm
; send d0.b over USB (a5 = SYSTEM; d1 is changed)
putc:   move.w  SERSTAT+2(a5),d1        ; low half: TXSPACE
        and.w   #SERSTAT_TXSPACE_M,d1
        beq.s   putc                    ; no room yet
        move.b  d0,SERDATA+3(a5)        ; send one byte
        rts

; send the zero-terminated string at a0
puts:   move.b  (a0)+,d0
        beq.s   .done
        bsr.s   putc
        bra.s   puts
.done:  rts
```

You can also write the byte with `MOVE.W` to `SERDATA+2` or `MOVE.L` to `SERDATA`, with the byte in bits 7–0. Each write sends exactly one byte.

Short messages appear on the PC at once. Normally an FT232H waits up to 16 ms before passing a few bytes to the PC; whenever the transmit FIFO empties, the FPGA tells the FT232H to send what it holds straight away.

### Sending a Block

Checking TXSPACE before every byte is slow. When you have many bytes to send, read TXSPACE once and write that many bytes without checking:

```asm
; send d1.l bytes from a0 (a5 = SYSTEM; d0, d1 and a0 are changed)
sendblk:
        tst.l   d1
        beq.s   .done
.more:  move.l  SERSTAT(a5),d0
        and.l   #SERSTAT_TXSPACE_M,d0   ; room for this many bytes
        beq.s   .more
        cmp.l   d1,d0
        bls.s   .n
        move.l  d1,d0                   ; but no more than are left
.n:     sub.l   d0,d1
        subq.w  #1,d0
.copy:  move.b  (a0)+,SERDATA+3(a5)
        dbra    d0,.copy
        tst.l   d1
        bne.s   .more
.done:  rts
```

## Receiving Bytes

Reading SERDATA takes the next byte from the receive FIFO. If a byte was waiting, bits 7–0 hold it and bit 8 (EMPTY) is 0. If the FIFO was empty, EMPTY is 1 and no byte is taken.

```asm
; wait for a byte from USB: d0.b = the byte (a5 = SYSTEM)
getc:   move.l  SERDATA(a5),d0
        btst    #SERDATA_EMPTY_B,d0
        bne.s   getc                    ; nothing yet
        rts
```

SERSTAT.RXCOUNT (bits 27–16) tells you how many bytes are waiting, so you can read that many without checking EMPTY each time:

```asm
; receive d1.l bytes to a0, waiting for them all (a5 = SYSTEM)
recvblk:
        tst.l   d1
        beq.s   .done
.more:  move.l  SERSTAT(a5),d0
        and.l   #SERSTAT_RXCOUNT_M,d0
        beq.s   .more
        swap    d0                      ; bytes waiting
        cmp.l   d1,d0
        bls.s   .n
        move.l  d1,d0                   ; but no more than we want
.n:     sub.l   d0,d1
        subq.w  #1,d0
.copy:  move.b  SERDATA+3(a5),(a0)+
        dbra    d0,.copy
        tst.l   d1
        bne.s   .more
.done:  rts
```

A read of SERDATA's low half takes a byte, so take care how you read it:

- Read it with `MOVE.L SERDATA` (the high half, then the low), or with `MOVE.W` or `MOVE.B` of its low half (`SERDATA+2` or `SERDATA+3`). Each of these takes exactly one byte.
- A read of the high half alone takes nothing.
- Do not use instructions that read a register before writing it, such as `CLR`, `TAS`, `BSET`, or `ADDQ` on memory, at SERDATA.

## Flow Control

The link has flow control in hardware, in both directions, so you never need XON/XOFF or RTS/CTS.

- **From the PC.** The FPGA reads from the FT232H only while the receive FIFO has room. When the FIFO is full, the FT232H's buffer fills, and USB then holds the PC back. Nothing is lost, however fast the PC sends and however slowly your program reads.
- **To the PC.** The FPGA writes to the FT232H only when it has room. If the program on the PC stops reading, the FT232H's buffer fills, and then the transmit FIFO. TXSPACE drops to 0, and a program that waits for room, such as `putc` above, waits too.

### When Nobody Is Listening

If no program on the PC has the port open, or no module is fitted, nothing drains the transmit FIFO. A program that only prints debug messages should not stop because of that. You have two choices:

- **Treat a full FIFO as "nobody listening".** If TXSPACE stays at 0 for a long time, stop sending.
- **Set SERCON.TXDROP.** When the FIFO is full, each new byte pushes out the oldest one, so writes never wait and the PC sees the most recent output when it opens the port. SERDROP counts the bytes dropped since you last read it; reading it sets it back to 0.

Without TXDROP, a byte written while the FIFO is full is lost, and the sticky flag SERIRQ.TXOVF is set to tell you.

## Serial Interrupts

Polling is fine for a boot ROM or a simple monitor, but a program with other work to do can let the link interrupt it. The link has four interrupt flags, in SERIRQ:

| Bit | Flag | Set when | Cleared |
|-----|------|----------|---------|
| 0 | RXREADY | At least RXLEVEL bytes are waiting | By itself, when you read the count below RXLEVEL |
| 1 | RXTIMEOUT | At least one byte has waited for SERTIME microseconds without reaching RXLEVEL, and no byte has arrived or been read in that time | Sticky: write 1 |
| 2 | TXREADY | At least TXLEVEL bytes of room are free in the transmit FIFO | By itself, when the free room drops below TXLEVEL |
| 3 | TXOVF | A byte was written while the transmit FIFO was full, and was lost | Sticky: write 1 |

The thresholds are in **SERLEVEL**: RXLEVEL in bits 27–16 and TXLEVEL in bits 11–0. A level of 0 turns that flag off. **SERTIME** holds the timeout in microseconds (bits 15–0); 0 turns RXTIMEOUT off.

RXREADY and TXREADY follow the FIFOs: they stay set for as long as the condition holds, and writing to them does nothing. An interrupt handler must therefore make the condition go away, by reading the bytes or by turning the enable off. The timeout catches the end of a message that is shorter than RXLEVEL, so you can use a large RXLEVEL for bulk data without polling for the last few bytes.

A typical console driver uses RXLEVEL = 1, an interrupt for every key. For bulk data, use a larger level, such as 256, with a short timeout, such as 100 microseconds.

**SERIRQEN** has the same layout as SERIRQ. A flag interrupts only while its bit in SERIRQEN is set. All of the link's flags share one interrupt source:

| Source | Vector | Default level | hw.inc |
|--------|--------|---------------|--------|
| 15 | 79 (`$13C`) | 3 | `INT_SERIAL`; vector `VECBASE_DEFAULT+INT_SERIAL` |

To take serial interrupts:

1. Put your handler's address in the vector table at vector 79. The vector table must be in RAM, with the overlay off.
2. Set the thresholds in SERLEVEL, and the timeout in SERTIME if you use RXTIMEOUT.
3. Set the flags you want in SERIRQEN.
4. Enable source 15 (`INT_SERIAL`) in INTENA, and set INTCON.MASTER. Source 15 is bit 16 (`INTB_SERIAL`), in INTENA's high half, whose SET/CLR bit is bit 31.
5. Lower the CPU's interrupt mask to 2 or less.

In the handler:

1. Read all the bytes waiting, and send what you can.
2. Turn TXREADY off in SERIRQEN if you have nothing more to send. Otherwise it interrupts again as soon as you return.
3. Clear RXTIMEOUT and TXOVF by writing 1 to them, if you use them.
4. Return with RTE.

### Example: An Interrupt-Driven Console

This driver keeps a 256-byte ring buffer for each direction. The handler fills the receive ring and empties the transmit ring; the program calls `sgetc` and `sputc`, which never touch the hardware FIFOs. TXREADY is on only while the transmit ring holds something.

```asm
; An interrupt-driven console with a 256-byte ring each way.
        include "hw.inc"

VECTORS     equ $000000
RXBUF       equ $009000             ; 256 bytes
TXBUF       equ $009100             ; 256 bytes
rx_head     equ $009200             ; word: next free place (written by the handler)
rx_tail     equ $009202             ; word: next byte to read (written by the program)
tx_head     equ $009204             ; word: next free place (written by the program)
tx_tail     equ $009206             ; word: next byte to send (written by the handler)

; set up: a5 = SYSTEM, vector table in RAM, overlay off
serinit:
        clr.l   rx_head                 ; rx_head and rx_tail (CLR.L is fine in RAM)
        clr.l   tx_head                 ; tx_head and tx_tail
        move.l  #serint,VECTORS+(VECBASE_DEFAULT+INT_SERIAL)*4
        move.l  #SERCON_EN_M|SERCON_CTLEN_M,SERCON(a5)
        move.l  #(1<<SERLEVEL_RXLEVEL_B)|1,SERLEVEL(a5) ; 1 byte waiting, 1 byte of room
        move.l  #SERIRQ_RXREADY_M,SERIRQEN(a5)          ; TXREADY only when needed
        move.w  #(INTENA_SETCLRH_M|(1<<INTB_SERIAL))>>16,INTENA(a5)  ; high half: set source 15
        move.l  #INTCON_MASTER_M,INTCON(a5)
        move.w  #$2000,sr               ; take interrupts of level 1 and up
        rts

; the serial interrupt handler (level 3, vector 79)
serint: movem.l d0-d1/a0/a5,-(sp)
        lea     SYSTEM,a5

        ; receive: take every byte waiting
        lea     RXBUF,a0
        move.w  rx_head,d1
.rx:    move.l  SERDATA(a5),d0
        btst    #SERDATA_EMPTY_B,d0
        bne.s   .rxdone
        move.b  d0,(a0,d1.w)            ; store it at the head
        move.w  d1,d0
        addq.b  #1,d0                   ; the next place, wrapping at 256
        cmp.w   rx_tail,d0
        beq.s   .rx                     ; ring full: this byte is lost
        move.w  d0,d1
        bra.s   .rx
.rxdone:
        move.w  d1,rx_head

        ; send: as much as the FIFO takes
        lea     TXBUF,a0
        move.w  tx_tail,d1
.tx:    cmp.w   tx_head,d1
        beq.s   .txoff                  ; the ring is empty
        move.w  SERSTAT+2(a5),d0
        and.w   #SERSTAT_TXSPACE_M,d0
        beq.s   .txdone                 ; FIFO full: TXREADY brings us back
        move.b  (a0,d1.w),SERDATA+3(a5)
        addq.b  #1,d1
        bra.s   .tx
.txoff: move.l  #SERIRQ_RXREADY_M,SERIRQEN(a5)  ; TXREADY off, or it never stops
.txdone:
        move.w  d1,tx_tail
        movem.l (sp)+,d0-d1/a0/a5
        rte

; queue d0.b to send, waiting while the ring is full (a5 = SYSTEM)
sputc:  movem.l d1/a0,-(sp)
        lea     TXBUF,a0
        move.w  tx_head,d1
        move.b  d0,(a0,d1.w)
        addq.b  #1,d1
.full:  cmp.w   tx_tail,d1
        beq.s   .full                   ; ring full: wait for the handler
        move.w  d1,tx_head
        move.l  #SERIRQ_RXREADY_M|SERIRQ_TXREADY_M,SERIRQEN(a5)
        movem.l (sp)+,d1/a0
        rts

; d0.l = next byte received, or -1 (N set) if there is none
sgetc:  movem.l d1/a0,-(sp)
        moveq   #-1,d0
        move.w  rx_tail,d1
        cmp.w   rx_head,d1
        beq.s   .done
        lea     RXBUF,a0
        moveq   #0,d0
        move.b  (a0,d1.w),d0
        addq.b  #1,d1
        move.w  d1,rx_tail
.done:  movem.l (sp)+,d1/a0
        tst.l   d0
        rts
```

Both the program and the handler write SERIRQEN with a whole new value instead of changing bits, so neither can undo the other's change halfway through. The program turns TXREADY on only after it has moved `tx_head`, so the handler always finds the new byte.

## Commands from the PC

The PC can control the computer through the link, even when the 68000 has crashed with interrupts off. There is no separate break signal in FIFO mode, so the PC sends commands in the data stream, and hardware in the FPGA picks them out. While command recognition is on, two byte values are kept for the link:

- `$C0` starts a command: `$C0`, then a command byte c, then its inverse ~c.
- `$DB` starts an escape: the PC sends a data `$C0` as `$DB $DC`, and a data `$DB` as `$DB $DD`. The hardware turns them back into `$C0` and `$DB` before they reach the receive FIFO.

Every other byte goes straight through. (This is the scheme SLIP, an old serial-line protocol, uses.)

| c | ~c | Command | Effect |
|---|----|---------|--------|
| `$01` | `$FE` | BREAK | A non-maskable interrupt (level 7, vector 31), with NMISTAT.USB set. Use it to enter a debugger |
| `$02` | `$FD` | RESET | Reset the computer, with RESETWHY.USB set |
| `$03` | `$FC` | UPLOAD | Reset the computer with RESETWHY.UPLOAD set, so the boot ROM waits for a program over the link |

- A command's 3 bytes and the escape bytes are removed from the data: your program sees only the data, in order, and so does the DMA engine.
- No data byte ever waits for the next one, so a message can end with any byte.
- A broken command (a wrong inverse, or an unknown c) is dropped.
- A plain terminal program sends its bytes unescaped. That is fine for ASCII text, which never contains `$C0` or `$DB`. For binary data, or non-ASCII text, use the PC tool `tools/rlink.py`, which escapes.

### Sending a Command from the PC

The PC tool `tools/rlink.py` sends commands (`rlink.py reset`, `break`, `uploadmode`) and escapes everything else it sends. Without it, on Linux, after setting the port to raw mode, a RESET is:

```
printf '\xc0\x02\xfd' > /dev/ttyUSB1
```

Or from Python, with the escaping a program needs when it sends data too:

```python
def r68k_command(f, c):
    f.write(bytes([0xC0, c, c ^ 0xFF]))

def r68k_escape(data):
    return data.replace(b"\xdb", b"\xdb\xdd").replace(b"\xc0", b"\xdb\xdc")

with open("/dev/ttyUSB1", "wb", buffering=0) as f:
    f.write(r68k_escape(b"some data"))
    r68k_command(f, 0x01)      # BREAK
```

### Handling BREAK

BREAK arrives as an NMI through vector 31, the same vector as the NMI button. NMISTAT tells you which it was: bit 0 (BUTTON) for the button, bit 1 (USB) for BREAK. Both flags are sticky; clear the ones you have seen. BREAK gives an NMI only while CTLEN is set and NMICON.USBEN is set (it is after reset).

```asm
; NMI (vector 31): the NMI button, or BREAK from the PC
nmi:    movem.l d0/a5,-(sp)
        lea     SYSTEM,a5
        move.l  NMISTAT(a5),d0
        move.l  d0,NMISTAT(a5)          ; clear the flags we saw
        btst    #NMISTAT_USB_B,d0
        beq.s   .done                   ; the NMI button: handle it here
        bsr     monitor                 ; BREAK from the PC: enter the debugger
.done:  movem.l (sp)+,d0/a5
        rte
```

### Handling RESET and UPLOAD

RESET and UPLOAD reset the computer like the reset button. Your start-up code can tell them apart by RESETWHY (see "Why Was I Reset?" in the Introduction and System Control Hardware chapter). After UPLOAD, the boot ROM is meant to wait for a program over the link instead of starting normally. The upload protocol is defined with the boot ROM and is not part of this chapter; the current boot ROM does not have an upload loader yet.

### Turning Commands Off

Some programs need every byte the PC sends, unchanged and unescaped. Clearing SERCON.CTLEN turns command recognition off, and BREAK with it. To keep a way to reset the machine from the PC, set CTLLOCK first: while CTLLOCK is set, RESET and UPLOAD still work.

```asm
        move.l  SERCON(a5),d0
        bset    #SERCON_CTLLOCK_B,d0    ; RESET and UPLOAD keep working
        bclr    #SERCON_CTLEN_B,d0      ; everything else passes through
        move.l  d0,SERCON(a5)
```

While CTLLOCK is set, the escapes are still decoded, so the PC must keep escaping. With both CTLEN and CTLLOCK clear, every byte goes to the FIFO as it is, `$C0` and `$DB` too, and the PC must not escape.

## Bulk Transfers with DMA

The DMA engine, when it is built, will be able to move whole files between the link and Chip RAM by itself, paced by the FIFOs, while the CPU does other work. The link is the DMA engine's port 1. Commands from the PC are still recognised during a DMA transfer. The DMA engine has its own chapter.

## Summary of Serial Registers

| Name | Address | Access | Function |
|------|---------|--------|----------|
| SERCON | `$F00200` | RW | EN (0) link on; CTLEN (1) recognise PC commands; CTLLOCK (2) keep RESET and UPLOAD; TXDROP (3) drop oldest when full |
| SERSTAT | `$F00204` | R | RXCOUNT (27–16) bytes waiting; TXSPACE (11–0) room to send, 0–2048 |
| SERDATA | `$F00208` | RW | Read: EMPTY (8), byte (7–0), takes one byte. Write: byte (7–0), sends one byte |
| SERLEVEL | `$F0020C` | RW | RXLEVEL (27–16), TXLEVEL (11–0): interrupt thresholds; 0 = off |
| SERTIME | `$F00210` | RW | Receive timeout in microseconds (15–0); 0 = off |
| SERIRQ | `$F00214` | RW1C | RXREADY (0), RXTIMEOUT (1, W1C), TXREADY (2), TXOVF (3, W1C) |
| SERIRQEN | `$F00218` | RW | Interrupt enables, same layout as SERIRQ |
| SERDROP | `$F0021C` | R | Bytes dropped by TXDROP since the last read; reading clears it |

| Item | Value |
|------|-------|
| Interrupt source | 15 (SERIAL), vector 79, level 3 by default |
| Commands and escapes | `$C0 c ~c`; data `$C0` sent as `$DB $DC`, data `$DB` as `$DB $DD` |
| Commands | `$01` BREAK (NMI), `$02` RESET, `$03` UPLOAD |
| FIFOs | 2 KB each way in the FPGA, 1 KB each way in the FT232H |
