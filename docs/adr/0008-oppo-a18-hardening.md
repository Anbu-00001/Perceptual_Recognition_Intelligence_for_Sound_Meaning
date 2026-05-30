# ADR 0008 — OPPO A18 / ColorOS 15 hardening (low-tier reference device)

**Status:** Active. 2026-05-30.

## Context

PRISM's user base skews toward deaf/HoH users whose phones are often
budget Android. The OPPO A18 (CPH2591) is our reference *low-tier
ceiling*: MediaTek Helio G85, 4 GB physical + 4 GB virtual RAM,
ColorOS 15.0 (Android 15), single-mic chassis exposed as fake stereo.
If PRISM is reliable here, it is reliable on anything we ship to.

Eight concerns surfaced during on-device verification that were not
visible in host tests or emulator runs. This ADR fixes the design
calls so future phases don't drift back into broken defaults.

## Decision 1 — Audio source ladder, not a single requested source

Phase 0 originally asked for `AudioSource.UNPROCESSED` unconditionally
(best quality, no AEC/AGC distortion of spatial cues). On low-tier
SoCs (Helio G85, Snapdragon 4xx, older Exynos), the driver silently
falls back or returns a `null AudioRecord`, leaving us with no mic at
all.

The fix is a runtime ladder:

```
UNPROCESSED (if PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED == "true")
  → VOICE_RECOGNITION  (no AEC/AGC; always available)
    → CAMCORDER        (stereo path; usually available)
      → MIC            (last resort)
```

The first source that returns `state == STATE_INITIALIZED` wins. The
selection is logged (`PrismCapture: AudioRecord selected source=…`)
and exposed via `captureDiagnostics` so the UI can show the user an
amber warning when UNPROCESSED was unavailable — spatial features
degrade gracefully, the user is told why, no silent quality loss.

Implementation: [openBestAudioRecord()](../../android/app/src/main/kotlin/com/prism/audio/AudioCaptureService.kt).
Verified on OPPO A18: ladder picks VOICE_RECOGNITION (UNPROCESSED
unsupported), UI shows the amber line.

## Decision 2 — Mono-replicated stereo detection in Rust DSP

Single-mic phones often report `CHANNEL_IN_STEREO` but actually
write the same PCM to both channels. Naive GCC-PHAT then computes
TDOA = 0 with high correlation and the Phase 1 pipeline emits
`SpatialZone::Center` with confidence ≈ 1.0 — a confidently wrong
verdict. For an assistive app, "I'm 100% sure the source is in
front of you" when the hardware can't possibly know is worse than
silence.

The fix has two layers:

1. **`channel_difference_rms()` early-out.** If L≈R bitwise (rms
   diff < `MONO_REPLICATED_THRESHOLD = 1e-3`), return
   `SpatialZone::Unknown`, `mono_replicated: true`, confidence 0.
2. **Confidence gate on the regular path.** Even when L ≠ R, if
   GCC-PHAT correlation peak height < `MIN_CONFIDENCE = 0.15`, the
   zone is Unknown rather than a low-confidence Left/Right/Center.

The Rust public surface adds `SpatialZone::Unknown` and a
`mono_replicated: bool` field on `SpatialEstimate`. The Dart `Zone`
enum gains a matching variant. The UI maps Unknown to "spatial
features degraded" rather than a directional arrow.

Implementation: [spatial.rs](../../rust/src/dsp/spatial.rs).
Test: `gcc_phat_resolves_unknown_for_identical_channels` in
[dsp_smoke.rs](../../rust/tests/dsp_smoke.rs).

## Decision 3 — Memory tiers, not "all devices same"

flutter_gemma is willing to install both Gemma3n E2B (~1.5 GB INT4)
*and* DeepSeek-R1 Qwen-1.5B (~1.5 GB Q8). On a 4 GB OPPO A18 the
peak RSS during simultaneous narration + reasoning crosses ColorOS
HansManager's foreground-service threshold and we get killed
mid-inference. Same calls run fine on a 8 GB Pixel.

`DeviceProfile.memoryTier` reads `ActivityManager.MemoryInfo.totalMem`
once at app start:

| Total RAM | Tier | DeepSeek | Slow-path throttle |
|---|---|---|---|
| < 3 GB | low | skipped | 8 s |
| 3–5 GB | low_borderline | skipped | 5 s |
| 5–7 GB | mid | optional | 3 s |
| ≥ 7 GB | high | enabled | 2 s |

`ModelManager.ensureDeepSeek()` returns `false` without touching the
network on `low` / `low_borderline`. `ScenePipeline` enforces
`minSlowPathInterval` so an event burst (e.g. ten knocks in a row)
can't queue ten Gemma3n inferences. Phase 6's narration polish must
respect the same tier — see `MemoryTier.minSlowPathInterval`.

OPPO A18 reports 3.6 GB total (some reserved for vendor) → tier
`low_borderline`. DeepSeek skipped, slow-path throttled to 5 s,
which is the rate at which a Helio G85 can finish one Gemma3n call
without queueing.

Implementation: [device_profile.dart](../../lib/src/audio/device_profile.dart),
[model_manager.dart](../../lib/src/llm/model_manager.dart),
[scene_pipeline.dart](../../lib/src/llm/scene_pipeline.dart).

## Decision 4 — Foreground service survival kit

