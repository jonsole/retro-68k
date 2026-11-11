// Interrupt controller at 0xF00000 (spec 13).
// 24 level-sensitive sources with their own vectors and programmable levels,
// plus an edge-triggered NMI (level 7) from the button and the USB break.
`include "regmap.vh"

module intc (
    input  wire        clk,
    input  wire        rst,

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire [23:0] req,            // request lines from the units (bit 18 is ignored: SOFT)
    input  wire        nmi_button,     // debounced, 1 = pressed
    input  wire        nmi_usb,        // 1-clock pulse: BREAK from the PC

    output reg  [2:0]  level,          // to the CPU's IPL (as a level, 0 = none)
    input  wire        iack,           // interrupt acknowledge (bus_if), 1 clock
    input  wire [2:0]  iack_level,
    output reg  [7:0]  iack_vector     // valid while iack is high
);
    localparam SRC_SOFT = 18;

    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hF0) && (off[15:8] == 8'h00);

    reg         master;
    reg  [23:0] intena;
    reg  [95:0] levels;               // 4 bits per source; bit 3 of each unused
    reg  [7:0]  vecbase;
    reg         soft;
    reg  [4:0]  intid;
    reg  [1:0]  nmicon, nmistat;
    reg         nmi_pend;
    reg         btn_d;

    wire [23:0] raw     = (req & ~(24'd1 << SRC_SOFT)) | ({23'd0, soft} << SRC_SOFT);
    // Registered, for timing: the requests come from logic all over the
    // chip, and the level and vector searches follow (one clock of latency)
    reg  [23:0] pending;
    always @(posedge clk) pending <= rst ? 24'd0 : raw & intena & {24{master}};

    function [2:0] lvl(input integer n);
        lvl = levels[4*n +: 3];
    endfunction

    // Highest level with a pending source: which levels have one (in
    // parallel, for timing), then the highest of them. Levels 0 and 7 count
    // as none.
    integer n, l;
    reg [6:1] at;
    reg [2:0] maxl;
    always @(*) begin
        at = 6'd0;
        for (n = 0; n < 24; n = n + 1)
            for (l = 1; l <= 6; l = l + 1)
                if (pending[n] && lvl(n) == l) at[l] = 1'b1;
        maxl = 3'd0;
        for (l = 1; l <= 6; l = l + 1)
            if (at[l]) maxl = l[2:0];
    end

    // Vector for an acknowledge at iack_level: the lowest pending source at that level
    reg [4:0] ack_src;
    reg       ack_found;
    always @(*) begin
        ack_found = 1'b0;
        ack_src   = 5'd0;
        for (n = 23; n >= 0; n = n - 1)
            if (pending[n] && lvl(n) == iack_level) begin
                ack_found = 1'b1;
                ack_src   = n[4:0];
            end
        if (iack_level == 3'd7)
            iack_vector = nmi_pend ? 8'd31 : 8'd24;
        else
            iack_vector = ack_found ? vecbase + ack_src : 8'd24;     // 24 = spurious
    end

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // Default levels (spec 13, section 4), nibble per source, source 0 lowest
    localparam [95:0] LEVELS_DEFAULT = {
        20'h00000,                                    // 23-19: off
        4'd1, 4'd2, 4'd2, 4'd3,                       // 18 SOFT, 17 KEYB, 16 SD, 15 SERIAL
        4'd6, 4'd6, 4'd6, 4'd6,                       // 14-11 timers
        4'd4, 4'd4, 4'd4,                             // 10-8 audio
        4'd4, 4'd4, 4'd4, 4'd4,                       // 7-5 not used, 4 blitter
        4'd5, 4'd5, 4'd5, 4'd5 };                     // 3-0 video

    always @(posedge clk) begin
        btn_d <= nmi_button;
        if (rst) begin
            master   <= 1'b0;
            intena   <= 24'd0;
            levels   <= LEVELS_DEFAULT;
            vecbase  <= 8'd64;
            soft     <= 1'b0;
            intid  <= 5'd0;
            nmicon   <= 2'b11;
            nmistat  <= 2'b00;
            nmi_pend <= 1'b0;
            level    <= 3'd0;
        end else begin
            // NMI: one per press or break
            if (nmi_button && !btn_d && nmicon[0]) begin nmi_pend <= 1'b1; nmistat[0] <= 1'b1; end
            if (nmi_usb && nmicon[1])              begin nmi_pend <= 1'b1; nmistat[1] <= 1'b1; end

            if (iack) begin
                if (iack_level == 3'd7) nmi_pend <= 1'b0;
                else if (ack_found)     intid  <= ack_src;
            end

            level <= nmi_pend ? 3'd7 : maxl;

            if (rb_wr && sel) case (off)
                `RM_INTCON:  if (rb_be[0]) master <= rb_wdata[0];
                // Two set/clear halves (spec 13, section 7), each written on its own:
                // bit 15 sets or clears sources 0-14 (bits 14-0), bit 31 sources 15-23 (bits 24-16)
                `RM_INTENA: begin
                    if (rb_be[1:0] == 2'b11) begin
                        if (rb_wdata[15]) intena[14:0] <= intena[14:0] |  rb_wdata[14:0];
                        else              intena[14:0] <= intena[14:0] & ~rb_wdata[14:0];
                    end
                    if (rb_be[3:2] == 2'b11) begin
                        if (rb_wdata[31]) intena[23:15] <= intena[23:15] |  rb_wdata[24:16];
                        else              intena[23:15] <= intena[23:15] & ~rb_wdata[24:16];
                    end
                end
                `RM_INTPRI0: levels[31:0]  <= merge(levels[31:0],  rb_wdata, rb_be) & 32'h77777777;
                `RM_INTPRI1: levels[63:32] <= merge(levels[63:32], rb_wdata, rb_be) & 32'h77777777;
                `RM_INTPRI2: levels[95:64] <= merge(levels[95:64], rb_wdata, rb_be) & 32'h77777777;
                `RM_VECBASE: if (rb_be[0]) vecbase <= rb_wdata[7:0];
                `RM_SOFTINT: if (rb_be[0]) begin
                    if (rb_wdata[0]) soft <= 1'b1;
                    if (rb_wdata[1]) soft <= 1'b0;
                end
                `RM_NMICON:  if (rb_be[0]) nmicon <= rb_wdata[1:0];
                `RM_NMISTAT: if (rb_be[0]) nmistat <= nmistat & ~rb_wdata[1:0];
                default: ;
            endcase
        end

        rb_rdata <= 32'd0;
        if (rb_rd && sel) case (off)
            `RM_INTCON:    rb_rdata <= {31'd0, master};
            `RM_INTENA:    rb_rdata <= {7'd0, intena[23:15], 1'b0, intena[14:0]};
            `RM_INTPEND:   rb_rdata <= {7'd0, pending[23:15], 1'b0, pending[14:0]};
            `RM_INTRAW:    rb_rdata <= {7'd0, raw[23:15], 1'b0, raw[14:0]};
            `RM_INTPRI0: rb_rdata <= levels[31:0];
            `RM_INTPRI1: rb_rdata <= levels[63:32];
            `RM_INTPRI2: rb_rdata <= levels[95:64];
            `RM_VECBASE:   rb_rdata <= {24'd0, vecbase};
            `RM_INTID:   rb_rdata <= {27'd0, intid};
            `RM_NMICON:    rb_rdata <= {30'd0, nmicon};
            `RM_NMISTAT:   rb_rdata <= {30'd0, nmistat};
            default: ;
        endcase
    end
endmodule
