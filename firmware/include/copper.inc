; Copper instruction macros (spec 10, section 4), for vasm (Motorola syntax).
; Include hw.inc first. Register names are offsets in the custom block,
; as in hw.inc (for example L1+L_BPL0PT, BGCOLOR, PALETTE0+4*n).
;
;   CMOVE   reg,value       write 16 bits to a register half
;   CMOVEL  reg,value       write a 32-bit register: two MOVEs, high half first
;   CWAIT   line,pixel      wait until the beam reaches line, pixel (frame order)
;   CWAITP  pixel           wait for a pixel position on the current or next line
;   CWAITB  line,pixel      as CWAIT, and until the blitter is idle
;   CSKIP   line,pixel      skip the next instruction if the beam has reached it
;   CSKIPP  pixel           as CSKIP, pixel position only
;   CJUMP   address         continue at address (4-byte aligned)
;   CSTOP                   stop until the next frame
;
; The copper's registers (spec 10, section 4.2), as operands below:
;   CX, CY      X and Y        CF          the flags (CLD, CLDI and CST only)
;   CR0-CR7     the storage registers COPR0-COPR7
;
;   CMOVX   value           write value to the register half at X
;   CMOVXP  value           the same, then X = X + 2
;   CMOVR   reg,src         write X or Y (src = CX or CY) to reg
;   CMOVXR  src             write X or Y to the register half at X
;   CMOVXRP src             the same, then X = X + 2
;   CLDI    d,value         d = value (d = CX, CY or CF)
;   CLD     d,src           d = src (src = CX, CY or CRn)
;   CST     n,d             CRn = d (n = CR0-CR7, d = CX, CY or CF)
;   CADDI   d,value         d = d + value, sets the flags (d = CX or CY);
;   CADD    d,src           also CSUB(I), CAND(I), COR(I)
;   CCMPI   d,value         compare d with value: d - value, flags only;
;   CCMP    d,src           also with src = CX, CY or CRn
;   CSKIPEQ ... CSKIPLS     skip the next instruction if the condition holds
;                           (EQ NE LO HS MI PL HI LS, as on the 68000)
;   CCALL   address         push the next instruction's address, continue at address
;   CRET                    continue at the address popped from the stack

CX          equ     $10
CY          equ     $20
CF          equ     $40
CR0         equ     $30
CR1         equ     $31
CR2         equ     $32
CR3         equ     $33
CR4         equ     $34
CR5         equ     $35
CR6         equ     $36
CR7         equ     $37

CMOVE       macro
            dc.w    (\1)&$7FFE,(\2)&$FFFF
            endm

CMOVEL      macro
            dc.w    (\1)&$7FFE,((\2)>>16)&$FFFF
            dc.w    ((\1)+2)&$7FFE,(\2)&$FFFF
            endm

CWAIT       macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CWAITP      macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|COP_PIXONLY|((\1)&$7FF)
            endm

CWAITB      macro
            dc.l    COP_EXT|(COP_OP_WAIT<<COP_OP_SHIFT)|COP_BLT|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CSKIP       macro
            dc.l    COP_EXT|(COP_OP_SKIP<<COP_OP_SHIFT)|(((\1)&$7FF)<<COP_V_SHIFT)|((\2)&$7FF)
            endm

CSKIPP      macro
            dc.l    COP_EXT|(COP_OP_SKIP<<COP_OP_SHIFT)|COP_PIXONLY|((\1)&$7FF)
            endm

CJUMP       macro
            dc.l    COP_EXT|(COP_OP_JUMP<<COP_OP_SHIFT)|((\1)&$7FFFFC)
            endm

CSTOP       macro
            dc.l    COP_EXT|(COP_OP_STOP<<COP_OP_SHIFT)
            endm

; ---- MOVE through X and Y

CMOVX       macro
            dc.l    COP_EXT|(COP_OP_MOVR<<COP_OP_SHIFT)|COP_MR_A|((\1)&$FFFF)
            endm

CMOVXP      macro
            dc.l    COP_EXT|(COP_OP_MOVR<<COP_OP_SHIFT)|COP_MR_A|COP_MR_I|((\1)&$FFFF)
            endm

CMOVR       macro
            dc.l    COP_EXT|(COP_OP_MOVR<<COP_OP_SHIFT)|COP_MR_S|((((\2)>>4)&1)*COP_MR_X)|((\1)&$7FFE)
            endm

CMOVXR      macro
            dc.l    COP_EXT|(COP_OP_MOVR<<COP_OP_SHIFT)|COP_MR_A|COP_MR_S|((((\1)>>4)&1)*COP_MR_X)
            endm

CMOVXRP     macro
            dc.l    COP_EXT|(COP_OP_MOVR<<COP_OP_SHIFT)|COP_MR_A|COP_MR_S|COP_MR_I|((((\1)>>4)&1)*COP_MR_X)
            endm

; ---- ALU. _CALU fn,d,source-kind,low-bits

_CALU       macro
            dc.l    COP_EXT|(COP_OP_ALU<<COP_OP_SHIFT)|((\1)<<COP_FN_SHIFT)|(((((\2)>>4)-1)&3)<<COP_D_SHIFT)|((\3)<<COP_S_SHIFT)|((\4)&$FFFF)
            endm

; register source: kind 1 X, 2 Y, 3 Rn (with n in the low bits)
_CALUR      macro
            _CALU   \1,\2,(((\3)>>4)&3),((\3)&7)
            endm

CLDI        macro
            _CALU   COP_FN_LD,\1,0,\2
            endm
CLD         macro
            _CALUR  COP_FN_LD,\1,\2
            endm
CST         macro
            _CALU   COP_FN_ST,\2,3,((\1)&7)
            endm
CADDI       macro
            _CALU   COP_FN_ADD,\1,0,\2
            endm
CADD        macro
            _CALUR  COP_FN_ADD,\1,\2
            endm
CSUBI       macro
            _CALU   COP_FN_SUB,\1,0,\2
            endm
CSUB        macro
            _CALUR  COP_FN_SUB,\1,\2
            endm
CANDI       macro
            _CALU   COP_FN_AND,\1,0,\2
            endm
CAND        macro
            _CALUR  COP_FN_AND,\1,\2
            endm
CORI        macro
            _CALU   COP_FN_OR,\1,0,\2
            endm
COR         macro
            _CALUR  COP_FN_OR,\1,\2
            endm
CCMPI       macro
            _CALU   COP_FN_CMP,\1,0,\2
            endm
CCMP        macro
            _CALUR  COP_FN_CMP,\1,\2
            endm

; ---- conditional SKIP

CSKIPEQ     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_EQ<<COP_CC_SHIFT)
            endm
CSKIPNE     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_NE<<COP_CC_SHIFT)
            endm
CSKIPLO     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_LO<<COP_CC_SHIFT)
            endm
CSKIPHS     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_HS<<COP_CC_SHIFT)
            endm
CSKIPMI     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_MI<<COP_CC_SHIFT)
            endm
CSKIPPL     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_PL<<COP_CC_SHIFT)
            endm
CSKIPHI     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_HI<<COP_CC_SHIFT)
            endm
CSKIPLS     macro
            dc.l    COP_EXT|(COP_OP_SKIPC<<COP_OP_SHIFT)|(COP_CC_LS<<COP_CC_SHIFT)
            endm

; ---- subroutines

CCALL       macro
            dc.l    COP_EXT|(COP_OP_CALL<<COP_OP_SHIFT)|((\1)&$7FFFFC)
            endm

CRET        macro
            dc.l    COP_EXT|(COP_OP_CALL<<COP_OP_SHIFT)|COP_RET
            endm
