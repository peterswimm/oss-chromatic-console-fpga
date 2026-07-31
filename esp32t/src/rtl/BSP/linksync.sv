// linksync.sv
//
// RetroPlug LSDj sync: a Game Boy serial-link BYTE INJECTOR.
//
// The host (RetroPlug) owns all timing: it runs Ableton Link / DAW transport
// and produces the exact LSDj serial byte stream (24-PPQN 0xF8 clock, Arduinoboy
// 0xFA/0xFC, MIDI-map rows) -- see docs/retroplug-port/midi-sync.md. Those bytes
// arrive over USB CDC -> ESP32 -> the 0x8F UART packet protocol -> system_monitor
// (RX address 0xE) -> here. This block just shifts each byte onto the Game Boy
// link as an external clock master, exactly as an Arduinoboy would, so LSDj (in an
// external-clock slave sync mode) consumes it.
//
// No timing intelligence lives here. When on-device Ableton Link is added later,
// the same injector can be driven by an on-chip clock generator instead of the MCU.
//
// Serial format: 8 bits, MSB first. The link idles clock-high; data is presented
// while the clock is low and is stable across the low->high (rising) edge on which
// the Game Boy slave samples. Bit rate defaults to the normal GB serial clock
// (8192 Hz). Not validated on hardware.

module linksync #(
    parameter integer CLK_HZ    = 16777216, // hClk domain
    parameter integer SERIAL_HZ = 8192      // GB normal-speed serial clock
)(
    input  wire       clk,
    input  wire       reset,

    // From system_monitor (RX address 0xE)
    input  wire [7:0] byte_in,
    input  wire       byte_valid,   // 1-cycle pulse: load byte_in
    input  wire       enable,       // hold the link (sync_mode != off)

    // To emu_system_top serial injection mux
    output reg        ready,        // idle and able to accept a byte
    output reg        sync_active,  // drive the link instead of the physical port
    output reg        serial_clk,   // -> core serial_clk_in when sync_active
    output reg        serial_data   // -> core serial_data_in when sync_active
);

    // Half-bit period: one full serial clock = HALF low + HALF high.
    localparam integer HALF   = (CLK_HZ / (SERIAL_HZ * 2));
    localparam integer HALFM1 = (HALF <= 1) ? 0 : HALF - 1;

    // Counter wide enough to hold HALFM1 (0 .. HALF-1).
    localparam integer CW = (HALF <= 1) ? 1 : $clog2(HALF);

    localparam [1:0] IDLE  = 2'd0;
    localparam [1:0] LOW   = 2'd1;  // clock low phase (present data bit)
    localparam [1:0] HIGH  = 2'd2;  // clock high phase (slave samples)

    reg [1:0]      state;
    reg [7:0]      shreg;
    reg [3:0]      bit_cnt;   // bits remaining (0..8)
    reg [CW-1:0]   div;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            state       <= IDLE;
            shreg       <= 8'd0;
            bit_cnt     <= 4'd0;
            div         <= {CW{1'b0}};
            ready       <= 1'b1;
            sync_active <= 1'b0;
            serial_clk  <= 1'b1; // idle high
            serial_data <= 1'b1;
        end else begin
            sync_active <= enable;

            case (state)
                IDLE: begin
                    ready      <= 1'b1;
                    serial_clk <= 1'b1; // idle high between bytes
                    if (enable && byte_valid) begin
                        shreg       <= byte_in;
                        bit_cnt     <= 4'd8;
                        div         <= {CW{1'b0}};
                        ready       <= 1'b0;
                        serial_data <= byte_in[7]; // present MSB
                        serial_clk  <= 1'b0;       // begin low phase
                        state       <= LOW;
                    end
                end

                LOW: begin
                    serial_clk  <= 1'b0;
                    serial_data <= shreg[7];
                    if (div == HALFM1[CW-1:0]) begin
                        div        <= {CW{1'b0}};
                        serial_clk <= 1'b1;  // rising edge: slave samples this bit
                        state      <= HIGH;
                    end else begin
                        div <= div + 1'b1;
                    end
                end

                HIGH: begin
                    serial_clk <= 1'b1;
                    if (div == HALFM1[CW-1:0]) begin
                        div     <= {CW{1'b0}};
                        shreg   <= {shreg[6:0], 1'b1}; // shift next bit up
                        bit_cnt <= bit_cnt - 1'b1;
                        if (bit_cnt == 4'd1) begin
                            state <= IDLE; // byte complete
                            ready <= 1'b1;
                        end else begin
                            serial_data <= shreg[6]; // next bit (post-shift MSB)
                            serial_clk  <= 1'b0;
                            state       <= LOW;
                        end
                    end else begin
                        div <= div + 1'b1;
                    end
                end

                default: state <= IDLE;
            endcase
        end
    end

endmodule
