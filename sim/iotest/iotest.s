; I/O test ROM: the SD card (spec 15) and the PS/2 keyboard (spec 16),
; against the testbench's models (sd_model.v, ps2_model.v). Run with
; +iotest (the keyboard then sends 1C F0 1C and a frame with bad parity).
;
;   SD card    start-up at 400 kHz: 80 clocks, CMD0, CMD8, ACMD41 until
;              ready, CMD58; then 25 MHz. Block 1 read and checked; written
;              to block 2; block 2 read back and compared.
;   keyboard   the three bytes in order; the bad frame dropped with PARITY
;              set; ED sent to the keyboard, its FA received.
;
; Prints PASS, or FAIL and what went wrong. The testbench also checks what
; the models saw (the byte the keyboard got, the block written).

            include "hw.inc"

BUF         equ     $090000             ; a block
SLOW        equ     SDCON_EN_M|(125<<SDCON_CLKDIV_B)        ; 400 kHz
FAST        equ     SDCON_EN_M|(2<<SDCON_CLKDIV_B)          ; 25 MHz

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            move.l  #KBCON_EN_M,KBCON(a5)               ; the keyboard on first: its bytes come early

; ---------------------------------------------------------------- SD card
            move.l  #SLOW,SDCON(a5)
            moveq   #10-1,d4                            ; 80 clocks, deselected
.clk:       moveq   #-1,d0
            bsr     spi
            dbra    d4,.clk
            move.l  #SLOW|SDCON_CS0_M,SDCON(a5)

            lea     s_cmd0(pc),a0
            moveq   #0,d1                               ; CMD0: idle
            moveq   #0,d2
            move.b  #$95,d3
            bsr     cmd
            cmp.b   #$01,d0
            bne     failed

            lea     s_cmd8(pc),a0
            moveq   #8,d1                               ; CMD8: voltage check
            move.l  #$1AA,d2
            move.b  #$87,d3
            bsr     cmd
            cmp.b   #$01,d0
            bne     failed
            bsr     get4
            cmp.l   #$000001AA,d0
            bne     failed

            lea     s_acmd41(pc),a0
            moveq   #20,d4
.acmd:      moveq   #55,d1                              ; CMD55, ACMD41 until ready
            moveq   #0,d2
            moveq   #-1,d3
            bsr     cmd
            moveq   #41,d1
            move.l  #$40000000,d2
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            beq.s   .ready
            subq.l  #1,d4
            bne.s   .acmd
            bra     failed
.ready:
            lea     s_cmd58(pc),a0
            moveq   #58,d1                              ; CMD58: the OCR (SDHC?)
            moveq   #0,d2
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            bne     failed
            bsr     get4
            btst    #30,d0
            beq     failed
            move.l  #FAST|SDCON_CS0_M,SDCON(a5)

            ; block 1 into BUF
            lea     s_rd(pc),a0
            moveq   #17,d1
            moveq   #1,d2
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            bne     failed
            bsr     token
            lea     BUF,a1
            move.w  #512-1,d2
.rd:        moveq   #-1,d0
            bsr     spi
            move.b  d0,(a1)+
            dbra    d2,.rd
            moveq   #-1,d0                              ; the CRC bytes
            bsr     spi
            moveq   #-1,d0
            bsr     spi
            lea     BUF,a1                              ; byte i = 7 + 3i
            moveq   #7,d1
            move.w  #512-1,d2
.chk:       cmp.b   (a1)+,d1
            bne     failed
            addq.b  #3,d1
            dbra    d2,.chk

            ; BUF to block 2
            lea     s_wr(pc),a0
            moveq   #24,d1
            moveq   #2,d2
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            bne     failed
            move.l  #$FE,d0                             ; the start token
            bsr     spi
            lea     BUF,a1
            move.w  #512-1,d2
.wr:        move.b  (a1)+,d0
            bsr     spi
            dbra    d2,.wr
            moveq   #-1,d0                              ; CRC
            bsr     spi
            moveq   #-1,d0
            bsr     spi
            moveq   #20,d4
.resp:      moveq   #-1,d0                              ; the data-response token
            bsr     spi
            cmp.b   #$FF,d0
            bne.s   .gotr
            subq.l  #1,d4
            bne.s   .resp
            bra     failed
.gotr:      and.b   #$1F,d0
            cmp.b   #$05,d0
            bne     failed
.busy:      moveq   #-1,d0                              ; busy: 0x00 until ready
            bsr     spi
            tst.b   d0
            beq.s   .busy

            ; block 2 back
            lea     s_rb(pc),a0
            moveq   #17,d1
            moveq   #2,d2
            moveq   #-1,d3
            bsr     cmd
            tst.b   d0
            bne     failed
            bsr     token
            lea     BUF,a1
            move.w  #512-1,d2
