import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:native_video_compression/native_video_compression.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methods = MethodChannel('native_video_compression/methods');
  final log = <MethodCall>[];

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, null);
    log.clear();
  });

  test('compress forwards args and maps a successful result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      log.add(call);
      return <String, dynamic>{
        'path': '/tmp/out.mp4',
        'width': 720,
        'height': 1280,
        'durationMs': 5000,
        'method': 'transcoded',
      };
    });

    final result = await NativeVideoCompression.compress(
      path: '/tmp/in.mov',
      targetPath: '/tmp/out.mp4',
      trimStartMs: 1000,
      trimEndMs: 4000,
    );

    expect(log.single.method, 'compressVideo');
    expect(log.single.arguments['path'], '/tmp/in.mov');
    expect(log.single.arguments['trimStartMs'], 1000);
    expect(result.width, 720);
    expect(result.height, 1280);
    expect(result.wasCopied, isFalse);
    expect(result.aspectRatio, 720 / 1280);
    expect(result.durationSeconds, 5);
  });

  test('compress maps a copied result', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      return <String, dynamic>{
        'path': '/tmp/out.mp4',
        'width': 1280,
        'height': 720,
        'durationMs': 3000,
        'method': 'copied',
      };
    });

    final result = await NativeVideoCompression.compress(
      path: '/tmp/in.mp4',
      targetPath: '/tmp/out.mp4',
    );

    expect(result.wasCopied, isTrue);
  });

  test('compress rethrows a PlatformException as VideoCompressionException',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      throw PlatformException(
        code: VideoCompressionError.unsupportedFormat,
        message: 'wmv not supported',
      );
    });

    expect(
      () => NativeVideoCompression.compress(
        path: '/tmp/in.wmv',
        targetPath: '/tmp/out.mp4',
      ),
      throwsA(isA<VideoCompressionException>()
          .having((e) => e.code, 'code',
              VideoCompressionError.unsupportedFormat)
          .having((e) => e.isUnsupportedFormat, 'isUnsupportedFormat', true)),
    );
  });

  test('cancel returns the native boolean', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(methods, (call) async {
      expect(call.method, 'cancelVideoCompression');
      return true;
    });

    expect(await NativeVideoCompression.cancel(), isTrue);
  });
}
