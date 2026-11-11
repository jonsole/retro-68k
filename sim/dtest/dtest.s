; DMA engine test ROM (spec 11). dgen.py puts random data, descriptors and
; a control table in Chip RAM; this program starts the 4 channels on their
; chains, waits for them all, checks that none stopped with an error and
; that each raised its interrupt, and prints PASS or FAIL. The testbench
; then dumps Chip RAM and dmodel.py checks every byte.
;
;   channel 0  a chain of descriptors in Chip RAM (START)
;   channel 1  a chain in the descriptor RAM (START)
;   channel 2  a chain in both (START)
;   channel 3  its first job written into its job registers (RUN), the
;              rest a chain in Chip RAM
;
; Then directed tests on single jobs (palettes, the ROM, registers, errors,
; STOP, PAUSE, port 1 both ways, HIGH, a timer start, MASK = 3), checked by the CPU.
; The PASS line itself is sent by a DMA job from the ROM to port 1. Run
; with +dmxsend (the PC sends the bytes the port test expects).
;
; The control table (keep in step with dgen.py):
CTL         equ     $0F0000
C_CH0       equ     $00                 ; channel 0's first descriptor
C_CH1       equ     $04
C_CH2       equ     $08
C_EXPECT    equ     $0C                 ; DMXINT bits to expect
C_JOB3      equ     $10                 ; channel 3's job registers (8 long words)
C_NDRAM     equ     $40                 ; long words of the descriptor RAM image ...
C_DRAM      equ     $44                 ; ... and the image

            include "hw.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            lea     CTL,a0

            ; the descriptor RAM image
            move.l  C_NDRAM(a0),d0
            lea     C_DRAM(a0),a1
            lea     DESCRAM(a4),a2
            bra.s   .dram1
.dram:      move.l  (a1)+,(a2)+
.dram1:     dbra    d0,.dram

            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
            move.l  #$F,DMXINTEN(a4)

            ; channel 3: the job registers
            lea     C_JOB3(a0),a1
            lea     DMX3(a4),a2
            moveq   #8-1,d0
.job3:      move.l  (a1)+,(a2)+
            dbra    d0,.job3

            ; start them all
            move.l  C_CH0(a0),DMX0+DMX_CHDESC(a4)
            move.l  C_CH1(a0),DMX1+DMX_CHDESC(a4)
            move.l  C_CH2(a0),DMX2+DMX_CHDESC(a4)
            move.l  #DMX_CHCTRL_START_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX0+DMX_CHCTRL(a4)
            move.l  #DMX_CHCTRL_START_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX1+DMX_CHCTRL(a4)
            move.l  #DMX_CHCTRL_START_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX2+DMX_CHCTRL(a4)
            move.l  #DMX_CHCTRL_RUN_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX3+DMX_CHCTRL(a4)

            ; wait for all four
.wait:      move.l  DMX0+DMX_CHSTAT(a4),d0
            or.l    DMX1+DMX_CHSTAT(a4),d0
            or.l    DMX2+DMX_CHSTAT(a4),d0
            or.l    DMX3+DMX_CHSTAT(a4),d0
            btst    #DMX_CHSTAT_BUSY_B,d0
            bne.s   .wait

            ; no errors, every channel done, and the interrupts asked for
            btst    #DMX_CHSTAT_ERR_B,d0
            bne.s   fail_err
            moveq   #0,d1
            lea     DMX0(a4),a1
            moveq   #4-1,d2
.done:      move.l  DMX_CHSTAT(a1),d0
            btst    #DMX_CHSTAT_DONE_B,d0
            beq.s   fail_done
            lea     DMX_SPAN(a1),a1
            dbra    d2,.done
            move.l  DMXINT(a4),d0
            cmp.l   C_EXPECT(a0),d0
            bne.s   fail_int
            move.l  #$F,DMXINT(a4)
            bsr     directed            ; a failure goes straight to failed
            lea     j_pass(pc),a1       ; PASS goes out by DMA: the boot ROM to port 1
            bsr     runjob
            bra.s   hang