.rb:        moveq   #-1,d0
            bsr     spi
            cmp.b   (a1)+,d0
            bne     failed
            dbra    d2,.rb
            moveq   #-1,d0
            bsr     spi
            moveq   #-1,d0
            bsr     spi
            move.l  #FAST,SDCON(a5)                     ; deselect, one more byte
            moveq   #-1,d0
            bsr     spi

; ---------------------------------------------------------------- keyboard
            lea     s_kb(pc),a0
            move.l  #200000,d4
.kw:        move.l  KBSTAT(a5),d0                       ; three bytes, and the bad frame flagged
            and.l   #KBSTAT_COUNT_M,d0
            cmp.l   #3,d0
            bcs.s   .kn
            btst    #KBIRQ_PARITY_B,KBIRQ+3(a5)
            bne.s   .kgot
.kn:        subq.l  #1,d4
            bne.s   .kw
            bra     failed
.kgot:      move.l  KBSTAT(a5),d0
            and.l   #KBSTAT_COUNT_M,d0
            cmp.l   #3,d0                               ; the bad byte was dropped
            bne     failed
            move.l  KBDATA(a5),d0
            cmp.l   #$1C,d0
            bne     failed
            move.l  KBDATA(a5),d0
            cmp.l   #$F0,d0
            bne     failed
            move.l  KBDATA(a5),d0
            cmp.l   #$1C,d0
            bne     failed
            move.l  KBDATA(a5),d0                       ; empty now
            btst    #KBDATA_EMPTY_B,d0
            beq     failed
            move.l  #KBIRQ_PARITY_M,KBIRQ(a5)

            lea     s_ks(pc),a0                         ; send ED; the keyboard answers FA
            move.l  #$ED,KBSEND(a5)
.tx:        btst    #KBSTAT_TXBUSY_B-8,KBSTAT+2(a5)
            bne.s   .tx
            btst    #KBIRQ_TIMEOUT_B,KBIRQ+3(a5)
            bne     failed
            move.l  #200000,d4
.fa:        move.l  KBSTAT(a5),d0
            and.l   #KBSTAT_COUNT_M,d0
            bne.s   .fag
            subq.l  #1,d4
            bne.s   .fa
            bra     failed
.fag:       move.l  KBDATA(a5),d0
            cmp.l   #$FA,d0
            bne     failed

            lea     s_pass(pc),a0
            bsr     puts
hang:       bra.s   hang

failed:     bsr     puts
            bra.s   hang

; ---------------------------------------------------------------- SD helpers
; spi: send d0.b, return the byte received in d0
spi:        and.l   #$FF,d0
            move.l  d0,SDDATA(a5)
.w:         move.l  SDDATA(a5),d0
            btst    #SDDATA_BUSY_B,d0
            bne.s   .w
            and.l   #$FF,d0
            rts
; cmd: command d1 with argument d2 and CRC byte d3; d0 = R1 ($FF: no answer)
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
; get4: the 4 bytes after an R3 or R7, in d0
get4:       moveq   #0,d6
            moveq   #4-1,d5
.g:         moveq   #-1,d0
            bsr     spi
            lsl.l   #8,d6
            or.b    d0,d6
            dbra    d5,.g
            move.l  d6,d0
            rts
; token: wait for a data block's start token 0xFE (fail on an error token)
token:      moveq   #100,d5
.t:         moveq   #-1,d0
            bsr     spi
            cmp.b   #$FE,d0
            beq.s   .ok
            cmp.b   #$FF,d0
            bne     failed
            subq.l  #1,d5
            bne.s   .t
            bra     failed
.ok:        rts

puts:       move.b  (a0)+,d0
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d0,SERDATA+3(a5)
            bra.s   puts
.done:      rts

s_pass:     dc.b    "PASS",13,10,0
s_cmd0:     dc.b    "FAIL: CMD0",13,10,0
s_cmd8:     dc.b    "FAIL: CMD8",13,10,0
s_acmd41:   dc.b    "FAIL: ACMD41",13,10,0
s_cmd58:    dc.b    "FAIL: CMD58",13,10,0
s_rd:       dc.b    "FAIL: reading block 1",13,10,0
s_wr:       dc.b    "FAIL: writing block 2",13,10,0
s_rb:       dc.b    "FAIL: reading block 2 back",13,10,0
s_kb:       dc.b    "FAIL: keyboard bytes",13,10,0
s_ks:       dc.b    "FAIL: sending to the keyboard",13,10,0
            even
