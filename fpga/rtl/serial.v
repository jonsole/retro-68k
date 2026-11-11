// USB serial through an FT232H in asynchronous 245 FIFO mode (spec 14):
// retro68k's registers on retro-hw's serial_link (FIFOs and the command
// decoder) and ft232h_if (the FT232H pins). See fpga/retro-hw/docs/spec.
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
    output wire        cmd_break,      // 1 clock each: control commands from the PC
    output wire        cmd_reset,
    output wire        cmd_upload,

    // FT232H pins
    input  wire        ft_rxf_n,
    input  wire        ft_txe_n,
    input  wire [7:0]  ft_d_i,
    output wire [7:0]  ft_d_o,
    output wire        ft_d_oe,
    output wire        ft_rd_n,
    output wire        ft_wr_n,
    output wire        ft_siwu_n
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

    // ---------------------------------------------------------------- the engine
    wire        rx_pop = rb_rd && sel && off == `RM_SERDATA && rb_be[0];   // the low half takes a byte
    wire        tx_wr  = rb_wr && sel && off == `RM_SERDATA && rb_be[0];

    wire        fe_rx_valid, fe_rx_room, fe_tx_valid, fe_tx_pop, fe_tx_empty;
    wire [7:0]  fe_rx_byte, fe_tx_byte;
    wire        rx_valid, rx_new, tx_full, tx_dropped;
    wire [7:0]  rx_rdata;
    wire [11:0] rx_count, tx_space;

    serial_link #(.AW(11), .RX_MARGIN(18), .KEY_CMD(0)) link (
        .clk(clk), .rst(rst), .rx_clear(rst), .tx_clear(rst),
        .ctl_en(sercon[1]), .ctl_lock(sercon[2]), .tx_en(en), .drop_oldest(sercon[3]),
        .fe_rx_valid(fe_rx_valid), .fe_rx_byte(fe_rx_byte), .fe_rx_room(fe_rx_room),
        .fe_tx_valid(fe_tx_valid), .fe_tx_byte(fe_tx_byte), .fe_tx_pop(fe_tx_pop),
        .fe_tx_empty(fe_tx_empty),
        .rx_valid(rx_valid), .rx_byte(rx_rdata), .rx_pop(rx_pop), .rx_new(rx_new),
        .rx_count(rx_count),
        .tx_push(tx_wr), .tx_byte(rb_wdata[7:0]), .tx_full(tx_full),
        .tx_dropped(tx_dropped), .tx_space(tx_space),
        .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
        .cmd_key(), .key_byte()
    );

    ft232h_if fe (
        .clk(clk), .rst(rst), .en(en),
        .rx_valid(fe_rx_valid), .rx_byte(fe_rx_byte), .rx_room(fe_rx_room),
        .tx_valid(fe_tx_valid), .tx_byte(fe_tx_byte), .tx_pop(fe_tx_pop), .tx_empty(fe_tx_empty),
        .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d_i), .ft_d_o(ft_d_o),
        .ft_d_oe(ft_d_oe), .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n)
    );

    // ---------------------------------------------------------------- interrupts
    wire s_rxready = (rxlevel != 0) && (rx_count >= rxlevel);
    wire s_txready = (txlevel != 0) && (tx_space >= txlevel);
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
            if (tx_dropped) dropcount <= dropcount + 1'b1;

            if (rx_new || rx_pop || rx_count == 0 || s_rxready) idle_us <= 16'd0;
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
            `RM_SERSTAT:  rb_rdata <= {4'd0, rx_count, 4'd0, tx_space};
            `RM_SERDATA:  rb_rdata <= rx_valid ? {24'd0, rx_rdata} : 32'h100;
            `RM_SERLEVEL: rb_rdata <= {4'd0, rxlevel, 4'd0, txlevel};
            `RM_SERTIME:  rb_rdata <= {16'd0, sertime};
            `RM_SERIRQ:   rb_rdata <= {28'd0, irqflags};
            `RM_SERIRQEN: rb_rdata <= {28'd0, irqen};
            `RM_SERDROP:  rb_rdata <= {16'd0, dropcount};
            default: ;
        endcase
    end
endmodule
