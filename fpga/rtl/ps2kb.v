// PS/2 keyboard (spec 16): retro68k's registers on retro-hw's ps2_core
// (fpga/retro-hw/docs/spec/ps2_core.md), which receives, sends and keeps
// the 16-byte FIFO.
`include "regmap.vh"

module ps2kb (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire        ps2_clk_i,
    input  wire        ps2_data_i,
    output wire        ps2_clk_low,    // pull the clock line low
    output wire        ps2_data_low,   // pull the data line low

    output wire        irq
);
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire        sel = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h04);

    reg         en;
    reg  [4:0]  irqf;                  // TIMEOUT 4, OVERFLOW 3, FRAME 2, PARITY 1 (DATA, bit 0, is live)
    reg  [4:0]  irqen;

    wire [7:0]  fifo_byte;
    wire [4:0]  fifo_count;
    wire        tx_busy, rx_frame_err, rx_parity_err, fifo_overflow, tx_timeout;
    wire        fifo_pop = rb_rd && sel && off == `RM_KBDATA && rb_be[0];   // the low half takes a byte
    wire        tx_req   = rb_wr && sel && off == `RM_KBSEND && rb_be[0];

    ps2_core core (
        .clk(clk), .rst(rst), .en(en), .rx_en(en),
        .ps2_clk_i(ps2_clk_i), .ps2_data_i(ps2_data_i),
        .ps2_clk_low(ps2_clk_low), .ps2_data_low(ps2_data_low),
        .rx_stb(), .rx_byte(),
        .rx_frame_err(rx_frame_err), .rx_parity_err(rx_parity_err),
        .ins_stb(1'b0), .ins_byte(8'd0),
        .fifo_byte(fifo_byte), .fifo_count(fifo_count), .fifo_pop(fifo_pop),
        .fifo_overflow(fifo_overflow),
        .tx_req(tx_req), .tx_byte(rb_wdata[7:0]), .tx_busy(tx_busy), .tx_timeout(tx_timeout)
    );

    assign irq = |({irqf[4:1], fifo_count != 5'd0} & irqen);

    always @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; irqf <= 5'd0; irqen <= 5'd0;
        end else begin
            if (rx_parity_err) irqf[1] <= 1'b1;
            if (rx_frame_err)  irqf[2] <= 1'b1;
            if (fifo_overflow) irqf[3] <= 1'b1;
            if (tx_timeout)    irqf[4] <= 1'b1;
            if (rb_wr && sel && rb_be[0]) case (off)
                `RM_KBCON:   en <= rb_wdata[0];
                `RM_KBIRQ:   irqf <= irqf & ~rb_wdata[4:0];
                `RM_KBIRQEN: irqen <= rb_wdata[4:0];
                default: ;
            endcase
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_KBCON:   rb_rdata <= {31'd0, en};
            `RM_KBSTAT:  rb_rdata <= {23'd0, tx_busy, 3'd0, fifo_count};
            `RM_KBDATA:  rb_rdata <= (fifo_count != 5'd0) ? {24'd0, fifo_byte} : 32'h100;
            `RM_KBIRQ:   rb_rdata <= {27'd0, irqf[4:1], fifo_count != 5'd0};
            `RM_KBIRQEN: rb_rdata <= {27'd0, irqen};
            default: ;
        endcase
    end
endmodule