fail_err:   lea     s_err(pc),a0
            bra.s   failed
fail_done:  lea     s_done(pc),a0
            bra.s   failed
fail_int:   lea     s_int(pc),a0
failed:     bsr     puts
hang:       bra.s   hang

; ---------------------------------------------------------------- directed tests
; Each runs on channel 0 (job registers and RUN) and is checked by the CPU.
; They use Chip RAM outside the area dmodel.py checks.
D_AREA      equ     $080000
COPY8       equ     ($CC<<DMX_CTRL_MINTERM_B)|(3<<DMX_CTRL_BPP_B)  ; BLIT D = B, 8 bpp, B from memory
FILL8       equ     COPY8|(DMX_KIND_VALUE<<DMX_CTRL_BKIND_B)          ; B is VALUE
CHGO        equ     DMX_CHCTRL_RUN_M|(1<<DMX_CHCTRL_CPUSHARE_B)

directed:   lea     D_AREA,a1           ; 16 long words of test data (palette colours)
            move.l  #$00102030,d0
            moveq   #16-1,d1
.data:      move.l  d0,(a1)+
            add.l   #$010203,d0
            and.l   #$FFFFFF,d0
            dbra    d1,.data

            lea     j_topal(pc),a1      ; Chip RAM -> PALETTE1
            lea     s_t1(pc),a0
            bsr     runok
            lea     D_AREA,a1
            lea     CUSTOM+PALETTE1,a2
            moveq   #16-1,d1
            bsr     cmpl

            lea     j_frompal(pc),a1    ; PALETTE1 -> Chip RAM
            lea     s_t2(pc),a0
            bsr     runok
            lea     D_AREA,a1
            lea     D_AREA+$100,a2
            moveq   #16-1,d1
            bsr     cmpl

            lea     j_rom(pc),a1        ; boot ROM -> Chip RAM
            lea     s_t3(pc),a0
            bsr     runok
            lea     ROM,a1
            lea     D_AREA+$200,a2
            moveq   #32-1,d1
            bsr     cmpl

            move.l  #$00900360,D_AREA+$300      ; Chip RAM -> layer 0 WINX and WINY
            move.l  #$00500200,D_AREA+$304
            lea     j_toreg(pc),a1
            lea     s_t4(pc),a0
            bsr     runok
            cmp.l   #$00900360,L0+L_WINX(a4)
            bne     failed
            cmp.l   #$00500200,L0+L_WINY(a4)
            bne     failed

            lea     j_fromreg(pc),a1    ; VIDSIZE -> Chip RAM
            lea     s_t5(pc),a0
            bsr     runok
            move.l  VIDSIZE(a4),d0
            cmp.l   D_AREA+$400,d0
            bne     failed

            lea     j_fillreg(pc),a1    ; FILL BGCOLOR
            lea     s_t6(pc),a0
            bsr     runok
            cmp.l   #$00123456,BGCOLOR(a4)
            bne     failed

            lea     j_todram(pc),a1     ; the descriptor RAM as data, both ways
            lea     s_t7(pc),a0
            bsr     runok
            lea     j_fromdram(pc),a1
            bsr     runok
            lea     D_AREA,a1
            lea     D_AREA+$500,a2
            moveq   #4-1,d1
            bsr     cmpl

            lea     j_bad(pc),a1        ; the system area: an error, CHERR its address
            lea     s_t8(pc),a0
            bsr     runjob
            btst    #DMX_CHSTAT_ERR_B,d0
            beq     failed
            cmp.l   #SYSTEM,DMX0+DMX_CHERR(a4)
            bne     failed
            move.l  #DMX_CHSTAT_ERR_M|DMX_CHSTAT_DONE_M,DMX0+DMX_CHSTAT(a4)
            lea     j_misreg(pc),a1     ; a reserved OP (7): an error
            lea     s_t9(pc),a0
            bsr     runjob
            btst    #DMX_CHSTAT_ERR_B,d0
            beq     failed
            move.l  #DMX_CHSTAT_ERR_M|DMX_CHSTAT_DONE_M,DMX0+DMX_CHSTAT(a4)
            lea     j_mask3(pc),a1      ; MASK = 3: an error
            lea     s_t16(pc),a0
            bsr     runjob
            btst    #DMX_CHSTAT_ERR_B,d0
            beq     failed
            move.l  #DMX_CHSTAT_ERR_M|DMX_CHSTAT_DONE_M,DMX0+DMX_CHSTAT(a4)
            move.l  #$F,DMXINT(a4)

            lea     j_ch1(pc),a1        ; a COPY into channel 1 CHCTRL starts it
            lea     DMX1(a4),a2
            moveq   #8-1,d1
