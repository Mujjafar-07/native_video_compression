// Integration test for native_video_compression.
//
// The real codec paths need a device + a sample asset, so those live in the
// example app's manual QA (the 13-case matrix). This smoke test just verifies
// the plugin's channels are registered and that cancel() is callable with no
// active job.

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:native_video_compression/native_video_compression.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('cancel with no active job returns false', (tester) async {
    final cancelled = await NativeVideoCompression.cancel();
    expect(cancelled, isFalse);
  });
}
