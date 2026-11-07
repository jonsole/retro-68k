// USB serial through an FT232H in asynchronous 245 FIFO mode (spec 14).
`include "regmap.vh"

module serial (
    input  wire        clk,            // 100 MHz
    input  wire        rst,            // device reset
    input  wire        us_tick,        // 1 clock every microsecond

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    output wire        irq,
    output reg         cmd_break,      // 1 clock each: control commands from the PC
    output reg         cmd_reset,
    output reg         cmd_upload,

    // DMA engine port 1 (spec 11, section 4): the CPU's own accesses go first
    output wire        p_rxv,
    output wire [7:0]  p_rxd,
    input  wire        p_rxpop,
    output wire        p_txr,
    input  wire        p_txpush,
    input  wire [7:0]  p_txd,

    // FT232H pins
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output reg  [7:0]  ft_d_o,
    output reg         ft_d_oe,
    output reg         ft_rd_n,
    output reg         ft_wr_n,
    output reg         ft_siwu_n
);
    // ---------------------------------------------------------------- registers
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h02);

    reg  [3:0]  sercon;                // TXDROP, CTLLOCK, CTLEN, EN
    reg  [11:0] rxlevel, txlevel;
    reg  [15:0] sertime;
    reg  [3:0]  irqen;
    reg         f_rxtimeout, f_txovf;
    reg  [15:0] dropcount;

    wire en = sercon[0];

    // ---------------------------------------------------------------- FIFOs
    reg         rx_push;  reg [7:0] rx_wdata;
    wire        rx_cpu = rb_rd && sel && off == `RM_SERDATA && rb_be[0];   // the low half takes a byte
    wire        rx_pop = rx_cpu || p_rxpop;
    wire [7:0]  rx_rdata;
    wire [12:0] rx_count;
    wire        rx_full, rx_valid;
    fifo8 #(.AW(11)) rx_fifo (.clk(clk), .rst(rst), .push(rx_push), .wdata(rx_wdata),
                          .pop(rx_pop), .rdata(rx_rdata), .count(rx_count), .full(rx_full),
                          .valid(rx_valid));

    wire        tx_cpu  = rb_wr && sel && off == `RM_SERDATA && rb_be[0];
    wire        tx_wr   = tx_cpu || p_txpush;
    reg         tx_pop_ft;
    wire [7:0]  tx_rdata;
    wire [12:0] tx_count;
    wire        tx_full, tx_valid;
    wire        tx_drop = tx_wr && tx_full && sercon[3];
    fifo8 #(.AW(11)) tx_fifo (.clk(clk), .rst(rst), .push(tx_wr && en), .wdata(tx_cpu ? rb_wdata[7:0] : p_txd),
                          .pop(tx_pop_ft || tx_drop), .rdata(tx_rdata), .count(tx_count), .full(tx_full),
                          .valid(tx_valid));

    assign p_rxv = rx_valid && !rx_cpu;
    assign p_rxd = rx_rdata;
    assign p_txr = en && !tx_full && !tx_cpu;
    wire [11:0] rxcount = (rx_count > 13'd2048) ? 12'd2048 : rx_count[11:0];
    wire [11:0] txspace = (tx_count >= 13'd2048) ? 12'd0 : 12'd2048 - tx_count[11:0];

    // ---------------------------------------------------------------- interrupts
    wire s_rxready = (rxlevel != 0) && (rxcount >= rxlevel);
    wire s_txready = (txlevel != 0) && (txspace >= txlevel);
    wire [3:0] irqflags = {f_txovf, s_txready, f_rxtimeout, s_rxready};
    assign irq = |(irqflags & irqen);

    // Receive timeout: bytes waiting below RXLEVEL with nothing new for SERTIME us
    reg [15:0] idle_us;

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    always @(posedge clk) begin
        if (rst) begin
            sercon      <= 4'b0010;          // CTLEN on after reset
            rxlevel     <= 12'd0;
            txlevel     <= 12'd0;
            sertime     <= 16'd0;
            irqen       <= 4'd0;
            f_rxtimeout <= 1'b0;
            f_txovf     <= 1'b0;
            dropcount   <= 16'd0;
            idle_us     <= 16'd0;
        end else begin
            if (tx_wr && tx_full && !sercon[3]) f_txovf <= 1'b1;
            if (tx_drop) dropcount <= dropcount + 1'b1;

            if (rx_push || rx_pop || rxcount == 0 || s_rxready) idle_us <= 16'd0;
            else if (us_tick && idle_us != 16'hFFFF) idle_us <= idle_us + 1'b1;
            if (sertime != 0 && idle_us == sertime && us_tick) f_rxtimeout <= 1'b1;

            if (rb_wr && sel) case (off)
                `RM_SERCON: begin : wcon
                    reg [31:0] v;
                    v = merge({28'd0, sercon}, rb_wdata, rb_be);
                    sercon <= {v[3], sercon[2] | v[2], v[1:0]};   // CTLLOCK stays set until reset
                end
                `RM_SERLEVEL: begin : wlev
                    reg [31:0] v;
                    v = merge({4'd0, rxlevel, 4'd0, txlevel}, rb_wdata, rb_be);
                    rxlevel <= v[27:16];
                    txlevel <= v[11:0];
                end
                `RM_SERTIME: begin : wtim
                    reg [31:0] v;
                    v = merge({16'd0, sertime}, rb_wdata, rb_be);
                    sertime <= v[15:0];
                end
                `RM_SERIRQ: if (rb_be[0]) begin
                    if (rb_wdata[1]) f_rxtimeout <= 1'b0;
                    if (rb_wdata[3]) f_txovf     <= 1'b0;
                end
                `RM_SERIRQEN: if (rb_be[0]) irqen <= rb_wdata[3:0];
                default: ;
            endcase
            if (rb_rd && sel && off == `RM_SERDROP && rb_be[0]) dropcount <= 16'd0;   // the low half clears it
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_SERCON:   rb_rdata <= {28'd0, sercon};
            `RM_SERSTAT:  rb_rdata <= {4'd0, rxcount, 4'd0, txspace};
            `RM_SERDATA:  rb_rdata <= rx_valid ? {24'd0, rx_rdata} : 32'h100;
            `RM_SERLEVEL: rb_rdata <= {4'd0, rxlevel, 4'd0, txlevel};
            `RM_SERTIME:  rb_rdata <= {16'd0, sertime};
            `RM_SERIRQ:   rb_rdata <= {28'd0, irqflags};
            `RM_SERIRQEN: rb_rdata <= {28'd0, irqen};
            `RM_SERDROP:  rb_rdata <= {16'd0, dropcount};
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- control commands and escapes
    // With recognition on (CTLEN or CTLLOCK) the PC's bytes are SLIP-style
    // (section 3): C0 c ~c is a control command, DB DC a data C0, DB DD a data
    // DB. Every other byte goes on at once, so no data byte waits for the next
    // one. A broken command is dropped; a C0 always starts a command again.
    // (The same as retro-z80's serial.v, which found that the old 16-byte
    // matcher held back a frame's last byte when it was 0x00.)
    localparam [7:0] B_END = 8'hC0, B_ESC = 8'hDB, B_ESC_END = 8'hDC, B_ESC_ESC = 8'hDD;
    localparam [1:0] D_DATA = 2'd0, D_ESC = 2'd1, D_CMD = 2'd2, D_INV = 2'd3;

    wire        match_on = sercon[1] || sercon[2];
    reg  [1:0]  ds;
    reg  [7:0]  mc;            // the command byte

    reg         in_valid;      // a byte from the FT232H
    reg  [7:0]  in_byte;

    always @(posedge clk) begin
        rx_push    <= 1'b0;
        cmd_break  <= 1'b0;
        cmd_reset  <= 1'b0;
        cmd_upload <= 1'b0;
        if (rst) begin
            ds <= D_DATA;
        end else if (in_valid) begin
            if (!match_on) begin
                rx_push <= 1'b1; rx_wdata <= in_byte;
                ds <= D_DATA;
            end else if (in_byte == B_END) begin
                ds <= D_CMD;
            end else case (ds)
                D_DATA: if (in_byte == B_ESC) ds <= D_ESC;
                        else begin rx_push <= 1'b1; rx_wdata <= in_byte; end
                D_ESC: begin
                    rx_push  <= 1'b1;
                    rx_wdata <= (in_byte == B_ESC_END) ? B_END : (in_byte == B_ESC_ESC) ? B_ESC : in_byte;
                    ds       <= D_DATA;
                end
                D_CMD: begin
                    mc <= in_byte;
                    ds <= D_INV;
                end
                default: begin   // D_INV
                    ds <= D_DATA;
                    if (in_byte == ~mc && mc >= 8'd1 && mc <= 8'd3) begin
                        cmd_break  <= (mc == 8'd1) && sercon[1];
                        cmd_reset  <= (mc == 8'd2);
                        cmd_upload <= (mc == 8'd3);
                    end
                end
            endcase
        end
    end

    // ---------------------------------------------------------------- FT232H
    // RXF# and TXE# are asynchronous: two-flop synchronisers.
    reg [1:0] rxf_s, txe_s;
    always @(posedge clk) begin
        rxf_s <= {rxf_s[0], ft_rxf_n};
        txe_s <= {txe_s[0], ft_txe_n};
    end
    wire rxf = !rxf_s[1];
    wire txe = !txe_s[1];

    // Read : RD# low 8 clocks (80 ns), data taken at the end, then 8 clocks high.
    // Write: data out; WR# high 3 clocks, low 5 clocks (the FT232H takes the
    //        byte as WR# falls), then data released and 8 clocks of recovery.
    localparam F_IDLE = 2'd0, F_READ = 2'd1, F_WRITE = 2'd2, F_REC = 2'd3;
    reg [1:0] fs;
    reg [3:0] ft_t;
    reg       sent;            // bytes went out since the last send-immediate
    reg [1:0] siwu_t;
    wire      rx_room = (rx_count < 13'd2030) && !in_valid;

    always @(posedge clk) begin
        in_valid  <= 1'b0;
        tx_pop_ft <= 1'b0;
        if (rst) begin
            fs        <= F_IDLE;
            ft_rd_n   <= 1'b1;
            ft_wr_n   <= 1'b1;
            ft_d_oe   <= 1'b0;
            ft_siwu_n <= 1'b1;
            sent      <= 1'b0;
            siwu_t    <= 2'd0;
        end else begin
            // Send immediate: when the transmit FIFO has emptied
            if (siwu_t != 0) begin
                siwu_t <= siwu_t - 1'b1;
                if (siwu_t == 2'd1) ft_siwu_n <= 1'b1;
            end else if (sent && tx_count == 0 && fs == F_IDLE) begin
                ft_siwu_n <= 1'b0;
                siwu_t    <= 2'd3;
                sent      <= 1'b0;
            end

            case (fs)
                F_IDLE: begin
                    ft_t <= 4'd0;
                    if (en && rxf && rx_room) begin
                        ft_rd_n <= 1'b0;
                        fs      <= F_READ;
                    end else if (en && txe && tx_valid && siwu_t == 0) begin
                        ft_d_o  <= tx_rdata;
                        ft_d_oe <= 1'b1;
                        fs      <= F_WRITE;
                    end
                end
                F_READ: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) begin
                        in_byte  <= ft_d_i;
                        in_valid <= 1'b1;
                        ft_rd_n  <= 1'b1;
                        ft_t     <= 4'd0;
                        fs       <= F_REC;
                    end
                end
                F_WRITE: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd2) ft_wr_n <= 1'b0;
                    if (ft_t == 4'd7) begin
                        ft_wr_n   <= 1'b1;
                        ft_d_oe   <= 1'b0;
                        tx_pop_ft <= 1'b1;
                        sent      <= 1'b1;
                        ft_t      <= 4'd0;
                        fs        <= F_REC;
                    end
                end
                F_REC: begin
                    ft_t <= ft_t + 1'b1;
                    if (ft_t == 4'd7) fs <= F_IDLE;
                end
            endcase
        end
    end
endmodule
