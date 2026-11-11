// Timers at 0xF00100 (spec 12): 64-bit time counter, 4 general timers,
// watchdog.
`include "regmap.vh"

module timers (
    input  wire        clk,            // 100 MHz
    input  wire        por,            // the time counter only starts at power-on
    input  wire        rst,            // device reset: the general timers
    input  wire        wd_rst,         // full reset: the watchdog too (not the RESET instruction)

    input  wire        rb_rd,
    input  wire        rb_wr,
    input  wire [23:2] rb_addr,
    input  wire [31:0] rb_wdata,
    input  wire [3:0]  rb_be,
    output reg  [31:0] rb_rdata,

    input  wire        us_tick,        // 1 clock every microsecond
    input  wire        line_tick,      // 1 clock at the start of each video line
    input  wire        frame_tick,     // 1 clock at the start of each vertical blank

    output wire [3:0]  irq,            // TIMER0-3
    output reg         wd_reset        // 1 clock: the watchdog resets the computer
);
    wire [15:0] off = {rb_addr[15:2], 2'b00};
    wire sel = (rb_addr[23:16] == 8'hF0) && (off[15:9] == 7'd0) && (off[8] == 1'b1);   // 0x100-0x1FF
    wire is_tmr = (off >= 16'h0140) && (off < 16'h01C0);

    function [31:0] merge(input [31:0] old, input [31:0] new, input [3:0] be);
        merge = { be[3] ? new[31:24] : old[31:24], be[2] ? new[23:16] : old[23:16],
                  be[1] ? new[15:8]  : old[15:8],  be[0] ? new[7:0]   : old[7:0] };
    endfunction

    // ---------------------------------------------------------------- time counter
    reg [63:0] time_c;
    reg [31:0] time_lo_cap, time_hi_cap;
    always @(posedge clk) time_c <= por ? 64'd0 : time_c + 1'b1;

    // ---------------------------------------------------------------- general timers
    reg [4:0]  ctrl     [0:3];         // IRQ, SRC, REPEAT, EN
    reg [15:0] prescale [0:3];
    reg [15:0] pre_c    [0:3];
    reg [31:0] reload   [0:3];
    reg [31:0] count    [0:3];
    reg [3:0]  under;                  // STAT.UNDER, sticky
    reg [3:0]  uf;                     // underflow this clock (chains to the next timer)

    assign irq = under & {ctrl[3][4], ctrl[2][4], ctrl[1][4], ctrl[0][4]};

    // Ticks per timer
    reg [3:0] tick;
    integer n;
    always @(*) for (n = 0; n < 4; n = n + 1)
        case (ctrl[n][3:2])
            2'd0: tick[n] = (pre_c[n] == 16'd0);
            2'd1: tick[n] = line_tick;
            2'd2: tick[n] = frame_tick;
            2'd3: tick[n] = uf[(n + 3) % 4];      // the previous timer (timer 0 counts timer 3)
        endcase

    // ---------------------------------------------------------------- watchdog
    reg        wd_en, wd_lock;
    reg [15:0] wd_time, wd_left;
    reg [9:0]  ms_div;
    wire       ms_tick = us_tick && (ms_div == 10'd999);

    always @(posedge clk) begin
        uf        <= 4'd0;
        wd_reset  <= 1'b0;
        // Watchdog countdown (before the register writes below, so a kick wins)
        if (us_tick) ms_div <= (ms_div == 10'd999) ? 10'd0 : ms_div + 1'b1;
        if (wd_en && ms_tick) begin
            if (wd_left == 16'd0) wd_reset <= 1'b1;
            else wd_left <= wd_left - 1'b1;
        end
        if (rst) begin
            for (n = 0; n < 4; n = n + 1) begin
                ctrl[n]     <= 5'd0;
                prescale[n] <= 16'd0;
                pre_c[n]    <= 16'd0;
                reload[n]   <= 32'd0;
                count[n]    <= 32'd0;
            end
            under   <= 4'd0;
        end else begin
            // Timers
            for (n = 0; n < 4; n = n + 1) begin
                pre_c[n] <= (pre_c[n] == 16'd0) ? prescale[n] : pre_c[n] - 1'b1;
                if (ctrl[n][0] && tick[n]) begin
                    if (count[n] == 32'd0) begin
                        uf[n]    <= 1'b1;
                        under[n] <= 1'b1;
                        if (ctrl[n][1]) count[n] <= reload[n];
                        else            ctrl[n][0] <= 1'b0;       // one-shot: stop
                    end else
                        count[n] <= count[n] - 1'b1;
                end
            end

            if (rb_wr && sel) begin
                if (is_tmr) begin : wtimer                     // 0x140-0x1BF: timers
                    integer t;
                    reg [31:0] v;
                    t = (off - 16'h0140) >> 5;
                    case (off[4:0])
                        5'h00: begin v = merge({27'd0, ctrl[t]}, rb_wdata, rb_be); ctrl[t] <= v[4:0];
                                     if (v[0] && !ctrl[t][0]) pre_c[t] <= prescale[t]; end
                        5'h04: begin v = merge({16'd0, prescale[t]}, rb_wdata, rb_be); prescale[t] <= v[15:0]; end
                        5'h08: reload[t] <= merge(reload[t], rb_wdata, rb_be);
                        5'h0C: count[t]  <= merge(count[t],  rb_wdata, rb_be);
                        5'h10: if (rb_be[0] && rb_wdata[0]) under[t] <= 1'b0;
                        default: ;
                    endcase
                end else case (off)
                    `RM_WDCTRL: if (!wd_lock && rb_be[0]) begin
                        wd_en   <= rb_wdata[0];
                        wd_lock <= rb_wdata[1];
                        wd_left <= wd_time;
                    end
                    `RM_WDTIME: if (!wd_lock) begin : wwt
                        reg [31:0] v;
                        v = merge({16'd0, wd_time}, rb_wdata, rb_be);
                        wd_time <= v[15:0];
                    end
                    `RM_WDKICK: if (wd_en) begin
                        if (rb_be[1:0] == 2'b11 && rb_wdata[15:0] == 16'h5A5A) wd_left <= wd_time;
                        else wd_reset <= 1'b1;                    // a wrong kick resets at once
                    end
                    default: ;
                endcase
            end
        end

        // Watchdog: only a full reset stops it (after the writes above, so it wins)
        if (wd_rst) begin
            wd_en    <= 1'b0;
            wd_lock  <= 1'b0;
            wd_time  <= 16'd1000;
            wd_left  <= 16'd1000;
            ms_div   <= 10'd0;
            wd_reset <= 1'b0;
        end

        // Reads. Reading TIMEHI captures the low half for TIMELO (spec 12, section 3).
        rb_rdata <= 32'd0;
        if (rb_rd && sel) begin
            if (is_tmr) begin : rtimer
                integer t;
                t = (off - 16'h0140) >> 5;
                case (off[4:0])
                    5'h00: rb_rdata <= {27'd0, ctrl[t]};
                    5'h04: rb_rdata <= {16'd0, prescale[t]};
                    5'h08: rb_rdata <= reload[t];
                    5'h0C: rb_rdata <= count[t];
                    5'h10: rb_rdata <= {31'd0, under[t]};
                    default: ;
                endcase
            end else case (off)
                // the high half captures all 64 bits; the rest come from the capture
                `RM_TIMEHI: if (rb_be[3:2] != 2'b00) begin
                                rb_rdata    <= time_c[63:32];
                                time_hi_cap <= time_c[63:32];
                                time_lo_cap <= time_c[31:0];
                            end else
                                rb_rdata <= time_hi_cap;
                `RM_TIMELO: rb_rdata <= time_lo_cap;
                `RM_WDCTRL: rb_rdata <= {30'd0, wd_lock, wd_en};
                `RM_WDTIME: rb_rdata <= {16'd0, wd_time};
                default: ;
            endcase
        end
    end
endmodule
