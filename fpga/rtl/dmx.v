// DMA engine and blitter (spec 11): retro68k's registers on retro-hw's
// dmx_core (fpga/retro-hw/docs/spec/dmx_core.md), which runs the four
// channels and the blitter datapath.
//
// Kept here: each channel's job registers (laid out as a descriptor), the
// descriptor RAM, CHDESC, CHCTRL, CHSTAT, CHERR, DMXINT and DMXINTEN; the
// decode of a job onto the core's ports; and the core's other port, which
// reaches the custom block (on the register bus, a register half at a
// time, as the CPU and copper write them) and the boot ROM (its second
// read port). Chip RAM is the core's memory port (the scheduler's DMA
// engine channel, dmac.v).
`include "regmap.vh"

module dmx #(
    parameter [23:0] CHIP_TOP = 24'h400000
) (
    input  wire        clk,
    input  wire        rst,

    // Register bus (slave)
    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output wire [31:0] rb_rdata,

    // Register bus (master, after the CPU and the copper: muxed in retro68k.v)
    output wire        dx_req,         // held until dx_go
    output wire        dx_we,
    output wire [23:2] dx_addr,
    output wire [31:0] dx_wdata,
    output wire [3:0]  dx_be,
    input  wire        dx_go,          // on the bus this clock
    input  wire [31:0] rb_rdall,       // the bus's read data (every unit's), the clock after a read

    // Memory (dmac.v BLT channel)
    output wire        mem_req,
    output wire        mem_we,
    output wire [21:1] mem_addr,
    output wire [15:0] mem_wdata,
    output wire [1:0]  mem_be,
    input  wire        mem_ack,
    input  wire        mem_rvalid,
    input  wire [15:0] mem_rdata,

    // Boot ROM, second port (read only)
    output reg         rom_en,
    output reg  [14:1] rom_addr,
    input  wire [15:0] rom_rdata,

    // Ports: 0 the SD card (spec 15), 1 the USB serial FIFOs (spec 14)
    input  wire        p0_rxv,         // a received byte is there ...
    input  wire [7:0]  p0_rxd,
    output wire        p0_rxpop,       // ... take it
    input  wire        p0_txr,         // room to send a byte ...
    output wire        p0_txpush,      // ... send this one
    input  wire        p1_rxv,
    input  wire [7:0]  p1_rxd,
    output wire        p1_rxpop,
    input  wire        p1_txr,
    output wire        p1_txpush,
    output wire [7:0]  p_txd,          // the byte to send, for either

    // The scheduler: the running job's HIGH bit (spec 11, section 5)
    output wire        blt_high,

    // Timers starting channels (spec 12): as a START written to CHCTRL
    input  wire [3:0]  tmr_start,
    input  wire [7:0]  tmr_ch,

    input  wire [15:0] dmacon,
    output wire        idle,           // no channel busy (the copper's WAIT B)
    output wire [3:0]  irq             // DMA0-DMA3
);
    // ================================================================ register decode
    wire [15:0] off      = {rb_addr[15:2], 2'b00};
    wire in_custom = (rb_addr[23:16] == 8'hE0);
    wire sel_dmx   = in_custom && off[15:8] == 8'h03;          // 0x300-0x3FF
    wire [1:0] rch = off[7:6];
    wire [3:0] rri = off[5:2];                                 // 0-7 job, 8 CHDESC, 9 CHCTRL, 10 CHSTAT, 11 CHERR
    wire sel_jr    = sel_dmx && !rri[3];
    wire sel_int   = sel_dmx && off[7:0] == 8'hF0;
    wire sel_inten = sel_dmx && off[7:0] == 8'hF4;
    wire sel_dram  = in_custom && off[15:11] == 5'b01100;     // 0x6000-0x67FF
    wire wr0       = rb_wr && sel_dmx && rb_be[0] && !sel_int && !sel_inten;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // ================================================================ channel registers
    reg  [3:0]  pause;
    reg  [3:0]  dint, dinten;
    wire [3:0]  busy, done, err, irq_set;
    wire [95:0] da_q, ea_q;
    wire [1:0]  cur;
    wire [23:0] chdesc_r = da_q[24*rch +: 24];

    assign irq = dint & dinten;

    // Strobes for the core, from CHCTRL, CHSTAT, CHDESC and the timers
    reg  [3:0]  s_ld, s_run;
    always @(*) begin : starts
        integer i;
        s_ld  = 4'd0;
        s_run = 4'd0;
        if (wr0 && rri == 4'd9) begin
            s_ld[rch]  = rb_wdata[0];
            s_run[rch] = rb_wdata[1] && !rb_wdata[0];
        end
        for (i = 0; i < 4; i = i + 1)
            if (tmr_start[i]) s_ld[tmr_ch[2*i +: 2]] = 1'b1;
    end
    wire [3:0]  s_stop  = (wr0 && rri == 4'd9  && rb_wdata[2]) ? (4'd1 << rch) : 4'd0;
    wire [3:0]  s_cdone = (wr0 && rri == 4'd10 && rb_wdata[1]) ? (4'd1 << rch) : 4'd0;
    wire [3:0]  s_cerr  = (wr0 && rri == 4'd10 && rb_wdata[2]) ? (4'd1 << rch) : 4'd0;
    wire        dsc_w   = rb_wr && sel_dmx && rri == 4'd8 && !sel_int && !sel_inten;
    wire [31:0] dsc_v   = merge({8'd0, chdesc_r}, rb_wdata, rb_be);

    // Job registers: 4 channels x 8 long words, in distributed RAM. Written
    // by the CPU (channel not busy) or by a descriptor load; one write a
    // clock, the CPU first (the load's write waits).
    reg  [31:0] jr [0:31];
    wire        cpu_jw  = rb_wr && sel_jr && !busy[rch];
    reg         eng_jw;
    reg  [4:0]  eng_ja;
    reg  [31:0] eng_jd;
    wire        dl_v;
    wire [2:0]  dl_i;
    wire [15:0] dl_w0, dl_w1;
    integer k;
    initial for (k = 0; k < 32; k = k + 1) jr[k] = 32'd0;
    always @(posedge clk) begin
        if (cpu_jw)      jr[{rch, rri[2:0]}] <= merge(jr[{rch, rri[2:0]}], rb_wdata, rb_be);
        else if (eng_jw) jr[eng_ja] <= eng_jd;
        if (rst)
            eng_jw <= 1'b0;
        else if (dl_v) begin
            eng_jw <= 1'b1;
            eng_ja <= {cur, dl_i};
            eng_jd <= {dl_w0, dl_w1};
        end else if (!cpu_jw)
            eng_jw <= 1'b0;
    end

    // Descriptor RAM: 512 x 32, on the register bus (the CPU, the copper, or
    // this engine through its own bus master)
    reg  [31:0] dram [0:511];
    reg  [31:0] dq;
    always @(posedge clk) begin
        if (rb_wr && sel_dram) begin
            if (rb_be[3]) dram[rb_addr[10:2]][31:24] <= rb_wdata[31:24];
            if (rb_be[2]) dram[rb_addr[10:2]][23:16] <= rb_wdata[23:16];
            if (rb_be[1]) dram[rb_addr[10:2]][15:8]  <= rb_wdata[15:8];
            if (rb_be[0]) dram[rb_addr[10:2]][7:0]   <= rb_wdata[7:0];
        end
        dq <= dram[rb_addr[10:2]];
    end
    reg dhit;
    always @(posedge clk) dhit <= rb_rd && sel_dram;

    reg [31:0] reg_q;
    assign rb_rdata = reg_q | (dhit ? dq : 32'd0);
    always @(posedge clk) begin
        reg_q <= 32'd0;
        if (rb_rd && sel_dmx) begin
            if (sel_int)        reg_q <= {28'd0, dint};
            else if (sel_inten) reg_q <= {28'd0, dinten};
            else case (rri)
                4'd8:  reg_q <= {8'd0, chdesc_r};
                4'd9:  reg_q <= {28'd0, pause[rch], 3'd0};
                4'd10: reg_q <= {28'd0, busy[rch] && pause[rch], err[rch], done[rch], busy[rch]};
                4'd11: reg_q <= {8'd0, ea_q[24*rch +: 24]};
                default: if (!rri[3]) reg_q <= jr[{rch, rri[2:0]}];
            endcase
        end
    end

    always @(posedge clk) begin
        if (rst) begin
            pause <= 4'd0; dint <= 4'd0; dinten <= 4'd0;
        end else begin
            // a flag due in the clock the CPU clears others is kept
            dint <= (dint & ~((rb_wr && sel_int && rb_be[0]) ? rb_wdata[3:0] : 4'd0)) | irq_set;
            if (rb_wr && sel_inten && rb_be[0]) dinten <= rb_wdata[3:0];
            if (wr0 && rri == 4'd9) pause[rch] <= rb_wdata[3];
        end
    end

    // ================================================================ the job, decoded
    // In the core's set-up clocks: job register su_i of channel cur
    wire        su_v;
    wire [2:0]  su_i;
    wire [31:0] jv = jr[{cur, su_i}];
    reg  [2:0]  j_op;
    reg  [7:0]  j_mt;
    reg         j_sat, j_sgn, j_desc, j_high, j_irq;
    reg  [1:0]  j_bpp, j_bk, j_dk, j_mask;
    reg  [23:0] j_b, j_d, j_a, j_next;
    reg  [2:0]  j_bbit, j_dbit, j_abit;
    reg  [15:0] j_width, j_height, j_bstr, j_dstr;
    reg  [31:0] j_val;
    always @(posedge clk) if (su_v) case (su_i)
        3'd0: begin j_op <= jv[2:0]; j_sat <= jv[4]; j_sgn <= jv[5]; j_bpp <= jv[9:8]; j_desc <= jv[10];
                    j_high <= jv[11]; j_irq <= jv[12]; j_bk <= jv[14:13]; j_dk <= jv[16:15];
                    j_mask <= jv[18:17]; j_mt <= jv[31:24]; end
        3'd1: begin j_b <= jv[23:0]; j_bbit <= jv[26:24]; end
        3'd2: begin j_d <= jv[23:0]; j_dbit <= jv[26:24]; end
        3'd3: begin j_width <= jv[15:0]; j_height <= jv[31:16]; end
        3'd4: begin j_a <= jv[23:0]; j_abit <= jv[26:24]; end
        3'd5: begin j_bstr <= jv[31:16]; j_dstr <= jv[15:0]; end
        3'd6: j_val  <= jv;
        default: j_next <= jv[23:0];
    endcase
    wire        j_bport = (j_bk == 2'd1);
    wire        j_dport = (j_dk == 2'd1);
    // BKIND 2 and DKIND 2-3 are reserved; a port job takes B from memory or
    // its port (not VALUE), and its port is 0 or 1
    wire        j_bad   = (j_bk == 2'd2) || j_dk[1]
                        || ((j_bport || j_dport) && (j_bk == 2'd3 || (j_bport ? j_b : j_d) > 24'd1));

    assign blt_high  = j_high;

    // The running port job's port (its BPT or DPT: 0 or 1)
    wire        psel  = j_bport ? j_b[0] : j_d[0];
    wire        p_rxpop, p_txpush;
    assign p0_rxpop  = p_rxpop  && !psel;
    assign p1_rxpop  = p_rxpop  &&  psel;
    assign p0_txpush = p_txpush && !psel;
    assign p1_txpush = p_txpush &&  psel;

    // ================================================================ the other port
    // Word addresses: the custom block, by the register bus; the boot ROM
    // (0xF80000-0xF87FFF), read only. Reads come back in the order taken.
    wire [22:0] acc_a, xp_addr;
    wire        acc_we, xp_req, xp_we;
    wire [15:0] xp_wdata;
    wire [1:0]  xp_be;
    wire        xp_ok   = (acc_a[22:15] == 8'hE0) || (acc_a[22:14] == 9'b1111_1000_0 && !acc_we);
    wire        x_cust  = (xp_addr[22:15] == 8'hE0);
    reg         rr_v, rr_lo, rom_q, rom_v;
    // The register bus request is registered (as the CPU's and copper's
    // are): taken from the core's request, held until dx_go, which is the
    // core's acknowledge
    reg         dx_r, dx_we_r, dx_lo;
    reg  [23:2] dx_addr_r;
    reg  [31:0] dx_wdata_r;
    reg  [3:0]  dx_be_r;
    assign dx_req   = dx_r;
    assign dx_we    = dx_we_r;
    assign dx_addr  = dx_addr_r;
    assign dx_wdata = dx_wdata_r;
    assign dx_be    = dx_be_r;
    wire        dx_take  = xp_req && x_cust && !dx_r && !rom_q && !rom_v;
    wire        rom_take = xp_req && !x_cust;
    wire        xp_ack   = (dx_r && dx_go) || rom_take;
    always @(posedge clk) begin
        if (rst) begin
            rr_v <= 1'b0; rom_q <= 1'b0; rom_v <= 1'b0; rom_en <= 1'b0; dx_r <= 1'b0;
        end else begin
            if (dx_take) begin
                dx_r       <= 1'b1;
                dx_we_r    <= xp_we;
                dx_addr_r  <= xp_addr[22:1];
                dx_wdata_r <= {xp_wdata, xp_wdata};
                dx_be_r    <= xp_addr[0] ? {2'b00, xp_we ? xp_be : 2'b11} : {xp_we ? xp_be : 2'b11, 2'b00};
                dx_lo      <= xp_addr[0];
            end else if (dx_go)
                dx_r <= 1'b0;
            rr_v   <= dx_r && dx_go && !dx_we_r;
            if (dx_r && dx_go) rr_lo <= dx_lo;
            rom_q  <= rom_take;
            rom_en <= rom_take;
            if (rom_take) rom_addr <= xp_addr[13:0];
            rom_v  <= rom_q;
        end
    end
    wire        xp_rvalid = rr_v || rom_v;
    wire [15:0] xp_rdata  = rr_v ? (rr_lo ? rb_rdall[15:0] : rb_rdall[31:16]) : rom_rdata;

    // A descriptor in the descriptor RAM is read through the other port
    wire [23:0] cdesc  = da_q[24*cur +: 24];
    wire        dl_xok = (cdesc[23:11] == 13'b1110_0000_0110_0);

    // ================================================================ the core
    wire        en = dmacon[`RM_DMACON_DMAEN] && dmacon[`RM_DMACON_BLTEN];

    dmx_core #(.CHIP_WORDS({1'b0, CHIP_TOP[23:1]}), .LE(0), .MASKIMG(1), .XPORT(1), .PORTJOB(1),
               .LINE(0), .EDGES(0)) core (
        .clk(clk), .rst(rst),
        .enable(en), .pause(pause),
        .start_ld(s_ld), .start_run(s_run), .stop(s_stop),
        .clr_done(s_cdone), .clr_err(s_cerr),
        .da_we(dsc_w ? (4'd1 << rch) : 4'd0), .da_d(dsc_v[23:0]),
        .busy(busy), .done(done), .err(err), .da_q(da_q), .ea_q(ea_q),
        .irq_set(irq_set), .idle(idle), .cur(cur),
        .su_v(su_v), .su_i(su_i),
        .job_op(j_op), .job_minterm(j_mt), .job_sat(j_sat), .job_signed(j_sgn),
        .job_mask(j_mask), .job_bpp(j_bpp), .job_desc(j_desc), .job_irq(j_irq),
        .job_bconst(j_bk == 2'd3), .job_ymaj(1'b0), .job_xneg(1'b0), .job_yneg(1'b0),
        .job_value(j_val), .job_bstride(j_bstr), .job_dstride(j_dstr),
        .job_width({8'd0, j_width}), .job_height(j_height),
        .job_aaddr(j_a), .job_baddr(j_b), .job_daddr(j_d),
        .job_abit(j_abit), .job_bbit(j_bbit), .job_dbit(j_dbit), .job_next(j_next),
        .job_bport(j_bport), .job_dport(j_dport), .job_bad(j_bad),
        .clip_xmin(16'd0), .clip_xmax(16'd0), .clip_ymin(16'd0), .clip_ymax(16'd0),
        .dl_xok(dl_xok), .dl_v(dl_v), .dl_i(dl_i), .dl_w0(dl_w0), .dl_w1(dl_w1), .dl_wait(eng_jw),
        .mem_req(mem_req), .mem_we(mem_we), .mem_addr(mem_addr), .mem_wdata(mem_wdata), .mem_be(mem_be),
        .mem_ack(mem_ack), .mem_rvalid(mem_rvalid), .mem_rdata(mem_rdata),
        .acc_a(acc_a), .acc_we(acc_we), .xp_ok(xp_ok),
        .xp_req(xp_req), .xp_we(xp_we), .xp_addr(xp_addr), .xp_wdata(xp_wdata), .xp_be(xp_be),
        .xp_ack(xp_ack), .xp_rvalid(xp_rvalid), .xp_rdata(xp_rdata),
        .p_rxv(psel ? p1_rxv : p0_rxv), .p_rxd(psel ? p1_rxd : p0_rxd), .p_rxpop(p_rxpop),
        .p_txr(psel ? p1_txr : p0_txr), .p_txpush(p_txpush), .p_txd(p_txd)
    );
endmodule
