// Video (spec 4): 576p (720x576 at 50 Hz, CEA-861, 27 MHz), four 256-colour
// palettes (one per layer, one for the sprites), background colour,
// three bitmap layers (chunky 1/2/4/8 bpp or planar 1-8 planes, Amiga-style:
// plane pointers, modulo and data registers, bpldma.v), priority, beam
// position, VBLANK, LINE and OVERRUN.
// Also DMACON (spec 5, section 8), which sits in this register block.
//
// Two clock domains, asynchronous to each other:
//   clk     100 MHz: registers, bitplane DMA, palette writes, interrupts
//   clk_pix  27 MHz: the beam and the pixel pipeline
// Crossings: events are toggles through two flip-flops; the data registers
// cross under the full/taken handshake (bpldma.v, layer_pix.v); the beam
// position is sampled until two samples agree; layer settings, PRIO,
// BGCOLOR and VIDCON are settings, copied into the pixel domain once per
// line (a write that lands exactly on that copy may take effect one line
// later, or show for one line in part); the palette is a two-clock RAM.
`include "regmap.vh"

module video (
    input  wire        clk,            // 100 MHz
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    input  wire [1:0]  rb_who,         // who writes: 0 the CPU, 1 the copper, 2 the DMA engine
    output wire [31:0] rb_rdata,

    output wire        irq_vblank,
    output wire        irq_line,
    output wire        irq_viderr,
    output wire        line_tick,      // 1 clock (100 MHz) per video line, for the timers
    output wire        frame_tick,     // 1 clock at the start of each vertical blank
    output wire [10:0] beam_v,         // the beam position, memory side (for the copper)
    output wire [10:0] beam_h,

    // DMACON, and the display fetch port of the SRAM controller
    output reg  [15:0] dmacon,
    output wire        disp_req,
    output wire        disp_urgent,
    output wire [9:0]  disp_deadline,
    output wire [21:1] disp_addr,
    input  wire        disp_ack,
    input  wire        disp_rvalid,
    input  wire [15:0] disp_rdata,

    // The sprite fetcher's port (spec 9; the same read data)
    output wire        spr_req,
    output wire        spr_urgent,
    output wire [9:0]  spr_deadline,
    output wire [21:1] spr_addr,
    input  wire        spr_ack,
    input  wire        spr_rvalid,

    input  wire        clk_pix,
    input  wire        clk_pix5,       // 5 x clk_pix (135 MHz), edges lined up
    output reg  [23:0] rgb,
    output reg         hsync,
    output reg         vsync,
    output reg         de
);
    // ================================================================ the mode (section 3.2)
    // 576p50 (CEA-861 format 17/18): 864 x 625 at 27 MHz, both syncs active low
    localparam [10:0] HVIS = 11'd720;
    localparam [10:0] HSS  = 11'd732;       // front porch 12
    localparam [10:0] HSE  = 11'd796;       // sync 64, back porch 68
    localparam [10:0] HTOT = 11'd864;
    localparam [10:0] VVIS = 11'd576;
    localparam [10:0] VSS  = 11'd581;       // front porch 5
    localparam [10:0] VSE  = 11'd586;       // sync 5, back porch 39
    localparam [10:0] VTOT = 11'd625;
    localparam        SPOL = 1'b0;          // 1: active-high sync
    // Beam coordinates (section 3.3): (0, 0) is the start of the horizontal
    // and vertical blanks, so the picture is pixels BH0-863, lines BV0-624.
    // Inside, the counters hc and vc stay picture-relative (0 = the first
    // pixel, the first line).
    localparam [10:0] BH0  = HTOT - HVIS;   // 144
    localparam [10:0] BV0  = VTOT - VVIS;   // 49

    // ================================================================ registers (100 MHz)
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_glob  = in_custom && (off[15:8] == 8'd0);         // 0x000-0x0FF
    wire [8:0] blk = off[15:7];                                // layers: 2, 3, 4
    wire sel_lay   = in_custom && (blk >= 9'd2) && (blk <= 9'd4) && (off[6:5] == 2'b00);
    wire [1:0] ln  = blk[1:0] - 2'd2;
    wire sel_pal   = in_custom && (off[15:12] == 4'h4);        // 0x4000-0x4FFF: PALETTE0-2, SPRPALETTE

    reg  [5:0]  vidcon;                // SHAREPAL (5), DIRECT (4), BLANKALL (2), EN (0)
    reg  [7:0]  vidstat;               // sticky flags; INVBLANK (bit 8) is live, below
    reg  [7:0]  vidinten;
    reg  [10:0] lc_v;                  // LINECMP
    reg  [23:0] bgcolor;
    reg  [5:0]  prio;

    // Layers 0-2: CTRL, window, fine scroll (pointers, modulo and data are in bpldma.v)
    reg  [23:0] l_ctrl [0:2];
    reg  [10:0] l_xs [0:2], l_xe [0:2], l_ys [0:2], l_ye [0:2];
    reg  [3:0]  l_sx [0:2];

    // From the pixel domain
    reg  [10:0] p_hc, p_vc;            // beam position (pixel domain)
    reg  [15:0] p_frames;
    // ... sampled on this side until two samples agree, so a read is never torn
    reg  [37:0] bs1, bs2, bsync;
    always @(posedge clk) begin
        bs1 <= {p_frames, p_vc, p_hc};
        bs2 <= bs1;
        if (bs1 == bs2) bsync <= bs2;
    end
    wire [10:0] s_hc = bsync[10:0], s_vc = bsync[21:11];
    wire [15:0] s_frames = bsync[37:22];
    assign beam_v = s_vc;
    assign beam_h = s_hc;
    reg         p_vb_t, p_line_t;      // toggles: vertical blank started, line compare hit
    wire        p_invblank = (s_vc < BV0);

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    reg  [1:0] vb_s, ln_s, un_s;
    wire [7:0] p_un;                   // sprites' underrun toggles (pixel side)
    reg  [1:0] ov_s [0:2];
    wire [2:0] ov_t;
    wire       fetch_en = vidcon[0] && dmacon[9] && dmacon[8];
    integer    i;
    reg [31:0] reg_q;

    always @(posedge clk) begin
        if (rst) begin
            vidcon   <= 6'd0;
            vidstat  <= 8'd0;
            vidinten <= 8'd0;
            lc_v     <= 11'd0;
            bgcolor  <= 24'd0;
            prio     <= 6'b10_01_00;    // L0 in front, then L1, then L2
            for (i = 0; i < 3; i = i + 1) begin
                l_ctrl[i] <= 24'd0;
                l_xs[i] <= BH0;  l_xe[i] <= HTOT;  l_ys[i] <= BV0;  l_ye[i] <= VTOT;
                l_sx[i] <= 4'd0;
                ov_s[i] <= 2'b00;
            end
            vb_s <= 2'b00; ln_s <= 2'b00;
            dmacon <= 16'd0;
        end else begin
            for (i = 0; i < 3; i = i + 1) begin
                ov_s[i] <= {ov_s[i][0], ov_t[i]};
                if (ov_s[i][1] != ov_s[i][0]) vidstat[4 + i] <= 1'b1;
            end
            // Events from the pixel domain
            vb_s <= {vb_s[0], p_vb_t};
            ln_s <= {ln_s[0], p_line_t};
            if (vb_s[1] != vb_s[0]) vidstat[0] <= 1'b1;
            if (ln_s[1] != ln_s[0]) vidstat[1] <= 1'b1;
            un_s <= {un_s[0], ^p_un};
            if (un_s[1] != un_s[0]) vidstat[7] <= 1'b1;          // SPRUNDER

            if (rb_wr && sel_lay) begin : wlayer
                reg [31:0] v;
                case (off[4:0])
                    5'h00: begin v = merge({8'd0, l_ctrl[ln]}, rb_wdata, rb_be); l_ctrl[ln] <= v[23:0]; end
                    5'h04: begin v = merge({5'd0, l_xs[ln], 5'd0, l_xe[ln]}, rb_wdata, rb_be);
                                 l_xs[ln] <= v[26:16]; l_xe[ln] <= v[10:0]; end
                    5'h08: begin v = merge({5'd0, l_ys[ln], 5'd0, l_ye[ln]}, rb_wdata, rb_be);
                                 l_ys[ln] <= v[26:16]; l_ye[ln] <= v[10:0]; end
                    5'h0C: if (rb_be[0]) l_sx[ln] <= rb_wdata[3:0];
                    default: ;
                endcase
            end
            if (rb_wr && sel_glob) begin : wglobal
                reg [31:0] v;
                case (off)
                    `RM_VIDCON:   begin v = merge({26'd0, vidcon}, rb_wdata, rb_be); vidcon <= {v[5], v[4], 1'b0, v[2], 1'b0, v[0]}; end
                    `RM_VIDSTAT:  if (rb_be[0]) vidstat <= vidstat & ~rb_wdata[7:0];
                    `RM_VIDINTEN: begin v = merge({24'd0, vidinten}, rb_wdata, rb_be); vidinten <= v[7:0] & 8'hF3; end
                    `RM_LINECMP:  begin v = merge({5'd0, lc_v, 16'd0}, rb_wdata, rb_be); lc_v <= v[26:16]; end
                    `RM_BGCOLOR:  begin v = merge({8'd0, bgcolor}, rb_wdata, rb_be); bgcolor <= v[23:0]; end
                    `RM_PRIO:     begin v = merge({26'd0, prio}, rb_wdata, rb_be); prio <= v[5:0]; end
                    `RM_DMACON:   if (rb_be[1:0] == 2'b11) begin              // set/clear (spec 3, rule 6)
                        if (rb_wdata[15]) dmacon <= dmacon | (rb_wdata[14:0] & 15'h03EF);
                        else              dmacon <= dmacon & ~(rb_wdata[14:0] & 15'h03EF);
                    end
                    default: ;
                endcase
            end
        end

        reg_q <= 32'd0;
        if (rb_rd && sel_lay) case (off[4:0])
            5'h00: reg_q <= {8'd0, l_ctrl[ln]};
            5'h04: reg_q <= {5'd0, l_xs[ln], 5'd0, l_xe[ln]};
            5'h08: reg_q <= {5'd0, l_ys[ln], 5'd0, l_ye[ln]};
            5'h0C: reg_q <= {28'd0, l_sx[ln]};
            default: ;
        endcase
        if (rb_rd && sel_glob) case (off)
            `RM_VIDCON:     reg_q <= {26'd0, vidcon};
            `RM_VIDSTAT:    reg_q <= {23'd0, p_invblank, vidstat};
            `RM_VIDINTEN:   reg_q <= {24'd0, vidinten};
            `RM_BEAMPOS:    reg_q <= {5'd0, s_vc, 5'd0, s_hc};
            `RM_FRAMECOUNT: reg_q <= {16'd0, s_frames};
            `RM_LINECMP:    reg_q <= {5'd0, lc_v, 16'd0};
            `RM_BGCOLOR:    reg_q <= {8'd0, bgcolor};
            `RM_PRIO:       reg_q <= {26'd0, prio};
            `RM_VIDSIZE:    reg_q <= {5'd0, VVIS, 5'd0, HVIS};
            `RM_DMACON:     reg_q <= {16'd0, dmacon};
            default: ;
        endcase
    end

    reg         line_t;
    wire [31:0] spr_q;
    reg  [2:0] lt_s;
    always @(posedge clk) lt_s <= {lt_s[1:0], line_t};
    assign line_tick  = lt_s[2] != lt_s[1];
    assign frame_tick = vb_s[1] != vb_s[0];

    wire [7:0] irqflags = vidstat & vidinten;
    assign irq_vblank = irqflags[0];
    assign irq_line   = irqflags[1];
    assign irq_viderr = |irqflags[7:4];

    // ================================================================ palettes
    // PALETTE0-2 (L0-L2) and SPRPALETTE (section 6.3): one RAM of 1024 x 24,
    // addressed by {palette, index}. Kept twice, written together from the
    // CPU side (100 MHz, with byte enables; bits 31-24 are not stored): one
    // copy is read back by the CPU, the other by the pixel side. Simple
    // one-write, one-read block RAMs map the same way in every tool.
    reg [23:0] pal [0:1023], pal_c [0:1023];     // RRGGBB
    integer k;
    initial for (k = 0; k < 1024; k = k + 1) begin pal[k] = 24'd0; pal_c[k] = 24'd0; end

    wire [9:0] pal_a = rb_addr[11:2];
    reg [23:0] pal_qa;

    // A colour changes all at once (spec 3, section 2): a write to an
    // entry's high half (red) alone is held, one for each writer, until
    // that writer's next write to the same entry's low half, which writes
    // red with green and blue. A write to both halves at once (or a low
    // half alone, keeping red) goes in as it is.
    reg        hv [0:2];               // a high half is held ...
    reg  [9:0] ha [0:2];               // ... for this entry
    reg  [7:0] hr [0:2];               // ... red
    wire       w_hi  = rb_wr && sel_pal && rb_be[3:2] != 2'b00 && rb_be[1:0] == 2'b00;
    wire       w_lo  = rb_wr && sel_pal && rb_be[1:0] != 2'b00;
    wire       h_hit = (rb_who != 2'd3) && hv[rb_who] && ha[rb_who] == pal_a;
    wire       w_r   = w_lo && (rb_be[2] || h_hit);                  // red is written
    wire [7:0] w_rv  = rb_be[2] ? rb_wdata[23:16] : hr[rb_who];
    initial begin hv[0] = 1'b0; hv[1] = 1'b0; hv[2] = 1'b0; end
    always @(posedge clk) begin
        if (rst) begin
            hv[0] <= 1'b0; hv[1] <= 1'b0; hv[2] <= 1'b0;
        end else if (rb_who != 2'd3) begin
            if (w_hi) begin
                hv[rb_who] <= rb_be[2];
                ha[rb_who] <= pal_a;
                hr[rb_who] <= rb_wdata[23:16];
            end else if (w_lo && h_hit)
                hv[rb_who] <= 1'b0;
        end
    end
    always @(posedge clk) if (w_lo) begin
        if (w_r)       pal[pal_a][23:16] <= w_rv;
        if (rb_be[1])  pal[pal_a][15:8]  <= rb_wdata[15:8];
        if (rb_be[0])  pal[pal_a][7:0]   <= rb_wdata[7:0];
    end
    always @(posedge clk) begin
        if (w_lo) begin
            if (w_r)      pal_c[pal_a][23:16] <= w_rv;
            if (rb_be[1]) pal_c[pal_a][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) pal_c[pal_a][7:0]   <= rb_wdata[7:0];
        end
        pal_qa <= pal_c[pal_a];
    end
    reg pal_hit;
    always @(posedge clk) pal_hit <= rb_rd && sel_pal;

    wire [31:0] dma_q;
    assign rb_rdata = reg_q | dma_q | spr_q | (pal_hit ? {8'd0, pal_qa} : 32'd0);

    // ================================================================ pixel domain
    reg [1:0] rst_p;
    always @(posedge clk_pix) rst_p <= {rst_p[0], rst};
    wire prst = rst_p[1];

    reg en_p;
    reg [1:0] en_s;
    always @(posedge clk_pix) begin
        en_s <= {en_s[0], vidcon[0]};
        en_p <= !prst && en_s[1];
    end

    // ---- beam
    reg [10:0] hc, vc;
    wire hlast = (hc == HTOT - 1'b1);
    wire vlast = (vc == VTOT - 1'b1);
    wire [10:0] hn = hlast ? 11'd0 : hc + 1'b1;
    wire [10:0] vn = hlast ? (vlast ? 11'd0 : vc + 1'b1) : vc;
    // The beam in beam coordinates: a beam line starts with its horizontal blank
    wire        inhb = (hc >= HVIS);
    wire [10:0] bh = inhb ? hc - HVIS : hc + BH0;
    wire [10:0] bv = inhb ? ((vc >= VVIS - 1'b1) ? vc - (VVIS - 1'b1) : vc + BV0 + 1'b1)
                          : ((vc >= VVIS) ? vc - VVIS : vc + BV0);

    reg [5:0]  prio_l;                 // PRIO and BGCOLOR, taken at the start of each line (section 5.4)
    reg [23:0] bg_l;
    always @(posedge clk_pix) begin
        if (!en_p) begin
            hc <= 11'd0;
            vc <= 11'd0;
        end else begin
            hc <= hn;
            vc <= vn;
            if (hn == 11'd0) begin
                prio_l <= prio;
                bg_l   <= bgcolor;
            end
        end
        p_hc <= bh;
        p_vc <= bv;
        if (prst) begin
            p_vb_t   <= 1'b0;
            p_line_t <= 1'b0;
            p_frames <= 16'd0;
        end else if (en_p) begin
            if (bh == 11'd0 && bv == 11'd0) begin   // the frame starts: (0, 0)
                p_vb_t   <= ~p_vb_t;
                p_frames <= p_frames + 1'b1;
            end
            if (bh == 11'd0 && bv == lc_v) p_line_t <= ~p_line_t;
        end
    end

    // ---- settings for the next line, worked out in the horizontal blank
    // (clocks HVIS to HVIS + 2), then handed to the DMA and the layer units
    wire [10:0] next_line = vlast ? 11'd0 : vc + 1'b1;
    // The windows (in beam coordinates) on the picture: clamped to it, then picture-relative
    function [10:0] tox(input [10:0] v);
        tox = (v < BH0) ? 11'd0 : (v > HTOT) ? HVIS : v - BH0;
    endfunction
    function [10:0] toy(input [10:0] v);
        toy = (v < BV0) ? 11'd0 : (v > VTOT) ? VVIS : v - BV0;
    endfunction
    wire [10:0] w_xs [0:2], w_xe [0:2], w_ys [0:2], w_ye [0:2];
    genvar gw;
    generate for (gw = 0; gw < 3; gw = gw + 1) begin : wins
        assign w_xs[gw] = tox(l_xs[gw]);
        assign w_xe[gw] = (tox(l_xe[gw]) < tox(l_xs[gw])) ? tox(l_xs[gw]) : tox(l_xe[gw]);
        assign w_ys[gw] = toy(l_ys[gw]);
        assign w_ye[gw] = toy(l_ye[gw]);
    end endgenerate
    reg  [2:0]  b_vsub [0:2];          // screen lines shown of this source line
    reg  [2:0]  b_act, b_adv;
    reg  [3:0]  n_pos0 [0:2];
    reg  [11:0] n_groups [0:2];
    reg  [2:0]  f_act, f_adv, f_chunky;
    reg  [11:0] f_groups [0:2];
    reg  [2:0]  f_planes [0:2];
    reg  [1:0]  f_hs [0:2];
    // This line's settings, for the layer units
    reg  [2:0]  c_act, c_planar, c_transp;
    reg  [10:0] c_xs [0:2], c_xe [0:2];
    reg  [1:0]  c_lb [0:2], c_hs [0:2];
    reg  [2:0]  c_planes [0:2];
    reg  [3:0]  c_pos0 [0:2], c_palofs [0:2];

    always @(posedge clk_pix) begin : setup
        integer n;
        reg [2:0]  vmax, vs_n;
        reg [10:0] w, srcpix;
        reg [3:0]  fine;
        if (prst) begin
            line_t <= 1'b0;
            c_act  <= 3'd0;
            f_act  <= 3'd0;
            f_adv  <= 3'd0;
            for (n = 0; n < 3; n = n + 1) b_vsub[n] <= 3'd0;
        end else if (hc == HVIS || !en_p) begin
            // 1: which layers show on the next line, and whether their pointers move on after it
            for (n = 0; n < 3; n = n + 1) begin
                vmax = 3'd7 >> (2'd3 - l_ctrl[n][9:8]);
                vs_n = (next_line == w_ys[n] || b_vsub[n] == vmax) ? 3'd0 : b_vsub[n] + 1'b1;
                b_act[n] <= en_p && l_ctrl[n][0] && next_line < VVIS &&
                            next_line >= w_ys[n] && next_line < w_ye[n];
                b_adv[n] <= (vs_n == vmax);
                if (next_line >= w_ys[n] && next_line < w_ye[n]) b_vsub[n] <= vs_n;
            end
        end else if (hc == HVIS + 1'b1) begin
            // 2: first pixel, groups to fetch
            for (n = 0; n < 3; n = n + 1) begin
                w      = w_xe[n] - w_xs[n];
                srcpix = (w + (3'd7 >> (2'd3 - l_ctrl[n][7:6]))) >> l_ctrl[n][7:6];
                // a group is 16 source pixels in either format
                fine = l_sx[n];
                n_pos0[n]   <= fine;
                /* verilator lint_off WIDTHTRUNC */ n_groups[n] <= ({10'd0, fine} + {3'd0, srcpix} + 14'd15) >> 4; /* verilator lint_on WIDTHTRUNC */
            end
        end else if (hc == HVIS + 2'd2) begin
            // 3: hand over
            f_act  <= b_act;
            f_adv  <= b_adv;
            line_t <= ~line_t;
            c_act  <= b_act;
            for (n = 0; n < 3; n = n + 1) begin
                f_groups[n] <= n_groups[n];
                f_planes[n] <= l_ctrl[n][1] ? l_ctrl[n][18:16] : (3'd1 << l_ctrl[n][3:2]) - 1'b1;
                f_chunky[n] <= !l_ctrl[n][1];
                f_hs[n]     <= l_ctrl[n][7:6];
                c_xs[n]     <= w_xs[n];
                c_xe[n]     <= w_xe[n];
                c_planar[n] <= l_ctrl[n][1];
                c_lb[n]     <= l_ctrl[n][3:2];
                c_transp[n] <= l_ctrl[n][4];
                c_hs[n]     <= l_ctrl[n][7:6];
                c_palofs[n] <= l_ctrl[n][15:12];
                c_planes[n] <= l_ctrl[n][18:16];
                c_pos0[n]   <= n_pos0[n];
            end
        end
    end

    // ---- bitplane DMA and registers (100 MHz)
    wire [383:0] dat;
    wire [2:0]   fill_t, take_t;
    wire         line_go, line_gen;
    bpldma dma (
        .clk(clk), .rst(rst), .enable(fetch_en),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(dma_q),
        .line_t(line_t), .act(f_act), .adv(f_adv),
        .planes({f_planes[2], f_planes[1], f_planes[0]}), .chunky(f_chunky), .hscale({f_hs[2], f_hs[1], f_hs[0]}),
        .wrap({l_ctrl[2][23:20], l_ctrl[1][23:20], l_ctrl[0][23:20]}),
        .ngroups({f_groups[2], f_groups[1], f_groups[0]}),
        .line_go(line_go), .line_gen(line_gen),
        .dat(dat), .fill_t(fill_t), .take_t(take_t),
        .req(disp_req), .urgent(disp_urgent), .deadline(disp_deadline), .addr(disp_addr), .ack(disp_ack), .rvalid(disp_rvalid), .rdata(disp_rdata)
    );

    // ---- sprites (spec 9): the fetcher and FIFOs (100 MHz), and a unit per sprite
    wire [79:0] sp_hs, sp_xe;
    wire [7:0]  sp_act;
    wire [15:0] sp_lb, sp_depth;
    wire [127:0] sp_xstep;
    wire [7:0]  sp_dma;
    wire [31:0] sp_pal;
    wire [39:0] sp_ra;
    wire [127:0] sp_rd;
    wire [47:0] sp_wpg, sp_rpg;
    wire [7:0]  sp_fl, sp_fla;
    reg  [31:0] coll_acc, coll_line;
    reg         coll_t;
    sprites spr (
        .clk(clk), .rst(rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be), .rb_rdata(spr_q),
        .dmacon(dmacon), .vblank(frame_tick), .beam_v(s_vc), .beam_h(s_hc),
        .mem_req(spr_req), .mem_addr(spr_addr), .mem_deadline(spr_deadline), .mem_urgent(spr_urgent),
        .mem_ack(spr_ack), .mem_rvalid(spr_rvalid), .mem_rdata(disp_rdata),
        .p_hs(sp_hs), .p_xe(sp_xe), .p_act(sp_act), .p_lb(sp_lb),
        .p_xstep(sp_xstep), .p_depth(sp_depth), .p_pal(sp_pal), .p_dma(sp_dma),
        .fifo_ra(sp_ra), .fifo_rd(sp_rd), .wp_g(sp_wpg), .rp_g(sp_rpg), .flush_t(sp_fl), .flush_ack_t(sp_fla),
        .coll_line(coll_line), .coll_t(coll_t)
    );

    // A sprite's line is a beam line: from the start of its horizontal blank
    // (beam pixel 0); its settings are taken at beam pixel 12, after the
    // sprite side's line-start pass (so HSTART must be 16 or more)
    reg  [7:0]  c_sact, c_sdma;
    reg  [9:0]  c_shs [0:7], c_sxe [0:7];
    reg  [1:0]  c_slb [0:7], c_sdep [0:7];
    reg  [15:0] c_sxs [0:7];
    reg  [3:0]  c_spal [0:7];
    always @(posedge clk_pix) if (hc == HVIS + 11'd12 || !en_p) begin : sset
        integer n;
        for (n = 0; n < 8; n = n + 1) begin
            c_sact[n]  <= en_p && sp_act[n];
            c_shs[n]   <= sp_hs[10*n +: 10];
            c_sxe[n]   <= sp_xe[10*n +: 10];
            c_slb[n]   <= sp_lb[2*n +: 2];
            c_sxs[n]   <= sp_xstep[16*n +: 16];
            c_sdep[n]  <= sp_depth[2*n +: 2];
            c_spal[n]  <= sp_pal[4*n +: 4];
            c_sdma[n]  <= sp_dma[n];
        end
    end

    wire [9:0]  st_now = bh[9:0];
    wire [7:0]  s_op;
    wire [7:0]  s_idx [0:7];
    genvar sg;
    generate for (sg = 0; sg < 8; sg = sg + 1) begin : sprs
        wire [5:0] rpb;
        assign sp_ra[5*sg +: 5] = rpb[4:0];
        sprite_pix u (
            .clk_pix(clk_pix), .en(en_p), .t(st_now),
            .act(c_sact[sg]), .hs(c_shs[sg]), .xe(c_sxe[sg]), .lb(c_slb[sg]),
            .xstep(c_sxs[sg]), .pal(c_spal[sg]), .dma(c_sdma[sg]),
            .head(sp_rd[16*sg +: 16]), .rp(rpb), .rp_g(sp_rpg[6*sg +: 6]), .wp_g(sp_wpg[6*sg +: 6]),
            .flush_t(sp_fl[sg]), .flush_ack_t(sp_fla[sg]),
            .opaque(s_op[sg]), .idx(s_idx[sg]), .underrun_t(p_un[sg])
        );
    end endgenerate

    // ---- layer units: their output is stage 1
    wire [2:0] bl_op;
    wire [7:0] bl_idx [0:2], bl_raw [0:2];
    // The layer units may take this line's first group once the DMA has
    // restarted (line_gen caught up) and the handshake has crossed back
    reg  [1:0] lg_s;
    always @(posedge clk_pix) lg_s <= {lg_s[0], line_gen};
    wire       buf_ready = (lg_s[1] == line_t) && (hc >= HVIS + 4'd8 || hc < HVIS);
    genvar g;
    generate for (g = 0; g < 3; g = g + 1) begin : lay
        layer_pix #(.PLANAR(1), .TILES(0)) u (
            .clk_pix(clk_pix), .clk_pix5(clk_pix5), .en(en_p), .hc(hc), .hn(hn), .line_start(hc == HVIS), .ready(buf_ready),
            .active(c_act[g]), .xs(c_xs[g]), .xe(c_xe[g]), .planar(c_planar[g]), .lb(c_lb[g]),
            .planes(c_planes[g]), .hs(c_hs[g]), .pos0(c_pos0[g]), .transp(c_transp[g]),
            .palofs(c_palofs[g]), .tile(1'b0),
            .dat(dat[128*g +: 128]), .attr(10'd0), .fill_t(fill_t[g]), .take_t(take_t[g]),
            .opaque(bl_op[g]), .idx(bl_idx[g]), .raw(bl_raw[g]), .pri(), .overrun_t(ov_t[g])
        );
    end endgenerate

    // ---- pipeline: 0 beam, 1 layer pixels, 2 priority, 3 palette read, 4 out
    wire       vis0 = en_p && (hc < HVIS) && (vc < VVIS);
    wire       hs0  = en_p && (hc >= HSS) && (hc < HSE);
    wire       vs0  = en_p && (vc >= VSS) && (vc < VSE);
    reg  [2:0] vis_d, hs_d, vs_d;
    reg  [9:0] pidx2;                  // {palette, index}: 0-2 a layer's, 3 the sprites'
    reg        opaque2, opaque3;
    reg [23:0] pal_q3;
    reg [23:0] dc3;                    // direct colour (section 4.9)
    reg        direct2, direct3;

    // Direct colour: each layer gives one channel (L0 red, L1 green, L2 blue),
    // as deep as the layer, widened to 8 bits by repeating its bits
    function [7:0] widen(input [7:0] v, input [3:0] d);
        integer k;
        reg [7:0] top;
        begin
            top   = v << (4'd8 - d);
            widen = top;
            for (k = 1; k < 8; k = k + 1)
                if (k * d < 8) widen = widen | (top >> (k * d));
        end
    endfunction
    wire [3:0] depth [0:2];
    reg  [7:0] ch2 [0:2];
    generate for (g = 0; g < 3; g = g + 1) begin : dep
        assign depth[g] = c_planar[g] ? {1'b0, c_planes[g]} + 4'd1 : 4'd1 << c_lb[g];
    end endgenerate

    // Collisions (spec 9, section 6): gathered over a line, handed to the
    // 100 MHz side at the end of it
    always @(posedge clk_pix) begin : collide
        integer n, k;
        reg [3:0] c;
        reg [31:0] h;
        c = 4'd0;
        for (n = 0; n < 8; n = n + 1) c = c + s_op[n];
        h = 32'd0;
        if (c > 4'd1) h[7:0] = s_op;
        for (k = 0; k < 3; k = k + 1) if (bl_op[k]) h[8*(k+1) +: 8] = s_op;
        if (!vis_d[0]) h = 32'd0;                // on the picture only
        if (!en_p) begin
            coll_acc <= 32'd0;
            coll_t   <= 1'b0;
        end else if (hc == HVIS + 11'd8) begin
            coll_line <= coll_acc | h;
            coll_acc  <= 32'd0;
            coll_t    <= ~coll_t;
        end else
            coll_acc <= coll_acc | h;
    end

    always @(posedge clk_pix) begin
        vis_d <= {vis_d[1:0], vis0};
        hs_d  <= {hs_d[1:0], hs0};
        vs_d  <= {vs_d[1:0], vs0};
        // 2: the front-most opaque layer or sprite (section 4.8; spec 9, 3.3).
        // From the front: sprites of DEPTH 0, the front layer, DEPTH 1, the
        // middle layer, DEPTH 2, the back layer, DEPTH 3. PRIO value 3 names
        // no layer. Among sprites, the lower number is in front. The winner's
        // palette goes with its index: the layer's own, or SPRPALETTE (3);
        // with VIDCON.SHAREPAL, PALETTE0 for all (section 4.6).
        begin : pix
            integer p, n;
            reg       any, sany;
            reg [7:0] fix, sfix;
            reg [1:0] l, fpal;
            any = 1'b0;
            fix = 8'd0;
            fpal = 2'd0;
            for (p = 3; p >= 0; p = p - 1) begin
                // sprites of DEPTH p (behind layer p - 1 in PRIO order)
                for (n = 7; n >= 0; n = n - 1)
                    if (s_op[n] && c_sdep[n] == p) begin any = 1'b1; fix = s_idx[n]; fpal = 2'd3; end
                if (p > 0) begin
                    l = prio_l[2*(p-1) +: 2];
                    if (l != 2'd3 && bl_op[l]) begin any = 1'b1; fix = bl_idx[l]; fpal = l; end
                end
            end
            // the front-most sprite, for direct colour
            sany = 1'b0;
            sfix = 8'd0;
            for (n = 7; n >= 0; n = n - 1)
                if (s_op[n]) begin sany = 1'b1; sfix = s_idx[n]; end
            opaque2 <= any;
            if (vidcon[5])      pidx2 <= {2'd0, vidcon[4] ? sfix : fix};
            else if (vidcon[4]) pidx2 <= {2'd3, sfix};
            else                pidx2 <= {fpal, fix};
            // Direct colour: on every visible pixel; a layer not showing gives
            // 0; sprites are in front, in palette colours
            direct2 <= vidcon[4] && !sany;
            if (vidcon[4]) opaque2 <= 1'b1;
            for (p = 0; p < 3; p = p + 1) ch2[p] <= widen(bl_raw[p], depth[p]);
        end
        // 3
        pal_q3  <= pal[pidx2];
        opaque3 <= opaque2 && !vidcon[2];
        dc3     <= {ch2[0], ch2[1], ch2[2]};
        direct3 <= direct2;
        // 4: out
        de    <= vis_d[2];
        hsync <= hs_d[2] ^ !SPOL;
        vsync <= vs_d[2] ^ !SPOL;
        rgb   <= !vis_d[2] ? 24'd0 : !opaque3 ? bg_l : direct3 ? dc3 : pal_q3;
    end
endmodule
