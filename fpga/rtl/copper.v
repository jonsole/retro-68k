// Copper (spec 10): retro68k's registers, instruction decoder, writes and
// ALU on retro-hw's copper_engine (fetch, WAIT/SKIP, JUMP/CALL/RET, starts).
// From retro-z80's sketch, checked clock for clock against 7db2483.
`include "regmap.vh"

module copper (
    input  wire        clk,
    input  wire        rst,
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,
    output wire        cw_req,
    output reg  [23:2] cw_addr,
    output reg  [31:0] cw_wdata,
    output reg  [3:0]  cw_be,
    input  wire        cw_go,
    output wire        mem_req,
    output wire [21:1] mem_addr,
    output wire [1:0]  mem_pri,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,
    input  wire [10:0] beam_v,
    input  wire [10:0] beam_h,
    input  wire        vblank,
    input  wire [15:0] dmacon,
    input  wire        blt_idle,
    output wire        irq
);
    reg  [5:0]  copcon;
    reg  [22:2] lc1, lc2;
    reg         st_err, st_irq;
    reg  [15:0] rx, ry;
    reg  [2:0]  rf;
    reg  [15:0] rr [0:7];

    wire en = copcon[0] && dmacon[`RM_DMACON_COPEN] && dmacon[`RM_DMACON_DMAEN];
    assign mem_pri = copcon[5:4];
    assign irq = st_irq && copcon[1];

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hE0) && (off[15:7] == 9'h0E);
    wire wr  = rb_wr && sel;
    function [31:0] merge(input [31:0] old, input [31:0] nw, input [3:0] be);
        merge = { be[3] ? nw[31:24] : old[31:24], be[2] ? nw[23:16] : old[23:16],
                  be[1] ? nw[15:8]  : old[15:8],  be[0] ? nw[7:0]   : old[7:0] };
    endfunction
    wire s_jmp1 = wr && off == `RM_COPJMP1 && rb_be[1:0] != 2'b00;
    wire s_jmp2 = wr && off == `RM_COPJMP2 && rb_be[1:0] != 2'b00;
    wire s_int  = wr && off == `RM_COPINT  && rb_be[1:0] != 2'b00;
    wire s_sp   = wr && off == `RM_COPSP   && rb_be[1:0] != 2'b00;

    localparam [3:0] OP_NEXT = 4'd0, OP_WRITE = 4'd1, OP_WAIT = 4'd2, OP_SKIP = 4'd3,
                     OP_SKIPC = 4'd4, OP_JUMP = 4'd5, OP_CALL = 4'd6, OP_RET = 4'd7,
                     OP_STOP = 4'd8, OP_ERR = 4'd9, OP_MORE = 4'd10;
    wire [15:0] b0, b1, b2;
    wire [31:0] ins = {b0, b1};
    wire        exec, more, error, save2, stopped, waiting;
    wire [22:1] save2_at, pc, maddr;
    wire [3:0]  sp;
    reg  [3:0]  op;

    wire        i_ext  = ins[31];
    wire [2:0]  i_op   = ins[30:28];
    wire        i_p    = ins[27];
    wire [10:0] i_line = ins[26:16];

    copper_engine #(.AW(22), .WR_HANDSHAKE(1)) eng (
        .clk(clk), .rst(rst),
        .run(en), .frame(vblank), .start1(s_jmp1), .start2(s_jmp2),
        .list1({lc1, 1'b0}), .list2({lc2, 1'b0}),
        .resume(copcon[2]), .stack_keep(copcon[3]), .stack_clear(s_sp),
        .save2(save2), .save2_at(save2_at),
        .word0(b0), .word1(b1), .word2(b2),
        .need(2'd2), .len(2'd2), .skip_len(2'd2), .op(op),
        .target({ins[22:2], 1'b0}),
        .pos_line(i_line), .pos_px(ins[10:0]), .pos_rel(i_p), .wait_blt(ins[15]),
        .cc(ins[27:24]), .flags(rf),
        .exec(exec), .more(more), .error(error),
        .wr_req(cw_req), .wr_go(cw_go),
        .stopped(stopped), .waiting(waiting), .pc(pc), .sp(sp),
        .mem_req(mem_req), .mem_addr(maddr),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .beam_v(beam_v), .beam_h(beam_h), .blt_idle(blt_idle)
    );
    assign mem_addr = maddr[21:1];

    reg bad;
    always @(*) begin
        bad = 1'b0;
        if (i_ext) case (i_op)
            3'd0: bad = ins[14:11] != 4'd0;
            3'd1: bad = ins[15:11] != 5'd0;
            3'd2: bad = ins[27:23] != 5'd0 || ins[1:0] != 2'd0;
            3'd3: bad = ins[27:0] != 28'd0;
            3'd4: bad = ins[23:16] != 8'd0 || (!ins[27] && !ins[26])
                        || (ins[25] && !ins[27]) || (ins[27] && ins[26] && ins[15:0] != 16'd0)
                        || (!ins[26] && ins[24]);
            3'd5: bad = ins[20:16] != 5'd0 || ins[27:25] == 3'd7
                        || ins[24:23] == 2'd2
                        || (ins[24:23] == 2'd3 && ins[27:25] >= 3'd2)
                        || (ins[27:25] == 3'd1 && ins[22:21] != 2'd3)
                        || (ins[22:21] == 2'd3 && ins[15:3] != 13'd0)
                        || ((ins[22:21] == 2'd1 || ins[22:21] == 2'd2) && ins[15:0] != 16'd0);
            3'd6: bad = ins[27] || ins[23:0] != 24'd0;
            3'd7: bad = ins[27] ? (ins[26:0] != 27'd0)
                                : (ins[26:23] != 4'd0 || ins[1:0] != 2'd0);
        endcase
    end
    always @(*) begin
        if (!i_ext) op = OP_WRITE;
        else if (bad) op = OP_ERR;
        else case (i_op)
            3'd0: op = (!i_p && i_line == 11'd2047) ? OP_STOP : OP_WAIT;
            3'd1: op = OP_SKIP;
            3'd2: op = OP_JUMP;
            3'd3: op = OP_STOP;
            3'd4: op = OP_WRITE;
            3'd5: op = OP_MORE;
            3'd6: op = OP_SKIPC;
            default: op = ins[27] ? OP_RET : OP_CALL;
        endcase
    end

    reg [31:0] ir;
    integer i;
    always @(posedge clk) begin
        if (rst) begin
            copcon <= 6'd0;
            lc1 <= 21'd0; lc2 <= 21'd0;
            st_err <= 1'b0; st_irq <= 1'b0;
            rx <= 16'd0; ry <= 16'd0; rf <= 3'd0;
            for (i = 0; i < 8; i = i + 1) rr[i] <= 16'd0;
        end else begin
            if (exec) begin
                ir <= ins;
                if (op == OP_WRITE) begin
                    if (!i_ext) do_write({1'b0, ins[30:17], 1'b0}, ins[15:0]);
                    else begin
                        if (ins[25]) rx <= rx + 16'd2;
                        do_write(ins[27] ? {1'b0, rx[14:1], 1'b0} : {1'b0, ins[14:1], 1'b0},
                                 ins[26] ? (ins[24] ? rx : ry) : ins[15:0]);
                    end
                end
            end
            if (error) st_err <= 1'b1;
            if (more) begin : alu
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
            end
            if (save2) lc2 <= save2_at[22:2];

            if (s_int) st_irq <= 1'b1;
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

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_COPCON:   rb_rdata <= {26'd0, copcon};
            `RM_COP1LC:   rb_rdata <= {9'd0, lc1, 2'd0};
            `RM_COP2LC:   rb_rdata <= {9'd0, lc2, 2'd0};
            `RM_COPPC:    rb_rdata <= {9'd0, pc[22:2], 2'd0};
            `RM_COPSTAT:  rb_rdata <= {28'd0, st_irq, st_err, stopped, waiting};
            `RM_COPX:     rb_rdata <= {16'd0, rx};
            `RM_COPY:     rb_rdata <= {16'd0, ry};
            `RM_COPFLAGS: rb_rdata <= {29'd0, rf};
            `RM_COPSP:    rb_rdata <= {28'd0, sp};
            default: if (off >= `RM_COPR_BASE && off < `RM_COPR_BASE + 16'd32)
                rb_rdata <= {16'd0, rr[off[4:2]]};
        endcase
    end

    task do_write(input [15:0] o, input [15:0] d);
        begin
            cw_addr  <= {8'hE0, 1'b0, o[14:2]};
            cw_wdata <= {d, d};
            cw_be    <= o[1] ? 4'b0011 : 4'b1100;
        end
    endtask
endmodule