.ch1:       move.l  (a1)+,(a2)+
            dbra    d1,.ch1
            move.l  #CHGO,D_AREA+$700
            lea     j_start1(pc),a1
            lea     s_t10(pc),a0
            bsr     runok
.w1:        btst    #DMX_CHSTAT_BUSY_B,DMX1+DMX_CHSTAT+3(a4)
            bne.s   .w1
            lea     D_AREA+$600,a1
            moveq   #8-1,d1
.c1:        cmp.l   #$A5A5A5A5,(a1)+
            bne     failed
            dbra    d1,.c1

            move.l  #$FFFFFFFF,$0AFFFC  ; job registers ignored while busy; STOP
            lea     j_big(pc),a1
            lea     DMX2(a4),a2
            moveq   #8-1,d1
.big:       move.l  (a1)+,(a2)+
            dbra    d1,.big
            move.l  #CHGO,DMX2+DMX_CHCTRL(a4)
            lea     s_t11(pc),a0
            move.l  #$12345678,DMX2+DMX_CTRL(a4)
            cmp.l   #FILL8,DMX2+DMX_CTRL(a4)
            bne     failed
            move.l  #DMX_CHCTRL_STOP_M|(1<<DMX_CHCTRL_CPUSHARE_B),DMX2+DMX_CHCTRL(a4)
.w2:        btst    #DMX_CHSTAT_BUSY_B,DMX2+DMX_CHSTAT+3(a4)
            bne.s   .w2
            btst    #DMX_CHSTAT_DONE_B,DMX2+DMX_CHSTAT+3(a4)
            beq     failed
            cmp.l   #$FFFFFFFF,$0AFFFC  ; stopped before the end
            bne     failed

            move.l  #$FFFFFFFF,$0B0000  ; PAUSE holds a job, and lets it go
            lea     j_pause(pc),a1
            lea     DMX2(a4),a2
            moveq   #8-1,d1
.pz:        move.l  (a1)+,(a2)+
            dbra    d1,.pz
            lea     s_t12(pc),a0
            move.l  #CHGO|DMX_CHCTRL_PAUSE_M,DMX2+DMX_CHCTRL(a4)
            moveq   #100,d1
.dly:       dbra    d1,.dly
            move.l  DMX2+DMX_CHSTAT(a4),d0
            and.l   #DMX_CHSTAT_BUSY_M|DMX_CHSTAT_PAUSED_M,d0
            cmp.l   #DMX_CHSTAT_BUSY_M|DMX_CHSTAT_PAUSED_M,d0
            bne     failed
            cmp.l   #$FFFFFFFF,$0B0000
            bne     failed
            move.l  #1<<DMX_CHCTRL_CPUSHARE_B,DMX2+DMX_CHCTRL(a4)
