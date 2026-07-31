# Per-channel (4-stem) audio out

Mirror of RetroPlug's [`spec/10-multichannel-audio-out.md`](https://github.com/peterswimm/retroplug).
RetroPlug can export a single Game Boy's four sound channels as four independent stereo pairs
(its `ChannelSplit` audio routing) so each voice can be mixed/effected separately in the DAW.
This brings the same capability to Chromatic hardware over USB.

## Where the mix happens

The Game Boy APU has four channels: **Square 1, Square 2, Wave, Noise**. In the MiSTer core
they are produced by four `apu_dac` instances and summed in exactly one place —
`esp32t/src/rtl/EMU/CORE/gbc_snd.vhd`, the `mixer` process (~lines 1646–1687):

```vhdl
sq1_dac : apu_dac port map (..., dac_output=>sq1_dac_out);
sq2_dac : apu_dac port map (..., dac_output=>sq2_dac_out);
wav_dac : apu_dac port map (..., dac_output=>wav_dac_out);
noi_dac : apu_dac port map (..., dac_output=>noi_dac_out);

mixer : process (sq1_dac_out, sq2_dac_out, wav_dac_out, noi_dac_out, ch_map, ch_vol)
  -- NR51 panning mask (ch_map) selects L/R per channel;
  -- NR50 master volume (ch_vol) scales the summed result.
```

`sq1_dac_out … noi_dac_out` are **internal signals**, not ports. This is the identical seam
RetroPlug taps in SameBoy's `apu.c` — the concept ports over even though the code is net-new
VHDL.

## Design

Expose the four channels as four NR51/NR50-scaled stereo pairs, **without changing the existing
mix** (`snd_left`/`snd_right` stay byte-identical — exactly as RetroPlug keeps the mixed
callback identical so the speaker output is unaffected).

1. **`gbc_snd.vhd`** — refactor the mixer so each channel's L/R contribution is available as a
   new output port (`ch1_l/ch1_r … ch4_l/ch4_r`, or a packed `channels` bus). The existing
   summation into `snd_left/snd_right` is kept as-is.
2. **`gb.v`** (~line 480, the `gbc_snd audio(...)` instance; ports at ~line 71) — thread the
   four new buses up alongside `audio_l/audio_r`.
3. **`emu_system_top.v`** (~lines 46, 286, 335) — expose `ch1..ch4` stereo buses next to
   `left/right`. Filter each stem through its **own `audio_filter` instance** (the existing IIR
   + DC-blocker), so a stem matches the tone of the mix. This is the analog of RetroPlug's
   per-stem high-pass.
4. **USB UAC widening** — promote the audio input terminal from 2 to 8 channels:
   - `USB/USBUVCUART/usb_video/uac_defs.v` — `UAC_PACKET_SIZE` scales with channel count
     (44100 Hz, 16-bit, now 8ch).
   - `USB/USBUVCUART/usb_video/usb_descriptor_video.v` — `bNrChannels` on the input terminal
     (~line 470) 2 → 8, with a channel-config bitmap.
   - `USB/USBUVCUART/usbuvcuart_top.v` — the `usbuac_ep` sample-fetch path (`sample_get_p`,
     ~line 1372) reads 8 samples per frame instead of 2.
   - **Keep a 2ch alt-setting** so OBS/Discord/macOS capture still see a normal stereo mic.
5. **`top.v`** — fan the four stems into `usbuvcuart_top` (~line 618); the I2S codec path
   (`aud_system_top`, ~line 340) keeps taking only the mix (the speaker is unchanged).

## Channel → stereo-pair mapping (matches RetroPlug ChannelSplit)

| USB channel pair | GB channel |
|---|---|
| 1–2 | Square 1 |
| 3–4 | Square 2 |
| 5–6 | Wave |
| 7–8 | Noise |

## Verification

- **Golden vectors:** `retroplug-cli render --split channels <rom> out.wav` produces the
  reference per-channel WAVs. A `gbc_snd` stem-tap simulation (given a simulator) is compared
  against them; without a simulator this is a review-only mapping check.
- **Regression:** confirm `snd_left/snd_right` are bit-identical before/after (the speaker mix
  must not change).

## Resource note

Four extra `audio_filter` instances (IIR biquad + DC-blocker each). If the GW5A-25A PnR
utilization is tight, time-multiplex a single filter across the four stems at the ~7 MHz
filter rate (there is ample clock headroom). Decide against the actual utilization report.
