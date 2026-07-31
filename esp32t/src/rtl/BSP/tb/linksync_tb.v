// linksync_tb.v -- testbench for the RetroPlug GB-serial byte injector.
//
// NOT run in CI (no simulator was available when written). To run:
//   iverilog -g2012 -o linksync_tb linksync_tb.v ../linksync.sv && vvp linksync_tb
//
// Checks that a byte loaded via {byte_in, byte_valid} is shifted out MSB-first
// on serial_data, with 8 rising edges on serial_clk, and that the sampled bits
// reconstruct the original byte. Uses a tiny CLK_HZ/SERIAL_HZ ratio so the sim
// is short.

`timescale 1ns/1ps

module linksync_tb;
    reg        clk = 0;
    reg        reset = 1;
    reg  [7:0] byte_in = 8'h00;
    reg        byte_valid = 0;
    reg        enable = 0;
    wire       ready, sync_active, serial_clk, serial_data;

    // 16 clocks per half-bit -> fast sim.
    linksync #(.CLK_HZ(16*2*1000), .SERIAL_HZ(1000)) dut (
        .clk(clk), .reset(reset),
        .byte_in(byte_in), .byte_valid(byte_valid), .enable(enable),
        .ready(ready), .sync_active(sync_active),
        .serial_clk(serial_clk), .serial_data(serial_data)
    );

    always #5 clk = ~clk;

    // Sample serial_data on each rising edge of serial_clk; reassemble MSB-first.
    reg [7:0] captured = 8'h00;
    integer   bits = 0;
    reg       clk_d = 1;
    always @(posedge clk) begin
        clk_d <= serial_clk;
        if (serial_clk && !clk_d && sync_active) begin  // rising edge
            captured <= {captured[6:0], serial_data};
            bits = bits + 1;
        end
    end

    localparam [7:0] TESTVAL = 8'hF8; // an LSDj MIDI clock byte

    initial begin
        repeat (4) @(posedge clk);
        reset = 0;
        enable = 1;
        @(posedge clk);
        // Load one byte.
        byte_in = TESTVAL;
        byte_valid = 1;
        @(posedge clk);
        byte_valid = 0;

        // Wait for all 8 bits to clock out.
        wait (bits == 8);
        repeat (4) @(posedge clk);

        if (captured === TESTVAL)
            $display("PASS: injected 0x%02h, captured 0x%02h", TESTVAL, captured);
        else
            $display("FAIL: injected 0x%02h, captured 0x%02h", TESTVAL, captured);

        if (bits !== 8)
            $display("FAIL: expected 8 serial-clock edges, got %0d", bits);

        $finish;
    end

    // Watchdog.
    initial begin
        #200000;
        $display("FAIL: timeout");
        $finish;
    end
endmodule
