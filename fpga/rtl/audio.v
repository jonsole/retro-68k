// Audio (spec 6): four sample channels, mixed to stereo at a fixed output
// rate, out through sigma-delta DACs.
//
// The channels are retro-hw's audio_engine (its docs/spec/audio_engine.md):
// it keeps their settings and plays them. Here are the bus, AUDRATE with its
// floor, the starts and stops from DMACON and AUDSTART/AUDSTOP, AUDSTAT and
// the interrupt, and the DACs.
`include "regmap.vh"

module audio (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output wire [31:0] rb_rdata,

    input  wire [15:0] dmacon,

    // Memory (dmac.v audio channel): reads
    output wire        mem_req,
    output wire [21:1] mem_addr,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    output wire        irq,

    output wire signed [15:0] out_l,   // the last output sample
    output wire signed [15:0] out_r,
    output wire        tick_done,      // 1 clock: out_l and out_r are new
    output wire        dac_l,          // sigma-delta streams
    output wire        dac_r,
    output wire        dac_m
);
    // ================================================================ registers
    reg  [15:0] rate;
    reg  [3:0]  stat, inten;
    reg  [3:0]  en_d;                  // DMACON's enables a clock ago
    wire [3:0]  on, ev;                // playing (AUDSTAT.ACTIVE); a block taken, or a one-shot's end

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_g  = in_custom && off[15:6] == 10'h010;                     // 0x400-0x43F
    wire [2:0] chn = off[7:5] - 3'd2;
    wire [1:0] cn  = chn[1:0];                                    // channel n at 0x440 + n x 0x20
    wire sel_c  = in_custom && off[15:8] == 8'h04 && off[7:5] >= 3'd2 && off[7:5] <= 3'd5;

    // Starting and stopping act as soon as they are written (spec 6, 4.2)
    wire [3:0]  en   = dmacon[`RM_DMACON_DMAEN] ? dmacon[3:0] : 4'd0;
    wire        w_start = rb_wr && sel_g && off == `RM_AUDSTART && rb_be[0];
    wire        w_stop  = rb_wr && sel_g && off == `RM_AUDSTOP  && rb_be[0];
    wire [3:0]  go   = (en & ~en_d) | (w_start ? rb_wdata[3:0] & en : 4'd0);
    wire [3:0]  halt = (~en & en_d) | (w_stop ? rb_wdata[3:0] : 4'd0);

    assign irq = |(stat & inten);
    wire [15:0] rate_c = (rate < 16'd200) ? 16'd200 : rate;

    // ================================================================ the channels
    // A channel's registers are the core's fields, in order: CTRL, LC, LEN,
    // STEP, VOL, POS at 0x00 to 0x14 (CTRL's bits sit one place up here)
    wire        is_ctrl = (off[4:2] == 3'd0);
    wire [23:0] rb_q;
    audio_engine #(.NCH(4), .AW(21), .LE(0), .INTERP(1), .RDBACK(1)) eng (
        .clk(clk), .rst(rst),
        .rate(rate_c), .start(go), .stop(halt), .on(on), .ev(ev),
        .set_we(rb_wr && sel_c), .set_ch(cn), .set_f(off[4:2]),
        .set_d(is_ctrl ? {21'd0, rb_wdata[3:1]} : rb_wdata[23:0]), .set_be(rb_be[2:0]),
        .rb_re(rb_rd && sel_c), .rb_ch(cn), .rb_f(off[4:2]), .rb_q(rb_q),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_ack(mem_ack),
        .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .out_l(out_l), .out_r(out_r), .out_v(tick_done)
    );

    reg  [31:0] g_q;                   // a read of the registers here
    reg         c_rd, c_ctrl;          // the last read was a channel's (CTRL)
    assign rb_rdata = !c_rd ? g_q : c_ctrl ? {28'd0, rb_q[2:0], 1'b0} : {8'd0, rb_q};

    always @(posedge clk) begin
        if (rst) begin
            rate  <= 16'd2083;
            stat  <= 4'd0;
            inten <= 4'd0;
            en_d  <= 4'd0;
        end else begin
            en_d <= en;
            stat <= stat | ev;
            if (rb_wr && sel_g) case (off)
                `RM_AUDRATE:  begin
                    if (rb_be[1]) rate[15:8] <= rb_wdata[15:8];
                    if (rb_be[0]) rate[7:0]  <= rb_wdata[7:0];
                end
                `RM_AUDSTAT:  if (rb_be[0]) stat <= (stat | ev) & ~rb_wdata[3:0];
                `RM_AUDINTEN: if (rb_be[0]) inten <= rb_wdata[3:0];
                default: ;
            endcase
        end

        // Reads (1 clock)
        c_rd   <= rb_rd && sel_c;
        c_ctrl <= is_ctrl;
        g_q    <= 32'd0;
        if (rb_rd && sel_g) case (off)
            `RM_AUDRATE:  g_q <= {16'd0, rate};
            `RM_AUDSTAT:  g_q <= {24'd0, on, stat};
            `RM_AUDINTEN: g_q <= {28'd0, inten};
            default: ;
        endcase
    end

    // ================================================================ DACs (retro-hw's sigma_delta2)
    sigma_delta2 sd_l (.clk(clk), .rst(rst), .x(out_l), .y(dac_l));
    sigma_delta2 sd_r (.clk(clk), .rst(rst), .x(out_r), .y(dac_r));
    wire signed [16:0] mono = out_l + out_r;
    sigma_delta2 sd_m (.clk(clk), .rst(rst), .x(mono[16:1]), .y(dac_m));
endmodule