.w3:        btst    #DMX_CHSTAT_BUSY_B,DMX2+DMX_CHSTAT+3(a4)
            bne.s   .w3
            tst.l   $0B0000
            bne     failed

            lea     j_portin(pc),a1     ; port 1 to memory: the 64 bytes the PC sent (7i + 3)
            lea     s_t13(pc),a0
            bsr     runok
            lea     D_AREA+$800,a1
            moveq   #3,d0
            moveq   #64-1,d1
.pin:       cmp.b   (a1)+,d0
            bne     failed
            addq.b  #7,d0
            dbra    d1,.pin

            lea     j_high(pc),a1       ; a HIGH job (it may take the CPU cycles)
            lea     s_t14(pc),a0
            bsr     runok
            lea     D_AREA+$A00,a1
            moveq   #64-1,d1
.hi:        cmp.l   #$3C3C3C3C,(a1)+
            bne     failed
            dbra    d1,.hi

            lea     j_tmr(pc),a1        ; a timer starts channel 3 at the descriptor in CHDESC
            lea     CUSTOM+DESCRAM+$7E0,a2
            moveq   #8-1,d1
.td:        move.l  (a1)+,(a2)+
            dbra    d1,.td
            move.l  #CUSTOM+DESCRAM+$7E0,DMX3+DMX_CHDESC(a4)
            move.l  #20,TMR0+TMR_COUNT(a5)
            move.l  #0,TMR0+TMR_PRESCALE(a5)
            move.l  #TMR_CTRL_EN_M|TMR_CTRL_DMA_M|(3<<TMR_CTRL_DMACH_B),TMR0+TMR_CTRL(a5)
            lea     s_t15(pc),a0
            move.l  #10000,d1
.tw:        btst    #DMX_CHSTAT_DONE_B,DMX3+DMX_CHSTAT+3(a4)
            bne.s   .tdone
            subq.l  #1,d1
            bne.s   .tw
            bra     failed
.tdone:     move.l  #0,TMR0+TMR_CTRL(a5)
            lea     D_AREA+$900,a1
            moveq   #8-1,d1
.tc:        cmp.l   #$5A5A5A5A,(a1)+
            bne     failed
            dbra    d1,.tc
            rts

; run the job at a1 on channel 0, and fail (a0) if it stopped with an error
runok:      bsr.s   runjob
            btst    #DMX_CHSTAT_ERR_B,d0
            bne     failed
            rts
; run the job at a1 (8 long words) on channel 0; d0 = CHSTAT at the end
runjob:     lea     DMX0(a4),a2
            moveq   #8-1,d1
.l:         move.l  (a1)+,(a2)+
            dbra    d1,.l
            move.l  #CHGO,DMX0+DMX_CHCTRL(a4)
.w:         move.l  DMX0+DMX_CHSTAT(a4),d0
            btst    #DMX_CHSTAT_BUSY_B,d0
            bne.s   .w
            rts
; compare d1 + 1 long words at a1 and a2; fail (a0) on a difference
cmpl:       cmpm.l  (a1)+,(a2)+
            bne     failed
            dbra    d1,cmpl
            rts

