; Video test ROM (spec 4): sets up the three layers over picture data that
; vgen.py put in Chip RAM, then keeps the plane pointers reset in every
; vertical blank. After a few frames it prints PASS; the testbench then
; dumps the frame and the video state, and vmodel.py checks every pixel.
; All four palettes (PALETTE0-2, SPRPALETTE) get different colours, so a
; pixel coloured from the wrong palette shows.
;
;   default    palette screen: chunky and planar, scaling, fine scroll,
;              modulo, a vertically flipped layer, transparency, priority,
;              a plane with its DMA off (constant data from BPL4DAT), and
;              pointer wrap (L0's pointer runs past the end of a 64 KB block)
;   -DDIRECT   direct colour: L0 red (5 planes), L1 green (chunky 8 bpp),
;              L2 blue (4 planes, narrower window: blue is 0 outside it;
;              plane 0's DMA off, constant data from BPL0DAT)
;   -DSPRITES  the 8 sprites (spec 9) over two layers: every size, depth and
;              format, scales bigger and smaller, clipping at every edge, collisions;
;              the CPU writes every sprite's registers in each vertical blank,
;              CTL last, and a copper list changes sprites while they are drawn
;              (a VSTOP made later and one made earlier, an image switched part
;              way down, a sprite reused lower down, a zoom, a wobble), and
;              sprite 2, reused lower down with its DMA off, is fed by the copper
;   -DSPRITES -DSHARE   the same with VIDCON.SHAREPAL: everything uses PALETTE0
;   -DCTL      live layer settings (spec 4, section 5.4), changed by a copper
;              list part way along lines: L0's depth (4 to 2 bpp) and its
;              PALOFS, put back in the right border; a split screen (L1's
;              pointers written after its last fetch on line 150); and L2's
;              pointer's low half written mid-line, on lines 300-340
;
; Keep the layouts in step with vgen.py.

            include "hw.inc"

    ifd SPRITES
COPPER      equ     1                   ; a copper list runs
    endif
    ifd CTL
COPPER      equ     1
    endif

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     SYSTEM,a5
            lea     CUSTOM,a4
            move.l  #SERCON_EN_M|SERCON_TXDROP_M,SERCON(a5)

            ; palettes: a spread of colours through all four
            lea     PALETTE0(a4),a0
            move.l  #$123456,d1
            move.w  #4*256-1,d0
.pal:       move.l  d1,(a0)+
            add.l   #$3A5F17,d1
            and.l   #$FFFFFF,d1
            dbra    d0,.pal
            move.l  #$102030,BGCOLOR(a4)

            lea     setup(pc),a0
            bsr     regs
            bsr     ptrs
    ifd COPPER
            ; the copper list into Chip RAM, and the copper on
            lea     clist(pc),a0
            lea     RAMLIST,a1
            move.w  #(clist_end-clist)/4-1,d0
.copy:      move.l  (a0)+,(a1)+
            dbra    d0,.copy
            move.l  #RAMLIST,COP1LC(a4)
            move.l  #COPCON_EN_M,COPCON(a4)
            move.w  #DMACON_SETCLR_M|DMACON_COPEN_M,DMACON+2(a4)
    endif
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|DMACON_BPLEN_M|DMACON_SPREN_M,DMACON+2(a4)
            move.l  #VIDCON_VALUE,VIDCON(a4)

            moveq   #0,d7
.frame:     move.l  VIDSTAT(a4),d0
            and.l   #VIDSTAT_VBLANK_M,d0
            beq.s   .frame
            move.l  #VIDSTAT_VBLANK_M,VIDSTAT(a4)
            bsr     ptrs
            addq.l  #1,d7
            cmp.l   #1,d7
            bne.s   .nocl
            move.l  #$FFFFFFFF,SPRCOLL(a4)  ; collisions from the second frame on
.nocl:      cmp.l   #3,d7
            bne.s   .frame
            lea     s_pass(pc),a0
            bsr     puts
            bra.s   .frame

ptrs:       lea     pointers(pc),a0
            ; fall through

; write a list of (offset in the custom block, value) pairs; -1 ends it
regs:       move.l  (a0)+,d0
            bmi.s   .done
            move.l  (a0)+,0(a4,d0.l)
            bra.s   regs
.done:      rts

puts:       move.b  (a0)+,d0
            beq.s   .done
.wait:      move.w  SERSTAT+2(a5),d1
            and.w   #SERSTAT_TXSPACE_M,d1
            beq.s   .wait
            move.b  d0,SERDATA+3(a5)
            bra.s   puts
.done:      rts

hang:       bra.s   hang

s_pass:     dc.b    "PASS",13,10,0
            even

    ifd CTL
; ---------------------------------------------------------------- live CTRL
VIDCON_VALUE equ VIDCON_EN_M

; L0: chunky 4 bpp, 1x, window 0-640 x 0-576, fine scroll 3, transparent,
; PALOFS 2; rows of 328 bytes. The copper makes it 2 bpp, or PALOFS 13,
; from part way along some lines, and puts it back in the right border
L0_DATA     equ $100000
L0_ROW      equ 328
L0C_BASE    equ L_CTRL_EN_M|(2<<L_CTRL_BPP_B)|L_CTRL_TRANSP_M|(2<<L_CTRL_PALOFS_B)
L0C_DEP     equ (L0C_BASE&~L_CTRL_BPP_M)|(1<<L_CTRL_BPP_B)
L0C_PAL     equ (L0C_BASE&~L_CTRL_PALOFS_M)|(13<<L_CTRL_PALOFS_B)
; L1: 2 planes, separate, 2x across, window 200-480 x 0-576, fine scroll 5,
; transparent; plane rows of 20 bytes. From line 151 a second picture
; (L1_ALT), its pointers written by the copper after line 150's last fetch
L1_DATA     equ $140000
L1_ROW      equ 20
L1_PLANE    equ L1_ROW*576
L1_ALT      equ $150000
; L2: chunky 1 bpp, 1x, the whole screen, solid, PALOFS 9; rows of 96 bytes.
; On lines 300-340 the copper writes the low half of its pointer mid-line
; (the high half stays): the rest of the line from L2_ALT, the next line
; from L2_ALT + 96
L2_DATA     equ $180000
L2_ROW      equ 96
L2_ALT      equ $18E000
RAMLIST     equ $020000             ; the copper list

setup:      dc.l    L0+L_CTRL,   L0C_BASE
            dc.l    L0+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+640)
            dc.l    L0+L_WINY,   ((VID_Y0+0)<<16)|(VID_Y0+576)
            dc.l    L0+L_SCROLLX, 3
            dc.l    L0+L_BPLSTRIDE, L0_ROW
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(1<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|L_CTRL_TRANSP_M|(6<<L_CTRL_PALOFS_B)
            dc.l    L1+L_WINX,   ((VID_X0+200)<<16)|(VID_X0+480)
            dc.l    L1+L_WINY,   ((VID_Y0+0)<<16)|(VID_Y0+576)
            dc.l    L1+L_SCROLLX, 5
            dc.l    L1+L_BPLSTRIDE, L1_ROW
            dc.l    L2+L_CTRL,   L_CTRL_EN_M|(9<<L_CTRL_PALOFS_B)
            dc.l    L2+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+720)
            dc.l    L2+L_WINY,   ((VID_Y0+0)<<16)|(VID_Y0+576)
            dc.l    L2+L_BPLSTRIDE, L2_ROW
            dc.l    PRIO,        (2<<4)|(0<<2)|1 ; L1 in front, then L0, then L2
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA
            dc.l    L1+L_BPL0PT, L1_DATA
            dc.l    L1+L_BPL1PT, L1_DATA+L1_PLANE
            dc.l    L2+L_BPL0PT, L2_DATA
            dc.l    -1

; The copper. Beam pixels: the picture starts at VID_X0 (144). L0's source
; pixel at picture x is x + 3, so picture 257 is pixel 4 of group 16
            include "copper.inc"
            cnop    0,4
clist:      CWAIT   VID_Y0+20,VID_X0+257        ; lines 20-60: 2 bpp from about group 18
dep_loop:   CMOVE   L0+L_CTRL+2,L0C_DEP
            CWAITP  820                         ; the right border: L0's window ended at 784
            CMOVE   L0+L_CTRL+2,L0C_BASE
            CSKIP   VID_Y0+60,0                 ; line 60 done: on
            CJUMP   RAMLIST+(dep_next-clist)
            CJUMP   RAMLIST+(dep_end-clist)
dep_next:   CWAITP  VID_X0+257
            CJUMP   RAMLIST+(dep_loop-clist)
dep_end:
            CWAIT   VID_Y0+80,VID_X0+356        ; lines 80-120: PALOFS 13 from about picture 356
pal_loop:   CMOVE   L0+L_CTRL+2,L0C_PAL
            CWAITP  820
            CMOVE   L0+L_CTRL+2,L0C_BASE
            CSKIP   VID_Y0+120,0
            CJUMP   RAMLIST+(pal_next-clist)
            CJUMP   RAMLIST+(pal_end-clist)
pal_next:   CWAITP  VID_X0+356
            CJUMP   RAMLIST+(pal_loop-clist)
pal_end:    CWAIT   VID_Y0+150,640              ; line 150's right border: L1's window ended at 624
            CMOVEL  L1+L_BPL0PT,L1_ALT
            CMOVEL  L1+L_BPL1PT,L1_ALT+L1_PLANE
            CWAIT   VID_Y0+300,VID_X0+408       ; lines 300-340: L2's pointer from about group 27
ptr_loop:   CMOVE   L2+L_BPL0PT+2,L2_ALT&$FFFF
            CSKIP   VID_Y0+340,0                ; line 340 done: on
            CJUMP   RAMLIST+(ptr_next-clist)
            CJUMP   RAMLIST+(ptr_end-clist)
ptr_next:   CWAITP  VID_X0+408
            CJUMP   RAMLIST+(ptr_loop-clist)
ptr_end:    CSTOP
clist_end:
    else
    ifd SPRITES
; ---------------------------------------------------------------- sprites
    ifd SHARE
VIDCON_VALUE equ VIDCON_EN_M|VIDCON_SHAREPAL_M
    else
VIDCON_VALUE equ VIDCON_EN_M
    endif

; L0: chunky 4 bpp, 2x by 2x, the whole screen (360 x 288 source), transparent
L0_DATA     equ $100000
; L1: 3 planes, separate, 1x, window 200-520 x 150-450, transparent; rows of 40 bytes
L1_DATA     equ $140000
L1_PLANE    equ 40*300
; sprite images (vgen.py fills $180000-$189000)
S_DATA      equ $180000
RAMLIST     equ $020000             ; the copper list

; n, x start, x stop, y start, y stop: picture coordinates, made beam coordinates
SPRH        macro
            dc.l    SPR\1+SPR_H, (VID_X0+(\2))|((VID_X0+(\3))<<16)
            dc.l    SPR\1+SPR_V, (VID_Y0+(\4))|((VID_Y0+(\5))<<16)
            endm
; n, bpp code (0 2, 1 4, 2 8), XSTEP, YSTEP (5.11: $0800 normal size), depth, pal, image
; (the step, the pointer, then CTL, which starts the sprite)
SPRC        macro
            dc.l    SPR\1+SPR_STEP, (\3)|((\4)<<16)
            dc.l    SPR\1+SPR_PT, S_DATA+(\7)
            dc.l    SPR\1+SPR_CTL, ((\2)<<SPR_CTL_BPP_B)|((\5)<<SPR_CTL_DEPTH_B)|((\6)<<SPR_CTL_PAL_B)
            endm

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|(2<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|L_CTRL_TRANSP_M
            dc.l    L0+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+720)
            dc.l    L0+L_WINY,   ((VID_Y0+0)<<16)|(VID_Y0+576)
            dc.l    L0+L_BPLSTRIDE, 180
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(2<<L_CTRL_PLANES_B)|L_CTRL_TRANSP_M|(6<<L_CTRL_PALOFS_B)
            dc.l    L1+L_WINX,   ((VID_X0+200)<<16)|(VID_X0+520)
            dc.l    L1+L_WINY,   ((VID_Y0+150)<<16)|(VID_Y0+450)
            dc.l    L1+L_BPLSTRIDE, 40
            dc.l    PRIO,        (2<<4)|(0<<2)|1 ; L1 in front, then L0 (L2 off)
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA
            dc.l    L1+L_BPL0PT, L1_DATA+0*L1_PLANE
            dc.l    L1+L_BPL1PT, L1_DATA+1*L1_PLANE
            dc.l    L1+L_BPL2PT, L1_DATA+2*L1_PLANE
            ; sprites, every frame: DMA on for all (the copper turns sprite 2's off),
            ; then window, step, pointer, then CTL
            dc.l    SPRDMA,      SPRDMA_SETCLR_M|$FF
            SPRH    0,-20,12,-10,20             ; off the left edge and the top, normal size
            SPRC    0,1,$0800,$0800,0,3,$0000
            SPRH    1,100,148,50,90             ; 1.5x across, 2x down, behind sprite 4
            SPRC    1,2,$0555,$0400,1,0,$1000
            SPRH    2,690,730,100,140           ; off the right edge; half across, 2/3 down
            SPRC    2,0,$1000,$0C00,2,5,$2000
            SPRH    3,300,364,300,340           ; 4x by 4x, at the back
            SPRC    3,1,$0200,$0200,3,7,$3000
            SPRH    4,90,154,40,100             ; 64 px of 8 bpp; lines skipped (2/3 down)
            SPRC    4,2,$0800,$1800,0,0,$4000
            SPRH    5,400,418,200,230           ; an odd step across (about 7x), 1/16 down
            SPRC    5,1,$0123,$8000,1,9,$6000
            SPRH    6,200,500,400,410           ; 300 px wide: 16x across (the limit); YSTEP 0: normal
            SPRC    6,0,$0080,$0000,0,2,$7000
            SPRH    7,500,504,560,590           ; off the bottom; 1/16 across
            SPRC    7,0,$8000,$0800,0,4,$8000
            dc.l    -1

; The copper: sprites changed while they are drawn. Each write is at pixel
; 100 of a line, and acts from the next line. The list runs from its copy
; in Chip RAM, so jumps go to RAMLIST+(label-clist).
            include "copper.inc"
            cnop    0,4
clist:      CWAIT   VID_Y0+9,100                ; sprite 0 goes on to line 29 (VSTOP later)
            CMOVEL  SPR0+SPR_V,(VID_Y0-10)|((VID_Y0+30)<<16)
            CWAIT   VID_Y0+59,100               ; sprite 4 ends after line 79 (VSTOP earlier)
            CMOVEL  SPR4+SPR_V,(VID_Y0+40)|((VID_Y0+80)<<16)
            CWAIT   VID_Y0+69,100               ; sprite 1 switches image from line 70
            CMOVEL  SPR1+SPR_PT,S_DATA+$8800
            ; sprite 2 again, fed by hand: its DMA off, 16 pixels at 2 bpp (2 words
            ; a line), lines 160-230, a pattern that changes on every line
            CWAIT   VID_Y0+142,100
            CMOVE   SPRDMA+2,1<<2               ; sprite 2's DMA off (SETCLR clear)
            CMOVEL  SPR2+SPR_H,(VID_X0+600)|((VID_X0+616)<<16)
            CMOVEL  SPR2+SPR_V,(VID_Y0+160)|((VID_Y0+231)<<16)
            CMOVEL  SPR2+SPR_STEP,$0800|($0800<<16)
            CMOVEL  SPR2+SPR_CTL,(0<<SPR_CTL_BPP_B)|(0<<SPR_CTL_DEPTH_B)|(5<<SPR_CTL_PAL_B)
            CWAITP  300                         ; (the FIFO empties after the CTL write)
            CLDI    CY,$1B1B                    ; 15 lines ahead: 30 words
            CLDI    CX,30
man_pre:    CMOVR   SPR2+SPR_DAT+2,CY
            CADDI   CY,$0101
            CSUBI   CX,1
            CSKIPEQ
            CJUMP   RAMLIST+(man_pre-clist)
            CWAIT   VID_Y0+160,0                ; then a line's words at the start of each line
man_loop:   CMOVR   SPR2+SPR_DAT+2,CY
            CMOVR   SPR2+SPR_DAT+2,CY
            CADDI   CY,$0101
            CWAITP  0
            CSKIP   VID_Y0+216,0                ; the last push (line 215) is line 230's
            CJUMP   RAMLIST+(man_loop-clist)
            CWAIT   VID_Y0+232,100              ; sprite 5 again, lower down: 2x, lines 250-269
            CMOVEL  SPR5+SPR_H,(VID_X0+420)|((VID_X0+460)<<16)
            CMOVEL  SPR5+SPR_V,(VID_Y0+250)|((VID_Y0+270)<<16)
            CMOVEL  SPR5+SPR_STEP,$0400|($0400<<16)
            CMOVEL  SPR5+SPR_PT,S_DATA+$1000
            CMOVEL  SPR5+SPR_CTL,(1<<SPR_CTL_BPP_B)|(0<<SPR_CTL_DEPTH_B)|(6<<SPR_CTL_PAL_B)
            CWAIT   VID_Y0+319,100              ; sprite 3 from line 320: 2x across, twice as wide
            CMOVEL  SPR3+SPR_H,(VID_X0+300)|((VID_X0+428)<<16)
            CMOVEL  SPR3+SPR_STEP,$0400|($0200<<16)
            CWAIT   VID_Y0+400,100
            CMOVEL  SPR6+SPR_H,(VID_X0+203)|((VID_X0+503)<<16)
            CWAIT   VID_Y0+401,100
            CMOVEL  SPR6+SPR_H,(VID_X0+206)|((VID_X0+506)<<16)
            CWAIT   VID_Y0+402,100
            CMOVEL  SPR6+SPR_H,(VID_X0+209)|((VID_X0+509)<<16)
            CWAIT   VID_Y0+403,100
            CMOVEL  SPR6+SPR_H,(VID_X0+212)|((VID_X0+512)<<16)
            CWAIT   VID_Y0+404,100
            CMOVEL  SPR6+SPR_H,(VID_X0+215)|((VID_X0+515)<<16)
            CWAIT   VID_Y0+405,100
            CMOVEL  SPR6+SPR_H,(VID_X0+218)|((VID_X0+518)<<16)
            CWAIT   VID_Y0+406,100
            CMOVEL  SPR6+SPR_H,(VID_X0+221)|((VID_X0+521)<<16)
            CWAIT   VID_Y0+407,100
            CMOVEL  SPR6+SPR_H,(VID_X0+224)|((VID_X0+524)<<16)
            CWAIT   VID_Y0+408,100
            CMOVEL  SPR6+SPR_H,(VID_X0+227)|((VID_X0+527)<<16)
            ; the end: a marker the model looks for (SPR7DAT with sprite 7 on DMA is ignored)
            CMOVE   SPR7+SPR_DAT+2,$C0DE
            CSTOP
clist_end:
    else
    ifnd DIRECT
; ---------------------------------------------------------------- palette screen
VIDCON_VALUE equ VIDCON_EN_M

; L0: chunky 4 bpp, 2x by 2x, window 0-640 x 16-464 (320 x 224 source),
; fine scroll 5, rows of 200 bytes
L0_DATA     equ $100000
L0_ROW      equ 200
; L1: 5 planes, separate, 1x, window 100-420 x 50-350, fine scroll 7,
; transparent; plane rows of 48 bytes, 300 rows
L1_DATA     equ $140000
L1_ROW      equ 48
L1_PLANE    equ L1_ROW*300
; L2: chunky 8 bpp, 4x by 8x, window 300-620 x 200-460 (80 x 33 source),
; fine scroll 1, transparent, shown upside down (negative stride); rows of 96 bytes
L2_DATA     equ $1A0000
L2_ROW      equ 96

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|(2<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)|(2<<L_CTRL_PALOFS_B)|(7<<L_CTRL_WRAP_B)
            dc.l    L0+L_WINX,   ((VID_X0+0)<<16)|(VID_X0+640)
            dc.l    L0+L_WINY,   ((VID_Y0+16)<<16)|(VID_Y0+464)
            dc.l    L0+L_SCROLLX, 5
            dc.l    L0+L_BPLSTRIDE, L0_ROW
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B)|L_CTRL_TRANSP_M
            dc.l    L1+L_WINX,   ((VID_X0+100)<<16)|(VID_X0+420)
            dc.l    L1+L_WINY,   ((VID_Y0+50)<<16)|(VID_Y0+350)
            dc.l    L1+L_SCROLLX, 7
            dc.l    L1+L_BPLSTRIDE, L1_ROW
            dc.l    L1+L_BPLDMA, 1<<4           ; plane 4: DMA off (SET/CLR clear) ...
            dc.l    L1+L_BPL4DAT, $F0F0         ; ... it shows this word in every group
            dc.l    L2+L_CTRL,   L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(2<<L_CTRL_HSCALE_B)|(3<<L_CTRL_VSCALE_B)|L_CTRL_TRANSP_M
            dc.l    L2+L_WINX,   ((VID_X0+300)<<16)|(VID_X0+620)
            dc.l    L2+L_WINY,   ((VID_Y0+200)<<16)|(VID_Y0+460)
            dc.l    L2+L_SCROLLX, 1
            dc.l    L2+L_BPLSTRIDE, -L2_ROW    ; back one row
            dc.l    PRIO,        (0<<4)|(2<<2)|1 ; L1 in front, then L2, then L0
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA+$C000     ; 48 KB into its 64 KB block: wraps to L0_DATA about row 82
            dc.l    L1+L_BPL0PT, L1_DATA+0*L1_PLANE
            dc.l    L1+L_BPL1PT, L1_DATA+1*L1_PLANE
            dc.l    L1+L_BPL2PT, L1_DATA+2*L1_PLANE
            dc.l    L1+L_BPL3PT, L1_DATA+3*L1_PLANE
            dc.l    L1+L_BPL4PT, L1_DATA+4*L1_PLANE
            dc.l    L2+L_BPL0PT, L2_DATA+32*L2_ROW
            dc.l    -1
    else
; ---------------------------------------------------------------- direct colour
VIDCON_VALUE equ VIDCON_EN_M|VIDCON_DIRECT_M

; all 2x by 2x; L0 and L1 window 64-576 x 40-440 (256 x 200 source)
; L0 red: 5 planes, separate, plane rows of 32 bytes
L0_DATA     equ $100000
L0_PLANE    equ 32*200
; L1 green: chunky 8 bpp, rows of 256 bytes
L1_DATA     equ $140000
; L2 blue: 4 planes, separate, window 64-400 x 40-440 (168 x 200 source),
; plane rows of 22 bytes
L2_DATA     equ $180000
L2_PLANE    equ 22*200

setup:      dc.l    L0+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(4<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L0+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+576)
            dc.l    L0+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L1+L_CTRL,   L_CTRL_EN_M|(3<<L_CTRL_BPP_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L1+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+576)
            dc.l    L1+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L2+L_CTRL,   L_CTRL_EN_M|L_CTRL_PLANAR_M|(3<<L_CTRL_PLANES_B)|(1<<L_CTRL_HSCALE_B)|(1<<L_CTRL_VSCALE_B)
            dc.l    L2+L_WINX,   ((VID_X0+64)<<16)|(VID_X0+400)
            dc.l    L2+L_WINY,   ((VID_Y0+40)<<16)|(VID_Y0+440)
            dc.l    L2+L_BPLDMA, 1<<0           ; plane 0: DMA off; the group completes on plane 1
            dc.l    L2+L_BPL0DAT, $AAAA
            dc.l    -1

pointers:   dc.l    L0+L_BPL0PT, L0_DATA+0*L0_PLANE
            dc.l    L0+L_BPL1PT, L0_DATA+1*L0_PLANE
            dc.l    L0+L_BPL2PT, L0_DATA+2*L0_PLANE
            dc.l    L0+L_BPL3PT, L0_DATA+3*L0_PLANE
            dc.l    L0+L_BPL4PT, L0_DATA+4*L0_PLANE
            dc.l    L1+L_BPL0PT, L1_DATA
            dc.l    L2+L_BPL0PT, L2_DATA+0*L2_PLANE
            dc.l    L2+L_BPL1PT, L2_DATA+1*L2_PLANE
            dc.l    L2+L_BPL2PT, L2_DATA+2*L2_PLANE
            dc.l    L2+L_BPL3PT, L2_DATA+3*L2_PLANE
            dc.l    -1
    endif
    endif
    endif
