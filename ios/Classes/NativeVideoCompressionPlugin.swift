import AVFoundation
import Flutter
import UIKit

public class NativeVideoCompressionPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {

    private let compressor = VideoCompressor()
    private var progressSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let instance = NativeVideoCompressionPlugin()

        let methodChannel = FlutterMethodChannel(
            name: "native_video_compression/methods",
            binaryMessenger: registrar.messenger()
        )
        registrar.addMethodCallDelegate(instance, channel: methodChannel)

        let progressChannel = FlutterEventChannel(
            name: "native_video_compression/progress",
            binaryMessenger: registrar.messenger()
        )
        progressChannel.setStreamHandler(instance)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "compressVideo":
            guard let args = call.arguments as? [String: Any],
                  let path = args["path"] as? String,
                  let targetPath = args["targetPath"] as? String
            else {
                result(FlutterError(code: "INVALID_ARGUMENTS",
                                    message: "path and targetPath are required", details: nil))
                return
            }
            if compressor.isBusy {
                result(FlutterError(code: "BUSY",
                                    message: "A video compression job is already running", details: nil))
                return
            }
            let trimStartMs = (args["trimStartMs"] as? NSNumber)?.int64Value
            let trimEndMs = (args["trimEndMs"] as? NSNumber)?.int64Value
            let maxInputBytes = (args["maxInputBytes"] as? NSNumber)?.int64Value

            compressor.onProgress = { [weak self] p in self?.progressSink?(p) }
            compressor.compress(path: path, targetPath: targetPath,
                                trimStartMs: trimStartMs, trimEndMs: trimEndMs,
                                maxInputBytes: maxInputBytes) { outcome in
                switch outcome {
                case .success(let map):
                    result(map)
                case .failure(let error):
                    result(Self.flutterError(for: error))
                }
            }

        case "cancelVideoCompression":
            compressor.cancel { cancelled in result(cancelled) }

        default:
            result(FlutterMethodNotImplemented)
        }
    }

    private static func flutterError(for error: Error) -> FlutterError {
        if let e = error as? VideoCompressor.CompressError {
            switch e {
            case .probeFailed:
                return FlutterError(code: "PROBE_FAILED", message: "Could not read video metadata", details: nil)
            case .unsupportedFormat(let msg):
                return FlutterError(code: "UNSUPPORTED_FORMAT", message: msg, details: nil)
            case .inputTooLarge(let msg):
                return FlutterError(code: "INPUT_TOO_LARGE", message: msg, details: nil)
            case .cancelled:
                return FlutterError(code: "CANCELLED", message: "Compression cancelled", details: nil)
            case .failed(let msg):
                return FlutterError(code: "COMPRESS_FAILED", message: msg, details: nil)
            }
        }
        return FlutterError(code: "COMPRESS_FAILED", message: error.localizedDescription, details: nil)
    }

    // MARK: - FlutterStreamHandler (progress)

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        progressSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        progressSink = nil
        return nil
    }
}
