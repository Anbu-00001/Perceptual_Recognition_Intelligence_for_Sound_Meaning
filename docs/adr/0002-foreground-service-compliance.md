# ADR 0002 — Android 14+ foreground service compliance

**Status:** Accepted. 2026-05-28.

## Context

Continuous microphone capture on Android requires a foreground service. Android 14
(API 34) tightened this dramatically: a service that uses the mic MUST declare
`foregroundServiceType="microphone"` in the manifest AND hold the
`FOREGROUND_SERVICE_MICROPHONE` runtime permission, OR `startForeground()` will
throw `MissingForegroundServiceTypeException`. Android 13 also added runtime
`POST_NOTIFICATIONS`.

## Decision

In `AndroidManifest.xml`:

```xml
<uses-permission android:name="android.permission.RECORD_AUDIO" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE" />
<uses-permission android:name="android.permission.FOREGROUND_SERVICE_MICROPHONE" />
<uses-permission android:name="android.permission.POST_NOTIFICATIONS" />

<service
    android:name="com.prism.audio.AudioCaptureService"
    android:exported="false"
    android:foregroundServiceType="microphone"
    android:stopWithTask="true" />
```

In Kotlin, call `startForeground(id, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MICROPHONE)`.

The service MUST be started while the app is in the foreground (`RECORD_AUDIO` is
a while-in-use permission). Starting from `BOOT_COMPLETED` is blocked.

## Audio source

`MediaRecorder.AudioSource.UNPROCESSED` is preferred when the device advertises
`PROPERTY_SUPPORT_AUDIO_SOURCE_UNPROCESSED`. It bypasses Android's voice
processing chain (AGC / NS / AEC), giving us raw PCM suitable for DSP.

## iOS counterpart

iOS requires:
- `NSMicrophoneUsageDescription` (plist).
- `NSMotionUsageDescription` (plist).
- `UIBackgroundModes` including `audio` (and `processing` for the future
  background-scan work).
- `AVAudioSession.setCategory(.playAndRecord, mode: .measurement)` — `.measurement`
  disables iOS's voice processing chain similarly to Android's UNPROCESSED.

App Store review will require justification of the `audio` background mode under
the accessibility use case.

## Consequences

- App requires Android 8 (API 26) minimum for modern AudioRecord behavior + the
  foreground service shape we use.
- The capture lifecycle starts and stops with the user's explicit tap on the
  "Start Capture" button (no auto-start). This also satisfies Play Store
  reviewer expectations for "necessary" foreground service usage.
