import AVFoundation
import Foundation

/// Native video compressor using AVAssetExportSession.
///
/// Threading model (the "native isolate"): a dedicated serial `DispatchQueue`
/// owns probe + export setup, so the main thread never performs media I/O and
/// cannot block. `exportAsynchronously` runs off-main on its own queue. All
/// mutable state (`activeExport`, `busy`) is confined to the worker queue
/// (single owner; no locks). The only hop back to main is to deliver the final
/// result to Flutter and to emit progress.
final class VideoCompressor {

    struct Probe {
        let displayWidth: Int
        let displayHeight: Int
        let durationMs: Int
        let bitrate: Double // bits/sec, video track
        let fps: Float
        let isH264OrHevc: Bool
    }

    enum CompressError: Error {
        case probeFailed
        case unsupportedFormat(String)
        case cancelled
        case failed(String)
    }

    private static let maxLongEdge = 1280
    private static let skipMaxBitrate: Double = 2_500_000

    // Containers AVFoundation cannot decode on iOS. Checked before probe.
    private static let unsupportedExt: Set<String> =
        ["avi", "mkv", "wmv", "flv", "rmvb", "webm"]

    /// Receives 0.0...1.0 on the MAIN thread. Set by the plugin per job.
    var onProgress: ((Double) -> Void)?

    private let workerQueue = DispatchQueue(label: "nvc.worker", qos: .userInitiated)
    // --- State below is confined to workerQueue -----------------------------
    private var activeExport: AVAssetExportSession?
    private var progressTimer: Timer?
    private var busy = false

    /// Synchronous busy check for the main-thread BUSY guard.
    var isBusy: Bool {
        workerQueue.sync { busy }
    }

    /// Compresses off the main thread. [completion] is invoked on the MAIN thread.
    func compress(
        path: String,
        targetPath: String,
        trimStartMs: Int64?,
        trimEndMs: Int64?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        workerQueue.async {
            self.busy = true
            self.runJob(path: path, targetPath: targetPath,
                        trimStartMs: trimStartMs, trimEndMs: trimEndMs,
                        completion: completion)
        }
    }

    /// Cancels the active job. [onResult] is invoked on the MAIN thread.
    func cancel(onResult: @escaping (Bool) -> Void) {
        workerQueue.async {
            let had = self.activeExport != nil
            self.activeExport?.cancelExport()
            // completion of the export delivers the CANCELLED error + cleanup.
            DispatchQueue.main.async { onResult(had) }
        }
    }

    // --- Worker-queue internals ---------------------------------------------

