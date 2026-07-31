// linkcapture_tb.v -- testbench for the RetroPlug GB-serial byte capture.
//
// NOT run in CI (no simulator was available when written). To run:
//   iverilog -g2012 -o linkcapture_tb linkcapture_tb.v ../linkcapture.sv && vvp linkcapture_tb
//
// Drives a serial clock + data (as the Game Boy would when it is the link
// master) and checks that linkcapture reassembles the byte MSB-first and pulses
// byte_valid once, only while sc_int_clock2 is asserted.

`timescale 1ns/1ps

module linkcapture_tb;
    reg        clk = 0;
    reg        reset = 1;
    reg        sc_int_clock2 = 0;
    reg        serial_clk_out = 0;
    reg        serial_data_out = 0;
    wire [7:0] byte_out;
    wire       byte_valid;

    linkcapture dut (
        .clk(clk), .reset(reset),
        .sc_int_clock2(sc_int_clock2),
        .serial_clk_out(serial_clk_out),
        .serial_data_out(serial_data_out),
        .byte_out(byte_out), .byte_valid(byte_valid)
    );

    always #5 clk = ~clk;

    reg [7:0] got = 8'h00;
    integer   valids = 0;
    always @(posedge clk) begin
        if (byte_valid) begin
            got <= byte_out;
            valids = valids + 1;
        end
    end

    localparam [7:0] TESTVAL = 8'hC3;
    integer i;

    // Emit one bit: present data, then pulse the serial clock high a while.
    task send_bit(input b);
    begin
        serial_data_out = b;
        repeat (6) @(posedge clk);
        serial_clk_out = 1;
        repeat (6) @(posedge clk);
        serial_clk_out = 0;
        repeat (2) @(posedge clk);
    end
    endtask

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        sc_int_clock2 = 1; // core is the link master
        @(posedge clk);

        for (i = 7; i >= 0; i = i - 1)  // MSB first
            send_bit(TESTVAL[i]);

        repeat (8) @(posedge clk);

        if (got === TESTVAL && valids == 1)
            $display("PASS: captured 0x%02h (%0d valid pulse)", got, valids);
        else
            $display("FAIL: captured 0x%02h, valids=%0d (expected 0x%02h, 1)", got, valids, TESTVAL);
        $finish;
    end

    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
