package io.nativevideo.native_video_compression

import android.content.Context
import android.media.MediaExtractor
import android.media.MediaFormat
import android.media.MediaMetadataRetriever
import android.net.Uri
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.util.Log
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.util.UnstableApi
import androidx.media3.effect.Presentation
import androidx.media3.transformer.Composition
import androidx.media3.transformer.DefaultEncoderFactory
import androidx.media3.transformer.EditedMediaItem
import androidx.media3.transformer.Effects
import androidx.media3.transformer.ExportException
import androidx.media3.transformer.ExportResult
import androidx.media3.transformer.ProgressHolder
import androidx.media3.transformer.Transformer
import androidx.media3.transformer.VideoEncoderSettings
import java.io.File
import kotlin.math.max
import kotlin.math.roundToInt

/** Raised into the pending result when cancel() is called. */
class VideoCompressCancelled : Exception("cancelled")

/** Raised when the source container cannot be handled on this platform. */
class UnsupportedFormat(message: String) : Exception(message)

/** Raised when the input exceeds the sanity size cap. */
class InputTooLarge(message: String) : Exception(message)

/**
 * Native video compressor using Media3 Transformer.
 *
 * Threading model (the "native isolate"): a dedicated [HandlerThread] owns the
 * ENTIRE job — probe, Transformer build/start, progress polling and file copy.
 * The platform main thread never performs media I/O, so it cannot ANR. The
 * worker thread's Looper also satisfies Media3's requirement that Transformer
 * be created/started on a thread with a Looper. All mutable job state is touched
 * only on the worker thread (single-owner confinement; no locks). The only hop
 * back to the main thread is to deliver the final result to Flutter.
 */
@androidx.annotation.OptIn(UnstableApi::class)
class VideoCompressor(private val appContext: Context) {

    companion object {
        private const val TAG = "VideoCompressor"
        private const val MAX_LONG_EDGE = 1280
        private const val BITRATE_DEFAULT = 2_000_000
        private const val BITRATE_HIGH_FPS = 2_750_000 // sources above 40 fps
        private const val SKIP_MAX_BITRATE = 2_500_000
        private const val MIN_VIDEO_BITRATE = 150_000 // never request below this
        private const val MAX_INPUT_BYTES = 500L * 1024 * 1024 // sanity cap
        private const val PROGRESS_INTERVAL_MS = 250L

        // Containers Media3 cannot reliably read. Checked before probe so the
        // caller gets a clean UNSUPPORTED_FORMAT instead of a late failure.
        private val UNSUPPORTED_EXT = setOf("wmv", "flv", "rmvb", "asf")
    }

    /** Receives 0.0..1.0 on the MAIN thread. Set by the plugin per job. */
    var onProgress: ((Double) -> Unit)? = null

    private val worker = HandlerThread("nvc-worker").apply { start() }
    private val workerHandler = Handler(worker.looper)
    private val mainHandler = Handler(Looper.getMainLooper())

    // --- State below is confined to the worker thread (no locks needed) ------
    private var activeTransformer: Transformer? = null
    private var pendingDone: ((Result<Map<String, Any>>) -> Unit)? = null
    private var activeTargetPath: String? = null
    private var progressRunnable: Runnable? = null

    // Quick flag for the main-thread BUSY guard (volatile write from worker).
    @Volatile
    var isBusy: Boolean = false
        private set

    data class Probe(
        val displayWidth: Int,
        val displayHeight: Int,
        val durationMs: Long,
        val bitrate: Int,
        val fps: Float,
        val isH264OrHevc: Boolean,
    )

    /**
     * Compresses off the main thread. [onDone] is invoked on the MAIN thread.
     * Safe to call from the main thread.
     */
    fun compress(
        path: String,
        targetPath: String,
        trimStartMs: Long?,
        trimEndMs: Long?,
        maxInputBytes: Long? = null,
        minVideoBitrate: Int? = null,
        onDone: (Result<Map<String, Any>>) -> Unit,
    ) {
        isBusy = true
        val maxInput = maxInputBytes ?: MAX_INPUT_BYTES
        val minBitrate = minVideoBitrate ?: MIN_VIDEO_BITRATE
        workerHandler.post {
            runJob(path, targetPath, trimStartMs, trimEndMs, maxInput, minBitrate, onDone)
        }
    }

    /** Cancels the active job. [compress]'s callback then fails with cancelled. */
    fun cancel(onResult: (Boolean) -> Unit) {
        workerHandler.post {
            val t = activeTransformer
            if (t == null) {
                mainHandler.post { onResult(false) }
                return@post
            }
            val done = pendingDone
            val target = activeTargetPath
            runCatching { t.cancel() }
            clearState()
            target?.let { File(it).delete() }
            finish(done, Result.failure(VideoCompressCancelled()))
            mainHandler.post { onResult(true) }
        }
    }

