import 'dart:io';

/// Result of a native video compression pass.
///
/// All dimensions are **display-oriented output** values (rotation already
/// applied), so a portrait video has [width] < [height]. Reading these from the
/// output — not the source — is what prevents the "stretched on the receiver"
/// bug.
class VideoCompressionResult {
  /// The compressed (or skip-copied) output file at the requested target path.
  final File file;

  /// Display-oriented output width (portrait ⇒ width < height).
  final int width;

  /// Display-oriented output height.
  final int height;

  /// Output duration in milliseconds.
  final int durationMs;

  /// True when the source was already compliant and was byte-copied instead of
  /// re-encoded (near-instant, no quality loss).
  final bool wasCopied;

  const VideoCompressionResult({
    required this.file,
    required this.width,
    required this.height,
    required this.durationMs,
    required this.wasCopied,
  });

  /// Aspect ratio of the output, or null if dimensions are unknown.
  double? get aspectRatio =>
      (width > 0 && height > 0) ? width / height : null;

  /// Output duration rounded to whole seconds.
  int get durationSeconds => (durationMs / 1000).round();

  factory VideoCompressionResult.fromMap(Map<dynamic, dynamic> map) {
    return VideoCompressionResult(
      file: File(map['path'] as String),
      width: (map['width'] as num?)?.toInt() ?? 0,
      height: (map['height'] as num?)?.toInt() ?? 0,
      durationMs: (map['durationMs'] as num?)?.toInt() ?? 0,
      wasCopied: map['method'] == 'copied',
    );
  }

  @override
  String toString() =>
      'VideoCompressionResult(${file.path}, ${width}x$height, '
      '${durationMs}ms, wasCopied: $wasCopied)';
}

/// Error codes surfaced by the native side.
class VideoCompressionError {
  static const invalidArguments = 'INVALID_ARGUMENTS';
  static const busy = 'BUSY';
  static const probeFailed = 'PROBE_FAILED';
  static const compressFailed = 'COMPRESS_FAILED';
  static const cancelled = 'CANCELLED';
  static const unsupportedFormat = 'UNSUPPORTED_FORMAT';
}

/// Thrown when native compression fails. [code] is one of
/// [VideoCompressionError]'s constants.
class VideoCompressionException implements Exception {
  final String code;
  final String? message;

  const VideoCompressionException(this.code, [this.message]);

  bool get wasCancelled => code == VideoCompressionError.cancelled;
  bool get isUnsupportedFormat =>
      code == VideoCompressionError.unsupportedFormat;

  @override
  String toString() => 'VideoCompressionException($code, $message)';
}
