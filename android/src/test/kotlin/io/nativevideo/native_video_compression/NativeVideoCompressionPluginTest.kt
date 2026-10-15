package io.nativevideo.native_video_compression

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test

/*
 * Plugin-level unit tests run on the JVM without an Android runtime, so the
 * Media3 / MediaMetadataRetriever paths are exercised in the example app's
 * integration tests on-device instead. This keeps a smoke test that an unknown
 * method is reported as not implemented.
 */
internal class NativeVideoCompressionPluginTest {
    @Test
    fun unknownMethod_reportsNotImplemented() {
        val plugin = NativeVideoCompressionPlugin()
        val call = MethodCall("someUnknownMethod", null)
        val mockResult: MethodChannel.Result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(call, mockResult)
        Mockito.verify(mockResult).notImplemented()
    }
}