ColorOS HansManager kills "noisy" background processes
[aggressively](https://dontkillmyapp.com/oppo). dontkillmyapp's
verdict ("no known solution on the dev end") is true *for arbitrary
background apps*. For a foreground service whose user-facing reason
is captured in a low-importance notification, the survival profile
improves measurably.

Five things together — none sufficient alone:

1. **Foreground service type = `microphone`** (Android 14+ required).
   `dumpsys activity services` confirms `types=0x00000080`.
2. **Notification channel `prism_audio_capture_v2` at
   `IMPORTANCE_MIN`.** A *new* channel ID is required — Android
   refuses to lower an existing channel's importance once set. The
   `v2` suffix makes upgrades from earlier installs land on a fresh
   channel.
3. **`PARTIAL_WAKE_LOCK` `PRISM:audio_capture`** held for the lifetime
   of capture (10-hour timeout safety net).
4. **`REQUEST_IGNORE_BATTERY_OPTIMIZATIONS` permission** declared,
   plus a MethodChannel-exposed `requestIgnoreBatteryOpt` that opens
   the system dialog. The home screen surfaces an amber banner on
   OEM-aggressive devices (xiaomi/redmi/poco/huawei/honor/oppo/realme/
   oneplus/vivo/iqoo/samsung) until the user grants the exemption or
   dismisses with "Not now."
5. **Foreground service started via `startForegroundService` from the
   foreground**, not from a receiver. (Android 14 blocks background
   FGS starts for the microphone type.)

The user-grant flow is *not optional* on ColorOS. The amber banner
makes the friction visible rather than hiding behind a future bug
report.

Implementation: [AudioCaptureService.kt](../../android/app/src/main/kotlin/com/prism/audio/AudioCaptureService.kt),
[AudioCapturePlugin.kt](../../android/app/src/main/kotlin/com/prism/audio/AudioCapturePlugin.kt),
[AndroidManifest.xml](../../android/app/src/main/AndroidManifest.xml),
[home_screen.dart](../../lib/src/ui/home_screen.dart).

### Empirical result (15-min screen-off, OPPO A18, 2026-05-30 04:06–04:21)

Test protocol: start capture, lock screen with power button, do not
touch the phone, poll device state every 60 s for 15 minutes. Verify
PID stability, foreground state, both wakelocks, and that
`mScreenState=OFF` for the entire window.

```
m1  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m2  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m3  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m4  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m5  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m6  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m7  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m8  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m9  pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m10 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m11 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m12 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m13 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m14 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
m15 pid=26183 alive | isForeground=true | Asleep OFF | PRISM:audio_capture LONG | AudioIn LONG
```

After waking the screen, the live waveform was still updating and
the home screen status read "Listening" — capture was still flowing,
not just the process surviving. Battery dropped from 72 % to 67 %
across the 15-minute window (≈ 20 mA average), an acceptable cost
for continuous mic + WakeLock.

**Outcome: PASS.** ColorOS 15 / HansManager respected the foreground
service + IMPORTANCE_MIN notification + microphone FGS type on the
OPPO A18 across a sustained screen-off window with no battery-opt
exemption granted. The amber banner is still recommended belt-and-
braces for sleep windows longer than this test or for users on
power-saver profiles; do not remove it just because this test
passed.

## Decision 5 — Cold-start observability via `print`, not `developer.log`

`developer.log` is the Flutter idiom for structured logging but it
does *not* pipe to `adb logcat` by default — only to the Dart DevTools
console. A regression that hangs cold start is then invisible from
the only tool available on a physical device.

`StartupProfiler` uses bare `print()` so every phase marker hits the
same `flutter:V` logcat stream as Flutter's own boot logs. The boot
trace becomes a `grep "PRISM..boot"` away on any device.

Phases marked at present: `main_entered`, `widgets_binding_ready`,
`rust_lib_init`, `device_profile_kicked_off`, `run_app_returned`.
Add more before any future cold-start change.

Implementation: [startup_profiler.dart](../../lib/src/diag/startup_profiler.dart).

Verified: 5 consecutive cold starts on OPPO A18 produce 785–932 ms
Dart boot trace, `RustLib.init` ≈ 210 ms. The 24 s splash hang seen
earlier in the session did not reproduce after the `print()` swap
and was likely first-launch-after-install state (resolved by ART
warm-cache).

## What is explicitly NOT in scope

- **Xiaomi MIUI Autostart toggle.** Different OEM, different
  whitelist mechanism. Phase 3+ will extend the same
  `DeviceProfile.isOemAggressive` matrix per OEM.
- **OPPO Phone Manager "Floating notification" toggle.** Out of band
  for the dev side — users must enable it manually if they want
  PRISM to escalate scene events to a floating notification. The
  amber banner is silent about this for now.
- **Background mic on devices that aged out of FGS-type support
  (Android ≤ 13).** Min SDK stays at 26; the manifest path works on
  older OS by ignoring the `foregroundServiceType` attribute, but
  ColorOS 11 (Android 11) is *not* a tested configuration.

## Reference: when to update this ADR

Update when:
- A new OEM reproduces a survival failure not covered above.
- A new memory tier boundary becomes load-bearing (e.g. Phase 9 LoRA
  pushes peak RSS).
- An Android version changes the foreground-service contract again.