    private func runJob(
        path: String,
        targetPath: String,
        trimStartMs: Int64?,
        trimEndMs: Int64?,
        completion: @escaping (Result<[String: Any], Error>) -> Void
    ) {
        let inputURL = URL(fileURLWithPath: path)
        let outputURL = URL(fileURLWithPath: targetPath)
        let ext = inputURL.pathExtension.lowercased()

        guard FileManager.default.fileExists(atPath: path) else {
            finish(completion, .failure(CompressError.failed("Input file does not exist")))
            return
        }
        if Self.unsupportedExt.contains(ext) {
            finish(completion, .failure(CompressError.unsupportedFormat("Unsupported container: .\(ext)")))
            return
        }
        guard let probe = probeVideo(url: inputURL) else {
            finish(completion, .failure(CompressError.probeFailed))
            return
        }

        let hasTrim = trimStartMs != nil && trimEndMs != nil && trimEndMs! > trimStartMs!
        let longEdge = max(probe.displayWidth, probe.displayHeight)
        let containerOk = ext == "mp4" || ext == "m4v"

        // Skip: already compliant, no trim -> byte-copy.
        if !hasTrim && probe.isH264OrHevc && longEdge <= Self.maxLongEdge
            && probe.bitrate > 0 && probe.bitrate <= Self.skipMaxBitrate && containerOk {
            do {
                try? FileManager.default.removeItem(at: outputURL)
                try FileManager.default.copyItem(at: inputURL, to: outputURL)
                busy = false
                finish(completion, .success(resultMap(targetPath, probe.displayWidth,
                                                      probe.displayHeight, probe.durationMs, "copied")))
            } catch {
                busy = false
                finish(completion, .failure(CompressError.failed("Copy failed: \(error.localizedDescription)")))
            }
            return
        }

        // One hardware pass.
        let asset = AVURLAsset(url: inputURL)
        guard let session = AVAssetExportSession(
            asset: asset, presetName: AVAssetExportPreset1280x720
        ) else {
            busy = false
            finish(completion, .failure(CompressError.failed("Export session unavailable for this asset")))
            return
        }

        try? FileManager.default.removeItem(at: outputURL)
        session.outputURL = outputURL
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true // faststart
        if hasTrim {
            let start = CMTime(value: CMTimeValue(trimStartMs!), timescale: 1000)
            let end = CMTime(value: CMTimeValue(trimEndMs!), timescale: 1000)
            session.timeRange = CMTimeRange(start: start, end: end)
        }

        activeExport = session
        startProgressTimer()

        session.exportAsynchronously { [weak self] in
            guard let self = self else { return }
            self.workerQueue.async {
                self.stopProgressTimer()
                let status = session.status
                self.activeExport = nil
                self.busy = false

                switch status {
                case .completed:
                    let out = self.probeVideo(url: outputURL)
                    let map = self.resultMap(
                        targetPath,
                        out?.displayWidth ?? probe.displayWidth,
                        out?.displayHeight ?? probe.displayHeight,
                        out?.durationMs ?? probe.durationMs,
                        "transcoded"
                    )
                    self.finish(completion, .success(map))
                case .cancelled:
                    try? FileManager.default.removeItem(at: outputURL)
                    self.finish(completion, .failure(CompressError.cancelled))
                default:
                    try? FileManager.default.removeItem(at: outputURL)
                    self.finish(completion, .failure(
                        CompressError.failed(session.error?.localizedDescription ?? "Export failed")))
                }
            }
        }
    }

    /// Delivers the result to Flutter on the main thread exactly once.
    private func finish(_ completion: @escaping (Result<[String: Any], Error>) -> Void,
                        _ result: Result<[String: Any], Error>) {
        DispatchQueue.main.async { completion(result) }
    }

    private func startProgressTimer() {
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                // activeExport is read on the worker queue to stay confined.
                self.workerQueue.async {
                    guard let s = self.activeExport else { return }
                    let p = Double(s.progress)
                    DispatchQueue.main.async { self.onProgress?(p) }
                }
            }
        }
    }

    private func stopProgressTimer() {
        DispatchQueue.main.async {
            self.progressTimer?.invalidate()
            self.progressTimer = nil
        }
    }

    private func probeVideo(url: URL) -> Probe? {
        let asset = AVURLAsset(url: url)
        guard let track = asset.tracks(withMediaType: .video).first else { return nil }
        let size = track.naturalSize.applying(track.preferredTransform)
        let w = Int(abs(size.width).rounded())
        let h = Int(abs(size.height).rounded())
        guard w > 0, h > 0 else { return nil }

        var codecOk = false
        if let descAny = track.formatDescriptions.first {
            let desc = descAny as! CMFormatDescription
            let sub = CMFormatDescriptionGetMediaSubType(desc)
            codecOk = (sub == kCMVideoCodecType_H264 || sub == kCMVideoCodecType_HEVC)
        }
        return Probe(
            displayWidth: w,
            displayHeight: h,
            durationMs: Int(CMTimeGetSeconds(asset.duration) * 1000.0),
            bitrate: Double(track.estimatedDataRate),
            fps: track.nominalFrameRate,
            isH264OrHevc: codecOk
        )
    }

    private func resultMap(_ path: String, _ w: Int, _ h: Int, _ durationMs: Int, _ method: String) -> [String: Any] {
        return [
            "path": path,
            "width": w,
            "height": h,
            "durationMs": durationMs,
            "method": method,
        ]
    }
}
