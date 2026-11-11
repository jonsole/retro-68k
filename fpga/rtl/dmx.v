// The blitter (spec 11): retro68k's registers on retro-hw's blitter core
// (fpga/retro-hw/docs/spec/blitter.md), which does the work.
//
// Kept here: the job registers (8 long words, laid out as a descriptor),
// which drive the core's job ports directly; BLTDESC, BLTCMD, BLTSTAT,
// DMXINT and DMXINTEN. A descriptor the core loads from Chip RAM is stored
// into the job registers a long word at a time. Chip RAM is the core's
// memory port (requester 5 of the scheduler, dmac.v).
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

    input  wire [15:0] dmacon,
    output wire        idle,           // no job running (the copper's WAIT B)
    output wire        irq             // BLT
);
    wire [15:0] off    = {rb_addr[15:2], 2'b00};
    wire        sel    = (rb_addr[23:16] == 8'hE0) && off[15:8] == 8'h03;      // 0x300-0x3FF
    wire        sel_jr = sel && off[7:5] == 3'b000;                            // 0x300-0x31C
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

    // DMXINT.BLT: set by the core's done; a flag due in the clock the CPU
    // clears it is kept
    reg         dint, dinten;
    assign irq  = dint && dinten;
    assign idle = !busy;
    always @(posedge clk) begin
        if (rst) begin
            dint <= 1'b0; dinten <= 1'b0;
        end else begin
            dint <= (dint && !(rb_wr && sel && off == `RM_DMXINT && rb_be[0] && rb_wdata[`RM_DMXINT_BLT])) || done;
            if (rb_wr && sel && off == `RM_DMXINTEN && rb_be[0]) dinten <= rb_wdata[`RM_DMXINTEN_BLT];
        end
    end

    always @(posedge clk) begin
        rb_rdata <= 32'd0;
        if (rb_rd && sel) begin
            if (sel_jr) rb_rdata <= jr[ri];
            else case (off)
                `RM_BLTDESC:  rb_rdata <= {8'd0, da_q};
                `RM_BLTSTAT:  rb_rdata <= {29'd0, err, 1'b0, busy};
                `RM_DMXINT:   rb_rdata <= {31'd0, dint};
                `RM_DMXINTEN: rb_rdata <= {31'd0, dinten};
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
endmodule
