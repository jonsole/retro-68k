// retro68k system testbench (phase 2): fx68k runs the boot ROM from the
// simulated board: SRAM model, FT232H model, optional DMA load.
//   +dma        keep the DMA port busy with random reads and writes
//   +trace      print the first bus cycles with their position in the slot
//   +frame      after PASS, wait for one more frame and write it to frame.ppm
//               and the video state to vstate/ (for vmodel.py)
//   +rom=FILE   load FILE into the boot ROM instead of boot.hex
//   +serial     after PASS: echo test (with escapes, a broken control
//               sequence), then the RESET control command; expects a second PASS
`timescale 1ns/1ps
module tb;
    reg clk200 = 1'b1, clk100 = 1'b1, clk40 = 1'b1;
    always #2.5  clk200 = ~clk200;
    always #5    clk100 = ~clk100;
    always #12.5 clk40  = ~clk40;

    // Power-on reset: last seen high by the clock edges at 2000 ns (a slot boundary)
    reg por = 1'b1;
    initial #2001 por = 1'b0;

    // ---------------------------------------------------------------- DUT
    wire [20:0] a;
    wire        ce_n, ub_n, lb_n, oe_r, oe_f, we_r, we_f, t_r, t_f;
    wire [15:0] dq_o;
    wire [15:0] dq;
    wire        ft_rxf_n, ft_txe_n, ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n;
    wire [7:0]  ft_d, ft_d_o;

    integer scan = 0, ls = 0, npass = 0, need = 1, serial_test = 0, echo_at = 0;
    reg [8*128-1:0] dumpfile;
    integer df, di;
    // Sprite debug counters (+sprdbg)
    integer spr_acks = 0, spr_rv = 0, spr_fw = 0, spr_px = 0;
    reg         dma_req = 0, dma_we = 0;
    reg  [21:1] dma_addr = 0;
    reg  [15:0] dma_wdata = 0;
    reg  [1:0]  dma_be = 2'b11;
    wire        dma_ack, dma_rvalid;
    wire [15:0] dma_rdata;
    wire [3:0]  sc;
    wire        halted;
    wire        clk_pix;
    wire [23:0] rgb;
    wire        hs, vs, de;
    // The 576p clocks, as from the KS3's second MMCM: 135 MHz (HDMI, and the
    // fast synchroniser) and 27 MHz = 135 / 5 with its edges on the 135 MHz
    // ones; free-running, with no fixed phase to the 100 MHz clock. Edges are
    // placed at exact times (n x 1/270 MHz) so the 1 ps rounding never drifts.
    reg clk_pix_r = 1'b0, clk_pix5 = 1'b0;
    initial begin : pixclocks
        integer n, k;
        real t;
        k = 0;
        n = 0;
        forever begin
            n = n + 1;
            t = 3.1 + n * (1000.0 / 270.0);          // an odd phase against the system clocks
            #(t - $realtime);
            clk_pix5 = ~clk_pix5;
            if (clk_pix5) begin
                if (k == 0) clk_pix_r = 1'b1;
                k = (k == 4) ? 0 : k + 1;
            end else if (k == 3) clk_pix_r = 1'b0;   // 2.5 fast periods after the rise
        end
    end
    assign clk_pix = clk_pix_r;

    // SD card and PS/2 keyboard lines (the models are below)
    wire sd_sclk, sd_mosi, sd_cs0_n, sd_cs1_n, sd_miso;
    wire ps2_clk_low_h, ps2_data_low_h, ps2_clk_low_k, ps2_data_low_k;
    wire ps2_clk  = !(ps2_clk_low_h  || ps2_clk_low_k);         // open collector, pulled up
    wire ps2_data = !(ps2_data_low_h || ps2_data_low_k);

    retro68k #(.ROM_INIT("boot.hex")) dut (
        .clk100(clk100), .clk40(clk40), .por100(por), .por40(por),
        .clk_pix(clk_pix), .clk_pix5(clk_pix5),
        .vid_rgb(rgb), .vid_hsync(hs), .vid_vsync(vs), .vid_de(de),
        .btn_reset_n(1'b1), .buttons(2'b00),
        .sram_a(a), .sram_ce_n(ce_n), .sram_ub_n(ub_n), .sram_lb_n(lb_n),
        .sram_oe_n_r(oe_r), .sram_oe_n_f(oe_f), .sram_we_n_r(we_r), .sram_we_n_f(we_f),
        .sram_dq_o(dq_o), .sram_dq_t_r(t_r), .sram_dq_t_f(t_f), .sram_dq_i(dq),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n),
        .dma_req(dma_req), .dma_we(dma_we), .dma_addr(dma_addr), .dma_wdata(dma_wdata),
        .dma_be(dma_be), .dma_ack(dma_ack), .dma_rvalid(dma_rvalid), .dma_rdata(dma_rdata),
        .sd_sclk(sd_sclk), .sd_mosi(sd_mosi), .sd_cs0_n(sd_cs0_n), .sd_cs1_n(sd_cs1_n), .sd_miso(sd_miso),
        .ps2_clk_i(ps2_clk), .ps2_data_i(ps2_data), .ps2_clk_low(ps2_clk_low_h), .ps2_data_low(ps2_data_low_h),
        .dbg_sc(sc), .dbg_halted(halted)
    );

    // ---------------------------------------------------------------- SD card and PS/2 keyboard
    sd_model sdc (.sclk(sd_sclk), .mosi(sd_mosi), .cs_n(sd_cs0_n), .miso(sd_miso));
    ps2_model kbd (.clk_line(ps2_clk), .data_line(ps2_data), .clk_low(ps2_clk_low_k), .data_low(ps2_data_low_k));
    // +iotest: the keyboard sends 1C F0 1C, then a frame with bad parity, early on
    initial if ($test$plusargs("iotest")) begin
        #300000;
        kbd.send(8'h1C, 1'b0);
        kbd.send(8'hF0, 1'b0);
        kbd.send(8'h1C, 1'b0);
        kbd.send(8'h55, 1'b1);
    end
    integer io_errors = 0;

    // ---------------------------------------------------------------- SRAM pads
    // Output registers in the pads: 1 ns clock-to-out
    reg  [20:0] pa;   reg pce_n = 1, pub_n = 1, plb_n = 1;  reg [15:0] pdq;
    always @(posedge clk100) begin
        pa    <= #1 a;
        pce_n <= #1 ce_n;
        pub_n <= #1 ub_n;
        plb_n <= #1 lb_n;
        pdq   <= #1 dq_o;
    end
    wire poe_n, pwe_n, pt;
    oddr #(.INIT(1'b1)) o_oe (.clk(clk100), .d_r(oe_r), .d_f(oe_f), .q(poe_n));
    oddr #(.INIT(1'b1)) o_we (.clk(clk100), .d_r(we_r), .d_f(we_f), .q(pwe_n));
    oddr #(.INIT(1'b1)) o_t  (.clk(clk100), .d_r(t_r),  .d_f(t_f),  .q(pt));
    assign dq = pt ? 16'hzzzz : pdq;

    sram_model sram (.a(pa), .dq(dq), .ce_n(pce_n), .oe_n(poe_n), .we_n(pwe_n),
                     .ub_n(pub_n), .lb_n(plb_n), .fpga_drives(!pt));

    // ---------------------------------------------------------------- FT232H
    assign ft_d = ft_d_oe ? ft_d_o : 8'hzz;
    ft232h_model ft (.d(ft_d), .rxf_n(ft_rxf_n), .txe_n(ft_txe_n),
                     .rd_n(ft_rd_n), .wr_n(ft_wr_n), .siwu_n(ft_siwu_n));

    // ---------------------------------------------------------------- DMA load
    // Random word reads and writes in 0x300000-0x3FFFFF, checked against a copy.
    reg  [15:0] shadow [0:(1<<19)-1];
    reg  [18:0] pend_q [0:7];      // addresses of reads waiting for their data
    reg  [15:0] pend_v [0:7];      // and the value at the time each read was issued
    integer     pend_h = 0, pend_t = 0;
    integer     dma_reads = 0, dma_writes = 0, dma_errors = 0, i;
    reg         dma_on = 0;
    initial begin
        for (i = 0; i < (1<<19); i = i + 1) shadow[i] = 16'h0000;
        for (i = 0; i < (1<<19); i = i + 1) sram.mem[(1<<20) + (1<<19) + i] = 16'h0000;
        dma_on = $test$plusargs("dma");
    end
    always @(posedge clk100) begin
        if (dma_rvalid) begin
            dma_reads = dma_reads + 1;
            if (pend_h == pend_t) begin
                $display("%t DMA ERROR: read data with no read waiting", $realtime);
                dma_errors = dma_errors + 1;
            end else begin
                if (dma_rdata !== pend_v[pend_h % 8]) begin
                    if (dma_errors < 10)
                        $display("%t DMA ERROR: read %h from %h, expected %h", $realtime,
                                 dma_rdata, {2'b11, pend_q[pend_h % 8], 1'b0}, pend_v[pend_h % 8]);
                    dma_errors = dma_errors + 1;
                end
                pend_h = pend_h + 1;
            end
        end
        if (dma_ack) begin
            if (dma_we) begin
                shadow[dma_addr[19:1]] = dma_wdata;
                dma_writes = dma_writes + 1;
            end else begin
                pend_q[pend_t % 8] = dma_addr[19:1];
                pend_v[pend_t % 8] = shadow[dma_addr[19:1]];
                pend_t = pend_t + 1;
            end
            dma_req <= 1'b0;
        end
        if (dma_on && !por && (!dma_req || dma_ack)) begin
            dma_req   <= 1'b1;
            dma_we    <= $random;
            dma_addr  <= {2'b11, 1'b0, $random} & 21'h1FFFFF | 21'h180000;
            dma_wdata <= $random;
        end
    end

    // ---------------------------------------------------------------- bus cycle monitor
    // Length of /AS low in ns: a zero-wait-state cycle has the same length
    // every time; each wait state adds 50 ns.
    real    t_as = 0;
    integer hist [0:15];
    integer ncyc = 0, ntrace = 0, trace = 0, nslow = 0;
    initial begin
        for (i = 0; i < 16; i = i + 1) hist[i] = 0;
        trace = $test$plusargs("trace");
    end
    reg [23:0] tr_addr; reg tr_rw; reg [2:0] tr_fc;
    always @(negedge dut.c_as_n) begin
        t_as = $realtime;
        tr_addr = {dut.c_addr, 1'b0}; tr_rw = dut.c_rw; tr_fc = dut.c_fc;
        if (trace && ntrace < 12)
            $display("%t bus cycle %0d: /AS low %0.0f ns into the slot", $realtime,
                     ntrace, $realtime - 2000.0 - 100.0 * $floor(($realtime - 2000.0) / 100.0));
    end
    // Full bus trace (+bustrace=N): address, direction and data of the first N cycles
    integer nbus = 0;
    always @(posedge dut.c_as_n) if (!por && t_as > 0 && nbus > 0) begin
        if (tr_rw) $display("%t  R %h = %h %s", $realtime, tr_addr, dut.din, dut.berr_n ? "" : "BERR");
        else       $display("%t  W %h = %h %b%b", $realtime, tr_addr, dut.c_dout, !dut.c_uds_n, !dut.c_lds_n);
        nbus = nbus - 1;
        ntrace = ntrace + 1;
    end
    initial if (!$value$plusargs("bustrace=%d", nbus)) nbus = 0;
    always @(posedge dut.c_as_n) if (!por && t_as > 0) begin
        i = ($realtime - t_as) / 50.0;
        hist[(i > 15) ? 15 : i] = hist[(i > 15) ? 15 : i] + 1;
        if (i > 3 && nslow < 10) begin
            $display("%t slow bus cycle: /AS low %0.0f ns, %s %h fc %0d", $realtime, $realtime - t_as,
                     tr_rw ? "read" : "write", tr_addr, tr_fc);
            nslow = nslow + 1;
        end
        ncyc = ncyc + 1;
    end

    // Audio log (+audio): every output sample, and how many 1s each DAC
    // stream gave during the sample before (audio.txt, for atest/amodel.py)
    integer af = 0, ones_l = 0, ones_r = 0;
    initial if ($test$plusargs("audio")) af = $fopen("audio.txt", "w");
    always @(posedge clk100) if (af != 0) begin
        ones_l = ones_l + dut.aud_l;
        ones_r = ones_r + dut.aud_r;
        if (dut.aud.tick_done) begin
            if (dut.aud.incl_q != 4'd0 || dut.aud.started != 4'd0)
                $fwrite(af, "%0d %0d %0d %0d %0d %0d\n", dut.aud.out_l, dut.aud.out_r, ones_l, ones_r,
                        dut.aud.started, dut.aud.incl_q);
            ones_l = 0;
            ones_r = 0;
        end
    end

    // Copper trace (+coptrace): its instructions and register writes
    integer ncop = 0, coptrace = 0;
    initial coptrace = $test$plusargs("coptrace");
    always @(posedge clk100) if (coptrace && ncop < 400) begin
        if (dut.cop.xs == 3'd1 && dut.cop.have && !dut.cop.hold) begin
            $display("%t cop %h: %h  beam %0d,%0d", $realtime, {dut.cop.npc, 2'b00}, dut.cop.ins, dut.cop.beam_v, dut.cop.beam_h);
            ncop = ncop + 1;
        end
        if (dut.cw_go) $display("%t cop write %h = %h be %b", $realtime, {dut.cw_addr, 2'b00}, dut.cw_wdata, dut.cw_be);
        if (dut.cop.vblank) $display("%t cop vblank, en %b", $realtime, dut.cop.en);
    end

    // Register bus trace (+rbtrace): the first 40 register accesses
    integer nrb = 0, rbtrace = 0;
    initial rbtrace = $test$plusargs("rbtrace");
    always @(posedge clk100) if (rbtrace && nrb < 40) begin
        if (dut.rb_wr) begin
            $display("%t rb write %h = %h be %b", $realtime, {dut.rb_addr, 2'b00}, dut.rb_wdata, dut.rb_be);
            nrb = nrb + 1;
        end
        if (dut.rb_rd) begin
            $display("%t rb read  %h", $realtime, {dut.rb_addr, 2'b00});
            nrb = nrb + 1;
        end
    end

    // ---------------------------------------------------------------- serial test
    // The escapes come back as the bytes they stand for, a broken command is
    // dropped, and a last byte of 0x00 is not held back (spec 14, section 3).
    event start_serial;
    reg [7:0] echo_exp [0:15];
    integer   n_echo = 0, j, serial_errors = 0;
    task push(input [7:0] b); begin ft.send(b); echo_exp[n_echo] = b; n_echo = n_echo + 1; end endtask
    task expect_echo(input [7:0] b); begin echo_exp[n_echo] = b; n_echo = n_echo + 1; end endtask
    initial begin
        @(start_serial);
        #2000;
        $display("\n%t PC: sending text with escapes and a broken control command", $realtime);
        push("H"); push("i");
        ft.send(8'hDB); ft.send(8'hDC); expect_echo(8'hC0);     // an escaped C0
        ft.send(8'hDB); ft.send(8'hDD); expect_echo(8'hDB);     // an escaped DB
        ft.send(8'hC0); ft.send(8'h05); ft.send(8'hFA);          // no such command: dropped
        push("!"); push(8'h00);                                  // the last byte 0x00: not held back
        wait_out(echo_at + n_echo, 5000);       // each echoed byte is also drawn on the bitmap console
        for (j = 0; j < n_echo; j = j + 1)
            if (ft.from_fpga[echo_at + j] !== echo_exp[j]) begin
                $display("SERIAL ERROR: echo byte %0d is %h, expected %h", j, ft.from_fpga[echo_at + j], echo_exp[j]);
                serial_errors = serial_errors + 1;
            end
        if (serial_errors == 0) $display("%t PC: echo ok (%0d bytes)", $realtime, n_echo);
        $display("%t PC: sending the BREAK control command", $realtime);
        j = ft.nout;
        send_ctl(8'h01);
        wait_out(j + 5, 1000);
        if (ft.nout < j + 5 || {ft.from_fpga[j], ft.from_fpga[j+1], ft.from_fpga[j+2]} != "NMI") begin
            $display("SERIAL ERROR: no NMI after BREAK");
            serial_errors = serial_errors + 1;
        end else $display("%t PC: NMI ok", $realtime);
        $display("%t PC: sending the RESET control command", $realtime);
        send_ctl(8'h02);
    end
    // Wait until the computer has sent n bytes in all, or us microseconds pass
    task wait_out(input integer n, input integer us);
        integer w;
        begin
            for (w = 0; w < us && ft.nout < n; w = w + 1) #1000;
        end
    endtask
    task send_ctl(input [7:0] c);   // C0 c ~c (spec 14, section 3)
        begin
            ft.send(8'hC0); ft.send(c); ft.send(~c);
        end
    endtask

    // ---------------------------------------------------------------- sync timing
    // 576p50: 864 x 625 at 27 MHz, both syncs active low;
    // hsync 64 pixels (2370 ns), vsync 5 lines.
    real t_hs = 0, t_vs = 0;
    integer n_hs = 0, n_vs = 0, sync_errors = 0;
    always @(negedge dut.vid.en_p) begin n_hs = 0; n_vs = 0; end
    always @(negedge hs) begin
        if (n_hs > 2 && ($realtime - t_hs < 31999.0 || $realtime - t_hs > 32001.0)) begin
            if (sync_errors < 5) $display("%t VIDEO ERROR: line period %0.1f ns, expected 32000", $realtime, $realtime - t_hs);
            sync_errors = sync_errors + 1;
        end
        t_hs = $realtime; n_hs = n_hs + 1;
    end
    always @(posedge hs) if (n_hs > 0 && ($realtime - t_hs < 2369.0 || $realtime - t_hs > 2372.0)) begin
        if (sync_errors < 5) $display("%t VIDEO ERROR: hsync %0.1f ns, expected 2370", $realtime, $realtime - t_hs);
        sync_errors = sync_errors + 1;
    end
    always @(negedge vs) begin
        if (n_vs > 0 && ($realtime - t_vs < 19999000.0 || $realtime - t_vs > 20001000.0)) begin
            $display("%t VIDEO ERROR: frame period %0.0f ns, expected 20000000", $realtime, $realtime - t_vs);
            sync_errors = sync_errors + 1;
        end
        t_vs = $realtime; n_vs = n_vs + 1;
    end
    always @(posedge vs) if (n_vs > 0 && ($realtime - t_vs < 159999.0 || $realtime - t_vs > 160001.0)) begin
        $display("%t VIDEO ERROR: vsync %0.0f ns, expected 160000", $realtime, $realtime - t_vs);
        sync_errors = sync_errors + 1;
    end

    // ---------------------------------------------------------------- frame grabber
    // Visible pixels (de) into a buffer; a long gap in de marks a new frame.
    reg  [23:0] fb [0:1280*800-1];
    integer fx = 0, fy = 0, fw = 0, fh = 0, gap = 0, frames_seen = 0;
    reg de_d = 0;
    always @(posedge clk_pix) begin
        if (de) begin
            if (fx < 1280 && fy < 800) fb[fy * 1280 + fx] = rgb;
            fx = fx + 1;
            gap = 0;
        end else begin
            if (de_d) begin
                if (fx > fw) fw = fx;
                fy = fy + 1;
                if (fy > fh) fh = fy;
                fx = 0;
            end
            gap = gap + 1;
            if (gap == 4000 && fy != 0) begin
                fy = 0;
                frames_seen = frames_seen + 1;
            end
        end
        de_d = de;
    end
    // Video state for the reference model (vmodel.py)
    reg [22:0] frame_bpt [0:23];
    integer bi;
    always @(posedge clk100) if (dut.vid.line_go && dut.vid.vc == dut.vid.VTOT - 1)
        for (bi = 0; bi < 24; bi = bi + 1) frame_bpt[bi] = dut.vid.dma.pt[bi];
    // Sprite pointers as the CPU or copper last wrote them (they move as fetched)
    reg [22:0] frame_spt [0:7];
    integer si;
    initial for (si = 0; si < 8; si = si + 1) frame_spt[si] = 23'd0;
    always @(posedge clk100) if (dut.rb_wr && dut.rb_addr[23:16] == 8'hE0 && {dut.rb_addr[15:2], 2'b00} >= 16'h0520
                                 && {dut.rb_addr[15:2], 2'b00} < 16'h0620 && dut.rb_addr[4:2] == 3'd0)
        frame_spt[({dut.rb_addr[15:2], 2'b00} - 16'h0520) >> 5] = dut.rb_be[0] ? {frame_spt[({dut.rb_addr[15:2], 2'b00} - 16'h0520) >> 5][22:16], dut.rb_wdata[15:0]}
                                                                   : {dut.rb_wdata[22:16], frame_spt[({dut.rb_addr[15:2], 2'b00} - 16'h0520) >> 5][15:0]};
    // Every write to a sprite's registers (SPRxDAT too) and to SPRDMA (as
    // sprite 8, register 6), with the frame and the beam, so the model can
    // replay changes made while sprites are drawn and words pushed by hand
    integer slog = 0;
    initial if ($test$plusargs("frame")) slog = $fopen("vstate_spr.txt", "w");
    always @(posedge clk100) if (slog != 0 && dut.vid.spr.rb_wr) begin
        if (dut.vid.spr.sel_s)
            $fwrite(slog, "%0d %0d %0d %0d %0d %0d %0d\n", dut.vid.s_frames, dut.vid.s_vc, dut.vid.s_hc,
                    dut.vid.spr.sn, dut.vid.spr.sr, dut.vid.spr.rb_wdata, dut.vid.spr.rb_be);
        if (dut.vid.spr.sel_g && dut.vid.spr.off == 16'h0500)   // SPRDMA
            $fwrite(slog, "%0d %0d %0d 8 6 %0d %0d\n", dut.vid.s_frames, dut.vid.s_vc, dut.vid.s_hc,
                    dut.vid.spr.rb_wdata, dut.vid.spr.rb_be);
    end
    task write_state;
        integer f, i, n;
        begin
            if (slog != 0) $fflush(slog);
            f = $fopen("vstate_regs.txt", "w");
            $fwrite(f, "frame %0d\n", dut.vid.s_frames - 1'b1);   // the frame grabbed (the next has just started)
            $fwrite(f, "hvis %0d\nvvis %0d\nprio %0d\nbg %0d\nvidcon %0d\nvidstat %0d\n",
                    dut.vid.HVIS, dut.vid.VVIS, dut.vid.prio, dut.vid.bgcolor, dut.vid.vidcon, dut.vid.vidstat);
            // Layer registers, and the plane pointers as taken for line 0
            for (n = 0; n < 3; n = n + 1)
                $fwrite(f, "layer %0d ctrl %0d xs %0d xe %0d ys %0d ye %0d sx %0d mod %0d\n", n,
                        dut.vid.l_ctrl[n], dut.vid.l_xs[n], dut.vid.l_xe[n], dut.vid.l_ys[n], dut.vid.l_ye[n],
                        dut.vid.l_sx[n], dut.vid.dma.mod[n]);
            for (n = 0; n < 24; n = n + 1) $fwrite(f, "bpt %0d %0d\n", n, frame_bpt[n]);
            for (n = 0; n < 3; n = n + 1)  $fwrite(f, "bpldma %0d %0d\n", n, dut.vid.dma.pm[n]);
            for (n = 0; n < 24; n = n + 1) $fwrite(f, "dat %0d %0d\n", n, dut.vid.dma.dr[n]);
            // Sprites (spec 9)
            for (n = 0; n < 8; n = n + 1)
                $fwrite(f, "sprite %0d hs %0d he %0d vs %0d ve %0d bpp %0d xstep %0d ystep %0d depth %0d pal %0d pt %0d dma %0d\n", n,
                        dut.vid.spr.m_h[n] & 11'h7FF, dut.vid.spr.m_h[n] >> 11, dut.vid.spr.m_v[n] & 11'h7FF, dut.vid.spr.m_v[n] >> 11,
                        dut.vid.spr.m_c[n] & 3, dut.vid.spr.m_s[n] & 16'hFFFF, dut.vid.spr.m_s[n] >> 16,
                        (dut.vid.spr.m_c[n] >> 2) & 3, dut.vid.spr.m_c[n] >> 4,
                        frame_spt[n], dut.vid.spr.active[n]);
            $fwrite(f, "sprcoll %0d\n", dut.vid.spr.coll);
            $fclose(f);
            f = $fopen("vstate_pal.hex", "w");
            for (i = 0; i < 1024; i = i + 1) $fwrite(f, "%h\n", dut.vid.pal[i]);   // PALETTE0-2, SPRPALETTE
            $fclose(f);
        end
    endtask

    task write_frame;
        integer f, x, y;
        begin
            f = $fopen("frame.ppm", "w");
            $fwrite(f, "P3\n%0d %0d\n255\n", fw, fh);
            for (y = 0; y < fh; y = y + 1) begin
                for (x = 0; x < fw; x = x + 1)
                    $fwrite(f, "%0d %0d %0d ", fb[y*1280+x][23:16], fb[y*1280+x][15:8], fb[y*1280+x][7:0]);
                $fwrite(f, "\n");
            end
            $fclose(f);
            $display("---- frame.ppm: %0d x %0d, %0d frames seen", fw, fh, frames_seen);
        end
    endtask

    // The boot ROM's bitmap (layer 1): 64 x 32 in 4 interleaved planes,
    // pixel (x, y) = (x xor y) and 15, shown 2x at (400, 300);
    // colour 16 + i = (16i, 255 - 16i, 0x80)
    integer bm_errors = 0;
    task check_bitmap;
        integer x, y;
        reg [7:0] v;
        begin
            for (y = 300; y < 364; y = y + 1)
                for (x = 400; x < 528; x = x + 1) begin
                    v = ((((x - 400) >> 1) ^ ((y - 300) >> 1)) & 15) << 4;
                    if (fb[y*1280+x] !== {v, 8'd255 - v, 8'h80}) begin
                        if (bm_errors < 8)
                            $display("BITMAP ERROR at (%0d, %0d): %h, expected %h", x, y, fb[y*1280+x], {v, 8'd255 - v, 8'h80});
                        bm_errors = bm_errors + 1;
                    end
                end
            $display("---- bitmap layer: %0d wrong pixels", bm_errors);
        end
    endtask

    // ---------------------------------------------------------------- finish
    integer k, done = 0, ok = 0;
    task report;
        begin
            $display("");
            $display("---- %0d bus cycles; /AS low time:", ncyc);
            for (k = 0; k < 16; k = k + 1)
                if (hist[k] != 0) $display("     %0d-%0d ns: %0d", k * 50, k * 50 + 49, hist[k]);
            $display("---- DMA: %0d reads, %0d writes, %0d errors", dma_reads, dma_writes, dma_errors);
            $display("---- SRAM timing errors: %0d, FT232H errors: %0d, send-immediate pulses: %0d",
                     sram.errors, ft.errors, ft.siwu_count);
            $display("---- video: %0d lines, %0d frames, %0d timing errors", n_hs, n_vs, sync_errors);
        end
    endtask

    initial begin
        serial_test = $test$plusargs("serial");
        if (serial_test) need = 2;
    end
    always @(posedge clk100) if (!done) begin
        // A line starting "PASS" or "FAIL" ends the test
        while (scan < ft.nout) begin
            if (scan == 0 || ft.from_fpga[scan-1] == 8'h0A) ls = scan;
            if (scan - ls == 3) begin
                if ({ft.from_fpga[ls], ft.from_fpga[ls+1], ft.from_fpga[ls+2], ft.from_fpga[ls+3]} == "PASS") begin
                    npass = npass + 1;
                    if (npass == need) begin done = 1; ok = 1; end
                    else if (npass == 1) begin echo_at = scan + 3; -> start_serial; end
                end
                if ({ft.from_fpga[ls], ft.from_fpga[ls+1], ft.from_fpga[ls+2], ft.from_fpga[ls+3]} == "FAIL") begin
                    done = 1; ok = 0;
                end
            end
            scan = scan + 1;
        end
        if (halted) begin
            $display("\n%t CPU halted (double bus fault)", $realtime);
            done = 1; ok = 0;
        end
        if (done) begin
            #20000;    // let the rest of the line out
            if ($test$plusargs("frame")) begin
                k = frames_seen;
                wait (frames_seen == k + 2);   // a complete frame after PASS
                write_frame;
                write_state;
                if (!$test$plusargs("rom=")) check_bitmap;
            end
            report;
            // +dumpram=FILE: Chip RAM 0x0F0000-0x1FFFFF at the end (the DMA test)
            if ($value$plusargs("dumpram=%s", dumpfile)) begin
                df = $fopen(dumpfile, "w");
                $fwrite(df, "@%h\n", 21'h78000);
                for (di = 21'h78000; di < 21'h100000; di = di + 1) $fwrite(df, "%h\n", sram.mem[di]);
                $fclose(df);
            end
            if ($test$plusargs("sprdbg"))
                $display("---- sprites: %0d acks, %0d words back, %0d FIFO writes, %0d opaque pixels",
                         spr_acks, spr_rv, spr_fw, spr_px);
            if (serial_test)
                $display("---- serial: %0d errors; RESETWHY after the command: %h", serial_errors, dut.resetwhy);
            if (serial_test && dut.resetwhy !== 8'h10) serial_errors = serial_errors + 1;
            if ($test$plusargs("iotest")) begin
                // what the models saw: the CPU sent ED to the keyboard, wrote one block
                if (kbd.last_rx !== 8'hED || kbd.rx_bad != 0 || kbd.nrx != 1) io_errors = io_errors + 1;
                if (sdc.errors != 0 || sdc.nblocks_w != 1) io_errors = io_errors + 1;
                $display("---- io: keyboard got %h (%0d bytes, %0d bad); SD card: %0d blocks written, %0d errors",
                         kbd.last_rx, kbd.nrx, kbd.rx_bad, sdc.nblocks_w, sdc.errors);
            end
            if (ok && sram.errors == 0 && ft.errors == 0 && dma_errors == 0 && serial_errors == 0 && sync_errors == 0 && bm_errors == 0 && io_errors == 0) $display("TEST PASSED");
            else $display("TEST FAILED");
            $finish;
        end
    end

    always @(posedge clk100) begin
        if (dut.spr_ack) spr_acks = spr_acks + 1;
        if (dut.spr_rvalid) spr_rv = spr_rv + 1;
        if (|dut.vid.spr.dma_wr) spr_fw = spr_fw + 1;
    end
    always @(posedge dut.vid.clk_pix) if (|dut.vid.s_op) spr_px = spr_px + 1;
    always @(posedge clk100) if ($test$plusargs("sprdbg") && dut.vid.frame_tick)
        $display("%t frame: alive %b flushing %b run %b want %b pk_v %b req %b wp0 %0d infl0 %0d dl0 %0d",
                 $realtime, dut.vid.spr.alive, dut.vid.spr.flushing, dut.vid.spr.run, dut.vid.spr.want,
                 dut.vid.spr.pk_v, dut.vid.spr.mem_req, dut.vid.spr.wp[0], dut.vid.spr.infl[0], dut.vid.spr.dl[0]);


    reg xseen = 0;
    always @(posedge clk100) if ($test$plusargs("xstop") && !xseen && !dut.vid.spr.rst && (^{dut.spr_req, dut.spr_ack, dut.spr_urgent} === 1'bx || (dut.spr_req && ^dut.spr_deadline === 1'bx))) begin : xdump
        integer q;
        xseen = 1;
        $display("%t X in want %b", $realtime, dut.vid.spr.want);
        for (q = 0; q < 8; q = q + 1)
            $display("  spr %0d: infl %b cnt %b wp %b rp_s2 %b alive %b flushing %b", q, dut.vid.spr.infl[q], dut.vid.spr.cnt[q],
                     dut.vid.spr.wp[q], dut.vid.spr.rp_s2[q], dut.vid.spr.alive[q], dut.vid.spr.flushing[q]);
        $display("  q_h %b q_t %b q_s %b %b %b %b rvalid %b ack %b req %b issue %b pk %b",
                 dut.vid.spr.q_h, dut.vid.spr.q_t, dut.vid.spr.q_s[0], dut.vid.spr.q_s[1], dut.vid.spr.q_s[2], dut.vid.spr.q_s[3],
                 dut.vid.spr.mem_rvalid, dut.vid.spr.mem_ack, dut.vid.spr.mem_req, dut.vid.spr.issue, dut.vid.spr.pk);
        $display("  req_s %b deadline %b urgent %b d3_dl %b d3_rr %b bt %b btr %b beam_h %b dl %b %b %b %b %b %b %b %b",
                 dut.vid.spr.req_s, dut.spr_deadline, dut.spr_urgent, dut.vid.spr.d3_dl, dut.vid.spr.d3_rr, dut.vid.spr.bt, dut.vid.spr.btr,
                 dut.vid.spr.beam_h, dut.vid.spr.dl[0], dut.vid.spr.dl[1], dut.vid.spr.dl[2], dut.vid.spr.dl[3],
                 dut.vid.spr.dl[4], dut.vid.spr.dl[5], dut.vid.spr.dl[6], dut.vid.spr.dl[7]);
        $display("  sched: win %b next_cycle %b start %b cpu %b bpl %b/%b dl %b spr %b aud %b cop %b pri %b blt %b port %b",
                 dut.sched.win, dut.sched.next_cycle, dut.sched.start_next, dut.sched.cpu_req, dut.sched.bpl_req, dut.sched.bpl_urgent,
                 dut.sched.bpl_deadline, dut.sched.spr_req, dut.sched.aud_req, dut.sched.cop_req, dut.sched.cop_pri,
                 dut.sched.blt_req, dut.sched.port_req);
        $finish;
    end

    integer tmo;
    reg [1023:0] romfile;
    initial if ($value$plusargs("rom=%s", romfile)) begin
        #1 $readmemh(romfile, dut.rom.mem);
        $display("boot ROM: %0s", romfile);
    end
    // +dmxsend: the PC sends 64 bytes (7i + 3) early on, for the DMA test's
    // port job to copy into memory
    initial if ($test$plusargs("dmxsend")) begin : dmxsend
        integer i;
        #50000;
        for (i = 0; i < 64; i = i + 1) ft.send(i * 7 + 3);
    end

    // +ram=FILE: Chip RAM contents at the start ($readmemh of 16-bit words, with @addresses)
    reg [1023:0] ramfile;
    initial if ($value$plusargs("ram=%s", ramfile)) begin
        #1 $readmemh(ramfile, sram.mem);
        $display("Chip RAM loaded: %0s", ramfile);
    end
    initial begin
        if ($test$plusargs("vcd")) begin
            $dumpfile("tb.vcd");
            $dumpvars(0, tb);
        end
        if (!$value$plusargs("timeout=%d", tmo)) tmo = ($test$plusargs("frame") || $test$plusargs("serial")) ? 120_000_000 : 60_000_000;
        #(tmo);
        $display("\nTIMEOUT");
        report;
        $display("TEST FAILED");
        $finish;
    end
endmodule
