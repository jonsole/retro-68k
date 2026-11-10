// The blitter (spec 11) and the rasteriser (spec 17): retro68k's registers
// on retro-hw's blitter and raster cores (fpga/retro-hw/docs/spec/blitter.md
// and raster.md), which do the work.
//
// Kept here, for each core: its job registers (8 long words, laid out as a
// descriptor), which drive the core's job ports directly; its descriptor
// address, command and status registers (BLTDESC, BLTCMD, BLTSTAT; RASDESC,
// RASCMD, RASSTAT). A descriptor a core loads from Chip RAM is stored into
// its job registers a long word at a time. The rasteriser's clip window
// (RASCLIPMIN, RASCLIPMAX) is here too, and DMXINT and DMXINTEN, which the
// two share. Each core has its own memory port (requesters 5 and 6 of the
// scheduler, dmac.v), so both can run at once.
`include "regmap.vh"

module dmx (
    input  wire        clk,
    input  wire        rst,

    // Register bus
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    // Memory (dmac.v BLT requester)
    output wire        mem_req,
    output wire        mem_we,
    output wire [21:1] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // Memory (dmac.v RAS requester); read data is mem_rdata
    output wire        ras_req,
    output wire        ras_we,
    output wire [21:1] ras_addr,
    output wire [15:0] ras_wdata,
    output wire [1:0]  ras_be,
    input  wire        ras_ack,
    input  wire        ras_rvalid,

    input  wire [15:0] dmacon,
    output wire        idle,           // no job running in either (the copper's WAIT B)
    output wire        irq             // BLT
);
    wire [15:0] off    = {rb_addr[15:2], 2'b00};
    wire        sel    = (rb_addr[23:16] == 8'hE0) && off[15:8] == 8'h03;      // 0x300-0x3FF
    wire        sel_jr = sel && off[7:5] == 3'b000;                            // 0x300-0x31C
    wire        sel_rj = sel && off[7:5] == 3'b010;                            // 0x340-0x35C
    wire [2:0]  ri     = off[4:2];

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    wire        busy, done, err;
    wire [23:0] da_q;
    wire        dl_v;
    wire [2:0]  dl_i;
    wire [15:0] dl_w0, dl_w1;

    // The job registers. Written by the CPU or the copper while no job
    // runs, and by a descriptor load (only while one does).
    reg  [31:0] jr [0:7];
    integer k;
    initial for (k = 0; k < 8; k = k + 1) jr[k] = 32'd0;
    always @(posedge clk) begin
        if (dl_v)                           jr[dl_i] <= {dl_w0, dl_w1};
        else if (rb_wr && sel_jr && !busy)  jr[ri]   <= merge(jr[ri], rb_wdata, rb_be);
    end

    // BLTCMD's strobes, and BLTDESC
    wire        w_cmd  = rb_wr && sel && off == `RM_BLTCMD && rb_be[0];
    wire        w_desc = rb_wr && sel && off == `RM_BLTDESC;
    wire [31:0] desc_v = merge({8'd0, da_q}, rb_wdata, rb_be);

    // ---------------------------------------------------------------- the rasteriser
    wire        r_busy, r_done, r_err;
    wire [23:0] r_da_q;
    wire        r_dl_v;
    wire [2:0]  r_dl_i;
    wire [15:0] r_dl_w0, r_dl_w1;

    // Its job registers, as the blitter's
    reg  [31:0] rj [0:7];
    initial for (k = 0; k < 8; k = k + 1) rj[k] = 32'd0;
    always @(posedge clk) begin
        if (r_dl_v)                           rj[r_dl_i] <= {r_dl_w0, r_dl_w1};
        else if (rb_wr && sel_rj && !r_busy)  rj[ri]     <= merge(rj[ri], rb_wdata, rb_be);
    end

    // The clip window, shared by every job: not part of a descriptor. Held
    // while a job runs
    reg  [31:0] clipmin = 32'd0, clipmax = 32'd0;
    always @(posedge clk) if (rb_wr && sel && !r_busy) begin
        if (off == `RM_RASCLIPMIN) clipmin <= merge(clipmin, rb_wdata, rb_be);
        if (off == `RM_RASCLIPMAX) clipmax <= merge(clipmax, rb_wdata, rb_be);
    end

    wire        w_rcmd  = rb_wr && sel && off == `RM_RASCMD && rb_be[0];
    wire        w_rdesc = rb_wr && sel && off == `RM_RASDESC;
    wire [31:0] rdesc_v = merge({8'd0, r_da_q}, rb_wdata, rb_be);
    // A reserved bit of RASCTRL set is an error: a blitter descriptor given
    // to the rasteriser by mistake, or a job for a later version
    wire        r_bad   = |{rj[0][23:18], rj[0][15:13], rj[0][11:10]};

    // ---------------------------------------------------------------- shared
    // DMXINT (BLT, RAS): set by each core's done; a flag due in the clock
    // the CPU clears it is kept
    reg  [1:0]  dint, dinten;
    wire        w_int = rb_wr && sel && off == `RM_DMXINT && rb_be[0];
    assign irq  = |(dint & dinten);
    assign idle = !busy && !r_busy;
    always @(posedge clk) begin
        if (rst) begin
            dint <= 2'b00; dinten <= 2'b00;
        end else begin
            dint <= (dint & ~({2{w_int}} & rb_wdata[1:0])) | {r_done, done};
            if (rb_wr && sel && off == `RM_DMXINTEN && rb_be[0]) dinten <= rb_wdata[1:0];
        end
    end

    always @(posedge clk) begin
        rb_rdata <= 32'd0;
        if (rb_rd && sel) begin
            if (sel_jr) rb_rdata <= jr[ri];
            else if (sel_rj) rb_rdata <= rj[ri];
            else case (off)
                `RM_BLTDESC:    rb_rdata <= {8'd0, da_q};
                `RM_BLTSTAT:    rb_rdata <= {29'd0, err, 1'b0, busy};
                `RM_RASDESC:    rb_rdata <= {8'd0, r_da_q};
                `RM_RASSTAT:    rb_rdata <= {29'd0, r_err, 1'b0, r_busy};
                `RM_RASCLIPMIN: rb_rdata <= clipmin;
                `RM_RASCLIPMAX: rb_rdata <= clipmax;
                `RM_DMXINT:     rb_rdata <= {30'd0, dint};
                `RM_DMXINTEN:   rb_rdata <= {30'd0, dinten};
                default: ;
            endcase
        end
    end

    wire [20:0] m_addr;
    assign mem_addr = m_addr;

    blitter #(.AW(21), .LE(0), .MASKIMG(1)) core (
        .clk(clk), .rst(rst),
        .enable(dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_BLTEN]),
        .start_ld(w_cmd && rb_wdata[`RM_BLTCMD_START]), .start_run(w_cmd && rb_wdata[`RM_BLTCMD_RUN]),
        .stop(w_cmd && rb_wdata[`RM_BLTCMD_STOP]),
        .da_we(w_desc), .da_d(desc_v[23:0]), .da_q(da_q),
        .busy(busy), .done(done), .err(err),
        .su_v(), .su_i(),
        .job_minterm(jr[0][`RM_BLTCTRL_MINTERM]), .job_mask(jr[0][`RM_BLTCTRL_MASK]),
        .job_bpp(jr[0][`RM_BLTCTRL_BPP]), .job_rtl(jr[0][`RM_BLTCTRL_RTL]),
        .job_bconst(jr[0][`RM_BLTCTRL_BCONST]), .job_irq(jr[0][`RM_BLTCTRL_IRQ]),
        .job_value(jr[6][`RM_BLTVALUE_VALUE]), .job_key(jr[0][`RM_BLTCTRL_KEY]),
        .job_astride(jr[6][`RM_BLTVALUE_ASTRIDE]),
        .job_bstride(jr[5][`RM_BLTSTRIDE_BSTRIDE]), .job_dstride(jr[5][`RM_BLTSTRIDE_DSTRIDE]),
        .job_width(jr[3][`RM_BLTSIZE_WIDTH]), .job_height(jr[3][`RM_BLTSIZE_HEIGHT]),
        .job_aaddr(jr[4][`RM_BLTAPT_ADDR]), .job_baddr(jr[1][`RM_BLTBPT_ADDR]), .job_daddr(jr[2][`RM_BLTDPT_ADDR]),
        .job_abit(jr[4][`RM_BLTAPT_BIT]), .job_bbit(jr[1][`RM_BLTBPT_BIT]), .job_dbit(jr[2][`RM_BLTDPT_BIT]),
        .job_next(jr[7][`RM_BLTNEXT_ADDR]), .job_bad(1'b0),
        .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(1'b0),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(m_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata)
    );

    wire [20:0] rm_addr;
    assign ras_addr = rm_addr;

    raster #(.AW(21), .LE(0), .TRI(1)) rcore (
        .clk(clk), .rst(rst),
        .enable(dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_BLTEN]),
        .start_ld(w_rcmd && rb_wdata[`RM_RASCMD_START]), .start_run(w_rcmd && rb_wdata[`RM_RASCMD_RUN]),
        .stop(w_rcmd && rb_wdata[`RM_RASCMD_STOP]),
        .da_we(w_rdesc), .da_d(rdesc_v[23:0]), .da_q(r_da_q),
        .busy(r_busy), .done(r_done), .err(r_err),
        .su_v(), .su_i(),
        .job_tri(rj[0][`RM_RASCTRL_TRI]), .job_minterm(rj[0][`RM_RASCTRL_MINTERM]),
        .job_bpp(rj[0][`RM_RASCTRL_BPP]), .job_value(rj[0][`RM_RASCTRL_VALUE]),
        .job_pattern(rj[6][`RM_RASPAT_PATTERN]), .job_nolast(rj[0][`RM_RASCTRL_NOLAST]),
        .job_irq(rj[0][`RM_RASCTRL_IRQ]),
        .job_x0(rj[1][`RM_RASP0_X]), .job_y0(rj[1][`RM_RASP0_Y]),
        .job_x1(rj[2][`RM_RASP1_X]), .job_y1(rj[2][`RM_RASP1_Y]),
        .job_x2(rj[3][`RM_RASP2_X]), .job_y2(rj[3][`RM_RASP2_Y]),
        .job_daddr(rj[4][`RM_RASDPT_ADDR]), .job_dstride(rj[5][`RM_RASSTRIDE_DSTRIDE]),
        .clip_xmin(clipmin[`RM_RASCLIPMIN_X]), .clip_xmax(clipmax[`RM_RASCLIPMAX_X]),
        .clip_ymin(clipmin[`RM_RASCLIPMIN_Y]), .clip_ymax(clipmax[`RM_RASCLIPMAX_Y]),
        .job_next(rj[7][`RM_RASNEXT_ADDR]), .job_bad(r_bad),
        .dl_v(r_dl_v), .dl_i(r_dl_i), .dl_w0(r_dl_w0), .dl_w1(r_dl_w1), .dl_wait(1'b0),
        .mem_req(ras_req), .mem_we(ras_we), .mem_addr(rm_addr), .mem_wdata(ras_wdata), .mem_be(ras_be),
        .mem_ack(ras_ack), .mem_rvalid(ras_rvalid), .mem_rdata(mem_rdata)
    );
endmodule
