// SD card: an SPI byte master (spec 15). 100 MHz.
//
// SPI mode 0, most significant bit first: SCLK rests low, MOSI changes
// after a falling edge (the first bit before the first rising edge), MISO
// is sampled at each rising edge. A byte goes out and one comes in at the
// same time; software does the commands, answers and blocks.
//
// A byte is clocked when the CPU writes SDDATA.
//
// MISO is taken through one input register at the edge SCLK rises: the
// card changed it after the falling edge half a period before, so it is
// steady there even at 25 MHz.
`include "regmap.vh"

module sdspi (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    // The card
    output reg         sd_sclk,
    output reg         sd_mosi,
    input  wire        sd_miso,
    output wire        sd_cs0_n,
    output wire        sd_cs1_n
);
    wire [15:0] off  = {rb_addr[15:2], 2'b00};
    wire        sel  = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h03);

    reg         en, cs0, cs1;
    reg  [7:0]  clkdiv;
    reg  [7:0]  rxd;                   // the last byte received

    assign sd_cs0_n = !(en && cs0);
    assign sd_cs1_n = !(en && cs1);

    // The shifter
    reg         busy;                  // a byte is being clocked
    reg  [7:0]  tx, rx;
    reg  [2:0]  bitn;
    reg  [7:0]  hc;                    // half-period counter
    reg         samp;                  // take MISO this clock (SCLK rose last clock)
    reg         miso_q;
    always @(posedge clk) miso_q <= sd_miso;
    wire [7:0]  half = (clkdiv < 8'd2) ? 8'd2 : clkdiv;

    wire        go       = en && !busy && rb_wr && sel && off == `RM_SDDATA && rb_be[0];

    always @(posedge clk) begin
        if (rst) begin
            en <= 1'b0; cs0 <= 1'b0; cs1 <= 1'b0; clkdiv <= 8'd125;
            rxd <= 8'hFF;
            busy <= 1'b0; sd_sclk <= 1'b0; sd_mosi <= 1'b1; samp <= 1'b0;
        end else begin
            samp <= 1'b0;
            if (go) begin
                busy    <= 1'b1;
                tx      <= rb_wdata[7:0];
                sd_mosi <= rb_wdata[7];
                bitn    <= 3'd0;
                hc      <= 8'd1;
            end else if (busy) begin
                if (hc == half) begin
                    hc <= 8'd1;
                    if (!sd_sclk) begin
                        sd_sclk <= 1'b1;           // rising: the card's bit is taken next clock
                        samp    <= 1'b1;
                    end else begin
                        sd_sclk <= 1'b0;           // falling: the next bit out, or the end
                        if (bitn == 3'd7) begin
                            busy <= 1'b0;
                            rxd  <= rx;
                        end else begin
                            bitn    <= bitn + 1'b1;
                            sd_mosi <= tx[6 - bitn];
                        end
                    end
                end else
                    hc <= hc + 1'b1;
            end
            if (samp) rx <= {rx[6:0], miso_q};
            if (!en) begin
                busy <= 1'b0; sd_sclk <= 1'b0;
            end

            if (rb_wr && sel && off == `RM_SDCON) begin
                if (rb_be[0]) begin en <= rb_wdata[0]; cs0 <= rb_wdata[1]; cs1 <= rb_wdata[2]; end
                if (rb_be[1]) clkdiv <= rb_wdata[15:8];
            end
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_SDCON:   rb_rdata <= {16'd0, clkdiv, 5'd0, cs1, cs0, en};
            `RM_SDDATA:  rb_rdata <= {23'd0, busy, rxd};
            default: ;
        endcase
    end
endmodule
