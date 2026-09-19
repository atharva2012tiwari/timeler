package io.github.atharva2012tiwari.timeler

import android.content.Context
import android.content.res.AssetFileDescriptor
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import io.flutter.FlutterInjector
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "io.github.atharva2012tiwari.timeler/audio"
    private var activePlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName).setMethodCallHandler { call, result ->
            when (call.method) {
                "playBell" -> {
                    playSound("assets/sounds/bell.mp3", loop = false)
                    triggerVibration(180)
                    result.success(true)
                }
                "playCompletion" -> {
                    playSound("assets/sounds/complete.mp3", loop = true)
                    triggerVibration(500)
                    result.success(true)
                }
                "stop" -> {
                    stopSound()
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun playSound(assetPath: String, loop: Boolean) {
        try {
            stopSound()
            val loader = FlutterInjector.instance().flutterLoader()
            val key = loader.getLookupKeyForAsset(assetPath)
            val afd: AssetFileDescriptor = context.assets.openFd(key)

            val player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .setUsage(AudioAttributes.USAGE_NOTIFICATION)
                        .build()
                )
                setDataSource(afd.fileDescriptor, afd.startOffset, afd.length)
                isLooping = loop
                prepare()
                start()
            }
            afd.close()

            if (!loop) {
                player.setOnCompletionListener {
                    it.release()
                    if (activePlayer == it) {
                        activePlayer = null
                    }
                }
            }
            activePlayer = player
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun stopSound() {
        try {
            activePlayer?.let {
                if (it.isPlaying) {
                    it.stop()
                }
                it.release()
            }
        } catch (_: Exception) {}
        activePlayer = null
    }

    private fun triggerVibration(durationMs: Long) {
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vibratorManager = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vibratorManager?.defaultVibrator?.vibrate(
                    VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
                )
            } else {
                @Suppress("DEPRECATION")
                val vibrator = getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(
                        VibrationEffect.createOneShot(durationMs, VibrationEffect.DEFAULT_AMPLITUDE)
                    )
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(durationMs)
                }
            }
        } catch (_: Exception) {}
    }

    override fun onDestroy() {
        stopSound()
        super.onDestroy()
    }
}
