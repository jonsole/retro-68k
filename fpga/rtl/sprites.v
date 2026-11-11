// Sprites, 100 MHz side (spec 9): retro68k's registers on retro-hw's
// sprite_fetch (fpga/retro-hw/docs/spec/sprite_fetch.md), which fetches
// the words, keeps the FIFOs and line starts, and gathers collisions.
//
// Eight sprites. Each has a pointer into its image (SPRxPT, the core's
// line start), a window (SPRxH, SPRxV), settings (SPRxCTL) and steps
// (SPRxSTEP), written by the CPU or copper. A write to SPRxCTL starts a
// sprite; SPRxDAT feeds a sprite by hand while its DMA is off.
`include "regmap.vh"

module sprites (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [15:0] dmacon,
    input  wire        vblank,         // 1 clock: the vertical blank starts
    input  wire [10:0] beam_v,         // the beam (memory side samples)
    input  wire [10:0] beam_h,

    // Scheduler: the sprite channel
    output wire        mem_req,
    output wire [21:1] mem_addr,
    output wire        mem_urgent,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // To the pixel side: each sprite's settings (read once per line there)
    output wire [79:0] p_hs,           // 8 x 10: first pixel (0-864)
    output wire [79:0] p_xe,           // 8 x 10: pixel after the last shown (0-864)
    output wire [7:0]  p_act,          // shows on this line (set at its start)
    output wire [15:0] p_lb,           // 8 x 2: log2 bits per pixel (1-3)
    output wire [127:0] p_xstep,       // 8 x 16: XSTEP, limited (5.11 source pixels per screen pixel)
    output wire [15:0] p_depth,
    output wire [31:0] p_pal,
    output wire [7:0]  p_dma,          // fed by the DMA

    // The FIFOs, between the domains
    input  wire [39:0] fifo_ra,        // 8 x 5: read addresses (pixel side)
    output wire [127:0] fifo_rd,       // 8 x 16: the words there
    output wire [47:0] wp_g,           // 8 x 6: write pointers, Gray-coded
    input  wire [47:0] rp,             // 8 x 6: read pointers, as the pixel units register them (pixel clock)
    output wire [7:0]  flush_t,
    input  wire [7:0]  flush_ack_t,

    // Collisions found on a line (pixel side, stable when coll_t toggles)
    input  wire [31:0] coll_line,
    input  wire        coll_t
);
    // ================================================================ registers
    reg  [7:0]  sprdma;
    // SPRxH, SPRxV, SPRxCTL, SPRxSTEP as written, in distributed RAM (one
    // write a clock: a register write, or clearing one a clock during reset)
    reg  [21:0] m_h [0:7];                     // HSTOP (21-11), HSTART (10-0)
    reg  [21:0] m_v [0:7];                     // VSTOP (21-11), VSTART (10-0)
    reg  [7:0]  m_c [0:7];                     // PAL 7-4, DEPTH 3-2, BPP 1-0
    reg  [31:0] m_s [0:7];                     // YSTEP 31-16, XSTEP 15-0

    wire [15:0] off   = {rb_addr[15:2], 2'b00};
    wire        in_c  = (rb_addr[23:16] == 8'hE0);
    wire        sel_g = in_c && (off == `RM_SPRDMA || off == `RM_SPRCOLL);
    wire [15:0] so    = off - `RM_SPR_BASE;
    wire        sel_s = in_c && (off >= `RM_SPR_BASE) && (so < 16'h0100) && (so[4:2] <= 3'd5);
    wire [2:0]  sn    = so[7:5];
    wire [2:0]  sr    = so[4:2];               // 0 PT, 1 H, 2 V, 3 CTL, 4 DAT, 5 STEP

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    wire        dma_on = dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_SPREN];
    wire [7:0]  active = dma_on ? sprdma : 8'd0;

    // ================================================================ the core
    wire [2:0]  cs;                            // the sprite whose settings the core takes
    wire [22:0] lst_cur;
    wire [5:0]  fifo_count;
    wire [31:0] coll;
    wire        w_ctl = rb_wr && sel_s && sr == 3'd3;
    wire        w_pt  = rb_wr && sel_s && sr == 3'd0;
    wire [31:0] lst_v = merge({9'd0, lst_cur}, rb_wdata, rb_be);
    wire [31:0] coll_clr = (rb_wr && sel_g && off == `RM_SPRCOLL) ? merge(32'd0, rb_wdata, rb_be) : 32'd0;

    sprite_fetch #(.NS(8), .PW(23), .AW(21), .LITTLE(0), .URGENT(5), .MANUAL(1)) core (
        .clk(clk), .rst(rst),
        .set_sel(cs),
        .set_hstart(m_h[cs][10:0]), .set_hstop(m_h[cs][21:11]),
        .set_vstart(m_v[cs][10:0]), .set_vstop(m_v[cs][21:11]),
        .set_bpp(m_c[cs][1:0]), .set_depth(m_c[cs][3:2]), .set_pal(m_c[cs][7:4]),
        .set_xstep(m_s[cs][15:0]), .set_ystep(m_s[cs][31:16]),
        .dma_on(dma_on), .dma_mask(sprdma),
        .start(w_ctl ? (8'd1 << sn) : 8'd0), .sel(sn),
        .lst_cur(lst_cur), .lst_wr(w_pt), .lst_new(lst_v[22:0]),
        .fifo_count(fifo_count),
        .dat_wr(rb_wr && sel_s && sr == 3'd4 && rb_be[1:0] == 2'b11), .dat(rb_wdata[15:0]),
        .vblank(vblank), .beam_v(beam_v), .beam_h(beam_h),
        .mem_req(mem_req), .mem_addr(mem_addr), .mem_urgent(mem_urgent),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .p_hs(p_hs), .p_xe(p_xe), .p_act(p_act), .p_lb(p_lb), .p_xstep(p_xstep),
        .p_depth(p_depth), .p_pal(p_pal), .p_dma(p_dma),
        .fifo_ra(fifo_ra), .fifo_rd(fifo_rd), .wp_g(wp_g), .rp(rp),
        .flush_t(flush_t), .flush_ack_t(flush_ack_t),
        .coll_line(coll_line), .coll_t(coll_t), .coll_clr(coll_clr), .coll(coll)
    );

    // ================================================================ the RAMs
    // The registers: written by halves (merged with the old value)
    wire [31:0] h_v = merge({5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] v_v = merge({5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]}, rb_wdata, rb_be);
    wire [31:0] c_v = merge({4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, m_c[sn][1:0], 12'd0}, rb_wdata, rb_be);
    wire [31:0] s_v = merge(m_s[sn], rb_wdata, rb_be);
    wire [2:0]  ra  = rst ? cs : sn;
    always @(posedge clk) begin
        if (rst || (rb_wr && sel_s && sr == 3'd1)) m_h[ra] <= rst ? 22'd0 : {h_v[26:16], h_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd2)) m_v[ra] <= rst ? 22'd0 : {v_v[26:16], v_v[10:0]};
        if (rst || (rb_wr && sel_s && sr == 3'd3))
            m_c[ra] <= rst ? 8'd0 : {c_v[27:24], c_v[21:20], (c_v[13:12] == 2'd3) ? 2'd2 : c_v[13:12]};
        if (rst || (rb_wr && sel_s && sr == 3'd5)) m_s[ra] <= rst ? 32'd0 : s_v;
    end
    integer ii;
    initial for (ii = 0; ii < 8; ii = ii + 1) begin
        m_h[ii] = 22'd0; m_v[ii] = 22'd0; m_c[ii] = 8'd0; m_s[ii] = 32'd0;
    end

    // ================================================================ main
    always @(posedge clk) begin
        if (rst)
            sprdma <= 8'hFF;
        else if (rb_wr && sel_g && off == `RM_SPRDMA && rb_be[1:0] == 2'b11) begin
            if (rb_wdata[15]) sprdma <= sprdma |  rb_wdata[7:0];
            else              sprdma <= sprdma & ~rb_wdata[7:0];
        end

        // ---- reads (1 clock)
        rb_rdata <= 32'd0;
        if (rb_rd && sel_g) rb_rdata <= (off == `RM_SPRDMA) ? {24'd0, sprdma} : coll;
        if (rb_rd && sel_s) case (sr)
            3'd0: rb_rdata <= {9'd0, lst_cur};
            3'd1: rb_rdata <= {5'd0, m_h[sn][21:11], 5'd0, m_h[sn][10:0]};
            3'd2: rb_rdata <= {5'd0, m_v[sn][21:11], 5'd0, m_v[sn][10:0]};
            3'd3: rb_rdata <= {4'd0, m_c[sn][7:4], 2'd0, m_c[sn][3:2], 6'd0, m_c[sn][1:0], 12'd0};
            3'd4: rb_rdata <= {26'd0, fifo_count};
            3'd5: rb_rdata <= m_s[sn];
            default: ;
        endcase
    end
endmodule
