; HDMI sound test ROM (spec 6, A3; retro-hw hdmi_packets). Built in place
; of the boot ROM for a listening test on the board, not run in simulation.
; Two sine tones, 440 Hz on channel 0 and 660 Hz on channel 1, in a loop of
; phases of 2 seconds; the background colour says which:
;
;   green   440 Hz, left only
;   blue    660 Hz, right only
;   cyan    both
;   yellow  both, AUDRATE 2268 (44.1 kHz): both tones about 8% lower, on the
;           jack and on HDMI (HDMI keeps its fixed 48 kHz tap)
;   red     4 seconds of VIDCON.DVI: the picture stays, HDMI sound stops,
;           the jack plays on

            include "hw.inc"

SINE        equ     $040000             ; 64 samples, 16-bit
STEP440     equ     38441               ; 440 * 64 * 65536 / 48008
STEP660     equ     57662
GREEN       equ     $00A000
BLUE        equ     $0030C0
CYAN        equ     $00A0A0
YELLOW      equ     $C0C000
RED         equ     $C00000

            org ROM
            dc.l    $010000             ; stack
            dc.l    start
            dcb.l   254,hang

start:      move.w  #$2700,sr
            lea     CUSTOM,a4
            move.l  #VIDCON_EN_M|VIDCON_BLANKALL_M,VIDCON(a4)     ; the background colour only
            lea     sine(pc),a0
            lea     SINE,a1
            moveq   #63,d0
.cp:        move.w  (a0)+,(a1)+
            dbra    d0,.cp

            move.l  #2083,AUDRATE(a4)
            lea     AUD0(a4),a0
            move.l  #STEP440,d0
            bsr     chan
            lea     AUD1(a4),a0
            move.l  #STEP660,d0
            bsr     chan
            move.w  #DMACON_SETCLR_M|DMACON_DMAEN_M|3,DMACON+2(a4)    ; channels 0 and 1 on

loop:       move.l  #GREEN,BGCOLOR(a4)
            move.l  #64<<16,AUD0+AUD_VOL(a4)
            clr.l   AUD1+AUD_VOL(a4)
            bsr     wait2
            move.l  #BLUE,BGCOLOR(a4)
            clr.l   AUD0+AUD_VOL(a4)
            move.l  #64,AUD1+AUD_VOL(a4)
            bsr     wait2
            move.l  #CYAN,BGCOLOR(a4)
            move.l  #64<<16,AUD0+AUD_VOL(a4)
            bsr     wait2
            move.l  #YELLOW,BGCOLOR(a4)
            move.l  #2268,AUDRATE(a4)
            bsr     wait2
            move.l  #2083,AUDRATE(a4)
            move.l  #RED,BGCOLOR(a4)
            or.l    #VIDCON_DVI_M,VIDCON(a4)
            bsr     wait2
            bsr     wait2
            and.l   #~VIDCON_DVI_M,VIDCON(a4)
            bra     loop

; a0 = the channel's registers, d0 = its step: 16-bit, interpolated, a
; looping block of the 64-sample sine, silent until its volume is set
chan:       move.l  #AUD_CTRL_BITS16_M,AUD_CTRL(a0)
            move.l  #SINE,AUD_LC(a0)
            move.l  #64,AUD_LEN(a0)
            move.l  d0,AUD_STEP(a0)
            clr.l   AUD_VOL(a0)
            rts

; wait 100 frames (2 seconds)
wait2:      move.l  FRAMECOUNT(a4),d1
.w:         move.l  FRAMECOUNT(a4),d0
            sub.w   d1,d0
            cmp.w   #100,d0
            blo.s   .w
            rts

hang:       bra.s   hang

sine:
            dc.w    0,2842,5658,8418,11098,13671,16112,18397
            dc.w    20506,22417,24113,25576,26793,27751,28443,28860
            dc.w    29000,28860,28443,27751,26793,25576,24113,22417
            dc.w    20506,18397,16112,13671,11098,8418,5658,2842
            dc.w    0,-2842,-5658,-8418,-11098,-13671,-16112,-18397
            dc.w    -20506,-22417,-24113,-25576,-26793,-27751,-28443,-28860
            dc.w    -29000,-28860,-28443,-27751,-26793,-25576,-24113,-22417
            dc.w    -20506,-18397,-16112,-13671,-11098,-8418,-5658,-2842
