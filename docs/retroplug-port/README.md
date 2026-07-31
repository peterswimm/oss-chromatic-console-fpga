# Porting RetroPlug features to the Chromatic

This directory documents a proof-of-concept effort to bring
[RetroPlug](https://github.com/peterswimm/retroplug)'s *music-production* capabilities to the
ModRetro Chromatic. RetroPlug is a DAW plugin that hosts a Game Boy emulator (SameBoy) and
wires it up for [LSDj](https://www.littlesounddj.com/) / mGB / Arduinoboy music production. The
Chromatic is a *hardware* Game Boy Color: the MiSTer GBC core on a Gowin GW5A-25A FPGA,
supervised by an ESP32 MCU.

Today the Chromatic can only be **captured** — it streams video + audio to a host over USB as
a webcam + microphone. The goal here is to make it **playable by a DAW**: multi-tracked stems,
MIDI, and tempo sync (via Ableton Link).

> **Status: design + prototype.** None of the RTL/firmware here has been synthesized or run on
> hardware — see [Caveats](#caveats). The host-side bridge (in the RetroPlug repo) is the only
> part that runs end-to-end in a normal dev environment.

## The three repos

| Repo | Role |
|---|---|
| `oss-chromatic-console-fpga` (this repo) | Per-channel audio tap, USB-MIDI, the GB-serial sync injector |
| `oss-chromatic-console-mcu` | ESP32 firmware — relays the host sync stream to the FPGA |
| `retroplug` | The host bridge: runs Ableton Link and streams LSDj sync over USB; also the behavioral reference + golden-vector source |

## Feature map

Each RetroPlug feature, where it lands on the Chromatic, and its feasibility.

| RetroPlug feature | Chromatic landing spot | Feasibility |
|---|---|---|
| **Per-channel (4-stem) audio out** | Tap the 4 APU DAC channels in `gbc_snd.vhd` before the mixer; widen USB UAC to 8ch | **Net-new RTL** — see [audio-multichannel.md](audio-multichannel.md) |
| **LSDj sync** (MIDI / Arduinoboy / MIDI-map / Master) | Host (RetroPlug) computes the LSDj serial byte stream; a new `linksync` block injects it onto the GB link | **Net-new RTL + firmware** — see [midi-sync.md](midi-sync.md) |
| **Ableton Link tempo sync** | Runs on the *host* (RetroPlug + Link SDK); streamed over the existing USB CDC | **Host software** — see [ableton-link.md](ableton-link.md) |
| **mGB** (MIDI → GB synth) | USB-MIDI OUT → GB serial in | **Net-new RTL** — see [midi-sync.md](midi-sync.md) |
| **MIDI out** (Arduinoboy MI.OUT / MasterSync) | GB serial out → USB-MIDI IN | **Net-new RTL** |
| USB audio streaming | `USB/USBUVCUART/` UAC (already present, 2ch) | **Ships** (extended to 8ch) |
| Palettes / color | ESP32-loaded palette LUTs (already present) | **Ships** |
| SRAM / saves | Physical cartridge battery | **Ships** (hardware) |
| Multi-instance grid | — (one core, one cartridge) | **Non-goal** |
| DAW-plugin / CLAP / VST shell | — (the host DAW connects over USB instead) | **Non-goal** |
| `.rplg` project persistence | — | **Non-goal** |
| Virtual link cable *between instances* | The real link port is used instead | **Non-goal** |
| LSDj `.sav` codec / SRAM auto-save | Physical cartridge | **Non-goal** |
| LSDj sample-kit compiler | Possible ESP32-side, but writes GB memory (hard against a real cart) | **Future / unbuilt** |

RetroPlug's own sync modes (`LsdjSyncMode` in `retroplug/packages/retroplug/src/settingsEnums.ts`)
carried by this design: `midiSync`, `midiSyncArduinoboy`, `midiMap`, `midiPassthrough`,
`midiOut`, `masterSync` (`keyboard`/`keyboardMidi` are host-side only). The 8-channel audio
mirrors RetroPlug's `ChannelSplit` routing (`AudioRouting.hpp`, value 3).

## Architecture

```
  ┌─────────────────────────┐        USB (existing composite device)
  │ Host: RetroPlug + Link   │   ┌──────────────────────────────────────┐
  │  • Ableton Link session  │   │ UVC video │ UAC audio │ CDC │ (+MIDI) │
  │  • lsdj-sync byte stream ├───┤           │  2→8 ch   │     │         │
  │  • retroplug-cli linksync│   └─────┬─────┴─────┬─────┴──┬──┴────┬────┘
  └─────────────────────────┘         │           │        │       │
                                  (video)     per-channel  sync   MIDI
                                                audio      bytes
                                                  │         │       │
                             ┌────────────────────┴─────────┴───────┴────┐
                             │ FPGA (GW5A-25A)                            │
                             │  gbc_snd 4-stem tap → USB UAC 8ch          │
                             │  linksync injector → GB link serial ← MIDI │
                             └───────────────┬────────────────────────────┘
                                             │ UART (0x8F protocol)
                                     ┌───────┴────────┐
                                     │ ESP32 MCU      │  relays sync bytes
                                     │ FPGA_Tx_SendSync│  (Link is NOT here in the PoC)
                                     └────────────────┘
```

The **host owns all timing intelligence** (RetroPlug already has the sample-accurate LSDj-sync
engine); the device is a thin byte injector. This mirrors how Arduinoboy syncs real Game Boys
over the link port today.

## Roadmap

1. **Design docs** (this directory). ✅
2. **Per-channel audio** — `gbc_snd.vhd` tap + 8ch UAC. Verifiable against
   `retroplug-cli render --split channels` golden WAVs.
3. **GB-serial sync injector** (`linksync.sv`) + MCU relay + RetroPlug Link/CDC bridge — the
   end-to-end sync PoC.
4. **USB-MIDI** — mGB in, MIDI out.
5. **Future:** on-device Ableton Link (ESP32 WiFi/lwip, or USB-Ethernet), so the Chromatic is
   a standalone Link peer with no host. See [ableton-link.md](ableton-link.md#future-on-device-link).

## Budget notes

- **USB bandwidth:** the existing High-Speed soft-PHY already carries UVC video. 8ch audio =
  44100 × 8 × 2 B = **706 KB/s**, plus small USB-MIDI packets — comfortably within HS.
- **FPGA resources (GW5A-25A):** the additions are small (4 extra `audio_filter` instances, a
  byte-shifter `linksync` block, wider UAC buffering, a MIDI interface). Utilization is not
  derivable from this repo (`impl/` and the timing report are not fully checked in); **confirm
  against the Gowin PnR utilization report before committing to the 4 extra filter instances**
  — if tight, time-multiplex one filter across the stems.

## Caveats

- **Not synthesized, not flashed.** No Gowin IDE (v1.9.9.03 required), no ESP-IDF v5.3, no
  hardware were available when this was written. RTL and firmware are prototypes verified by
  review + (where a simulator is available) per-module testbenches; the RetroPlug host bridge
  is the piece that actually builds and runs.
- **Version bumps are mandatory.** Any RTL change bumps the 14-bit version in
  `esp32t/src/rtl/BSP/system_monitor.sv`; any firmware change bumps
  `CONFIG_CHROMATIC_FW_VER_STR` — otherwise the ModRetro Update Tool reconciliation breaks.
- **Timing/jitter is unmeasured.** Host→USB→UART→GB-serial adds latency/jitter vs. RetroPlug's
  in-process path. LSDj tolerates some jitter; the PoC must measure it. See
  [midi-sync.md](midi-sync.md#timing).

## Portability

The **host half** (RetroPlug + Link) is device-agnostic — its output is an LSDj/Arduinoboy
sync byte stream, which is *already* a hardware protocol over the Game Boy link port. So the
same bridge can drive a real Game Boy (via an Arduinoboy-style adapter), a MiSTer, or an
Analogue Pocket. The **device half** is specific: MiSTer shares this exact `gbc_snd.vhd` core
(the audio tap ports nearly 1:1) but has different audio/USB I/O; the Analogue Pocket uses
different cores under openFPGA (concepts transfer, code is a reimplementation).
