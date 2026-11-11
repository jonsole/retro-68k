; Blitter speed (spec 11, section 8): six 64 KB jobs, timed by the testbench
; (+blttime prints each run's time and memory cycles). First with the CPU
; polling BLTSTAT from ROM, then with the CPU reading Chip RAM all the while.
; Chip RAM is dgen.py's random data (make dspeed).

            include "hw.inc"

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

C8          equ     ($CC<<BLTCTRL_MINTERM_B)|(3<<BLTCTRL_BPP_B)     ; D = B, 8 bpp
NJOBS       equ     6

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BLTEN_M,DMACON+2(a4)

            lea     jobs(pc),a1         ; the CPU in ROM
            moveq   #NJOBS-1,d7
.j:         bsr     setjob
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
.w:         btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            bne.s   .w
            dbra    d7,.j

            lea     jobs(pc),a1         ; the CPU reading Chip RAM
            moveq   #NJOBS-1,d7
.k:         bsr     setjob
            move.l  #BLTCMD_RUN_M,BLTCMD(a4)
            lea     $080000,a3
.v:         tst.w   (a3)
            tst.w   (a3)
            tst.w   (a3)
            tst.w   (a3)
            btst    #BLTSTAT_BUSY_B,BLTSTAT+3(a4)
            bne.s   .v
            dbra    d7,.k

            lea     s_pass(pc),a0
.p:         move.b  (a0)+,d0
            beq.s   hang
.t:         move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .t
            move.b  d0,SERDATA+3(a5)
            bra.s   .p
hang:       bra.s   hang

; the job at a1 (8 long words) into the job registers
setjob:     lea     BLTCTRL(a4),a2
            moveq   #8-1,d1
.l:         move.l  (a1)+,(a2)+
            dbra    d1,.l
            rts

;                   CTRL  BPT  DPT  SIZE  APT  STRIDE (B<<16 | D)  VALUE (ASTRIDE<<16 | VALUE)  NEXT
; 64 KB each: 4 rows of 16 KB (the last: 4 rows of 65,529 pixels at 1 bpp)
jobs:       dc.l    C8|BLTCTRL_BCONST_M, 0, $100000, (4<<16)|$4000, 0, $4000, $0707, 0                 ; a fill
            dc.l    C8, $120000, $100000, (4<<16)|$4000, 0, ($4000<<16)|$4000, 0, 0                    ; a copy
            dc.l    C8-($CC<<24)+($CA<<24)|(BLT_MASK_KEY<<BLTCTRL_MASK_B), $120000, $100000, (4<<16)|$4000, 0, ($4000<<16)|$4000, 0, 0   ; a cookie-cut, key 0
            dc.l    C8-($CC<<24)+($CA<<24)|(BLT_MASK_IMAGE<<BLTCTRL_MASK_B), $120000, $100000, (4<<16)|$4000, $140000, ($4000<<16)|$4000, $0800<<16, 0   ; a cookie-cut, mask image
            dc.l    C8-($CC<<24)+($66<<24)|BLTCTRL_BCONST_M, 0, $100000, (4<<16)|$4000, 0, $4000, $FFFF, 0   ; invert
            dc.l    $CC<<24, $03120000, $100000, (4<<16)|$FFF9, 0, ($2000<<16)|$2000, 0, 0             ; a 1 bpp copy, 3 bits apart

s_pass:     dc.b    "PASS",13,10,0
            even
