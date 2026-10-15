import 'dart:async';

import 'package:flutter/services.dart';

import 'src/video_compression_result.dart';

export 'src/video_compression_result.dart';

/// A general-purpose, drop-in native video compressor.
///
/// Android uses AndroidX Media3 Transformer; iOS uses AVAssetExportSession.
/// Both do trim + scale + H.264/AAC transcode in one hardware pass, with
/// correct aspect ratio / rotation, metadata-based skip, progress and
/// cancellation. All heavy work runs off the platform main thread.
///
/// Output is always H.264 (High) + AAC in an `.mp4` container, long edge
/// capped at 1280 (720p), aspect ratio and rotation preserved, never upscaled.
class NativeVideoCompression {
  NativeVideoCompression._();

  static const MethodChannel _methods =
      MethodChannel('native_video_compression/methods');
  static const EventChannel _progressChannel =
      EventChannel('native_video_compression/progress');

  static Stream<double>? _progress;

  /// Progress of the active compression job, 0.0 → 1.0, emitted ~4×/second.
  /// Nothing is emitted for a skip-copied result. Broadcast stream.
  static Stream<double> get progress => _progress ??= _progressChannel
      .receiveBroadcastStream()
      .map((event) => (event as num).toDouble());

  /// Compresses [path] into [targetPath] in one native hardware pass.
  ///
  /// [targetPath] must end in `.mp4`. When [trimStartMs]/[trimEndMs] are given,
  /// the clip is trimmed in the same pass (exact cut points, always re-encodes).
  ///
  /// Returns a [VideoCompressionResult] with **output** dimensions/duration.
  /// Throws [VideoCompressionException] on failure (e.g. [VideoCompressionError]
  /// `BUSY`, `UNSUPPORTED_FORMAT`, `CANCELLED`, `PROBE_FAILED`,
  /// `COMPRESS_FAILED`). Only one job runs at a time.
  static Future<VideoCompressionResult> compress({
    required String path,
    required String targetPath,
    int? trimStartMs,
    int? trimEndMs,
  }) async {
    try {
      final result = await _methods.invokeMethod<Map<dynamic, dynamic>>(
        'compressVideo',
        <String, dynamic>{
          'path': path,
          'targetPath': targetPath,
          'trimStartMs': ?trimStartMs,
          'trimEndMs': ?trimEndMs,
        },
      );
      if (result == null) {
        throw const VideoCompressionException(
          VideoCompressionError.compressFailed,
          'Native side returned no result',
        );
      }
      return VideoCompressionResult.fromMap(result);
    } on PlatformException catch (e) {
      throw VideoCompressionException(e.code, e.message);
    }
  }

  /// Cancels the active compression job, if any. The pending [compress] call
  /// then throws [VideoCompressionException] with code `CANCELLED`.
  /// Returns true if a job was actually cancelled.
  static Future<bool> cancel() async {
    final result = await _methods.invokeMethod<bool>('cancelVideoCompression');
    return result ?? false;
  }
}
