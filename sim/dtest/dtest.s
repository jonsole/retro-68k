; Blitter test ROM (spec 11). dgen.py puts random data, descriptors and a
; control table in Chip RAM; this program runs the chains one after
; another, checks that none stopped with an error and that each set
; DMXINT at its end, and prints PASS or FAIL. The testbench then dumps
; Chip RAM and dmodel.py checks every byte. Every depth, mask kind, row
; direction and stride sign is among dgen.py's jobs.
;
; Then directed tests, checked by the CPU: the registers, a job by RUN and
; by START, a chain with and without IRQ on its first job, the errors,
; writes while busy, STOP, BLTEN, the interrupt request, and the memory
; slot plan (the default one, and one with the blitter owner of every slot).
;
; The control table (keep in step with dgen.py):
CTL         equ     $0F0000             ; the number of chains, then 9 long words a chain:
                                        ; the first descriptor (START), or 0 and a job (RUN)

            include "hw.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
            move.l  #DMXINT_BLT_M,DMXINTEN(a4)

            lea     CTL,a3
            move.l  (a3)+,d7
            bra.s   .next
.chain:     move.l  (a3)+,d0
            beq.s   .run
            move.l  d0,BLTDESC(a4)      ; a chain in Chip RAM
            lea     32(a3),a3
            move.l  #BLTCMD_START_M,BLTCMD(a4)
            bra.s   .wait
.run:       lea     BLTCTRL(a4),a2      ; the first job in the job registers
            moveq   #8-1,d1
.job:       move.l  (a3)+,(a2)+
            dbra    d1,.job
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
.wait:      move.l  BLTSTAT(a4),d0
            btst    #BLTSTAT_BUSY_B,d0
            bne.s   .wait
            btst    #BLTSTAT_ERR_B,d0
            bne.s   fail_err
            btst    #DMXINT_BLT_B,DMXINT+3(a4)
            beq.s   fail_int
            move.l  #DMXINT_BLT_M,DMXINT(a4)
.next:      dbra    d7,.chain

            bsr     directed            ; a failure goes straight to failed
            lea     s_pass(pc),a0
            bsr     puts
            bra.s   hang

fail_err:   lea     s_err(pc),a0
            bra.s   failed
fail_int:   lea     s_int(pc),a0
failed:     bsr     puts
hang:       bra.s   hang

; ---------------------------------------------------------------- directed tests
; They use Chip RAM outside the area dmodel.py checks.
D_AREA      equ     $080000
DSC         equ     D_AREA+$E00         ; descriptors, 32 bytes each
BIG         equ     $0A0000             ; 64 KB
SMALL       equ     $0B0000
COPY8       equ     ($CC<<BLTCTRL_MINTERM_B)|(3<<BLTCTRL_BPP_B)  ; D = B, 8 bpp, B from memory
FILL8       equ     COPY8|BLTCTRL_BCONST_M                       ; B is VALUE

directed:   lea     D_AREA,a1           ; 16 long words of test data
            move.l  #$00102030,d0
            moveq   #16-1,d1
.data:      move.l  d0,(a1)+
            add.l   #$01020304,d0
            dbra    d1,.data
            lea     descs(pc),a1        ; the descriptors into Chip RAM
            lea     DSC,a2
            moveq   #6*8-1,d1
