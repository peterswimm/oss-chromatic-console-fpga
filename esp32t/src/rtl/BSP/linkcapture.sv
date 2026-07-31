// linkcapture.sv
//
// RetroPlug MIDI-out / LSDj MasterSync: a Game Boy serial-link BYTE CAPTURE.
//
// The device->host direction of the sync bridge. When LSDj runs in a mode where
// the Game Boy is the serial MASTER (MasterSync, or Arduinoboy MI.OUT), it drives
// the link's serial clock and data out. This block deserializes that stream back
// into bytes so the ESP32 can forward them to the host (RetroPlug), which turns
// them into MIDI -- mirroring RetroPlug's ArduinoboyMaster MI.OUT decoder and
// masterSync role.
//
// It watches the core's serial_clk_out; on each rising edge (while the core is the
// clock master, sc_int_clock2 = 1) it samples serial_data_out MSB-first into a byte
// and pulses byte_valid when 8 bits have accumulated. Purely a deserializer -- no
// interpretation. Not validated on hardware.

module linkcapture (
    input  wire       clk,          // sample/domain clock (e.g. hClk)
    input  wire       reset,

    // From the core's serial port (as seen in emu_system_top)
    input  wire       sc_int_clock2, // 1 = GB is serial master (driving the link)
    input  wire       serial_clk_out,
    input  wire       serial_data_out,

    // To system_monitor -> MCU (a new FPGA->MCU TX channel) -> host
    output reg  [7:0] byte_out,
    output reg        byte_valid     // 1-cycle pulse when byte_out is complete
);

    // Synchronize the (core-domain) serial clock/data into this clock and detect
    // rising edges of the serial clock.
    reg clk_s0, clk_s1, clk_s2;
    reg dat_s0, dat_s1;
    reg active_s0, active_s1;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            clk_s0 <= 0; clk_s1 <= 0; clk_s2 <= 0;
            dat_s0 <= 0; dat_s1 <= 0;
            active_s0 <= 0; active_s1 <= 0;
        end else begin
            clk_s0 <= serial_clk_out;  clk_s1 <= clk_s0;  clk_s2 <= clk_s1;
            dat_s0 <= serial_data_out;  dat_s1 <= dat_s0;
            active_s0 <= sc_int_clock2;  active_s1 <= active_s0;
        end
    end

    wire serial_clk_rise = clk_s1 & ~clk_s2;

    reg [7:0] shreg;
    reg [3:0] bit_cnt;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            shreg     <= 8'd0;
            bit_cnt   <= 4'd0;
            byte_out  <= 8'd0;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            if (!active_s1) begin
                // Not mastering the link -- reset the bit assembler.
                bit_cnt <= 4'd0;
            end else if (serial_clk_rise) begin
                shreg   <= {shreg[6:0], dat_s1}; // MSB-first
                if (bit_cnt == 4'd7) begin
                    bit_cnt   <= 4'd0;
                    byte_out  <= {shreg[6:0], dat_s1};
                    byte_valid <= 1'b1;
                end else begin
                    bit_cnt <= bit_cnt + 1'b1;
                end
            end
        end
    end

endmodule
