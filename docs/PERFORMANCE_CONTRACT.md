# `native_video_compression` — Architecture & Performance Contract

**Status:** locked design. The implementation (Phase 1–2) MUST satisfy every MUST below.
**Goal:** a general-purpose, drop-in replacement for `video_compress` that is the best performer — no main-thread blocking, low constant RAM, no ANR on low-end devices.

---

## 1. Engine (locked)

- **Android:** AndroidX **Media3 Transformer** (`media3-transformer`, `-effect`, `-common`, same version).
- **iOS:** **AVAssetExportSession** (AVFoundation).
- Output is **always** H.264 (High) + AAC in `.mp4`, faststart. Universal decode.
- Long edge ≤ 1280, aspect ratio + rotation preserved, never upscaled.
- Android bitrate ≈ 2.0 Mbps (2.75 Mbps for >40 fps sources). iOS uses `AVAssetExportPreset1280x720`.

## 2. Public Dart API (stable; app sees only this)

```dart
class NativeVideoCompression {
  static Future<VideoCompressionResult?> compress({
    required String path,
    required String targetPath,     // must end .mp4
    int? trimStartMs,
    int? trimEndMs,
  });
  static Future<bool> cancel();
  static Stream<double> get progress; // 0.0 → 1.0, ~4x/sec, broadcast
}

class VideoCompressionResult {
  final File file;
  final int width, height, durationMs; // OUTPUT-oriented (portrait => w<h)
  final bool wasCopied;                // true => skip-copied, not transcoded
}
```

- `null` return == **failure, do not send**. No silent `copySync` fallback.
- Channels: `native_video_compression/methods`, `native_video_compression/progress`.
- Errors: `INVALID_ARGUMENTS`, `BUSY`, `PROBE_FAILED`, `COMPRESS_FAILED`, `CANCELLED`, `UNSUPPORTED_FORMAT`.

## 3. Behaviour

1. **Probe** input (dims, rotation, duration, bitrate, codec, fps).
2. **Skip-by-metadata** (no trim only): H.264/HEVC AND long edge ≤ 1280 AND overall bitrate ≤ 2.5 Mbps AND container `.mp4`/`.m4v` → byte-copy, `method: "copied"`.
3. Else **one hardware pass**: trim (if given) + scale + H.264/AAC.
4. Return **output** metadata (re-probe the output file).
5. On any error: delete the partial output.

---

## 4. Threading & Performance Contract (the core of "best performer")

### 4.1 Android — dedicated worker thread (the "native isolate")
- **MUST** run probe, `Transformer` build/start, and file copy on a dedicated **`HandlerThread("nvc-worker")`** with its own `Looper`. The platform **main thread MUST NOT** perform any media I/O.
  - This also satisfies Media3's requirement that `Transformer` be created/started on a thread with a `Looper` — the worker thread provides it. (The original handoff doc ran probe + Transformer on main — that is the ANR bug we are fixing.)
- **MUST** touch all mutable job state (`activeTransformer`, `pendingResult`, `isBusy`) **only on the worker thread** (single-owner confinement; no locks, no races).
- **MUST** hop back to the main thread **only** to answer the Flutter `Result` (`mainHandler.post { ... }`), since `MethodChannel.Result` must be replied on the platform thread.
- Progress polling: `Handler.postDelayed(250ms)` on the worker thread.
- `cancel()` posts to the worker → `transformer.cancel()`.
- **MUST** `quitSafely()` the `HandlerThread` on plugin detach.

