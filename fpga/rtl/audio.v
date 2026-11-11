// Audio (spec 6): four sample channels, mixed to stereo at a fixed output
// rate, out through sigma-delta DACs.
//
// Every AUDRATE clocks one engine visits the channels in turn. For each
// playing channel it reads the word holding the sample at its position
// (and the word holding the next sample, if that is another word),
// interpolates between the two, multiplies by the left and right volumes
// into the mix, and moves the position on by STEP, taking the next block
// at the end of this one. After the fourth channel the mix goes to the DACs.
`include "regmap.vh"

module audio (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [15:0] dmacon,

    // Memory (dmac.v audio channel): reads
    output reg         mem_req,
    output reg  [21:1] mem_addr,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    output wire        irq,

    output reg  signed [15:0] out_l,   // the last output sample
    output reg  signed [15:0] out_r,
    output reg         tick_done,      // 1 clock: out_l and out_r are new
    output wire        dac_l,          // sigma-delta streams
    output wire        dac_r,
    output wire        dac_m
);
    // ================================================================ registers
    reg  [15:0] rate;
    reg  [3:0]  stat, inten;
    reg  [2:0]  ctrl [0:3];            // ONESHOT (2), NEAREST (1), BITS16 (0)
    reg  [22:0] lc   [0:3];
    reg  [22:0] len  [0:3];
    reg  [19:0] step [0:3];
    reg  [6:0]  vl   [0:3], vr [0:3];

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_g  = in_custom && off[15:6] == 10'h010;                     // 0x400-0x43F
    // Channel state
    reg  [3:0]  on;                    // playing (AUDSTAT.ACTIVE)
    reg  [3:0]  startp;                // to start at the next output sample
    reg  [3:0]  en_d;                  // DMACON's enables a clock ago
    reg  [3:0]  started;               // for the testbench: channels started at the last output sample
    reg  [3:0]  incl, incl_q;          // ... and played in it
    wire [3:0]  en   = dmacon[`RM_DMACON_DMAEN] ? dmacon[3:0] : 4'd0;
    // Starting and stopping act as soon as they are written (spec 6, 4.2)
    wire        w_start = rb_wr && sel_g && off == `RM_AUDSTART && rb_be[0];
    wire        w_stop  = rb_wr && sel_g && off == `RM_AUDSTOP  && rb_be[0];
    wire [3:0]  go   = (en & ~en_d) | (w_start ? rb_wdata[3:0] & en : 4'd0);
    wire [3:0]  halt = (~en & en_d) | (w_stop ? rb_wdata[3:0] : 4'd0);
    reg  [22:0] b_start [0:3];         // the block being played
    reg  [22:0] b_len   [0:3];
    reg  [38:0] pos     [0:3];         // 23.16 within the block

    assign irq = |(stat & inten);

    wire [2:0] chn = off[7:5] - 3'd2;
    wire [1:0] cn  = chn[1:0];                                    // channel n at 0x440 + n x 0x20
    wire sel_c  = in_custom && off[15:8] == 8'h04 && off[7:5] >= 3'd2 && off[7:5] <= 3'd5;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction
    function [6:0] vclip(input [6:0] v);
        vclip = (v > 7'd64) ? 7'd64 : v;
    endfunction

    // ================================================================ engine
    // For timing, each multiply has a clock to itself: E_INT the
    // interpolation's, E_VOL the volumes'; E_MIX and E_ADV add their results.
    localparam E_IDLE = 4'd0, E_CH = 4'd1, E_RD0 = 4'd2, E_RD1 = 4'd3, E_INT = 4'd4,
               E_VOL = 4'd5, E_ADV = 4'd6, E_OUT = 4'd7, E_MIX = 4'd8;
    reg  [3:0]  es;
    reg  [1:0]  ch;
    reg  [15:0] cnt;
    reg  [22:0] a0, a1;                // byte addresses of s0 and s1
    reg  [15:0] d0, d1;
    reg  signed [15:0] s0, s1, smp;
    reg  signed [25:0] acc_l, acc_r;
    reg  signed [15:0] s0_r;
    reg  signed [33:0] ip_r;           // the interpolation's product
    reg  signed [23:0] pl, pr;         // the sample times each volume
    reg                padd;           // pl and pr are to be added (E_ADV)

    wire [15:0] rate_c = (rate < 16'd200) ? 16'd200 : rate;
    wire        tick = (cnt == 16'd0);

    // Positions of the channel being worked on
    wire [22:0] ip   = pos[ch][38:16];
    wire [22:0] ip1  = (ip + 1'b1 < b_len[ch]) ? ip + 1'b1 : ip;
    wire        b16  = ctrl[ch][0];
    wire [22:0] pa0  = b16 ? b_start[ch] + {ip[21:0], 1'b0}  : b_start[ch] + ip;
    wire [22:0] pa1  = b16 ? b_start[ch] + {ip1[21:0], 1'b0} : b_start[ch] + ip1;

    function signed [15:0] pick(input [15:0] w, input [22:0] a, input b16_);
        pick = b16_ ? w : {(a[0] ? w[7:0] : w[15:8]), 8'd0};
    endfunction

    // The next position, and the block it falls in
    wire [38:0] pnext = pos[ch] + {19'd0, step[ch]};
    wire        past  = pnext[38:16] >= b_len[ch];
    wire [38:0] pwrap = pnext - {b_len[ch], 16'd0};

    integer i;
    always @(posedge clk) begin
        tick_done <= 1'b0;
        if (rst) begin
            rate  <= 16'd2083;
            stat  <= 4'd0;
            inten <= 4'd0;
            for (i = 0; i < 4; i = i + 1) begin
                ctrl[i] <= 3'd0; lc[i] <= 23'd0; len[i] <= 23'd0; step[i] <= 20'h10000;
                b_start[i] <= 23'd0; b_len[i] <= 23'd0; pos[i] <= 39'd0;
            end
            vl[0] <= 7'd64; vr[0] <= 7'd0;
            vl[1] <= 7'd0;  vr[1] <= 7'd64;
            vl[2] <= 7'd0;  vr[2] <= 7'd64;
            vl[3] <= 7'd64; vr[3] <= 7'd0;
            on    <= 4'd0;
            startp <= 4'd0;
            en_d  <= 4'd0;
            started <= 4'd0;
            incl  <= 4'd0;
            incl_q <= 4'd0;
            es    <= E_IDLE;
            padd  <= 1'b0;
            cnt   <= 16'd0;
            mem_req <= 1'b0;
            out_l <= 16'sd0; out_r <= 16'sd0;
        end else begin
            cnt <= tick ? rate_c - 1'b1 : cnt - 1'b1;
            if (mem_ack) mem_req <= 1'b0;

            case (es)
                E_IDLE: if (tick) begin
                    // Channels to start take their registers (a block of
                    // length 0 leaves the channel stopped)
                    for (i = 0; i < 4; i = i + 1)
                        if (startp[i]) begin
                            on[i]      <= (len[i] != 23'd0);
                            b_start[i] <= lc[i];
                            b_len[i]   <= len[i];
                            pos[i]     <= 39'd0;
                            stat[i]    <= 1'b1;
                        end
                    started <= startp;
                    startp  <= 4'd0;
                    incl    <= 4'd0;
                    acc_l <= 26'sd0;
                    acc_r <= 26'sd0;
                    ch    <= 2'd0;
                    es    <= E_CH;
                end

                E_CH: if (on[ch]) begin
                    incl[ch] <= 1'b1;
                    a0 <= pa0;
                    a1 <= pa1;
                    mem_req  <= 1'b1;
                    mem_addr <= pa0[21:1];
                    es       <= E_RD0;
                end else es <= E_ADV;

                E_RD0: if (mem_rvalid) begin
                    d0 <= mem_rdata;
                    if (a1[22:1] != a0[22:1]) begin
                        mem_req  <= 1'b1;
                        mem_addr <= a1[21:1];
                        es       <= E_RD1;
                    end else begin
                        d1 <= mem_rdata;
                        es <= E_INT;
                    end
                end

                E_RD1: if (mem_rvalid) begin
                    d1 <= mem_rdata;
                    es <= E_INT;
                end

                E_INT: begin : interp
                    reg signed [16:0] diff;
                    s0   = pick(d0, a0, b16);
                    s1   = pick(d1, a1, b16);
                    diff = s1 - s0;
                    s0_r <= s0;
                    ip_r <= diff * $signed({1'b0, pos[ch][15:0]});
                    es   <= E_MIX;
                end

                E_MIX: begin
                    smp <= ctrl[ch][1] ? s0_r : s0_r + ip_r[31:16];
                    es  <= E_VOL;
                end

                E_VOL: begin
                    pl   <= smp * $signed({1'b0, vclip(vl[ch])});
                    pr   <= smp * $signed({1'b0, vclip(vr[ch])});
                    padd <= 1'b1;
                    es   <= E_ADV;
                end

                E_ADV: begin
                    if (padd) begin
                        acc_l <= acc_l + pl;
                        acc_r <= acc_r + pr;
                    end
                    padd <= 1'b0;
                    if (on[ch]) begin
                        if (past && ctrl[ch][2]) begin
                            // One-shot: the block is done; stop
                            on[ch]   <= 1'b0;
                            stat[ch] <= 1'b1;
                        end else if (past) begin
                            // On into the next block: take the registers again
                            b_start[ch] <= lc[ch];
                            b_len[ch]   <= len[ch];
                            pos[ch]     <= (pwrap[38:16] < len[ch]) ? pwrap : {23'd0, pwrap[15:0]};
                            stat[ch]    <= 1'b1;
                            if (len[ch] == 23'd0) on[ch] <= 1'b0;
                        end else
                            pos[ch] <= pnext;
                    end
                    if (ch == 2'd3) es <= E_OUT;
                    else begin
                        ch <= ch + 1'b1;
                        es <= E_CH;
                    end
                end

                E_OUT: begin
                    out_l <= acc_l[23:8];
                    out_r <= acc_r[23:8];
                    incl_q <= incl;
                    tick_done <= 1'b1;
                    es <= E_IDLE;
                end
                default: es <= E_IDLE;
            endcase

            // Starting and stopping (after the engine: a stop wins)
            en_d <= en;
            for (i = 0; i < 4; i = i + 1) begin
                if (go[i])   startp[i] <= 1'b1;
                if (halt[i]) begin
                    startp[i] <= 1'b0;
                    on[i]     <= 1'b0;
                end
            end

            // Register writes
            if (rb_wr && sel_g) case (off)
                `RM_AUDRATE:  begin : wr_rate
                    reg [31:0] v;
                    v = merge({16'd0, rate}, rb_wdata, rb_be);
                    rate <= v[15:0];
                end
                `RM_AUDSTAT:  if (rb_be[0]) stat <= stat & ~rb_wdata[3:0];
                `RM_AUDINTEN: if (rb_be[0]) inten <= rb_wdata[3:0];
                default: ;
            endcase
            if (rb_wr && sel_c) begin : wr_ch
                reg [31:0] v;
                case (off[4:0])
                    5'h00: if (rb_be[0]) ctrl[cn] <= rb_wdata[3:1];
                    5'h04: begin v = merge({9'd0, lc[cn]}, rb_wdata, rb_be);  lc[cn]  <= v[22:0]; end
                    5'h08: begin v = merge({9'd0, len[cn]}, rb_wdata, rb_be); len[cn] <= v[22:0]; end
                    5'h0C: begin v = merge({12'd0, step[cn]}, rb_wdata, rb_be); step[cn] <= v[19:0]; end
                    5'h10: begin v = merge({9'd0, vl[cn], 9'd0, vr[cn]}, rb_wdata, rb_be);
                                 vl[cn] <= v[22:16]; vr[cn] <= v[6:0]; end
                    default: ;
                endcase
            end
        end

        // Reads (1 clock)
        rb_rdata <= 32'd0;
        if (rb_rd && sel_g) case (off)
            `RM_AUDRATE:  rb_rdata <= {16'd0, rate};
            `RM_AUDSTAT:  rb_rdata <= {24'd0, on, stat};
            `RM_AUDINTEN: rb_rdata <= {28'd0, inten};
            default: ;
        endcase
        if (rb_rd && sel_c) case (off[4:0])
            5'h00: rb_rdata <= {28'd0, ctrl[cn], 1'b0};
            5'h04: rb_rdata <= {9'd0, lc[cn]};
            5'h08: rb_rdata <= {9'd0, len[cn]};
            5'h0C: rb_rdata <= {12'd0, step[cn]};
            5'h10: rb_rdata <= {9'd0, vl[cn], 9'd0, vr[cn]};
            5'h14: rb_rdata <= {9'd0, pos[cn][38:16]};
            default: ;
        endcase
    end

    // ================================================================ DACs (retro-hw's sigma_delta2)
    sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
    sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
    wire signed [16:0] mono = out_l + out_r;
    sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
endmodule
