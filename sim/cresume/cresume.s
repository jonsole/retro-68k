; Copper RESUME test (spec 10): turning the copper off while list 2 runs
; must forget that it was in list 2, so the next vertical blank with
; COPCON.RESUME set does not save the old place into COP2LC over a value
; the CPU wrote while the copper was off. Prints PASS, or FAIL and a number.

            include "hw.inc"
            include "copper.inc"

RAMLIST     equ     $020000

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)

            ; the lists into Chip RAM
            lea     clist(pc),a0
            lea     RAMLIST,a1
            move.w  #(clist_end-clist)/4-1,d0
.copy:      move.l  (a0)+,(a1)+
            dbra    d0,.copy

            ; list 1 jumps to list 2, which loops; RESUME on
            move.l  #RAMLIST,COP1LC(a4)
            move.l  #RAMLIST+(list2-clist),COP2LC(a4)
            move.l  #COPCON_EN_M|COPCON_RESUME_M,COPCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_COPEN_M,DMACON+2(a4)
            move.l  #VIDCON_EN_M,VIDCON(a4)
            bsr     vbl
            bsr     vbl                 ; list 2 is running now

            ; the copper off while list 2 runs; a new COP2LC; on again
            move.l  #COPCON_RESUME_M,COPCON(a4)
            move.l  #RAMLIST+(list2b-clist),COP2LC(a4)
            move.l  #COPCON_EN_M|COPCON_RESUME_M,COPCON(a4)

            ; at the next vertical blank the copper must not save list 2's old place
            bsr     vbl
            moveq   #1,d0
            move.l  COP2LC(a4),d1
            cmp.l   #RAMLIST+(list2b-clist),d1
            blo.s   failed
            cmp.l   #RAMLIST+(list2b_end-clist),d1
            bhs.s   failed

            lea     s_pass(pc),a0
            bsr.s   puts
hang:       bra.s   hang

failed:     lea     s_fail(pc),a0
            bsr.s   puts
            bra.s   hang

; wait for the start of a vertical blank
vbl:        move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
.w:         move.l  VIDSTAT(a4),d1
            and.l   #VIDSTAT_VBLANK_M,d1
            beq.s   .w
            rts

puts:       move.b  (a0)+,d4
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d4,SERDATA+3(a5)
            bra.s   puts
.done:      rts

s_pass:     dc.b    "PASS",13,10,0
s_fail:     dc.b    "FAIL 01",13,10,0
            even

            cnop    0,4
clist:      CMOVE   COPJMP2+2,0                 ; list 1: on to list 2
            CSTOP
list2:      CJUMP   RAMLIST+(list2-clist)       ; list 2: loops
            CSTOP
list2b:     CJUMP   RAMLIST+(list2b-clist)      ; the list the CPU points COP2LC at
            CSTOP
list2b_end:
clist_end:
