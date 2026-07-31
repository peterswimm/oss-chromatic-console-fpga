# MIDI + LSDj sync

Two related capabilities:

- **LSDj sync** — drive LSDj's tempo/transport from the host (the core PoC feature).
- **USB-MIDI** — mGB (MIDI → GB synth) and MIDI-out (Arduinoboy MI.OUT / MasterSync).

Both ride the Game Boy **serial link port**, which the MiSTer core already exposes and the
Chromatic already routes to the physical link connector.

## The link-port serial hook

`top.v` pins `LINK_CLK` / `LINK_IN` / `LINK_OUT` / `LINK_SD` → `emu_system_top.v` (~lines
242–265) → the core serial port (`serial_clk_in/out`, `serial_data_in/out`, and the
`sc_int_clock2` internal-vs-external clock select) in `EMU/CORE/link.v`:

```verilog
assign LINK_CLK      = sc_int_clock2_r1 ? serial_clk_out_r1 : 1'bZ;
assign serial_clk_in = LINK_CLK_r1;
wire serial_data_in  = LINK_IN_r1;
assign LINK_OUT      = serial_data_out_r1;
```

When LSDj runs as an external-clock slave, it consumes bytes clocked in on `serial_clk_in` /
`serial_data_in`. That is precisely the injection point for hardware sync — and it is exactly
how Arduinoboy syncs a real Game Boy today.

## LSDj sync (the timing brain)

**The host owns the timing.** RetroPlug's `lsdj-sync` DSP role
(`retroplug/packages/retroplug/src/dspRoles.ts`, with the sample-accurate `walkTicks` clock in
`dspKernel.ts`) already turns transport into the exact LSDj byte stream: 24-PPQN `0xF8` clock
scaled by a tempo divisor, Arduinoboy note-gated `0xFA`/`0xFC` play/stop, and MIDI-map row
bytes. Reusing it (see [ableton-link.md](ableton-link.md)) means the FPGA does **not** compute
timing — it just shifts the host's bytes onto the link at GB-serial rate.

### `linksync.sv` (new, `esp32t/src/rtl/BSP/`)

A GB-serial **byte injector**:

- Accepts a byte (+ mode flag) from the MCU protocol.
- Drives `serial_clk_in` / `serial_data_in` into the core, clocking 8 bits at GB-serial rate
  (with `sc_int_clock2` selecting external clock).
- LSDj-as-slave consumes them; no timing logic lives here.
- **Reused later:** when on-device Link lands, the same injector is fed by an on-chip clock
  generator instead of the MCU stream.

### MCU → FPGA command channel

Extend the existing `0x8F` (V2) UART packet protocol in
`esp32t/src/rtl/BSP/system_monitor.sv` (framing = start `0x8F` + 7-bit address + byte count +
data + CRC; RX map ~lines 115–148). Add a new RX address:

| Field | Bytes | Meaning |
|---|---|---|
| mode | 1 | `LsdjSyncMode` (midiSync / arduinoboy / midiMap / passthrough / …) |
| serial byte(s) | N | the LSDj/MIDI bytes to shift out |

This is the **same mechanism the firmware already uses to inject buttons** (`FPGA_Tx_PokeButtons`
/ `MCU_buttons`), so MCU→FPGA control injection is a proven pattern.

`top.v` instantiates `linksync` and wires it between the protocol decoder and the emu serial
pins.

### <a name="timing"></a>Timing / jitter

Host → USB-CDC → internal UART → GB-serial adds latency and jitter that RetroPlug's in-process
serial pump doesn't have. LSDj tolerates a degree of clock jitter, but the PoC **must measure**
end-to-end jitter (compare the injected clock's period stability against
`tools/reaper-timing-analyze.py`-style analysis on captured audio). If audible:

- Send a slightly-ahead schedule and let `linksync` reclock each tick from a local timer, or
- Move clock generation on-device (a step toward on-device Link).

Do not pre-solve — flag and measure first.

## MIDI over the CDC/UART transport (what the PoC builds)

MIDI rides the **same CDC → 0x8F-UART path as sync**, both directions — no new USB class is
needed to demo mGB or MIDI-out, and it stays on the proven, low-risk transport.

- **Host → device (mGB / raw serial): already covered by `linksync`.** The injector shifts
  *any* byte onto the GB link, so RetroPlug's `mgb` role (which forwards every MIDI byte
  verbatim into GB serial) simply sends its bytes down the same RX-address-0xE path. No extra
  RTL — mGB is a mode of the existing sync stream.
- **Device → host (MIDI-out / MasterSync): `linkcapture.sv` (new).** When the core is the
  serial *master* (`sc_int_clock2` = 1, LSDj driving the clock), `linkcapture` deserializes
  `serial_clk_out`/`serial_data_out` into bytes and hands them to `system_monitor`, which
  forwards them to the MCU on a **new FPGA→MCU TX channel 10** (following the existing
  `request_gpd` clear-on-send pattern). The MCU relays them over CDC to RetroPlug, which
  decodes them exactly like its `ArduinoboyMaster` MI.OUT / `masterSync` roles.
  Instantiated in `emu_system_top.v`; wired through `top.v`.

## Native USB-MIDI class (deferred — future work)

A proper USB-MIDI (MIDIStreaming) interface — bulk IN/OUT endpoints of 32-bit USB-MIDI event
packets added to the composite config + `endpt_sel` mux in `usbuvcuart_top.v` and the
descriptors in `usb_descriptor_video.v` (the `USB_AUDIO_MIDISTREAMING` constant already exists
at `uac_defs.v:7`) — is the cleaner long-term transport and lets a DAW see the Chromatic as a
native MIDI device. It is **not built in the PoC**: it is a high-risk change to a working USB
descriptor/enumeration path that cannot be validated without hardware, and the CDC transport
already carries MIDI both ways. Deferred deliberately, same posture as the 8ch UAC widening.
