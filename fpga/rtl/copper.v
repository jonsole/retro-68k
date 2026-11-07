// Copper (spec 10): runs a list of 32-bit instructions from Chip RAM every
// frame and writes custom registers at chosen beam positions.
//
//   fetch     one 16-bit word at a time through the scheduler's copper
//             channel (dmac.v), into a one-instruction buffer: the next
//             instruction is fetched while this one runs (a WAIT, say).
//             A jump throws the buffer away; a word still on its way is
//             dropped when it arrives.
//   execute   one instruction at a time. Register writes go out on the
//             register bus, shared with the CPU: a CPU access already on
//             the bus goes first, and the copper's write waits a clock.
//             Every write is followed by one spare clock, so that a write
//             to the copper's own registers (a strobe, COPX) has taken
//             effect before the next instruction runs.
//
// The copper's own registers are written through the register bus like
// any other, whether the CPU or the copper itself writes them.
`include "regmap.vh"

module copper (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    // Register bus (the CPU's side, from bus_if)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    // The copper's write onto the register bus (muxed in retro68k.v)
    output reg         cw_req,         // held until cw_go
    output reg  [23:2] cw_addr,
    output reg  [31:0] cw_wdata,
    output reg  [3:0]  cw_be,
    input  wire        cw_go,          // the write is on the bus this clock

    // Memory (dmac.v copper channel)
    output reg         mem_req,
    output reg  [21:1] mem_addr,
    output wire [1:0]  mem_pri,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // From the video (memory side)
    input  wire [10:0] beam_v,
    input  wire [10:0] beam_h,
    input  wire        vblank,         // 1 clock: the vertical blank starts
    input  wire [15:0] dmacon,
    input  wire        blt_idle,       // the DMA engine has nothing to do

    output wire        irq
);
    localparam [10:0] VVIS = 11'd576, VTOT = 11'd625, HTOT = 11'd864;

    // ================================================================ registers
    reg  [5:0]  copcon;                // PRI (5:4), STKKEEP (3), RESUME (2), IRQEN (1), EN (0)
    reg  [22:2] lc1, lc2;
    reg         st_err, st_irq;
    reg  [15:0] rx, ry;
    reg  [2:0]  rf;                    // C (2), N (1), Z (0)
    reg  [15:0] rr [0:7];
    reg  [22:2] stk [0:7];
    reg  [3:0]  sp;

    wire en = copcon[0] && dmacon[`RM_DMACON_COPEN] && dmacon[`RM_DMACON_DMAEN];
    assign mem_pri = copcon[5:4];
    assign irq = st_irq && copcon[1];

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hE0) && (off[15:7] == 9'h0E);       // 0x700-0x77F
    wire wr  = rb_wr && sel;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // Strobes act on a write that reaches the low half
    wire s_jmp1 = wr && off == `RM_COPJMP1 && rb_be[1:0] != 2'b00;
    wire s_jmp2 = wr && off == `RM_COPJMP2 && rb_be[1:0] != 2'b00;
    wire s_int  = wr && off == `RM_COPINT  && rb_be[1:0] != 2'b00;
    wire s_sp   = wr && off == `RM_COPSP   && rb_be[1:0] != 2'b00;

    // ================================================================ beam
    // Beam coordinates (spec 4, section 3.3): the frame starts at line 0, the
    // start of the vertical blank, so lines only go up through a frame
    function [11:0] fo(input [10:0] v);
        fo = {1'b0, v};
    endfunction
    wire [11:0] b_fo = fo(beam_v);

    // ================================================================ state
    localparam X_OFF = 3'd0, X_RUN = 3'd1, X_WAIT = 3'd2, X_WR = 3'd3, X_GAP = 3'd4, X_ALU = 3'd5;
    reg  [2:0]  xs;
    reg  [22:2] npc;                   // next instruction to run
    reg  [22:2] xpc;                   // the instruction running
    reg         in2;                   // in list 2 (RESUME)

    // Fetch: a buffer of two words, and at most one word on its way
    reg  [15:0] buf_hi, buf_lo;
    reg  [1:0]  buf_n;
    reg  [21:1] fpc;                   // next word to fetch
    reg         outst;                 // a word is on its way (acked, data not back)
    reg         stale;                 // ... and it is to be dropped

    // The halves latch (spec 3, section 2)

    // A WAIT in progress
    reg  [11:0] w_fo;
    reg  [10:0] w_px;
    reg         w_never, w_blt;

    // The ALU, one clock after decode
    reg  [31:0] ir;

    wire [31:0] ins = {buf_hi, buf_lo};
    wire        have = (buf_n == 2'd2);

    // ---------------------------------------------------------------- decode helpers
    wire        i_ext  = ins[31];
    wire [2:0]  i_op   = ins[30:28];
    wire        i_p    = ins[27];
    wire [10:0] i_line = ins[26:16];
    wire [10:0] i_px   = ins[10:0];

    // Reached: the beam is at or past (line, pixel) in frame order
    wire        t_never = (i_line >= VTOT) || (i_px >= HTOT);
    wire [11:0] t_fo    = fo(i_line);
    wire        t_reach = !t_never && ((b_fo > t_fo) || (b_fo == t_fo && beam_h >= i_px));
    wire        t_preach = (i_px < HTOT) && (beam_h >= i_px);


    function cond(input [3:0] cc, input [2:0] f);   // f = {C, N, Z}
        case (cc)
            4'd0: cond = f[0];
            4'd1: cond = !f[0];
            4'd2: cond = f[2];
            4'd3: cond = !f[2];
            4'd4: cond = f[1];
            4'd5: cond = !f[1];
            4'd6: cond = !f[2] && !f[0];
            4'd7: cond = f[2] || f[0];
            default: cond = 1'b0;
        endcase
    endfunction

    // Reserved patterns (spec 10, section 4): bits shown as 0 must be 0
    reg bad;
    always @(*) begin
        bad = 1'b0;
        if (i_ext) case (i_op)
            3'd0: bad = ins[14:11] != 4'd0;                                      // WAIT
            3'd1: bad = ins[15:11] != 5'd0;                                      // SKIP
            3'd2: bad = ins[27:23] != 5'd0 || ins[1:0] != 2'd0;                  // JUMP
            3'd3: bad = ins[27:0] != 28'd0;                                      // STOP
            3'd4: bad = ins[23:16] != 8'd0 || (!ins[27] && !ins[26])            // MOVR
                        || (ins[25] && !ins[27]) || (ins[27] && ins[26] && ins[15:0] != 16'd0)
                        || (!ins[26] && ins[24]);
            3'd5: bad = ins[20:16] != 5'd0 || ins[27:25] == 3'd7                // ALU
                        || ins[24:23] == 2'd2
                        || (ins[24:23] == 2'd3 && ins[27:25] >= 3'd2)
                        || (ins[27:25] == 3'd1 && ins[22:21] != 2'd3)
                        || (ins[22:21] == 2'd3 && ins[15:3] != 13'd0)
                        || ((ins[22:21] == 2'd1 || ins[22:21] == 2'd2) && ins[15:0] != 16'd0);
            3'd6: bad = ins[27] || ins[23:0] != 24'd0;                           // SKIPC
            3'd7: bad = ins[27] ? (ins[26:0] != 27'd0)                           // RET
                                : (ins[26:23] != 4'd0 || ins[1:0] != 2'd0);      // CALL
        endcase
    end

    // A clock that restarts the copper runs no instruction, so that a cut-off
    // never leaves one half done
    wire hold = (vblank || s_jmp1 || s_jmp2) && en;

    // ---------------------------------------------------------------- main
    integer i;
    reg        flush;                  // throw the fetched words away, fetch from f_to
    reg [22:2] f_to;

    always @(posedge clk) begin
        flush = 1'b0;
        f_to  = npc;

        if (rst) begin
            copcon <= 6'd0;
            lc1 <= 21'd0; lc2 <= 21'd0;
            st_err <= 1'b0; st_irq <= 1'b0;
            rx <= 16'd0; ry <= 16'd0; rf <= 3'd0;
            for (i = 0; i < 8; i = i + 1) rr[i] <= 16'd0;
            sp <= 4'd0;
            xs <= X_OFF;
            npc <= 21'd0; xpc <= 21'd0;
            in2 <= 1'b0;
            buf_n <= 2'd0;
            fpc <= 21'd0;
            mem_req <= 1'b0;
            outst <= 1'b0;
            stale <= 1'b0;
            cw_req <= 1'b0;
        end else begin
            // ---- execute
            if (cw_go) cw_req <= 1'b0;

            case (xs)
                X_RUN: if (have && !hold) begin
                    buf_n <= 2'd0;             // taken: the next one is fetched meanwhile
                    xpc   <= npc;
                    npc   <= npc + 1'b1;
                    ir    <= ins;
                    if (!i_ext) begin
                        // MOVE
                        do_write({1'b0, ins[30:17], 1'b0}, ins[15:0]);
                    end else if (bad) begin
                        st_err <= 1'b1;
                        stop;
                    end else case (i_op)
                        3'd0: begin            // WAIT
                            if (!i_p && i_line == 11'd2047) stop;
                            else begin
                                w_fo    <= i_p ? b_fo + (beam_h >= i_px) : t_fo;
                                w_px    <= i_px;
                                w_never <= i_p ? (i_px >= HTOT) : t_never;
                                w_blt   <= ins[15];
                                xs      <= X_WAIT;
                            end
                        end
                        3'd1: if (i_p ? t_preach : t_reach) begin   // SKIP
                            flush = 1'b1; f_to = npc + 2'd2;
                        end
                        3'd2: begin flush = 1'b1; f_to = ins[22:2]; end   // JUMP
                        3'd3: stop;                                       // STOP
                        3'd4: begin                                       // MOVR
                            if (ins[25]) rx <= rx + 16'd2;
                            do_write(ins[27] ? {1'b0, rx[14:1], 1'b0} : {1'b0, ins[14:1], 1'b0},
                                     ins[26] ? (ins[24] ? rx : ry) : ins[15:0]);
                        end
                        3'd5: xs <= X_ALU;                                // ALU
                        3'd6: if (cond(ins[27:24], rf)) begin             // SKIPC
                            flush = 1'b1; f_to = npc + 2'd2;
                        end
                        3'd7: if (ins[27]) begin                          // RET
                            if (sp == 4'd0) begin st_err <= 1'b1; stop; end
                            else begin
                                sp <= sp - 1'b1;
                                flush = 1'b1; f_to = stk[sp[2:0] - 1'b1];
                            end
                        end else begin                                    // CALL
                            if (sp == 4'd8) begin st_err <= 1'b1; stop; end
                            else begin
                                stk[sp[2:0]] <= npc + 1'b1;
                                sp <= sp + 1'b1;
                                flush = 1'b1; f_to = ins[22:2];
                            end
                        end
                    endcase
                end

                X_ALU: if (!hold) begin : alu
                    reg [16:0] r;
                    reg [15:0] d, s;
                    reg [2:0]  fn;
                    fn = ir[27:25];
                    d  = ir[23] ? ry : rx;
                    s  = (ir[22:21] == 2'd0) ? ir[15:0] : (ir[22:21] == 2'd1) ? rx :
                         (ir[22:21] == 2'd2) ? ry : rr[ir[2:0]];
                    case (fn)
                        3'd0: if (ir[24:23] == 2'd3) rf <= s[2:0];
                              else if (ir[23]) ry <= s; else rx <= s;
                        3'd1: rr[ir[2:0]] <= (ir[24:23] == 2'd3) ? {13'd0, rf} : d;
                        default: begin
                            case (fn)
                                3'd2: r = {1'b0, d} + {1'b0, s};
                                3'd3, 3'd6: r = {1'b0, d} - {1'b0, s};
                                3'd4: r = {1'b0, d & s};
                                default: r = {1'b0, d | s};
                            endcase
                            rf <= {r[16], r[15], r[15:0] == 16'd0};
                            if (fn != 3'd6) begin
                                if (ir[23]) ry <= r[15:0]; else rx <= r[15:0];
                            end
                        end
                    endcase
                    xs <= X_RUN;
                end

                X_WAIT: if (!w_never && ((b_fo > w_fo) || (b_fo == w_fo && beam_h >= w_px))
                            && (!w_blt || blt_idle))
                    xs <= X_RUN;

                X_WR:  if (cw_go) xs <= X_GAP;
                X_GAP: xs <= X_RUN;
                default: ;
            endcase

            // ---- strobes and the vertical blank (after execute: they win)
            if (s_jmp1 && en) begin
                in2 <= 1'b0;
                restart(lc1);
            end
            if (s_jmp2 && en) begin
                in2 <= 1'b1;
                restart(lc2);
            end
            if (vblank && en) begin
                if (copcon[2] && in2)
                    lc2 <= (xs == X_RUN || xs == X_GAP || xs == X_OFF || (xs == X_WR && cw_go)) ? npc : xpc;
                in2 <= 1'b0;
                if (!copcon[3]) sp <= 4'd0;
                restart(lc1);
            end
            if (!en) begin
                xs <= X_OFF;
                in2 <= 1'b0;           // off forgets list 2, so RESUME saves nothing stale
                cw_req <= 1'b0;
                if (xs != X_OFF) flush = 1'b1;
            end

            // ---- fetch
            if (mem_ack) begin
                mem_req <= 1'b0;
                outst   <= 1'b1;
            end
            if (mem_rvalid) begin
                outst <= 1'b0;
                if (stale) stale <= 1'b0;
                else if (!flush) begin
                    if (buf_n == 2'd0) buf_hi <= mem_rdata; else buf_lo <= mem_rdata;
                    buf_n <= buf_n + 1'b1;
                end
            end
            if (flush) begin
                buf_n <= 2'd0;
                fpc   <= {f_to[21:2], 1'b0};
                npc   <= f_to;
                // A word asked for or on its way is dropped when it comes
                if ((mem_req && !mem_ack) || mem_ack || (outst && !mem_rvalid)) stale <= 1'b1;
            end else if (!mem_req && !outst && !mem_ack && !mem_rvalid && !stale
                         && xs != X_OFF && buf_n != 2'd2) begin
                mem_req  <= 1'b1;
                mem_addr <= fpc;
                fpc      <= fpc + 1'b1;
            end

            // ---- register writes (after the instructions: the bus wins)
            if (s_int) st_irq <= 1'b1;
            if (s_sp) sp <= 4'd0;
            if (wr) begin : wregs
                reg [31:0] v;
                case (off)
                    `RM_COPCON:   begin v = merge({26'd0, copcon}, rb_wdata, rb_be); copcon <= v[5:0]; end
                    `RM_COP1LC:   begin v = merge({9'd0, lc1, 2'd0}, rb_wdata, rb_be); lc1 <= v[22:2]; end
                    `RM_COP2LC:   begin v = merge({9'd0, lc2, 2'd0}, rb_wdata, rb_be); lc2 <= v[22:2]; end
                    `RM_COPSTAT:  if (rb_be[0]) begin
                        if (rb_wdata[2]) st_err <= 1'b0;
                        if (rb_wdata[3]) st_irq <= 1'b0;
                    end
                    `RM_COPX:     begin v = merge({16'd0, rx}, rb_wdata, rb_be); rx <= v[15:0]; end
                    `RM_COPY:     begin v = merge({16'd0, ry}, rb_wdata, rb_be); ry <= v[15:0]; end
                    `RM_COPFLAGS: if (rb_be[0]) rf <= rb_wdata[2:0];
                    default: if (off >= `RM_COPR_BASE && off < `RM_COPR_BASE + 16'd32) begin
                        v = merge({16'd0, rr[off[4:2]]}, rb_wdata, rb_be);
                        rr[off[4:2]] <= v[15:0];
                    end
                endcase
            end
        end

        // ---- reads (1 clock)
        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_COPCON:   rb_rdata <= {26'd0, copcon};
            `RM_COP1LC:   rb_rdata <= {9'd0, lc1, 2'd0};
            `RM_COP2LC:   rb_rdata <= {9'd0, lc2, 2'd0};
            `RM_COPPC:    rb_rdata <= {9'd0, (xs == X_RUN) ? npc : xpc, 2'd0};   // stopped: the STOP
            `RM_COPSTAT:  rb_rdata <= {28'd0, st_irq, st_err, xs == X_OFF, xs == X_WAIT};
            `RM_COPX:     rb_rdata <= {16'd0, rx};
            `RM_COPY:     rb_rdata <= {16'd0, ry};
            `RM_COPFLAGS: rb_rdata <= {29'd0, rf};
            `RM_COPSP:    rb_rdata <= {28'd0, sp};
            default: if (off >= `RM_COPR_BASE && off < `RM_COPR_BASE + 16'd32)
                rb_rdata <= {16'd0, rr[off[4:2]]};
        endcase
    end

    // A register write: its half, at once (spec 3, section 2; a palette entry
    // holds its high half itself, video.v)
    task do_write(input [15:0] o, input [15:0] d);
        begin
            cw_req   <= 1'b1;
            cw_addr  <= {8'hE0, 1'b0, o[14:2]};
            cw_wdata <= {d, d};
            cw_be    <= o[1] ? 4'b0011 : 4'b1100;
            xs       <= X_WR;
        end
    endtask

    task stop;
        begin
            xs  <= X_OFF;
            in2 <= 1'b0;
        end
    endtask

    task restart(input [22:2] to);
        begin
            xs     <= X_RUN;
            cw_req <= 1'b0;
            flush  = 1'b1;
            f_to   = to;
        end
    endtask
endmodule
