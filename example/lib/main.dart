import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:native_video_compression/native_video_compression.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  final _picker = ImagePicker();
  StreamSubscription<double>? _progressSub;

  double _progress = 0;
  String _status = 'Pick a video to compress.';
  bool _running = false;

  @override
  void dispose() {
    _progressSub?.cancel();
    super.dispose();
  }

  Future<void> _pickAndCompress() async {
    final picked = await _picker.pickVideo(source: ImageSource.gallery);
    if (picked == null) return;

    final source = File(picked.path);
    final inMb = await source.length() / (1024 * 1024);

    final dir = await getTemporaryDirectory();
    final target = p.join(dir.path, 'nvc_${DateTime.now().millisecondsSinceEpoch}.mp4');

    setState(() {
      _running = true;
      _progress = 0;
      _status = 'Input: ${inMb.toStringAsFixed(1)} MB — compressing…';
    });

    final sw = Stopwatch()..start();
    _progressSub = NativeVideoCompression.progress.listen((p) {
      setState(() => _progress = p);
    });

    try {
      final result = await NativeVideoCompression.compress(path: source.path, targetPath: target);
      sw.stop();
      final outMb = await result.file.length() / (1024 * 1024);
      setState(() {
        _status =
            'Done in ${sw.elapsedMilliseconds} ms\n'
            'method: ${result.wasCopied ? "copied" : "transcoded"}\n'
            '${inMb.toStringAsFixed(1)} MB → ${outMb.toStringAsFixed(1)} MB\n'
            'output: ${result.width}x${result.height}, '
            '${result.durationSeconds}s, AR ${result.aspectRatio?.toStringAsFixed(3)}';
      });
    } on VideoCompressionException catch (e) {
      setState(() => _status = 'Failed: ${e.code} — ${e.message}');
    } catch (e) {
      setState(() => _status = 'Error: $e');
    } finally {
      await _progressSub?.cancel();
      _progressSub = null;
      setState(() => _running = false);
    }
  }

  Future<void> _cancel() async {
    await NativeVideoCompression.cancel();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        appBar: AppBar(title: const Text('native_video_compression')),
        body: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (_running) ...[
                  LinearProgressIndicator(value: _progress),
                  const SizedBox(height: 8),
                  Text('${(_progress * 100).toStringAsFixed(0)}%'),
                  const SizedBox(height: 16),
                ],
                Text(_status, textAlign: TextAlign.center),
                const SizedBox(height: 24),
                FilledButton(onPressed: _running ? null : _pickAndCompress, child: const Text('Pick & compress video')),
                const SizedBox(height: 8),
                OutlinedButton(onPressed: _running ? _cancel : null, child: const Text('Cancel')),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