.desc:      move.l  (a1)+,(a2)+
            dbra    d1,.desc

            ; T1: the job registers read back, a byte written on its own; BLTDESC
            lea     s_t1(pc),a0
            lea     j_regs(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.r1:        move.l  (a1)+,(a2)+
            dbra    d1,.r1
            lea     j_regs(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
            bsr     cmpl
            move.b  #$5A,BLTSIZE+2(a4)
            cmp.l   #$ABCD5A01,BLTSIZE(a4)
            bne     failed
            move.l  #$00C81235,BLTDESC(a4)      ; bits 23-22 and bit 0 are not kept
            cmp.l   #$00081234,BLTDESC(a4)
            bne     failed

            ; T2: a fill by RUN; the bytes either side untouched
            lea     s_t2(pc),a0
            move.l  #$FFFFFFFF,D_AREA+$A00-4
            move.l  #$FFFFFFFF,D_AREA+$B00
            lea     j_fill(pc),a1
            bsr     runok
            lea     D_AREA+$A00,a1
            moveq   #64-1,d1
.f:         cmp.l   #$3C3C3C3C,(a1)+
            bne     failed
            dbra    d1,.f
            cmp.l   #$FFFFFFFF,(a1)
            bne     failed
            cmp.l   #$FFFFFFFF,D_AREA+$A00-4
            bne     failed
            btst    #DMXINT_BLT_B,DMXINT+3(a4)  ; DMXINT at the end, with or without IRQ
            beq     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)

            ; T3: a copy by START; the job registers hold the descriptor after
            lea     s_t3(pc),a0
            move.l  #DSC,BLTDESC(a4)
            bsr     startok
            lea     D_AREA,a1
            lea     D_AREA+$100,a2
            moveq   #16-1,d1
            bsr     cmpl
            lea     DSC,a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
            bsr     cmpl
            cmp.l   #DSC,BLTDESC(a4)
            bne     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)

            ; T4: a chain. Its first job has no IRQ: DMXINT stays clear until the end
            lea     s_t4(pc),a0
            clr.l   SMALL+$0C
            move.l  #DSC+$20,BLTDESC(a4)
            move.l  #BLTCMD_START_M,BLTCMD(a4)
            move.l  #100000,d1
.c1:        cmp.l   #$11111111,SMALL+$0C        ; the first job is done
            beq.s   .c1d
            subq.l  #1,d1
            bne.s   .c1
            bra     failed
.c1d:       btst    #DMXINT_BLT_B,DMXINT+3(a4)
            bne     failed
            btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            beq     failed
            bsr     waitok
            btst    #DMXINT_BLT_B,DMXINT+3(a4)
            beq     failed
            cmp.l   #$22222222,BIG+$FFFC
            bne     failed
            cmp.l   #DSC+$40,BLTDESC(a4)        ; the last descriptor run
            bne     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)
            ; ... and with IRQ: DMXINT while the second job runs
            lea     s_t5(pc),a0
            or.l    #BLTCTRL_IRQ_M,DSC+$20
            move.l  #DSC+$20,BLTDESC(a4)
            move.l  #BLTCMD_START_M,BLTCMD(a4)
            move.l  #100000,d1
.c2:        btst    #DMXINT_BLT_B,DMXINT+3(a4)
            bne.s   .c2d
            subq.l  #1,d1
            bne.s   .c2
            bra     failed