    /** Stops the worker thread. Call from plugin detach. */
    fun release() {
        workerHandler.post {
            runCatching { activeTransformer?.cancel() }
            clearState()
        }
        worker.quitSafely()
    }

    // --- Worker-thread internals --------------------------------------------

    private fun runJob(
        path: String,
        targetPath: String,
        trimStartMs: Long?,
        trimEndMs: Long?,
        maxInputBytes: Long,
        minVideoBitrate: Int,
        onDone: (Result<Map<String, Any>>) -> Unit,
    ) {
        val ext = path.substringAfterLast('.', "").lowercase()
        if (ext in UNSUPPORTED_EXT) {
            finish(onDone, Result.failure(UnsupportedFormat("Unsupported container: .$ext")))
            return
        }

        val inputBytes = File(path).length()
        if (inputBytes > maxInputBytes) {
            finish(onDone, Result.failure(InputTooLarge("Input exceeds ${maxInputBytes / (1024 * 1024)} MB")))
            return
        }

        val probe = probe(path)
        if (probe == null) {
            finish(onDone, Result.failure(IllegalStateException("PROBE_FAILED")))
            return
        }

        val hasTrim = trimStartMs != null && trimEndMs != null && trimEndMs > trimStartMs
        val longEdge = max(probe.displayWidth, probe.displayHeight)
        val containerOk = ext == "mp4" || ext == "m4v"

        // Skip: already compliant and no trim -> byte-copy (near-instant).
        if (!hasTrim && probe.isH264OrHevc && longEdge <= MAX_LONG_EDGE &&
            probe.bitrate in 1..SKIP_MAX_BITRATE && containerOk
        ) {
            val copied = runCatching {
                File(path).copyTo(File(targetPath), overwrite = true)
            }.isSuccess
            if (copied) {
                finish(
                    onDone,
                    Result.success(
                        resultMap(targetPath, probe.displayWidth, probe.displayHeight, probe.durationMs, "copied")
                    )
                )
            } else {
                finish(onDone, Result.failure(IllegalStateException("COMPRESS_FAILED: copy failed")))
            }
            return
        }

        // One hardware pass: trim + scale + re-encode. A video effect is always
        // attached so Transformer takes the encode path (otherwise it transmuxes
        // same-codec input and the bitrate would silently not apply).
        val targetDisplayHeight = computeTargetDisplayHeight(probe)

        val mediaItemBuilder = MediaItem.Builder().setUri(Uri.fromFile(File(path)))
        if (hasTrim) {
            mediaItemBuilder.setClippingConfiguration(
                MediaItem.ClippingConfiguration.Builder()
                    .setStartPositionMs(trimStartMs!!)
                    .setEndPositionMs(trimEndMs!!)
                    .build()
            )
        }

        val edited = EditedMediaItem.Builder(mediaItemBuilder.build())
            .setEffects(Effects(listOf(), listOf(Presentation.createForHeight(targetDisplayHeight))))
            .build()

        // Bitrate must be a CEILING, never a floor: a source already below our
        // target must not be re-encoded upward. Cap the request at the source's
        // overall bitrate (a safe upper bound), with a sane minimum.
        val targetBitrate = if (probe.fps > 40f) BITRATE_HIGH_FPS else BITRATE_DEFAULT
        val videoBitrate = when {
            probe.bitrate in 1 until targetBitrate -> max(minVideoBitrate, probe.bitrate)
            else -> targetBitrate
        }
        val encoderFactory = DefaultEncoderFactory.Builder(appContext)
            .setRequestedVideoEncoderSettings(
                VideoEncoderSettings.Builder().setBitrate(videoBitrate).build()
            )
            .setEnableFallback(true) // software encoder if HW is busy/absent
            .build()

        val transformer = Transformer.Builder(appContext)
            .setVideoMimeType(MimeTypes.VIDEO_H264)
            .setAudioMimeType(MimeTypes.AUDIO_AAC)
            .setEncoderFactory(encoderFactory)
            .addListener(object : Transformer.Listener {
                override fun onCompleted(composition: Composition, exportResult: ExportResult) {
                    val done = pendingDone
                    clearState()

                    // Output-size guard: if the transcode produced a file that is
                    // NOT smaller than the source, compression failed its purpose.
                    // When the source is a valid MP4 container, discard the output
                    // and return the original (byte-copy) so we never hand back a
                    // file larger than the input.
                    val outputBytes = File(targetPath).length()
                    if (outputBytes >= inputBytes && inputBytes > 0 &&
                        (ext == "mp4" || ext == "m4v")
                    ) {
                        File(targetPath).delete()
                        val copied = runCatching {
                            File(path).copyTo(File(targetPath), overwrite = true)
                        }.isSuccess
                        val map = if (copied) {
                            resultMap(targetPath, probe.displayWidth, probe.displayHeight, probe.durationMs, "copied")
                        } else {
                            resultMap(targetPath, probe.displayWidth, probe.displayHeight, probe.durationMs, "transcoded")
                        }
                        finish(done, Result.success(map))
                        return
                    }

                    val out = probe(targetPath) // re-probe output for exact metadata
                    val map = if (out != null) {
                        resultMap(targetPath, out.displayWidth, out.displayHeight, out.durationMs, "transcoded")
                    } else {
                        resultMap(targetPath, probe.displayWidth, probe.displayHeight, probe.durationMs, "transcoded")
                    }
                    finish(done, Result.success(map))
                }

                override fun onError(
                    composition: Composition,
                    exportResult: ExportResult,
                    exportException: ExportException,
                ) {
                    Log.e(TAG, "export failed", exportException)
                    val done = pendingDone
                    clearState()
                    File(targetPath).delete()
                    finish(done, Result.failure(exportException))
                }
            })
            .build()

        activeTransformer = transformer
        pendingDone = onDone
        activeTargetPath = targetPath
        transformer.start(edited, targetPath)
        startProgressPolling()
    }

