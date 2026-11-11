; Rasteriser test ROM (spec 17). rgen.py puts random data, descriptors and a
; control table in Chip RAM; this program runs the chains one after
; another, each under its own clip window, checks that none stopped with an
; error and that each set DMXINT.RAS at its end, and prints PASS or FAIL.
; The testbench then dumps Chip RAM and rmodel.py checks every byte. Lines
; and triangles at every depth, stride sign and minterm class are among
; rgen.py's jobs.
;
; Then directed tests, checked by the CPU: the registers, a line by RUN
; (the spec's worked example), the pattern, NOLAST and the window, a
; triangle by START (the worked example), a chain with and without IRQ on
; its first job, the error, writes while busy, STOP, BLTEN, the interrupt
; request, the blitter and the rasteriser running together, and the
; copper's WAIT B.
;
; The control table (keep in step with rgen.py):
CTL         equ     $0F0000             ; the number of chains, then 11 long words a chain:
                                        ; RASCLIPMIN, RASCLIPMAX, the first descriptor
                                        ; (START), or 0 and a job (RUN)

            include "hw.inc"
            include "copper.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)
            move.l  #DMXINT_BLT_M|DMXINT_RAS_M,DMXINTEN(a4)

            lea     CTL,a3
            move.l  (a3)+,d7
            bra.s   .next
.chain:     move.l  (a3)+,RASCLIPMIN(a4)
            move.l  (a3)+,RASCLIPMAX(a4)
            move.l  (a3)+,d0
            beq.s   .run
            move.l  d0,RASDESC(a4)      ; a chain in Chip RAM
            lea     32(a3),a3
            move.l  #RASCMD_START_M,RASCMD(a4)
            bra.s   .wait
.run:       lea     RASCTRL(a4),a2      ; the first job in the job registers
            moveq   #8-1,d1
.job:       move.l  (a3)+,(a2)+
            dbra    d1,.job
            move.l  #RASCMD_RUN_M,RASCMD(a4)
.wait:      move.l  RASSTAT(a4),d0
            btst    #RASSTAT_BUSY_B,d0
            bne.s   .wait
            btst    #RASSTAT_ERR_B,d0
            bne.s   fail_err
            btst    #DMXINT_RAS_B,DMXINT+3(a4)
            beq.s   fail_int
            move.l  #DMXINT_RAS_M,DMXINT(a4)
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
; They use Chip RAM outside the area rmodel.py checks.
D_AREA      equ     $080000
DSC         equ     D_AREA+$E00         ; descriptors, 32 bytes each
BM          equ     D_AREA+$1000        ; a bitmap: 16 x 16 pixels, 8 bits each, 16 bytes a row
BM2         equ     D_AREA+$1100        ; another, for the triangle
WIDE        equ     D_AREA+$2000        ; one row of 256 pixels
COPL        equ     D_AREA+$3000        ; a copper list
BIG         equ     $0A0000             ; the blitter's 16 KB
LINE8       equ     ($CC<<RASCTRL_MINTERM_B)|(3<<RASCTRL_BPP_B)     ; D = the colour, 8 bpp; add the colour
TRI8        equ     LINE8|RASCTRL_TRI_M
FILL8       equ     ($CC<<BLTCTRL_MINTERM_B)|(3<<BLTCTRL_BPP_B)|BLTCTRL_BCONST_M
FULL        equ     $000F000F           ; RASCLIPMAX for the 16 x 16 bitmaps
FAR         equ     30000               ; a line's end far outside the window: about 600 us of stepping

directed:   lea     BM,a1               ; the bitmaps cleared
            move.w  #2*64-1,d1
.clr:       clr.l   (a1)+
            dbra    d1,.clr
            lea     descs(pc),a1        ; the descriptors into Chip RAM
            lea     DSC,a2
            moveq   #6*8-1,d1
.desc:      move.l  (a1)+,(a2)+
            dbra    d1,.desc

            ; R1: the job registers read back, a byte written on its own;
            ; RASDESC; the clip window
            lea     s_r1(pc),a0
            lea     j_regs(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.r1:        move.l  (a1)+,(a2)+
            dbra    d1,.r1
            lea     j_regs(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
            bsr     cmpl
            move.b  #$5A,RASP1+2(a4)
            cmp.l   #$9ABC5AF0,RASP1(a4)
            bne     failed
            move.l  #$00C81235,RASDESC(a4)      ; bits 23-22 and bit 0 are not kept
            cmp.l   #$00081234,RASDESC(a4)
            bne     failed
            move.l  #$FFF08001,RASCLIPMIN(a4)
            move.l  #$7FFF0123,RASCLIPMAX(a4)
            cmp.l   #$FFF08001,RASCLIPMIN(a4)
            bne     failed
            move.b  #$45,RASCLIPMAX+1(a4)
            cmp.l   #$7F450123,RASCLIPMAX(a4)
            bne     failed
            clr.l   RASCLIPMIN(a4)              ; the window for what follows: the whole bitmap
            move.l  #FULL,RASCLIPMAX(a4)

            ; R2: a line by RUN, the spec's example: (2,1) to (9,4)
            lea     s_r2(pc),a0
            lea     j_line(pc),a1
            bsr     runok
            lea     x_line(pc),a1
            lea     BM,a2
            moveq   #6*4-1,d1
            bsr     cmpl
            btst    #DMXINT_RAS_B,DMXINT+3(a4)  ; DMXINT at the end, with or without IRQ
            beq     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)

            ; R3: the pattern through minterm 0xCA, NOLAST, and the window's
            ; left edge at x = 2
            lea     s_r3(pc),a0
            move.l  #$00020000,RASCLIPMIN(a4)
            lea     j_pat(pc),a1
            bsr     runok
            clr.l   RASCLIPMIN(a4)
            lea     x_pat(pc),a1
            lea     BM+6*16,a2
            moveq   #4-1,d1
            bsr     cmpl

            ; R4: a triangle by START, the spec's example; the job registers
            ; hold the descriptor after
            lea     s_r4(pc),a0
            move.l  #DSC,RASDESC(a4)
            bsr     startok
            lea     x_tri(pc),a1
            lea     BM2,a2
            moveq   #10*4-1,d1
            bsr     cmpl
            lea     DSC,a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
            bsr     cmpl
            cmp.l   #DSC,RASDESC(a4)
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)

            ; R5: a chain. Its first job has no IRQ: DMXINT stays clear until the end
            lea     s_r5(pc),a0
            move.l  #DSC+$20,RASDESC(a4)
            move.l  #RASCMD_START_M,RASCMD(a4)
            move.l  #100000,d1
.c1:        cmp.b   #$11,BM+10*16               ; the first job is done
            beq.s   .c1d
            subq.l  #1,d1
            bne.s   .c1
            bra     failed
.c1d:       btst    #DMXINT_RAS_B,DMXINT+3(a4)
            bne     failed
            btst    #RASSTAT_BUSY_B,RASSTAT+3(a4)
            beq     failed
            bsr     waitok
            btst    #DMXINT_RAS_B,DMXINT+3(a4)
            beq     failed
            cmp.b   #$22,BM+11*16+15            ; the second job's last pixel inside the window
            bne     failed
            tst.b   BM+11*16
            bne     failed
            cmp.l   #DSC+$40,RASDESC(a4)        ; the last descriptor run
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)
            ; ... and with IRQ: DMXINT while the second job runs
            lea     s_r6(pc),a0
            or.l    #RASCTRL_IRQ_M,DSC+$20
            move.l  #DSC+$20,RASDESC(a4)
            move.l  #RASCMD_START_M,RASCMD(a4)
            move.l  #100000,d1