.c2d:       btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            beq     failed
            bsr     waitok
            move.l  #DMXINT_BLT_M,DMXINT(a4)

            ; T6: MASK = 3 is an error: ERR and DMXINT, nothing written
            lea     s_t6(pc),a0
            move.l  #$FFFFFFFF,D_AREA+$200
            lea     j_mask3(pc),a1
            bsr     runjob
            btst    #BLTSTAT_ERR_B,d0
            beq     failed
            btst    #DMXINT_BLT_B,DMXINT+3(a4)
            beq     failed
            cmp.l   #$FFFFFFFF,D_AREA+$200
            bne     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)
            ; T7: an error in a chain: the chain ends, BLTDESC names the descriptor;
            ; the next start clears ERR
            lea     s_t7(pc),a0
            move.l  #DSC+$60,BLTDESC(a4)
            move.l  #BLTCMD_START_M,BLTCMD(a4)
            bsr     waitend
            btst    #BLTSTAT_ERR_B,d0
            beq     failed
            cmp.l   #$33333333,SMALL+$10        ; the job before it ran
            bne     failed
            cmp.l   #DSC+$80,BLTDESC(a4)
            bne     failed
            lea     j_fill(pc),a1
            bsr     runok
            move.l  #DMXINT_BLT_M,DMXINT(a4)

            ; T8: the job registers and BLTDESC are not written while busy; STOP
            ; ends the job and the chain
            lea     s_t8(pc),a0
            move.l  #$FFFFFFFF,BIG+$FFFC
            move.l  #$FFFFFFFF,SMALL+$20
            lea     j_big(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.big:       move.l  (a1)+,(a2)+
            dbra    d1,.big
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            move.l  #$12345678,BLTCTRL(a4)
            cmp.l   #FILL8,BLTCTRL(a4)
            bne     failed
            move.l  #$00123456,BLTDESC(a4)
            cmp.l   #DSC+$80,BLTDESC(a4)
            bne     failed
            move.l  #BLTCMD_STOP_M,BLTCMD(a4)
            bsr     waitok
            btst    #DMXINT_BLT_B,DMXINT+3(a4)
            beq     failed
            tst.l   BIG                         ; it had started ...
            bne     failed
            cmp.l   #$FFFFFFFF,BIG+$FFFC        ; ... and stopped before the end
            bne     failed
            cmp.l   #$FFFFFFFF,SMALL+$20        ; the chain was not followed
            bne     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)

            ; T9: with DMACON.BLTEN clear a job waits
            lea     s_t9(pc),a0
            move.l  #$FFFFFFFF,SMALL+$30
            move.w  #DMACON_BLTEN_M,DMACON+2(a4)
            lea     j_held(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.held:      move.l  (a1)+,(a2)+
            dbra    d1,.held
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            moveq   #100,d1
.dly:       dbra    d1,.dly
            btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            beq     failed
            cmp.l   #$FFFFFFFF,SMALL+$30
            bne     failed
            move.w  #DMACON_SETCLR_M|DMACON_BLTEN_M,DMACON+2(a4)
            bsr     waitok
            cmp.l   #$44444444,SMALL+$30
            bne     failed

            ; T10: the interrupt request (source 4) is DMXINT and DMXINTEN
            lea     s_t10(pc),a0
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            beq     failed
            clr.l   DMXINTEN(a4)
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            bne     failed
            move.l  #DMXINT_BLT_M,DMXINTEN(a4)
            move.l  #DMXINT_BLT_M,DMXINT(a4)
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            bne     failed

            ; The slot plan (MEMSLOT0-4), by the time the CPU takes for 32
            ; Chip RAM reads while an 8 KB fill runs (spec 5, section 10)
            lea     s_t17(pc),a0
            lea     plan0(pc),a1        ; the default plan reads back
            lea     MEMSLOT0(a4),a2
            moveq   #5-1,d1
            bsr     cmpl
            lea     s_t18(pc),a0
            bsr     reads32             ; no job: d3 = the time with no waits
            move.l  d2,d3
            lea     j_time(pc),a1       ; a job: the CPU never waits
            bsr     timejob
            sub.l   d3,d2
            cmp.l   #10,d2
            bge     failed
            lea     s_t19(pc),a0
            moveq   #MEMSLOT0_BLT_M,d0  ; a plan with the blitter owner of every slot
            lea     MEMSLOT0(a4),a2
            moveq   #5-1,d1
.pl1:       move.l  d0,(a2)+
            dbra    d1,.pl1
            clr.l   $0C1FFC
            lea     j_time(pc),a1       ; the job and the CPU both still run (the blitter
            bsr     timejob             ; asks for too few cycles to hold the CPU off)
            cmp.l   #$69696969,$0C1FFC
            bne     failed
            lea     plan0(pc),a1        ; the default plan back
            lea     MEMSLOT0(a4),a2
            moveq   #5-1,d1
.pl2:       move.l  (a1)+,(a2)+
            dbra    d1,.pl2
            lea     s_t17(pc),a0
            lea     plan0(pc),a1
            lea     MEMSLOT0(a4),a2
            moveq   #5-1,d1
            bsr     cmpl
            rts

; run the job at a1 (8 long words) by RUN; d0 = BLTSTAT at the end
runjob:     lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.l:         move.l  (a1)+,(a2)+
            dbra    d1,.l
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
waitend:    move.l  BLTSTAT(a4),d0
            btst    #BLTSTAT_BUSY_B,d0
            bne.s   waitend
            rts
; the same, and fail (a0) if it stopped with an error
runok:      bsr.s   runjob
            btst    #BLTSTAT_ERR_B,d0
            bne     failed
            rts
; START, wait, and fail (a0) on an error
startok:    move.l  #BLTCMD_START_M,BLTCMD(a4)
; wait for the end, and fail (a0) on an error
waitok:     bsr.s   waitend
            btst    #BLTSTAT_ERR_B,d0
            bne     failed
            rts
; run the job at a1 and time 32 Chip RAM reads while it runs: d2 = their
; time in 10 ns units; fail (a0) if the job ended with an error
timejob:    lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.l:         move.l  (a1)+,(a2)+
            dbra    d1,.l
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            bsr.s   reads32
            bra.s   waitok
; time 32 Chip RAM reads (TIME, 10 ns units) into d2
reads32:    lea     D_AREA,a3
            move.l  TIMEHI(a5),d0
            move.l  TIMELO(a5),d2
            rept    32
            tst.w   (a3)
            endr
            move.l  TIMEHI(a5),d0
            move.l  TIMELO(a5),d0
            sub.l   d2,d0
            move.l  d0,d2
            rts
; compare d1 + 1 long words at a1 and a2; fail (a0) on a difference
cmpl:       cmpm.l  (a1)+,(a2)+
            bne     failed
            dbra    d1,cmpl
            rts

;           CTRL   BPT   DPT   SIZE (HEIGHT<<16 | WIDTH)   APT   STRIDE (B<<16 | D)   VALUE (ASTRIDE<<16 | VALUE)   NEXT
j_regs:     dc.l   $A5062535, $05123456, $03654320, $ABCD0001, $07111110, $80017FFF, $12345678, $00222222
j_fill:     dc.l   FILL8, 0, D_AREA+$A00, (1<<16)|256, 0, 0, $3C3C, 0
j_mask3:    dc.l   COPY8|(3<<BLTCTRL_MASK_B), D_AREA, D_AREA+$200, (1<<16)|4, 0, 0, 0, 0
j_big:      dc.l   FILL8, 0, BIG, (4<<16)|$4000, 0, $4000, 0, DSC+$A0
j_held:     dc.l   FILL8, 0, SMALL+$30, (1<<16)|4, 0, 0, $4444, 0
j_time:     dc.l   FILL8, 0, $0C0000, (1<<16)|$2000, 0, 0, $6969, 0
; the descriptors, copied to DSC
descs:      dc.l   COPY8, D_AREA, D_AREA+$100, (1<<16)|64, 0, 0, 0, 0                   ; +$00 T3
            dc.l   FILL8, 0, SMALL, (1<<16)|16, 0, 0, $1111, DSC+$40                    ; +$20 T4: a chain ...
            dc.l   FILL8, 0, BIG, (4<<16)|$4000, 0, $4000, $2222, 0                     ; +$40
            dc.l   FILL8, 0, SMALL+$10, (1<<16)|4, 0, 0, $3333, DSC+$80                 ; +$60 T7: a job ...
            dc.l   COPY8|(3<<BLTCTRL_MASK_B), D_AREA, D_AREA+$200, (1<<16)|4, 0, 0, 0, 0   ; +$80 ... then an error
            dc.l   FILL8, 0, SMALL+$20, (1<<16)|4, 0, 0, 0, 0                           ; +$A0 T8: after the stopped job

s_t1:       dc.b    "FAIL: T1 the job registers and BLTDESC read back",13,10,0
s_t2:       dc.b    "FAIL: T2 a fill by RUN",13,10,0
s_t3:       dc.b    "FAIL: T3 a copy by START",13,10,0
s_t4:       dc.b    "FAIL: T4 a chain; DMXINT only at its end",13,10,0
s_t5:       dc.b    "FAIL: T5 a chain; DMXINT after a job with IRQ",13,10,0
s_t6:       dc.b    "FAIL: T6 MASK = 3 is an error",13,10,0
s_t7:       dc.b    "FAIL: T7 an error in a chain",13,10,0
s_t8:       dc.b    "FAIL: T8 writes while busy, STOP",13,10,0
s_t9:       dc.b    "FAIL: T9 BLTEN clear holds a job",13,10,0
s_t10:      dc.b    "FAIL: T10 the interrupt request",13,10,0
s_t17:      dc.b    "FAIL: T17 MEMSLOT0-4 read back",13,10,0
s_t18:      dc.b    "FAIL: T18 a job never makes the CPU wait",13,10,0
s_t19:      dc.b    "FAIL: T19 a job under a plan with the blitter in every slot",13,10,0
            even
; the default slot plan, MEMSLOT0-4 (spec 5, section 8.1)
plan0:      dc.l    MEMSLOT0_CPU_M, MEMSLOT0_BPL_M|MEMSLOT0_SPR_M, MEMSLOT0_AUD_M
            dc.l    MEMSLOT0_BPL_M|MEMSLOT0_SPR_M, 0

puts:       move.b  (a0)+,d0
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d0,SERDATA+3(a5)
            bra.s   puts
.done:      rts

s_pass:     dc.b    "PASS",13,10,0
s_err:      dc.b    "FAIL: a chain stopped with an error",13,10,0
s_int:      dc.b    "FAIL: DMXINT is not set at a chain's end",13,10,0
            even
