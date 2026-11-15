// retro68k on the ZX Spectrum Next KS3 (issue 5): pins to the computer.
// Pin names follow the Next's own zxnext_top_issue5.vhd and
// zxnext_pins_issue5.xdc (fpga/ks3/ks3.xdc has the locations).
//
// Not used yet (held at safe levels): SD card, PS/2, Spectrum keyboard,
// joysticks, I2C, audio. The FT232H USB module sits on the accelerator
// port (provisional pins, spec 14 open point U6):
//   accel_io[7:0] D7-D0, [8] RXF#, [9] TXE#, [10] RD#, [11] WR#, [12] SIWU#
module top_ks3 (
    input  wire        clock_50_i,

    // SRAM
    output wire [20:0] ram_addr_o,
    inout  wire [15:0] ram_data_io,
    output wire        ram_lb_n_o, ram_ub_n_o, ram_oe_n_o, ram_we_n_o, ram_cs_n_o,

    // Video
    output wire [3:0]  rgb_r_o, rgb_g_o, rgb_b_o,
    output wire        hsync_o, vsync_o, vgaclk_o, vgaclkn_o,
    output wire [3:0]  hdmi_p_o, hdmi_n_o,

    // Buttons
    input  wire        btn_reset_n_i, btn_multiface_n_i, btn_divmmc_n_i,

    // Accelerator port (FT232H)
    inout  wire [27:0] accel_io,

    // SD card (SPI mode) and PS/2 keyboard (open collector, pulled up)
    output wire        sd_cs0_n_o, sd_cs1_n_o, sd_sclk_o, sd_mosi_o,
    input  wire        sd_miso_i,
    inout  wire        ps2_clk_io, ps2_data_io,

    // Held at safe levels for now
    output wire        flash_cs_n_o,
    output wire        audioext_l_o, audioext_r_o, audioint_o,
    output wire        joysel_o
);
    // ---------------------------------------------------------------- clocks and reset
    wire clk100, clk40, clk_pix, clk_pix5, clk_pixd, locked, por;
    ks3_clocks clocks (
        .clk50(clock_50_i), .clk100(clk100), .clk40(clk40),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .clk_pixd(clk_pixd), .locked(locked)
    );
    por_align pa (.clk100(clk100), .clk40(clk40), .locked(locked), .por(por));

    // Buttons: synchronise, then 2^20 clocks (10 ms) of agreement
    reg  [2:0]  btn_s0, btn_s1, btn_q = 3'b000;     // 1 = pressed: reset, multiface, divmmc
    reg  [19:0] btn_t;
    wire [2:0]  btn_raw = {!btn_divmmc_n_i, !btn_multiface_n_i, !btn_reset_n_i};
    always @(posedge clk100) begin
        btn_s0 <= btn_raw;
        btn_s1 <= btn_s0;
        if (btn_s1 == btn_q) btn_t <= 20'd0;
        else if (&btn_t) begin btn_q <= btn_s1; btn_t <= 20'd0; end
        else btn_t <= btn_t + 1'b1;
    end

    // ---------------------------------------------------------------- the computer
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o, dq_i;
    wire [7:0]  ft_d_i, ft_d_o;
    wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [23:0] rgb;
    wire        hs, vs, de, dvi;
    wire [15:0] snd_l, snd_r;
    wire        snd_v;

    retro68k #(.ROM_INIT("boot.hex")) sys (
        .clk100(clk100), .clk40(clk40), .clk_pix(clk_pix), .clk_pix5(clk_pix5),
        .por100(por), .por40(por),
        .btn_reset_n(!btn_q[0]), .buttons(btn_q[2:1]),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq_i),
        .ft_rxf_n(accel_io[8]), .ft_txe_n(accel_io[9]), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .dma_req(1'b0), .dma_we(1'b0), .dma_addr(21'd0), .dma_wdata(16'd0), .dma_be(2'b00),
        .dma_ack(), .dma_rvalid(), .dma_rdata(),
        .vid_rgb(rgb), .vid_hsync(hs), .vid_vsync(vs), .vid_de(de), .vid_dvi(dvi),
        .snd_l(snd_l), .snd_r(snd_r), .snd_v(snd_v),
        .aud_l(audioext_l_o), .aud_r(audioext_r_o), .aud_m(audioint_o),
        .sd_sclk(sd_sclk_o), .sd_mosi(sd_mosi_o), .sd_cs0_n(sd_cs0_n_o), .sd_cs1_n(sd_cs1_n_o), .sd_miso(sd_miso_i),
        .ps2_clk_i(ps2_clk_io), .ps2_data_i(ps2_data_io), .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .dbg_sc(), .dbg_halted()
    );

    // ---------------------------------------------------------------- SRAM pads
    // Output flip-flops in the pads (IOB), DDR registers for /OE, /WE and the
    // data bus enable; read data is taken by sram_ctl's rdata register, which
    // goes in the input pads (spec 5, section 4.2).
    (* IOB = "TRUE" *) reg [20:0] pad_a;
    (* IOB = "TRUE" *) reg        pce_n = 1'b1, pub_n = 1'b1, plb_n = 1'b1;
    (* IOB = "TRUE" *) reg [15:0] pdq;
    always @(posedge clk100) begin
        pad_a <= a;
        pce_n <= ce_n;
        pub_n <= ub_n;
        plb_n <= lb_n;
        pdq   <= dq_o;
    end
    assign ram_addr_o = pad_a;
    assign ram_cs_n_o = pce_n;
    assign ram_ub_n_o = pub_n;
    assign ram_lb_n_o = plb_n;

    oddr #(.INIT(1'b1)) o_oe (.clk(clk100), .d_r(oe_r), .d_f(oe_f), .q(ram_oe_n_o));
    oddr #(.INIT(1'b1)) o_we (.clk(clk100), .d_r(we_r), .d_f(we_f), .q(ram_we_n_o));

    genvar i;
    generate for (i = 0; i < 16; i = i + 1) begin : dq
        wire t;
        oddr #(.INIT(1'b1)) o_t (.clk(clk100), .d_r(t_r), .d_f(t_f), .q(t));
        IOBUF io (.IO(ram_data_io[i]), .I(pdq[i]), .O(dq_i[i]), .T(t));
    end endgenerate

    // ---------------------------------------------------------------- FT232H
    generate for (i = 0; i < 8; i = i + 1) begin : ftd
        IOBUF io (.IO(accel_io[i]), .I(ft_d_o[i]), .O(ft_d_i[i]), .T(!ft_d_oe));
    end endgenerate
    assign accel_io[10] = ft_rd_n;
    assign accel_io[11] = ft_wr_n;
    assign accel_io[12] = ft_siwu_n;
    assign accel_io[8]  = 1'bz;          // RXF#, TXE#: inputs (pulled up when no module)
    assign accel_io[9]  = 1'bz;
    assign accel_io[27:13] = 15'bz;

    // ---------------------------------------------------------------- video out
    reg [2:0] prst = 3'b111;
    always @(posedge clk_pix) prst <= {prst[1:0], por};
    // HDMI with the mixer's sound (retro-hw hdmi_packets); VIDCON.DVI sends plain DVI
    hdmi_out #(.AUDIO(1), .VIC(17)) hdmi (
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rst(prst[2]),
        .rgb(rgb), .hsync(hs), .vsync(vs), .de(de),
        .hdmi_on(!dvi), .clk(clk100), .aud_l(snd_l), .aud_r(snd_r), .aud_v(snd_v),
        .tmds_p(hdmi_p_o), .tmds_n(hdmi_n_o)
    );
    vga_out vga (
        .clk_pix(clk_pix), .clk_pixd(clk_pixd), .rgb(rgb), .hsync(hs), .vsync(vs),
        .r(rgb_r_o), .g(rgb_g_o), .b(rgb_b_o), .hs(hsync_o), .vs(vsync_o),
        .vgaclk(vgaclk_o), .vgaclkn(vgaclkn_o)
    );

    // ---------------------------------------------------------------- PS/2: pull low, or let go
    wire ps2_clk_low, ps2_data_low;
    assign ps2_clk_io  = ps2_clk_low  ? 1'b0 : 1'bz;
    assign ps2_data_io = ps2_data_low ? 1'b0 : 1'bz;

    // ---------------------------------------------------------------- not used yet
    assign flash_cs_n_o = 1'b1;          // keep the configuration flash deselected
    assign joysel_o     = 1'b0;
endmodule
