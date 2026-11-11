// Boot ROM: 32 KB of block RAM, loaded with the bitstream (spec 7, section 3).
// Writable with byte enables when SYSCON.ROMWE is set (checked by bus_if).
module bootrom #(
    parameter INIT = "boot.hex"     // 16K lines of 16-bit hex words
) (
    input  wire        clk,
    input  wire        en,
    input  wire [1:0]  we,          // [1] = D15-8
    input  wire [14:1] addr,
    input  wire [15:0] wdata,
    output reg  [15:0] rdata
);
    reg [15:0] mem [0:16383];
    initial $readmemh(INIT, mem);

    always @(posedge clk) if (en) begin
        if (we[1]) mem[addr][15:8] <= wdata[15:8];
        if (we[0]) mem[addr][7:0]  <= wdata[7:0];
        rdata <= mem[addr];
    end
endmodule
