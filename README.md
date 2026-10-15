# native_video_compression

General-purpose native video compression for Flutter. A drop-in replacement for
packages like `video_compress`, built on first-party hardware stacks:

- **Android** — AndroidX **Media3 Transformer**
- **iOS** — **AVAssetExportSession** (AVFoundation)

Trim + scale + transcode in **one hardware pass**, with correct aspect
ratio/rotation, real bitrate control, metadata-based skip, progress and
cancellation. All heavy work runs **off the platform main thread**, so it will
not ANR on low-end devices.

## Output spec

- H.264 (High) + AAC in `.mp4`, faststart
- Long edge capped at 1280 (720p), aspect ratio & rotation preserved, never upscaled
- ~2 Mbps video (2.75 Mbps for >40 fps sources) on Android; `AVAssetExportPreset1280x720` on iOS
- Skip-by-metadata: already H.264/HEVC, ≤720p-class, ≤2.5 Mbps, `.mp4`/`.m4v`, no trim → byte-copy

## Usage

```dart
import 'package:native_video_compression/native_video_compression.dart';

// Optional: observe progress (0.0 → 1.0).
final sub = NativeVideoCompression.progress.listen((p) => print('${p * 100}%'));

try {
  final result = await NativeVideoCompression.compress(
    path: input.path,
    targetPath: outputMp4Path,   // must end in .mp4
    trimStartMs: 1000,           // optional
    trimEndMs: 8000,             // optional
  );
  // Use OUTPUT metadata (prevents the "stretched" bug):
  print('${result.width}x${result.height}, ${result.durationSeconds}s, '
        'copied: ${result.wasCopied}');
} on VideoCompressionException catch (e) {
  if (e.isUnsupportedFormat) { /* e.g. .wmv on both, .mkv/.avi/.webm on iOS */ }
  // e.code: BUSY | PROBE_FAILED | COMPRESS_FAILED | CANCELLED | UNSUPPORTED_FORMAT
}

await sub.cancel();
await NativeVideoCompression.cancel(); // cancels the active job
```

Only **one** job runs at a time; a second concurrent call throws `BUSY`.

## Format support

| Container | Android | iOS |
|---|---|---|
| mp4, mov, m4v, 3gp | ✅ | ✅ |
| mpg/mpeg | ✅ | ⚠️ codec-dependent |
| webm, mkv, avi | ⚠️ device-dependent | ❌ `UNSUPPORTED_FORMAT` |
| wmv, flv, rmvb | ❌ `UNSUPPORTED_FORMAT` | ❌ `UNSUPPORTED_FORMAT` |

Unsupported containers fail fast with `UNSUPPORTED_FORMAT` (never a silent error).

## Threading & performance

See [`docs/PERFORMANCE_CONTRACT.md`](docs/PERFORMANCE_CONTRACT.md). In short:
Android uses a dedicated `HandlerThread` worker; iOS a serial `DispatchQueue`.
Probe, encode and copy never touch the main thread; mutable job state has a
single owner; native resources are released deterministically; RAM stays small
and constant regardless of input size.

## Requirements

- Android `minSdk` 24+ (Media3 needs 21+)
- iOS 13+

## Status

Phase 0–1 complete: plugin scaffold, Dart API, Android + iOS implementations,
unit tests. **Pending: on-device QA** (the 13-case matrix in the example app)
and native-build verification on real hardware.
