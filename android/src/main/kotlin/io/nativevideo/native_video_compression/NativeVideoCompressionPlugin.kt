package io.nativevideo.native_video_compression

import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/** NativeVideoCompressionPlugin — self-registers its own method + event channels. */
class NativeVideoCompressionPlugin :
    FlutterPlugin,
    MethodCallHandler {

    companion object {
        private const val METHODS_CHANNEL = "native_video_compression/methods"
        private const val PROGRESS_CHANNEL = "native_video_compression/progress"
    }

    private lateinit var methodChannel: MethodChannel
    private lateinit var progressChannel: EventChannel
    private var progressSink: EventChannel.EventSink? = null
    private var compressor: VideoCompressor? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        compressor = VideoCompressor(binding.applicationContext)

        methodChannel = MethodChannel(binding.binaryMessenger, METHODS_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        progressChannel = EventChannel(binding.binaryMessenger, PROGRESS_CHANNEL)
        progressChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                progressSink = events
            }

            override fun onCancel(arguments: Any?) {
                progressSink = null
            }
        })
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "compressVideo" -> {
                val path = call.argument<String>("path")
                val targetPath = call.argument<String>("targetPath")
                if (path.isNullOrBlank() || targetPath.isNullOrBlank()) {
                    result.error("INVALID_ARGUMENTS", "path and targetPath are required", null)
                    return
                }
                val comp = compressor
                if (comp == null) {
                    result.error("COMPRESS_FAILED", "Plugin not attached", null)
                    return
                }
                if (comp.isBusy) {
                    result.error("BUSY", "A video compression job is already running", null)
                    return
                }
                val trimStart = (call.argument<Any>("trimStartMs") as? Number)?.toLong()
                val trimEnd = (call.argument<Any>("trimEndMs") as? Number)?.toLong()
                val maxInputBytes = (call.argument<Any>("maxInputBytes") as? Number)?.toLong()
                val minVideoBitrate = (call.argument<Any>("minVideoBitrate") as? Number)?.toInt()

                comp.onProgress = { p -> progressSink?.success(p) }
                comp.compress(
                    path, targetPath, trimStart, trimEnd,
                    maxInputBytes = maxInputBytes,
                    minVideoBitrate = minVideoBitrate,
                ) { r ->
                    r.fold(
                        onSuccess = { map -> result.success(map) },
                        onFailure = { e ->
                            when {
                                e is VideoCompressCancelled ->
                                    result.error("CANCELLED", "Compression cancelled", null)
                                e is UnsupportedFormat ->
                                    result.error("UNSUPPORTED_FORMAT", e.message, null)
                                e is InputTooLarge ->
                                    result.error("INPUT_TOO_LARGE", e.message, null)
                                e.message?.startsWith("PROBE_FAILED") == true ->
                                    result.error("PROBE_FAILED", "Could not read video metadata", null)
                                else ->
                                    result.error("COMPRESS_FAILED", e.message, null)
                            }
                        }
                    )
                }
            }

            "cancelVideoCompression" -> {
                val comp = compressor
                if (comp == null) {
                    result.success(false)
                } else {
                    comp.cancel { cancelled -> result.success(cancelled) }
                }
            }

            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        progressChannel.setStreamHandler(null)
        progressSink = null
        compressor?.release()
        compressor = null
    }
}
