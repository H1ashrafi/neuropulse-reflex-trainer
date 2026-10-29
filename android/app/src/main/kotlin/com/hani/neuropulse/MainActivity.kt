package com.hani.neuropulse

import android.media.AudioManager
import android.media.ToneGenerator
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var toneGenerator: ToneGenerator? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "beep" -> {
                    beep(call)
                    result.success(null)
                }
                "keepScreenOn" -> {
                    keepScreenOn(call.argument<Boolean>("on") == true)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun beep(call: MethodCall) {
        val requestedMs = call.argument<Int>("ms") ?: DEFAULT_BEEP_MS
        tones()?.startTone(ToneGenerator.TONE_PROP_BEEP, requestedMs.coerceIn(MIN_BEEP_MS, MAX_BEEP_MS))
    }

    private fun tones(): ToneGenerator? {
        toneGenerator?.let { return it }
        val created = runCatching { ToneGenerator(AudioManager.STREAM_MUSIC, TONE_VOLUME) }.getOrNull()
        toneGenerator = created
        return created
    }

    private fun keepScreenOn(enabled: Boolean) {
        val flag = WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
        if (enabled) window.addFlags(flag) else window.clearFlags(flag)
    }

    override fun onDestroy() {
        toneGenerator?.release()
        toneGenerator = null
        super.onDestroy()
    }

    private companion object {
        const val CHANNEL = "neuropulse/native"
        const val TONE_VOLUME = 80
        const val DEFAULT_BEEP_MS = 60
        const val MIN_BEEP_MS = 10
        const val MAX_BEEP_MS = 400
    }
}
