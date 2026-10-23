# macOS capture

Implemented for macOS 14+ in [`Sources/StationCapture`](../../Sources/StationCapture). API availability was checked against the installed macOS 27 SDK headers, using only APIs available on macOS 14. Capture is opt-in: initialization and Core Graphics display enumeration do not request permission; screen/system-audio and microphone authorization happen in their respective `start` methods.

## API basis

- Screen Color Play uses `SCShareableContent`, a display `SCContentFilter`, and `SCStream`. Output is sRGB BGRA, at most 320 pixels on the longer side and 10 frames/second. Requested intervals are bounded to 0.1–60 seconds. Only complete frames are sampled; blank/suspended frames produce black. Apple's [capture sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) documents the stream, frame-status attachments, and sample-buffer path.
- Music Flow system audio uses ScreenCaptureKit's `capturesAudio`, 48 kHz stereo, and [`excludesCurrentProcessAudio`](https://developer.apple.com/documentation/screencapturekit/scstreamconfiguration/excludescurrentprocessaudio). It needs Screen Recording authorization and an available display; it needs no virtual audio driver. The associated display surface is tiny and no video output is consumed.
- Microphone capture uses `AVCaptureDevice` authorization and an `AVAudioEngine` input tap, preserving macOS 14 support. The enclosing app must supply `NSMicrophoneUsageDescription` and any microphone entitlements required by its signing/sandbox configuration. Missing usage text is reported before requesting access. Hardware changes stop capture with a restartable error; teardown is deferred from the audio-engine notification queue as required by [Apple's configuration-change documentation](https://developer.apple.com/documentation/avfaudio/avaudioengineconfigurationchangenotification).
- Native float32 PCM is validated before reading either interleaved or planar `AudioBufferList` storage. `CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer` supplies the required list size and retains ownership of aligned sample storage through the read; its lifetime and size contract was checked in the local Core Media `CMSampleBuffer.h`.

## Processing and lifecycle

Zones use normalized top-left coordinates, clipped to the frame. Empty or invalid zones yield black. A 12-bin hue histogram excludes low-saturation/dark pixels, weights both red boundary bins by three, and averages the winning bin. Without eligible pixels, the full region's average preserves grayscale and fades to black. The extracted Windows `appsettings.yee` supplies cutoff values 25 and red weight 3; interpreting the cutoffs as byte-scale HSV and the exact hue-bin boundaries remains an inference.

Audio output is an RMS-derived level, mapped from −60…−6 dBFS to 0…1 with 35 ms attack and 200 ms release smoothing. It is a responsive music envelope rather than calibrated loudness. Samples arriving between delivery ticks replace the mailbox's previous sample; no task is created per frame. Audio callbacks run on the main actor at most 20 times/second and decay to silence when samples stop arriving.

Stop invalidates callbacks synchronously, then awaits any in-flight stream start and shared teardown. Generation checks reject superseded starts, and a new start waits for earlier teardown. Both capture classes expose `lastError` for asynchronous stream/input failures alongside `isRunning`.

## Limits and verification

Screen permission changes may require reopening the app. Protected/DRM content can be blank or silent. Capture is SDR; display removal and microphone format/device changes require Start again. Headless system-audio capture is unsupported. App/helper processes other than the current process are not automatically excluded from audio.

Build and synthetic tests do not request capture permissions or open devices. Tests cover BGRA geometry and histogram behavior, float32 layouts and malformed storage, normalized smoothing, and delivery cancellation. Actual permission dialogs, stream interruption, device hot-plug, and end-to-end screen/system-audio/microphone capture still require an explicit interactive Start in the app.
