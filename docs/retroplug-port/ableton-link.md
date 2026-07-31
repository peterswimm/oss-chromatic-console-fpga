# Ableton Link tempo sync

[Ableton Link](https://www.ableton.com/en/link/) synchronizes tempo, beat, and phase across
apps and devices on a shared network — Ableton Live, iOS/Android music apps, other Link
peers. This design makes the Chromatic follow a Link session, so its LSDj tempo locks to the
rest of a jam wirelessly.

## PoC: Link on the host, over USB CDC

For the proof-of-concept, **Link runs on the host, not the console.** The rationale:

- The Chromatic's base ESP32 has **no native USB** — all USB is the FPGA soft-PHY, reached
  from the ESP32 only through an internal UART bridge. Running a network stack on the ESP32
  for the PoC would mean bringing up WiFi + lwip, which is out of scope for a first cut.
- **RetroPlug already contains the LSDj-sync engine.** Rather than reimplement timing, the
  host bridge *is* RetroPlug: it runs the Link session and feeds Link's tempo/beat/playing into
  the same `SetBpm`/`SetTransport` path its plugin uses for DAW transport, driving the existing
  `lsdj-sync` role unchanged.

### Data flow

```
Ableton Live / phone / other Link peers
        │  (Ableton Link session, LAN)
        ▼
RetroPlug host bridge  (retroplug-cli linksync)
  • Link C++ SDK → beat/phase/tempo/playing
  • lsdj-sync role → LSDj serial byte stream   (existing code, unchanged)
  • CDC serial sink → /dev/ttyACM0
        │  (USB CDC — the composite device already exposes this)
        ▼
FPGA soft-USB → internal UART → ESP32
  • FPGA_Tx_SendSync() → 0x8F packet
        ▼
FPGA linksync.sv → GB link serial → LSDj (external-clock slave)
```

### Sync-command protocol (host ↔ device)

The host writes a compact framed stream to the CDC device. Suggested framing (documented so
both the MCU relay and the FPGA `linksync` block agree):

```
0xF5  <mode>  <len>  <byte0 … byteN>   # sync frame over CDC
      mode : LsdjSyncMode (midiSync / midiSyncArduinoboy / midiMap / midiPassthrough / ...)
      len  : payload length
      bytes: the LSDj/MIDI serial bytes to inject
```

The ESP32 (`FPGA_Tx_SendSync`) re-wraps the payload into the FPGA's `0x8F` V2 UART packet with
a new sync address (see [midi-sync.md](midi-sync.md#mcu--fpga-command-channel)). `0xF5` is a
placeholder — pick a marker that can't collide with the CDC's existing flashing/debug use.

### Semantics to mirror

The host reproduces RetroPlug's `lsdj-sync` behavior (already implemented — this is reuse, not
new logic):

- **tempoDivisor** — LSDj clock is 24-PPQN subdivided by the project's divisor.
- **autoStart** — tap Start on the transport rising edge (Link `playing` false→true).
- **Arduinoboy note-gate** — `0xFA`/`0xFC` play/stop bracketing in `midiSyncArduinoboy`.
- **MIDI-map** — row bytes + `0xFE` in `midiMap`.

## <a name="future-on-device-link"></a>Future: on-device Link (no host)

The base ESP32 is **dual-core**, which satisfies Link's hard requirement (single-core S2/C3
lack the lock-free atomics `abl_link` needs), so the console can become a *standalone* Link
peer later:

- Add `abl_link` (or `esp_abl_link`) as an ESP-IDF managed component.
- Enable WiFi + lwip in `sdkconfig.defaults` (fits 4 MB flash but tightens the budget —
  verify); `esp_wifi_ps_set` to disable modem sleep for multicast reliability; WiFi
  credentials via NVS/provisioning.
- A `link_task` `xTaskCreatePinnedToCore`'d to core 0 (mirroring the LVGL task pinned to core 1
  in `main/main.c`), converting Link beat/phase → the same sync command already consumed by
  `linksync`.

Only the *tempo source* changes — the `linksync` injector and the sync-command format are
identical, so the on-device path reuses everything built for the PoC.

An intermediate option that avoids WiFi is **USB networking** (a CDC-NCM/ECM class added to the
FPGA composite, with the ESP32 running lwip over the internal bridge). It works for Link's tiny
multicast packets but requires net-new USB-class RTL and is throttled by the internal UART —
documented as an alternative, not recommended for the first on-device cut.