### 4.2 iOS — serial queue + actor (the "native isolate")
- **MUST** run probe + export setup on a dedicated serial `DispatchQueue(label: "nvc.worker", qos: .userInitiated)`. First access to `AVURLAsset.tracks`/`.duration` can block — it **MUST NOT** happen on main. (Fixes the doc's main-thread probe.)
- `exportAsynchronously` already runs off-main — keep it.
- **MUST** confine mutable state (`activeExport`, `progressSink`) to a Swift **`actor`** or the serial queue (single owner).
- **MUST** hop to `DispatchQueue.main.async` only for `FlutterResult` and sink emission.
- `cancel()` → `session.cancelExport()`; progress `Timer` on main (cheap).

### 4.3 Concurrency (both platforms) — MUST
1. **One job at a time.** A second `compress` while busy returns `BUSY`. (Two concurrent hardware encoders is what OOMs low-end devices.)
2. **Single-owner mutable state** (worker thread / actor). No shared-memory races.
3. **All heavy work off the platform main thread.** Main only answers Flutter + ticks progress.

### 4.4 RAM — MUST
4. **Never read a whole media file into memory** in Dart or native. Use `file.length()` (not `readAsBytes`), streaming copy, and native streaming encode.
5. RAM MUST stay roughly **constant and small** regardless of input size (10 MB or 500 MB).
6. **Release native resources in `finally`**: `MediaMetadataRetriever`, `MediaExtractor` (Android); invalidate timers / nil the session (iOS). These hold native buffers.

### 4.5 Low-end-device resilience — MUST
7. `DefaultEncoderFactory.setEnableFallback(true)` — software encoder if HW is busy/absent.
8. Cap output at 720p (long edge 1280) — minimal encoder memory.
9. Input cap 500 MB (reject early), output cap 50 MB (checked on the **output**).
10. Watchdog timeout → cancel + `COMPRESS_FAILED` so a stuck encode can't hang forever.

### 4.6 Dart side — MUST
11. Async-only file APIs (`file.length()`, `await file.copy()`); **zero `*Sync`** on the UI path.
12. Platform calls are `await`-ed (already non-blocking); never busy-wait.
13. Throttle progress UI (don't rebuild on every tick).
14. Dart isolates **only** for Dart CPU (image byte-encode/save, hashing) — **not** for the native encode.

---

## 5. Format support (per-platform capability map)

| Container | Android | iOS | Package verdict |
|---|---|---|---|
| mp4, mov, m4v, 3gp | ✅ | ✅ | full |
| mpg/mpeg | ✅ | ⚠️ | Android full / iOS codec-dependent |
| webm, mkv, avi | ⚠️ (device-dependent) | ❌ | Android-only; iOS → `UNSUPPORTED_FORMAT` |
| wmv, flv, rmvb | ❌ | ❌ | `UNSUPPORTED_FORMAT` both |

- Codecs: H.264 ✅✅, HEVC ✅✅(A9+), VP8/VP9 Android-only, AV1 Android (iOS newer only).
- **MUST** check the capability map and return `UNSUPPORTED_FORMAT` **before** probing, so unsupported input fails fast and cleanly (never a silent/mislabelled error).

---

## 6. Repo integration (drop-in replacement)

1. `pubspec.yaml`: remove `video_compress`; add `native_video_compression` (git/path dep).
2. `media_compression.dart`: `VideoCompress.compressVideo(...)` → `NativeVideoCompression.compress(...)`; return the richer result.
3. Call sites (`edit_screen`, `gallery_bottom_sheet`, `sharing_service`): take dims/duration from the **output** result; treat `null` as "don't send"; drop the EXIF-leaking `copySync` fallback.
4. `MainActivity.kt` / `AppDelegate.swift`: **no changes** — the plugin self-registers its channels.
5. Keep `flutter_image_compress`, `video_trimmer` (UI only), `get_thumbnail_video`.

## 7. Roadmap

| Phase | Work | Effort |
|---|---|---|
| 0 | Scaffold plugin + example harness app | 0.5 d |
| 1 | Android: worker-thread `VideoCompressor` + Media3 + registrar | 1–1.5 d |
| 2 | iOS: serial-queue/actor `VideoCompressor` + registrar | 1–1.5 d |
| 3 | Dart API + result model + progress/cancel; run 13-case matrix | 1 d |
| 4 | Integrate into repo (pubspec + media_compression + 3 call sites) | 1 d |
| 5 | Device QA on real low-/mid-end hardware, both platforms | 1–2 d |

**Total ≈ 5–7 days** to a shipped drop-in replacement.

## 8. Acceptance (must pass before merge)

- No ANR on a low-end device for a 500 MB input (probe + encode fully off-main).
- RAM delta during a 200 MB compress stays small/flat (no whole-file reads).
- Portrait clip not stretched on the receiver (output-oriented dims).
- 60–70 MB input sends (output-size gate).
- iPhone `.mov` from gallery and share sheet → sends as `.mp4`.
- Cancel mid-job: `CANCELLED`, partial deleted, next job works.
- Unsupported container → clean `UNSUPPORTED_FORMAT`, no crash.
