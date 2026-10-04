# Screen audio feasibility — #540

Investigated on 4 October 2026, Search `cddb9cd`, macOS 27.0.1 (26A434), Apple Swift 6.4.

**Result: no small production fix established.** Keep this as an investigation;
do not add an audio switch or claim that #540 is fixed.

## Reproduce

```sh
mkdir -p build
swiftc Tests/display_audio.swift -o build/display-audio-probe
build/display-audio-probe
```

The standalone probe uses installed WebKit, synthetic capture devices, an
ephemeral data store and an offscreen window. It captures no real screen or
sound and sends nothing over a network. Missing test hooks, failed controls,
JavaScript errors and timeouts fail the probe.

| Request | Video tracks | Audio tracks |
| --- | ---: | ---: |
| Display, audio false | 1 | 0 |
| Display, audio true | 1 | 0 |
| Microphone control | 0 | 1 |

The microphone control confirms that the probe can receive a synthetic audio
track. This is not a live picker, real audio, WebRTC delivery or cross-version test.

## Why changing a flag is insufficient

- Search's extension shim explicitly requests `audio: false` and reports
  `canRequestAudioTrack: false`. Ordinary websites call WebKit directly.
- WebKit's [getDisplayMedia implementation](https://github.com/WebKit/WebKit/blob/ded238657d1beb915e76f06475222ff3f2835005/Source/WebCore/Modules/mediastream/MediaDevices.cpp)
  builds the display request with empty audio capture constraints.
- Its [ScreenCaptureKit source](https://github.com/WebKit/WebKit/blob/ded238657d1beb915e76f06475222ff3f2835005/Source/WebCore/platform/mediastream/cocoa/ScreenCaptureKitCaptureSource.mm)
  registers screen output only, and expects screen sample buffers.
- Apple's [capturesAudio](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/capturesaudio)
  controls native capture. It does not supply a WKWebView page with an audio track.

## Next step

Prefer native WebKit support when available; rerun this probe, then verify real
screen/window consent and audio received by a WebRTC peer before changing Search.
Tab-only audio needs separate verification. Do not substitute microphone audio
for the requested screen sound.

A custom native-to-page audio bridge would need explicit design agreement,
bounded buffering, synchronization, origin-bound consent, teardown on navigation
and stop, and measured CPU/memory use. That is outside the small-fix scope.
Coordinate with [#530](https://github.com/driceroland/Search/pull/530), which changes
screen-sharing permission handling but does not implement system audio.