    /** Clears job state. Worker thread only. */
    private fun clearState() {
        progressRunnable?.let { workerHandler.removeCallbacks(it) }
        progressRunnable = null
        activeTransformer = null
        pendingDone = null
        activeTargetPath = null
        isBusy = false
    }

    /** Delivers the result to Flutter on the main thread exactly once. */
    private fun finish(done: ((Result<Map<String, Any>>) -> Unit)?, result: Result<Map<String, Any>>) {
        if (done == null) return
        mainHandler.post { done(result) }
    }

    private fun startProgressPolling() {
        val holder = ProgressHolder()
        val r = object : Runnable {
            override fun run() {
                val t = activeTransformer ?: return
                if (t.getProgress(holder) == Transformer.PROGRESS_STATE_AVAILABLE) {
                    val p = holder.progress / 100.0
                    mainHandler.post { onProgress?.invoke(p) }
                }
                workerHandler.postDelayed(this, PROGRESS_INTERVAL_MS)
            }
        }
        progressRunnable = r
        workerHandler.postDelayed(r, PROGRESS_INTERVAL_MS)
    }

    /** Long edge -> 1280, AR preserved, never upscaled, even number. */
    private fun computeTargetDisplayHeight(p: Probe): Int {
        val w = p.displayWidth
        val h = p.displayHeight
        val target = when {
            max(w, h) <= MAX_LONG_EDGE -> h // no downscale; effect forces encode path
            h >= w -> MAX_LONG_EDGE // portrait / square: height is the long edge
            else -> (h * MAX_LONG_EDGE.toDouble() / w).roundToInt() // landscape
        }
        return max(2, (target / 2) * 2)
    }

    /** Probes metadata. Runs on the worker thread; releases native resources. */
    private fun probe(path: String): Probe? {
        val r = MediaMetadataRetriever()
        return try {
            r.setDataSource(path)
            val w = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_WIDTH)?.toIntOrNull() ?: return null
            val h = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_HEIGHT)?.toIntOrNull() ?: return null
            val rotation = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_VIDEO_ROTATION)?.toIntOrNull() ?: 0
            val durationMs = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_DURATION)?.toLongOrNull() ?: 0L
            val bitrate = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_BITRATE)?.toIntOrNull() ?: 0
            val captureFps = r.extractMetadata(MediaMetadataRetriever.METADATA_KEY_CAPTURE_FRAMERATE)?.toFloatOrNull()

            var mime = ""
            var formatFps = 0f
            runCatching {
                val ex = MediaExtractor()
                try {
                    ex.setDataSource(path)
                    for (i in 0 until ex.trackCount) {
                        val f = ex.getTrackFormat(i)
                        val m = f.getString(MediaFormat.KEY_MIME) ?: continue
                        if (m.startsWith("video/")) {
                            mime = m
                            if (f.containsKey(MediaFormat.KEY_FRAME_RATE)) {
                                formatFps = f.getInteger(MediaFormat.KEY_FRAME_RATE).toFloat()
                            }
                            break
                        }
                    }
                } finally {
                    ex.release()
                }
            }

            val rotated = rotation == 90 || rotation == 270
            Probe(
                displayWidth = if (rotated) h else w,
                displayHeight = if (rotated) w else h,
                durationMs = durationMs,
                bitrate = bitrate,
                fps = captureFps ?: (if (formatFps > 0f) formatFps else 30f),
                isH264OrHevc = mime == MediaFormat.MIMETYPE_VIDEO_AVC || mime == MediaFormat.MIMETYPE_VIDEO_HEVC,
            )
        } catch (e: Exception) {
            Log.e(TAG, "probe failed", e)
            null
        } finally {
            runCatching { r.release() }
        }
    }

    private fun resultMap(path: String, w: Int, h: Int, durationMs: Long, method: String): Map<String, Any> =
        mapOf(
            "path" to path,
            "width" to w,
            "height" to h,
            "durationMs" to durationMs,
            "method" to method,
        )
}