;           CTRL   BPT                 DPT                         SIZE (HEIGHT<<16 | WIDTH)  APT STRIDE VALUE NEXT
j_topal:    dc.l   COPY8, D_AREA, CUSTOM+PALETTE1, (1<<16)|64, 0, 0, 0, 0
j_frompal:  dc.l   COPY8, CUSTOM+PALETTE1, D_AREA+$100, (1<<16)|64, 0, 0, 0, 0
j_rom:      dc.l   COPY8, ROM, D_AREA+$200, (1<<16)|128, 0, 0, 0, 0
j_toreg:    dc.l   COPY8, D_AREA+$300, CUSTOM+L0+L_WINX, (1<<16)|8, 0, 0, 0, 0
j_fromreg:  dc.l   COPY8, CUSTOM+VIDSIZE, D_AREA+$400, (1<<16)|4, 0, 0, 0, 0
j_fillreg:  dc.l   FILL8, 0, CUSTOM+BGCOLOR, (1<<16)|4, 0, 0, $00123456, 0
j_todram:   dc.l   COPY8, D_AREA, CUSTOM+DESCRAM+$700, (1<<16)|16, 0, 0, 0, 0
j_fromdram: dc.l   COPY8, CUSTOM+DESCRAM+$700, D_AREA+$500, (1<<16)|16, 0, 0, 0, 0
j_bad:      dc.l   COPY8, D_AREA, SYSTEM, (1<<16)|4, 0, 0, 0, 0
j_misreg:   dc.l   7|COPY8, D_AREA, D_AREA+$100, (1<<16)|4, 0, 0, 0, 0
j_ch1:      dc.l   FILL8, 0, D_AREA+$600, (1<<16)|32, 0, 0, $A5A5A5A5, 0
j_start1:   dc.l   COPY8, D_AREA+$700, CUSTOM+DMX1+DMX_CHCTRL, (1<<16)|4, 0, 0, 0, 0
j_big:      dc.l   FILL8, 0, $0A0000, (4<<16)|$4000, 0, $4000, 0, 0
j_pause:    dc.l   FILL8, 0, $0B0000, (1<<16)|256, 0, 0, 0, 0
j_portin:   dc.l   COPY8|(1<<DMX_CTRL_BKIND_B), 1, D_AREA+$800, (1<<16)|64, 0, 0, 0, 0
j_high:     dc.l   FILL8|DMX_CTRL_HIGH_M, 0, D_AREA+$A00, (1<<16)|256, 0, 0, $3C3C3C3C, 0
j_tmr:      dc.l   FILL8, 0, D_AREA+$900, (1<<16)|32, 0, 0, $5A5A5A5A, 0
j_pass:     dc.l   COPY8|(1<<DMX_CTRL_DKIND_B), s_pass, 1, (1<<16)|6, 0, 0, 0, 0

j_mask3:    dc.l   COPY8|(3<<DMX_CTRL_MASK_B), D_AREA, D_AREA+$100, (1<<16)|4, 0, 0, 0, 0

s_t1:       dc.b    "FAIL: T1 Chip RAM to a palette",13,10,0
s_t2:       dc.b    "FAIL: T2 a palette to Chip RAM",13,10,0
s_t3:       dc.b    "FAIL: T3 the boot ROM to Chip RAM",13,10,0
s_t4:       dc.b    "FAIL: T4 Chip RAM to layer registers",13,10,0
s_t5:       dc.b    "FAIL: T5 a register to Chip RAM",13,10,0
s_t6:       dc.b    "FAIL: T6 FILL a register",13,10,0
s_t7:       dc.b    "FAIL: T7 the descriptor RAM as data",13,10,0
s_t8:       dc.b    "FAIL: T8 the system area is an error",13,10,0
s_t9:       dc.b    "FAIL: T9 a reserved OP is an error",13,10,0
s_t10:      dc.b    "FAIL: T10 a COPY into CHCTRL starts a channel",13,10,0
s_t11:      dc.b    "FAIL: T11 job registers while busy, STOP",13,10,0
s_t12:      dc.b    "FAIL: T12 PAUSE",13,10,0
s_t13:      dc.b    "FAIL: T13 port 1 to memory",13,10,0
s_t14:      dc.b    "FAIL: T14 a HIGH job",13,10,0
s_t15:      dc.b    "FAIL: T15 a timer starts a channel",13,10,0
s_t16:      dc.b    "FAIL: T16 MASK = 3 is an error",13,10,0
            even

puts:       move.b  (a0)+,d0
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d0,SERDATA+3(a5)
            bra.s   puts
.done:      rts

s_pass:     dc.b    "PASS",13,10,0
s_err:      dc.b    "FAIL: a channel stopped with an error",13,10,0
s_done:     dc.b    "FAIL: a channel is not DONE",13,10,0
s_int:      dc.b    "FAIL: DMXINT is not as expected",13,10,0
            even