.c2:        btst    #DMXINT_RAS_B,DMXINT+3(a4)
            bne.s   .c2d
            subq.l  #1,d1
            bne.s   .c2
            bra     failed
.c2d:       btst    #RASSTAT_BUSY_B,RASSTAT+3(a4)
            beq     failed
            bsr     waitok
            move.l  #DMXINT_RAS_M,DMXINT(a4)

            ; R7: a reserved bit of RASCTRL is an error: ERR and DMXINT, nothing written
            lea     s_r7(pc),a0
            lea     j_bad(pc),a1
            bsr     runjob
            btst    #RASSTAT_ERR_B,d0
            beq     failed
            btst    #DMXINT_RAS_B,DMXINT+3(a4)
            beq     failed
            tst.l   BM+12*16
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)
            ; R8: an error in a chain: the chain ends, RASDESC names the descriptor;
            ; the next start clears ERR
            lea     s_r8(pc),a0
            move.l  #DSC+$60,RASDESC(a4)
            move.l  #RASCMD_START_M,RASCMD(a4)
            bsr     waitend
            btst    #RASSTAT_ERR_B,d0
            beq     failed
            cmp.b   #$33,BM+13*16               ; the job before it ran
            bne     failed
            tst.l   BM+12*16
            bne     failed
            cmp.l   #DSC+$80,RASDESC(a4)
            bne     failed
            lea     j_dot(pc),a1
            bsr     runok
            move.l  #DMXINT_RAS_M,DMXINT(a4)

            ; R9: the job registers, RASDESC and the window are not written
            ; while busy; STOP ends the job and the chain
            lea     s_r9(pc),a0
            lea     j_long(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.long:      move.l  (a1)+,(a2)+
            dbra    d1,.long
            move.l  #RASCMD_RUN_M,RASCMD(a4)
            move.l  #$12345678,RASCTRL(a4)
            cmp.l   #LINE8|$44,RASCTRL(a4)
            bne     failed
            move.l  #$00123456,RASDESC(a4)
            cmp.l   #DSC+$80,RASDESC(a4)
            bne     failed
            move.l  #$00010001,RASCLIPMAX(a4)
            cmp.l   #FULL,RASCLIPMAX(a4)
            bne     failed
            btst    #RASSTAT_BUSY_B,RASSTAT+3(a4)
            beq     failed
            move.l  #RASCMD_STOP_M,RASCMD(a4)
            bsr     waitok
            btst    #DMXINT_RAS_B,DMXINT+3(a4)
            beq     failed
            cmp.b   #$44,BM+14*16+15            ; it had drawn its pixels in the window ...
            bne     failed
            tst.b   BM+15*16                    ; ... and the chain was not followed
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)

            ; R10: with DMACON.BLTEN clear a job waits
            lea     s_r10(pc),a0
            move.w  #DMACON_BLTEN_M,DMACON+2(a4)
            lea     j_held(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.held:      move.l  (a1)+,(a2)+
            dbra    d1,.held
            move.l  #RASCMD_RUN_M,RASCMD(a4)
            moveq   #100,d1
.dly:       dbra    d1,.dly
            btst    #RASSTAT_BUSY_B,RASSTAT+3(a4)
            beq     failed
            tst.b   BM+15*16+3
            bne     failed
            move.w  #DMACON_SETCLR_M|DMACON_BLTEN_M,DMACON+2(a4)
            bsr     waitok
            cmp.b   #$88,BM+15*16+3
            bne     failed

            ; R11: the interrupt request (source 4, shared with the blitter)
            ; is DMXINT and DMXINTEN, bit by bit
            lea     s_r11(pc),a0
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            beq     failed
            move.l  #DMXINT_BLT_M,DMXINTEN(a4)  ; only the blitter's enable: no request
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINTEN(a4)
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            beq     failed
            move.l  #DMXINT_BLT_M,DMXINT(a4)    ; clearing the blitter's flag leaves this one
            cmp.l   #DMXINT_RAS_M,DMXINT(a4)
            bne     failed
            move.l  #DMXINT_RAS_M,DMXINT(a4)
            tst.l   DMXINT(a4)
            bne     failed
            move.l  INTRAW(a5),d0
            btst    #INTB_BLT,d0
            bne     failed
            move.l  #DMXINT_BLT_M|DMXINT_RAS_M,DMXINTEN(a4)

            ; R12: the blitter and the rasteriser run at the same time
            lea     s_r12(pc),a0
            clr.l   WIDE+$200                   ; the blitter's first job reads C (spec 11, D8)
            lea     j_warm(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.wj:        move.l  (a1)+,(a2)+
            dbra    d1,.wj
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
.ww:        btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            bne.s   .ww
            move.l  #DMXINT_BLT_M,DMXINT(a4)
            lea     WIDE,a1
            moveq   #64-1,d1
.w0:        clr.l   (a1)+
            dbra    d1,.w0
            move.l  #$FFFFFFFF,(a1)
            clr.l   BIG
            clr.l   BIG+$3FFC
            move.l  #$00FF0000,RASCLIPMAX(a4)   ; the window: 256 x 1
            lea     j_fill(pc),a1
            lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.bj:        move.l  (a1)+,(a2)+
            dbra    d1,.bj
            lea     j_wide(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.rj:        move.l  (a1)+,(a2)+
            dbra    d1,.rj
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            move.l  #RASCMD_RUN_M,RASCMD(a4)
            move.l  BLTSTAT(a4),d2
            move.l  RASSTAT(a4),d3
            btst    #RASSTAT_BUSY_B,d3          ; both were busy
            beq     failed
            btst    #BLTSTAT_BUSY_B,d2
            beq     failed
            bsr     waitok
.bw:        move.l  BLTSTAT(a4),d0
            btst    #BLTSTAT_BUSY_B,d0
            bne.s   .bw
            btst    #BLTSTAT_ERR_B,d0
            bne     failed
            cmp.l   #DMXINT_BLT_M|DMXINT_RAS_M,DMXINT(a4)
            bne     failed
            move.l  #DMXINT_BLT_M|DMXINT_RAS_M,DMXINT(a4)
            lea     WIDE,a1
            moveq   #64-1,d1
.w1:        cmp.l   #$99999999,(a1)+
            bne     failed
            dbra    d1,.w1
            cmp.l   #$FFFFFFFF,(a1)
            bne     failed
            cmp.l   #$3C3C3C3C,BIG
            bne     failed
            cmp.l   #$3C3C3C3C,BIG+$3FFC
            bne     failed
            move.l  #FULL,RASCLIPMAX(a4)

            ; R13: the copper's WAIT with B waits for the rasteriser too
            lea     s_r13(pc),a0
            lea     clist(pc),a1
            lea     COPL,a2
            moveq   #4-1,d1
.cl:        move.l  (a1)+,(a2)+
            dbra    d1,.cl
            clr.l   BGCOLOR(a4)
            lea     j_long2(pc),a1
            lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.l2:        move.l  (a1)+,(a2)+
            dbra    d1,.l2
            move.l  #RASCMD_RUN_M,RASCMD(a4)
            move.l  #COPL,COP1LC(a4)
            move.l  #COPCON_EN_M,COPCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_COPEN_M,DMACON+2(a4)
            move.l  #0,COPJMP1(a4)
            moveq   #50,d1
.cd:        dbra    d1,.cd
            move.l  BGCOLOR(a4),d2              ; not written yet ...
            btst    #RASSTAT_BUSY_B,RASSTAT+3(a4)   ; ... and the job was still running then
            beq     failed
            tst.l   d2
            bne     failed
            bsr     waitok
            moveq   #50,d1
.ce:        dbra    d1,.ce
            cmp.l   #$00123456,BGCOLOR(a4)
            bne     failed
            move.w  #DMACON_COPEN_M,DMACON+2(a4)
            clr.l   COPCON(a4)
            clr.l   BGCOLOR(a4)
            move.l  #DMXINT_RAS_M,DMXINT(a4)
            rts

; run the job at a1 (8 long words) by RUN; d0 = RASSTAT at the end
runjob:     lea     RASCTRL(a4),a2
            moveq   #8-1,d1
.l:         move.l  (a1)+,(a2)+
            dbra    d1,.l
            move.l  #RASCMD_RUN_M,RASCMD(a4)
waitend:    move.l  RASSTAT(a4),d0
            btst    #RASSTAT_BUSY_B,d0
            bne.s   waitend
            rts
; the same, and fail (a0) if it stopped with an error
runok:      bsr.s   runjob
            btst    #RASSTAT_ERR_B,d0
            bne     failed
            rts
; START, wait, and fail (a0) on an error
startok:    move.l  #RASCMD_START_M,RASCMD(a4)
; wait for the end, and fail (a0) on an error
waitok:     bsr.s   waitend
            btst    #RASSTAT_ERR_B,d0
            bne     failed
            rts
; compare d1 + 1 long words at a1 and a2; fail (a0) on a difference
cmpl:       cmpm.l  (a1)+,(a2)+
            bne     failed
            dbra    d1,cmpl
            rts

; a point
PT          macro
            dc.l    (((\1)&$FFFF)<<16)|((\2)&$FFFF)
            endm

;           CTRL   P0   P1   P2   DPT   STRIDE   PAT   NEXT
j_regs:     dc.l   $A5C3B5E7, $12345678, $9ABCDEF0, $0FEDCBA9, $07654321, $ABCD8001, $5555F0F0, $00222222
j_line:     dc.l   LINE8|$55
            PT     2,1
            PT     9,4
            dc.l   0, BM, 16, $FFFF, 0
j_pat:      dc.l   ($CA<<RASCTRL_MINTERM_B)|(3<<RASCTRL_BPP_B)|RASCTRL_NOLAST_M|$77
            PT     0,6
            PT     15,6
            dc.l   0, BM, 16, $F0FF, 0
j_bad:      dc.l   LINE8|BLTCTRL_BCONST_M|$EE       ; bit 13 is reserved here
            PT     0,12
            PT     3,12
            dc.l   0, BM, 16, $FFFF, 0
j_dot:      dc.l   LINE8|$01
            PT     15,13
            PT     15,13
            dc.l   0, BM, 16, $FFFF, 0
j_long:     dc.l   LINE8|$44
            PT     1,14
            PT     FAR,14
            dc.l   0, BM, 16, $FFFF, DSC+$A0
j_held:     dc.l   LINE8|$88
            PT     3,15
            PT     3,15
            dc.l   0, BM, 16, $FFFF, 0
j_wide:     dc.l   LINE8|$99
            PT     0,0
            PT     255,0
            dc.l   0, WIDE, 256, $FFFF, 0
j_long2:    dc.l   LINE8|$45
            PT     1,14
            PT     FAR,14
            dc.l   0, BM, 16, $FFFF, 0
;           the blitter's: CTRL   BPT   DPT   SIZE   APT   STRIDE   VALUE   NEXT
j_fill:     dc.l   FILL8, 0, BIG, (1<<16)|$4000, 0, 0, $3C3C, 0
j_warm:     dc.l   FILL8^($AA<<BLTCTRL_MINTERM_B), 0, WIDE+$200, (1<<16)|4, 0, 0, 0, 0     ; D = B xor C
; the descriptors, copied to DSC
descs:      dc.l   TRI8|$33                         ; +$00 R4: the spec's triangle
            PT     10,2
            PT     3,6
            PT     14,9
            dc.l   BM2, 16, 0, 0
            dc.l   LINE8|$11                        ; +$20 R5: a chain: a pixel ...
            PT     0,10
            PT     0,10
            dc.l   0, BM, 16, $FFFF, DSC+$40
            dc.l   LINE8|$22                        ; +$40 ... then a long line
            PT     1,11
            PT     FAR,11
            dc.l   0, BM, 16, $FFFF, 0
            dc.l   LINE8|$33                        ; +$60 R8: a job ...
            PT     0,13
            PT     0,13
            dc.l   0, BM, 16, $FFFF, DSC+$80
            dc.l   LINE8|(1<<18)|$EE                ; +$80 ... then an error
            PT     0,12
            PT     3,12
            dc.l   0, BM, 16, $FFFF, 0
            dc.l   LINE8|$66                        ; +$A0 R9: after the stopped job
            PT     0,15
            PT     0,15
            dc.l   0, BM, 16, $FFFF, 0

; what the bitmap holds, 4 long words a row
x_line:     dc.l   0, 0, 0, 0                       ; (2,1) (3,1) (4,2) (5,2) (6,3) (7,3) (8,4) (9,4)
            dc.l   $00005555, 0, 0, 0
            dc.l   0, $55550000, 0, 0
            dc.l   0, $00005555, 0, 0
            dc.l   0, 0, $55550000, 0
            dc.l   0, 0, 0, 0
x_pat:      dc.l   $00007777, 0, $77777777, $77777700   ; x 2-3 (0-1 are outside), 8-14 (15 is the last)
x_tri:      dc.l   0, 0, 0, 0
            dc.l   0, 0, 0, 0
            dc.l   0, 0, 0, 0                       ; row 2: none
            dc.l   0, 0, $00333300, 0               ; row 3: 9 to 10
            dc.l   0, $00000033, $33333333, 0       ; row 4: 7 to 11
            dc.l   0, $00333333, $33333333, 0       ; row 5: 5 to 11
            dc.l   $00000033, $33333333, $33333333, $33000000   ; row 6: 3 to 12
            dc.l   0, $00000033, $33333333, $33000000           ; row 7: 7 to 12
            dc.l   0, 0, $00000033, $33330000       ; row 8: 11 to 13
            dc.l   0, 0, 0, 0                       ; row 9: not drawn

; R13's copper list: when the blitter and the rasteriser are idle, set BGCOLOR
clist:      CWAITB  0,0
            CMOVEL  BGCOLOR,$00123456
            CSTOP

s_r1:       dc.b    "FAIL: R1 the job registers, RASDESC and the window read back",13,10,0
s_r2:       dc.b    "FAIL: R2 a line by RUN",13,10,0
s_r3:       dc.b    "FAIL: R3 the pattern, NOLAST and the window",13,10,0
s_r4:       dc.b    "FAIL: R4 a triangle by START",13,10,0
s_r5:       dc.b    "FAIL: R5 a chain; DMXINT only at its end",13,10,0
s_r6:       dc.b    "FAIL: R6 a chain; DMXINT after a job with IRQ",13,10,0
s_r7:       dc.b    "FAIL: R7 a reserved RASCTRL bit is an error",13,10,0
s_r8:       dc.b    "FAIL: R8 an error in a chain",13,10,0
s_r9:       dc.b    "FAIL: R9 writes while busy, STOP",13,10,0
s_r10:      dc.b    "FAIL: R10 BLTEN clear holds a job",13,10,0
s_r11:      dc.b    "FAIL: R11 the interrupt request",13,10,0
s_r12:      dc.b    "FAIL: R12 the blitter and the rasteriser together",13,10,0
s_r13:      dc.b    "FAIL: R13 the copper's WAIT B",13,10,0
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
s_err:      dc.b    "FAIL: a chain stopped with an error",13,10,0
s_int:      dc.b    "FAIL: DMXINT.RAS is not set at a chain's end",13,10,0
            even
