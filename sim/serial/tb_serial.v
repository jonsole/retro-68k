// serial.v on its own (spec 14, section 3): the PC's bytes through the
// FT232H model, the escapes and the control commands C0 c ~c. A port of the
// retro-z80 session's tb_serial.v to retro68k's 32-bit registers.
//   - a frame ending in 0x00 is all in the receive FIFO at once (the old
//     16-byte matcher held a trailing 0x00 back until the next byte)
//   - DB DC and DB DD give C0 and DB; other bytes are passed on as they are
//   - C0 01 FE, C0 02 FD, C0 03 FC give one BREAK, RESET and UPLOAD pulse,
//     and nothing reaches the FIFO; broken commands are dropped
//   - BREAK only with CTLEN; with CTLLOCK alone RESET and UPLOAD still work
//   - with CTLEN and CTLLOCK clear every byte, C0 and DB too, goes on raw
`timescale 1ns/1ps
`include "regmap.vh"
module tb_serial;
    reg clk = 0;
    always #5 clk = !clk;
    reg rst = 1;

    reg         rb_rd = 0, rb_wr = 0;
    reg  [23:2] rb_addr = 0;
    reg  [31:0] rb_wdata = 0;
    reg  [3:0]  rb_be = 0;
    wire [31:0] rb_rdata;
    wire        irq, cmd_break, cmd_reset, cmd_upload, p_rxv, p_txr;
    wire [7:0]  p_rxd;

    wire [7:0] ft_d;
    wire [7:0] ft_d_o;
    wire       ft_d_oe, ft_rd_n, ft_wr_n, ft_siwu_n, ft_rxf_n, ft_txe_n;
    assign ft_d = ft_d_oe ? ft_d_o : 8'hzz;

    serial dut (.clk(clk), .rst(rst), .us_tick(1'b0),
                .rb_rd(rb_rd), .rb_wr(rb_wr), .rb_addr(rb_addr), .rb_wdata(rb_wdata), .rb_be(rb_be),
                .rb_rdata(rb_rdata), .irq(irq),
                .cmd_break(cmd_break), .cmd_reset(cmd_reset), .cmd_upload(cmd_upload),
                .p_rxv(p_rxv), .p_rxd(p_rxd), .p_rxpop(1'b0), .p_txr(p_txr), .p_txpush(1'b0), .p_txd(8'h00),
                .ft_rxf_n(ft_rxf_n), .ft_txe_n(ft_txe_n), .ft_d_i(ft_d), .ft_d_o(ft_d_o), .ft_d_oe(ft_d_oe),
                .ft_rd_n(ft_rd_n), .ft_wr_n(ft_wr_n), .ft_siwu_n(ft_siwu_n));
    ft232h_model ft (.d(ft_d), .rxf_n(ft_rxf_n), .txe_n(ft_txe_n), .rd_n(ft_rd_n), .wr_n(ft_wr_n), .siwu_n(ft_siwu_n));

    integer errors = 0, nbrk = 0, nrst = 0, nupl = 0;
    always @(posedge clk) begin
        if (cmd_break)  nbrk = nbrk + 1;
        if (cmd_reset)  nrst = nrst + 1;
        if (cmd_upload) nupl = nupl + 1;
    end

    // System block registers (0xF00000 + offset), whole 32-bit accesses
    task wr(input [15:0] off, input [31:0] d);
        begin
            @(posedge clk); rb_addr <= {8'hF0, off[15:2]}; rb_wdata <= d; rb_be <= 4'b1111; rb_wr <= 1;
            @(posedge clk); rb_wr <= 0;
        end
    endtask
    reg [31:0] rd_val;
    task rd(input [15:0] off);
        begin
            @(posedge clk); rb_addr <= {8'hF0, off[15:2]}; rb_be <= 4'b1111; rb_rd <= 1;
            @(posedge clk); rb_rd <= 0;
            @(posedge clk); rd_val = rb_rdata;
        end
    endtask
    task idle;   // all the model's bytes read by the FPGA
        begin
            wait (ft.head == ft.tail);
            repeat (40) @(posedge clk);
        end
    endtask
    // the receive FIFO must hold exactly these n bytes; it is emptied after
    reg [7:0] want [0:31];
    task expect_rx(input integer n, input [8*40-1:0] what);
        integer i, have;
        begin
            idle;
            rd(`RM_SERSTAT);
            have = rd_val[27:16];
            if (have != n) begin
                $display("FAIL %0s: %0d bytes waiting, not %0d", what, have, n);
                errors = errors + 1;
            end
            for (i = 0; i < have; i = i + 1) begin
                rd(`RM_SERDATA);
                if (i < n && rd_val[7:0] !== want[i]) begin
                    $display("FAIL %0s: byte %0d is %h, not %h", what, i, rd_val[7:0], want[i]);
                    errors = errors + 1;
                end
            end
        end
    endtask
    task expect_cmds(input integer b, input integer r, input integer u, input [8*40-1:0] what);
        begin
            idle;
            if (nbrk != b || nrst != r || nupl != u) begin
                $display("FAIL %0s: BREAK %0d RESET %0d UPLOAD %0d, not %0d %0d %0d", what, nbrk, nrst, nupl, b, r, u);
                errors = errors + 1;
            end
            nbrk = 0; nrst = 0; nupl = 0;
        end
    endtask

    integer i;
    initial begin
        repeat (5) @(posedge clk);
        rst = 0;
        wr(`RM_SERCON, 32'h3);                    // EN, CTLEN

        // 1. a frame whose CRC ends in 0x00, with nothing after it
        ft.send(8'h4C); ft.send(8'h46); ft.send(8'h12); ft.send(8'h43); ft.send(8'h01);
        for (i = 0; i < 5; i = i + 1) ft.send(8'h00);
        ft.send(8'hFF); ft.send(8'hFF); ft.send(8'h55); ft.send(8'h42); ft.send(8'h14); ft.send(8'h00);
        want[0] = 8'h4C; want[1] = 8'h46; want[2] = 8'h12; want[3] = 8'h43; want[4] = 8'h01;
        for (i = 5; i < 10; i = i + 1) want[i] = 8'h00;
        want[10] = 8'hFF; want[11] = 8'hFF; want[12] = 8'h55; want[13] = 8'h42; want[14] = 8'h14; want[15] = 8'h00;
        expect_rx(16, "frame ending 0x00");

        // 2. escapes
        ft.send(8'hDB); ft.send(8'hDC); ft.send(8'h41); ft.send(8'hDB); ft.send(8'hDD); ft.send(8'hDB); ft.send(8'h42);
        want[0] = 8'hC0; want[1] = 8'h41; want[2] = 8'hDB; want[3] = 8'h42;
        expect_rx(4, "escapes");

        // 3. commands among data; nothing of them reaches the FIFO
        ft.send(8'h61); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE); ft.send(8'h62);
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hC0); ft.send(8'h03); ft.send(8'hFC); ft.send(8'h00);
        want[0] = 8'h61; want[1] = 8'h62; want[2] = 8'h00;
        expect_rx(3, "commands among data");
        expect_cmds(1, 1, 1, "commands among data");

        // 4. broken commands: dropped; a C0 starts again; DB then C0 is a command
        ft.send(8'hC0); ft.send(8'h05); ft.send(8'hFA);          // no such command
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFF);          // wrong inverse
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'hDB); ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'h63);
        want[0] = 8'h63;
        expect_rx(1, "broken commands");
        expect_cmds(1, 1, 0, "broken commands");

        // 5. CTLLOCK alone: RESET and UPLOAD, no BREAK; escapes still decoded
        wr(`RM_SERCON, 32'h5);                    // EN, CTLLOCK
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE);
        ft.send(8'hC0); ft.send(8'h02); ft.send(8'hFD);
        ft.send(8'hDB); ft.send(8'hDC);
        want[0] = 8'hC0;
        expect_rx(1, "CTLLOCK");
        expect_cmds(0, 1, 0, "CTLLOCK");

        // 6. raw: CTLEN and CTLLOCK clear (CTLLOCK needs a reset to clear)
        rst = 1; repeat (2) @(posedge clk); rst = 0;
        wr(`RM_SERCON, 32'h1);                    // EN only
        ft.send(8'hC0); ft.send(8'h01); ft.send(8'hFE); ft.send(8'hDB); ft.send(8'hDC);
        want[0] = 8'hC0; want[1] = 8'h01; want[2] = 8'hFE; want[3] = 8'hDB; want[4] = 8'hDC;
        expect_rx(5, "raw");
        expect_cmds(0, 0, 0, "raw");

        if (errors == 0 && ft.errors == 0) $display("TEST PASSED");
        else $display("TEST FAILED: %0d errors, %0d FT232H errors", errors, ft.errors);
        $finish;
    end
    initial begin #2000000 $display("TEST FAILED: timeout"); $finish; end
endmodule
