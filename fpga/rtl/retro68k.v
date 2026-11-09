// retro68k: the computer, without board-specific parts (clocks, pads).
//
// Version 1 (phase 2): fx68k, bus interface, SRAM controller, boot ROM,
// system registers and USB serial. One DMA port stands in for the DMA users
// still to come, so tests can load the memory while the CPU runs.
module retro68k #(
    parameter ROM_INIT = "boot.hex",
    parameter [5:0] CHIPMB = 6'd4
) (
    input  wire        clk100,
    input  wire        clk40,
    input  wire        clk_pix,       // 27 MHz pixel clock (576p), asynchronous to clk100
    input  wire        clk_pix5,      // 135 MHz, 5 x clk_pix with edges lined up (same MMCM)
    input  wire        por100,        // power-on reset; last seen high on a slot boundary
    input  wire        por40,         // the same, in the 40 MHz domain
    input  wire        btn_reset_n,   // debounced
    input  wire [1:0]  buttons,       // MULTIFACE (0), DIVMMC (1), 1 = pressed

    // SRAM (before the DDR output registers)
    output wire [20:0] sram_a,
    output wire        sram_ce_n, sram_ub_n, sram_lb_n,
    output wire        sram_oe_n_r, sram_oe_n_f,
    output wire        sram_we_n_r, sram_we_n_f,
    output wire [15:0] sram_dq_o,
    output wire        sram_dq_t_r, sram_dq_t_f,
    input  wire [15:0] sram_dq_i,

    // FT232H
    input  wire        ft_rxf_n, ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output wire [7:0]  ft_d_o,
    output wire        ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n,

    // DMA port (tests; later the DMA users)
    input  wire        dma_req, dma_we,
    input  wire [21:1] dma_addr,
    input  wire [15:0] dma_wdata,
    input  wire [1:0]  dma_be,
    output wire        dma_ack, dma_rvalid,
    output wire [15:0] dma_rdata,

    // Video out (pixel clock domain)
    output wire [23:0] vid_rgb,
    output wire        vid_hsync, vid_vsync, vid_de,

    // Audio: sigma-delta streams (the jack's left and right, the speaker)
    output wire        aud_l, aud_r, aud_m,

    // SD card (spec 15) and PS/2 keyboard (spec 16)
    output wire        sd_sclk, sd_mosi, sd_cs0_n, sd_cs1_n,
    input  wire        sd_miso,
    input  wire        ps2_clk_i, ps2_data_i,
    output wire        ps2_clk_low, ps2_data_low,

    // Debug
    output wire [3:0]  dbg_sc,
    output wire        dbg_halted
);
    // ---------------------------------------------------------------- timebase
    wire [2:0] ph;
    wire [3:0] sc;
    timebase tb0 (.clk(clk100), .rst(por100), .ph(ph), .sc(sc));
    assign dbg_sc = sc;

    reg [6:0] us_div;
    wire      us_tick = (us_div == 7'd99);
    always @(posedge clk100) us_div <= (por100 || us_tick) ? 7'd0 : us_div + 1'b1;

    // ---------------------------------------------------------------- reset (spec 7, section 2)
    wire soft_reset, cmd_break, cmd_reset, cmd_upload, haltreset;
    wire c_halted_n;
    reg  [1:0] btn_s;
    always @(posedge clk100) btn_s <= {btn_s[0], btn_reset_n};

    wire halted   = !c_halted_n;
    wire wd_reset;
    wire rst_req  = !btn_s[1] || soft_reset || cmd_reset || cmd_upload || (halted && haltreset) || wd_reset;
    reg  [8:0] rst_cnt;
    // It resets nearly everything: Vivado copies it, so each copy drives
    // few enough loads to meet timing
    (* max_fanout = 50 *) reg sys_rst;
    reg        cold;                // power-on: fx68k's pwrUp
    reg  [7:0] resetwhy;

    always @(posedge clk100) begin
        if (por100) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            cold     <= 1'b1;
            resetwhy <= 8'h01;       // POWER
        end else if (rst_req && !sys_rst) begin
            rst_cnt  <= 9'd0;
            sys_rst  <= 1'b1;
            resetwhy <= {halted && haltreset, 1'b0, cmd_upload, cmd_reset,   // one bit per source (spec 7, section 2.1)
                         soft_reset, !btn_s[1], wd_reset, 1'b0};
        end else if (sys_rst) begin
            // Hold reset for 5.12 us, and end it on a slot boundary
            if (rst_cnt != 9'd511) rst_cnt <= rst_cnt + 1'b1;
            else if (sc == 4'd9) begin
                sys_rst <= 1'b0;
                cold    <= 1'b0;
            end
        end
    end

    // The device reset (spec 7, section 2.4): every reset, and the 68000's
    // RESET instruction (fx68k drives its reset output low for 124 clocks).
    // It resets the custom hardware, the interrupt controller, the timers
    // (not the watchdog or the time counter), the SD card and keyboard
    // controllers. The CPU, the bus, the system registers (overlay,
    // RESETWHY), the memory scheduler and the USB link keep sys_rst: reads
    // on their way when RESET starts come back while their device is still
    // held in reset, and are ignored.
    wire       c_reset_n;
    reg  [2:0] ri_s;
    (* max_fanout = 50 *) reg dev_rst = 1'b1;
    always @(posedge clk100) begin
        ri_s    <= {ri_s[1:0], !c_reset_n};
        dev_rst <= sys_rst || ri_s[2];
    end

    // fx68k's reset inputs cross like its other inputs (they change at 10 or 30 ns)
    // and so does IPL, from the interrupt controller
    reg cpu_rst = 1'b1, cpu_cold = 1'b1;
    reg [2:0] cpu_ipl_n = 3'b111;
    wire [2:0] int_level;
    always @(posedge clk100) if (ph == 3'd0 || ph == 3'd2) begin
        cpu_rst   <= sys_rst;
        cpu_cold  <= cold;
        cpu_ipl_n <= ~int_level;
    end

    // ---------------------------------------------------------------- CPU
    wire        c_as_n, c_uds_n, c_lds_n, c_rw;
    wire [2:0]  c_fc;
    wire [23:1] c_addr;
    wire [15:0] c_dout;
    wire        dtack_n, berr_n;
    wire [15:0] din;

    cpu_fx68k cpu (
        .clk(clk40), .por(por40), .rst(cpu_rst), .pwrup(cpu_cold),
        .as_n(c_as_n), .uds_n(c_uds_n), .lds_n(c_lds_n), .rw(c_rw),
        .fc(c_fc), .addr(c_addr), .dout(c_dout),
        .reset_out_n(c_reset_n), .halted_n(c_halted_n),
        .dtack_n(dtack_n), .berr_n(berr_n), .ipl_n(cpu_ipl_n), .din(din)
    );
    assign dbg_halted = halted;

    // ---------------------------------------------------------------- bus
    wire        overlay, romwe, protect;
    wire        m_req, m_we, m_ack, m_rvalid;
    wire [21:1] m_addr;
    wire [15:0] m_wdata, mem_rdata;
    wire [1:0]  m_be;
    wire        rom_en;
    wire [1:0]  rom_we;
    wire [14:1] rom_addr;
    wire [15:0] rom_wdata, rom_rdata;
    wire        rom_en_b;
    wire [14:1] rom_addr_b;
    wire [15:0] rom_rdata_b;
    // The register bus: the CPU's accesses (bus_if) and the copper's writes.
    // A CPU access on the bus goes first; the copper's write waits a clock.
    wire        c_rb_rd, c_rb_wr;
    wire [23:2] c_rb_addr;
    wire [31:0] c_rb_wdata;
    wire [3:0]  c_rb_be;
    wire        cw_req;
    wire [23:2] cw_addr;
    wire [31:0] cw_wdata;
    wire [3:0]  cw_be;
    wire        cw_go    = cw_req && !c_rb_rd && !c_rb_wr;
    // ... and the DMA engine's accesses, after the CPU's and the copper's
    wire        dx_req, dx_we;
    wire [23:2] dx_addr;
    wire [31:0] dx_wdata;
    wire [3:0]  dx_be;
    wire        dx_go    = dx_req && !c_rb_rd && !c_rb_wr && !cw_req;
    wire        rb_rd    = c_rb_rd || (dx_go && !dx_we);
    wire        rb_wr    = c_rb_wr || cw_go || (dx_go && dx_we);
    wire [23:2] rb_addr  = cw_go ? cw_addr  : dx_go ? dx_addr  : c_rb_addr;
    wire [31:0] rb_wdata = cw_go ? cw_wdata : dx_go ? dx_wdata : c_rb_wdata;
    wire [3:0]  rb_be    = cw_go ? cw_be    : dx_go ? dx_be    : c_rb_be;
    wire [1:0]  rb_who   = cw_go ? 2'd1 : dx_go ? 2'd2 : 2'd0;          // for the palette's held high halves
    wire [31:0] rd_sys, rd_ser;
    wire        iack;
    wire [2:0]  iack_level;
    wire [7:0]  iack_vector;
    wire [31:0] rd_int, rd_vid, rd_tmr, rd_cop, rd_aud, rd_dmx, rd_sd, rd_kb;
    wire [31:0] rb_rdall = rd_sys | rd_ser | rd_int | rd_vid | rd_tmr | rd_cop | rd_aud | rd_dmx | rd_sd | rd_kb;
    wire        berr_ev;
    wire [23:0] berr_addr;
    wire [3:0]  berr_why;

    bus_if #(.CHIP_TOP({CHIPMB[3:0], 20'd0})) bus (
        .clk(clk100), .rst(sys_rst), .ph(ph),
        .c_as_n(c_as_n), .c_uds_n(c_uds_n), .c_lds_n(c_lds_n), .c_rw(c_rw),
        .c_fc(c_fc), .c_addr(c_addr), .c_dout(c_dout),
        .dtack_n(dtack_n), .berr_n(berr_n), .din(din),
        .overlay(overlay), .romwe(romwe), .protect(protect),
        .m_req(m_req), .m_we(m_we), .m_addr(m_addr), .m_wdata(m_wdata), .m_be(m_be),
        .m_ack(m_ack), .m_rvalid(m_rvalid), .m_rdata(mem_rdata),
        .rom_en(rom_en), .rom_we(rom_we), .rom_addr(rom_addr), .rom_wdata(rom_wdata),
        .rom_rdata(rom_rdata),
        .rb_rd(c_rb_rd), .rb_wr(c_rb_wr), .rb_addr(c_rb_addr), .rb_wdata(c_rb_wdata), .rb_be(c_rb_be),
        .rb_rdata(rb_rdall),
        .iack(iack), .iack_level(iack_level), .iack_vector(iack_vector),
        .berr_ev(berr_ev), .berr_addr(berr_addr), .berr_why(berr_why)
    );

    // ---------------------------------------------------------------- memory
    wire        disp_req, disp_urgent, disp_ack, disp_rvalid;
    wire        spr_req, spr_urgent, spr_ack, spr_rvalid;
    wire [21:1] spr_addr;
    wire [21:1] disp_addr;
    wire        aud_req, aud_ack, aud_rvalid;
    wire [21:1] aud_addr;
    wire        cop_req, cop_ack, cop_rvalid;
    wire [21:1] cop_addr;
    wire [1:0]  cop_pri;
    wire        blt_req, blt_we, blt_ack, blt_rvalid, blt_high;
    wire [21:1] blt_addr;
    wire [15:0] blt_wdata;
    wire [1:0]  blt_be;
    wire [39:0] memplan;                   // MEMSLOT0-4 (in video.v): slot n in bits 8n+7..8n

    // The slot plan (spec 5, section 6.2). Requesters by number: 0 layers,
    // 1 sprites, 2 audio, 3 copper, 4 CPU, 5 DMA engine, 6 DMA port. While
    // a nasty copper (COPCON.PRI 2) or a HIGH DMA engine job asks, it owns
    // slot 0 in place of the CPU, whatever MEMSLOT0 says.
    wire        nasty  = cop_req && cop_pri == 2'd2;
    wire        hijob  = blt_req && blt_high;
    wire [6:0]  own0   = (nasty || hijob) ? {memplan[6], hijob || memplan[5], 1'b0, nasty || memplan[3], memplan[2:0]}
                                          : memplan[6:0];
    wire [34:0] slot_owner = {memplan[38:32], memplan[30:24], memplan[22:16], memplan[14:8], own0};
    wire [4:0]  slot_lock  = {memplan[39], memplan[31], memplan[23], memplan[15], memplan[7]};

    // The DMA scheduler (spec 5): who gets each memory cycle
    wire        m_start, m_go, m_go_we, m_rvalid_any;
    wire [2:0]  m_cycle;
    wire [21:1] m_go_addr;
    wire [15:0] m_go_wdata;
    wire [1:0]  m_go_be;
    dmac #(.N(7), .S(5)) sched (
        .clk(clk100), .rst(sys_rst), .start_next(m_start), .next_slot(m_cycle),
        .slot_owner(slot_owner), .slot_lock(slot_lock),
        .req   ({dma_req, blt_req, m_req, cop_req, aud_req, spr_req, disp_req}),
        .urgent({5'd0, spr_urgent, disp_urgent}),
        .high  ({1'b0, blt_high, 1'b0, cop_pri != 2'd0, 3'd0}),
        .we    ({dma_we, blt_we, m_we, 4'd0}),
        .addr  ({dma_addr, blt_addr, m_addr, cop_addr, aud_addr, spr_addr, disp_addr}),
        .wdata ({dma_wdata, blt_wdata, m_wdata, 64'd0}),
        .be    ({dma_be, blt_be, m_be, 8'd0}),
        .ack     ({dma_ack, blt_ack, m_ack, cop_ack, aud_ack, spr_ack, disp_ack}),
        .rvalid_o({dma_rvalid, blt_rvalid, m_rvalid, cop_rvalid, aud_rvalid, spr_rvalid, disp_rvalid}),
        .go(m_go), .go_we(m_go_we), .go_addr(m_go_addr), .go_wdata(m_go_wdata), .go_be(m_go_be),
        .rvalid(m_rvalid_any)
    );
    sram_ctl mem (
        .clk(clk100), .rst(sys_rst), .sc(sc),
        .go(m_go), .go_we(m_go_we), .go_addr(m_go_addr), .go_wdata(m_go_wdata), .go_be(m_go_be),
        .start_next(m_start), .next_cycle(m_cycle), .rvalid(m_rvalid_any),
        .rdata(mem_rdata),
        .sram_a(sram_a), .sram_ce_n(sram_ce_n), .sram_ub_n(sram_ub_n), .sram_lb_n(sram_lb_n),
        .sram_oe_n_r(sram_oe_n_r), .sram_oe_n_f(sram_oe_n_f),
        .sram_we_n_r(sram_we_n_r), .sram_we_n_f(sram_we_n_f),
        .sram_dq_o(sram_dq_o), .sram_dq_t_r(sram_dq_t_r), .sram_dq_t_f(sram_dq_t_f),
        .sram_dq_i(sram_dq_i)
    );
    assign dma_rdata = mem_rdata;

    bootrom #(.INIT(ROM_INIT)) rom (
        .clk(clk100), .en(rom_en), .we(rom_we), .addr(rom_addr), .wdata(rom_wdata),
        .rdata(rom_rdata), .en_b(rom_en_b), .addr_b(rom_addr_b), .rdata_b(rom_rdata_b)
    );

    // ---------------------------------------------------------------- system block
    sysregs #(.CHIPMB(CHIPMB)) sys (
        .clk(clk100), .rst(sys_rst), .por(por100),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_sys),
        .resetwhy(resetwhy), .buttons(buttons), .halted(halted),
        .berr_ev(berr_ev), .berr_addr(berr_addr), .berr_why(berr_why),
        .overlay(overlay), .romwe(romwe), .protect(protect), .haltreset(haltreset),
        .soft_reset(soft_reset)
    );

    // The USB link survives resets it causes itself (spec 14), so only power-on resets it
    wire ser_irq;
    // DMA engine ports: 0 the SD card, 1 the serial FIFOs; timers starting DMA channels
    wire       p0_rxv, p0_rxpop, p0_txr, p0_txpush;
    wire       p_rxv, p_rxpop, p_txr, p_txpush;
    wire [7:0] p0_rxd, p_rxd, p_txd;
    wire [3:0] tmr_irq, tmr_dma_start;
    wire [7:0] tmr_dma_ch;
    serial ser (
        .clk(clk100), .rst(por100), .us_tick(us_tick),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_ser),
        .irq(ser_irq), .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .p_rxv(p_rxv), .p_rxd(p_rxd), .p_rxpop(p_rxpop), .p_txr(p_txr), .p_txpush(p_txpush), .p_txd(p_txd),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
    );

    // ---------------------------------------------------------------- video (spec 4)
    wire irq_vblank, irq_line, irq_viderr, line_tick, frame_tick;
    wire [15:0] dmacon;
    wire [10:0] beam_v, beam_h;
    video vid (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be), .rb_who(rb_who),
        .rb_rdata(rd_vid),
        .irq_vblank(irq_vblank), .irq_line(irq_line), .irq_viderr(irq_viderr),
        .line_tick(line_tick), .frame_tick(frame_tick), .beam_v(beam_v), .beam_h(beam_h),
        .dmacon(dmacon), .memplan(memplan), .disp_req(disp_req), .disp_urgent(disp_urgent), .disp_addr(disp_addr),
        .disp_ack(disp_ack), .disp_rvalid(disp_rvalid), .disp_rdata(mem_rdata),
        .spr_req(spr_req), .spr_urgent(spr_urgent), .spr_addr(spr_addr),
        .spr_ack(spr_ack), .spr_rvalid(spr_rvalid),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5), .rgb(vid_rgb), .hsync(vid_hsync), .vsync(vid_vsync), .de(vid_de)
    );

    wire       dmx_idle;               // the DMA engine (below)
    wire [3:0] dmx_irq;

    // ---------------------------------------------------------------- copper (spec 10)
    wire cop_irq;
    copper cop (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_cop),
        .cw_req(cw_req), .cw_addr(cw_addr), .cw_wdata(cw_wdata), .cw_be(cw_be), .cw_go(cw_go),
        .mem_req(cop_req), .mem_addr(cop_addr), .mem_pri(cop_pri), .mem_ack(cop_ack),
        .mem_rvalid(cop_rvalid), .mem_rdata(mem_rdata),
        .beam_v(beam_v), .beam_h(beam_h), .vblank(frame_tick), .dmacon(dmacon),
        .blt_idle(dmx_idle),
        .irq(cop_irq)
    );

    // ---------------------------------------------------------------- DMA engine and blitter (spec 11)
    dmx #(.CHIP_TOP({CHIPMB[3:0], 20'd0})) dx (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_dmx),
        .dx_req(dx_req), .dx_we(dx_we), .dx_addr(dx_addr), .dx_wdata(dx_wdata), .dx_be(dx_be),
        .dx_go(dx_go), .rb_rdall(rb_rdall),
        .rom_en(rom_en_b), .rom_addr(rom_addr_b), .rom_rdata(rom_rdata_b),
        .p0_rxv(p0_rxv), .p0_rxd(p0_rxd), .p0_rxpop(p0_rxpop), .p0_txr(p0_txr), .p0_txpush(p0_txpush),
        .p1_rxv(p_rxv), .p1_rxd(p_rxd), .p1_rxpop(p_rxpop), .p1_txr(p_txr), .p1_txpush(p_txpush), .p_txd(p_txd),
        .blt_high(blt_high),
        .tmr_start(tmr_dma_start), .tmr_ch(tmr_dma_ch),
        .mem_req(blt_req), .mem_we(blt_we), .mem_addr(blt_addr), .mem_wdata(blt_wdata), .mem_be(blt_be),
        .mem_ack(blt_ack), .mem_rvalid(blt_rvalid), .mem_rdata(mem_rdata),
        .dmacon(dmacon), .idle(dmx_idle), .irq(dmx_irq)
    );

    // ---------------------------------------------------------------- audio (spec 6)
    wire aud_irq;
    audio aud (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_aud), .dmacon(dmacon),
        .mem_req(aud_req), .mem_addr(aud_addr), .mem_ack(aud_ack),
        .mem_rvalid(aud_rvalid), .mem_rdata(mem_rdata),
        .irq(aud_irq), .out_l(), .out_r(), .tick_done(),
        .dac_l(aud_l), .dac_r(aud_r), .dac_m(aud_m)
    );

    // ---------------------------------------------------------------- timers (spec 12)
    timers tmr (
        .clk(clk100), .por(por100), .rst(dev_rst), .wd_rst(sys_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_tmr),
        .us_tick(us_tick), .line_tick(line_tick), .frame_tick(frame_tick),
        .irq(tmr_irq), .dma_start(tmr_dma_start), .dma_ch(tmr_dma_ch), .wd_reset(wd_reset)
    );

    // ---------------------------------------------------------------- SD card (spec 15)
    sdspi sd (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_sd),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_miso(sd_miso), .sd_cs0_n(sd_cs0_n), .sd_cs1_n(sd_cs1_n),
        .p_rxv(p0_rxv), .p_rxd(p0_rxd), .p_rxpop(p0_rxpop), .p_txr(p0_txr), .p_txpush(p0_txpush), .p_txd(p_txd)
    );

    // ---------------------------------------------------------------- PS/2 keyboard (spec 16)
    wire kb_irq;
    ps2kb kb (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_kb),
        .ps2_clk_i(ps2_clk_i), .ps2_data_i(ps2_data_i), .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .irq(kb_irq)
    );

    // ---------------------------------------------------------------- interrupts (spec 13)
    reg [1:0] nmi_s;
    always @(posedge clk100) nmi_s <= {nmi_s[0], buttons[0]};

    intc ic (
        .clk(clk100), .rst(dev_rst),
        .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
        .rb_rdata(rd_int),
        .req({6'd0, kb_irq, 1'b0, ser_irq, tmr_irq, 1'b0, aud_irq, 1'b0, dmx_irq, irq_viderr, cop_irq, irq_line, irq_vblank}),
        .nmi_button(nmi_s[1]), .nmi_usb(cmd_break),
        .level(int_level), .iack(iack), .iack_level(iack_level), .iack_vector(iack_vector)
    );
endmodule
