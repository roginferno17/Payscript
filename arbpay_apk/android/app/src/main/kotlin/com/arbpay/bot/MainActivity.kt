package com.arbpay.bot

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.MediaPlayer
import android.net.Uri
import android.os.Build
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.lifecycle.DefaultLifecycleObserver
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.ProcessLifecycleOwner
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {

    private val ICON_CHANNEL = "com.arbpay.bot/icon"
    private val DEVICE_CHANNEL = "com.arbpay.bot/device"

    // Pending icon switch — applied when app goes to background
    private var pendingIsDark: Boolean? = null

    private var activeMediaPlayer: MediaPlayer? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        // Observe app lifecycle — apply icon switch when app backgrounds
        ProcessLifecycleOwner.get().lifecycle.addObserver(object : DefaultLifecycleObserver {
            override fun onStop(owner: LifecycleOwner) {
                pendingIsDark?.let {
                    applyLauncherIcon(it)
                    pendingIsDark = null
                }
            }
        })

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, ICON_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "setIcon" -> {
                        val isDark = call.argument<Boolean>("isDark") ?: true
                        pendingIsDark = isDark
                        result.success(null)
                    }
                    else -> result.notImplemented()
                }
            }

        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, DEVICE_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "launchExternal" -> {
                        val url = call.argument<String>("url") ?: ""
                        if (url.isEmpty()) {
                            result.error("INVALID_URL", "URL cannot be empty", null)
                            return@setMethodCallHandler
                        }
                        val launched = launchExternalUrl(url)
                        result.success(launched)
                    }
                    "playAlert" -> {
                        val type = call.argument<String>("type") ?: "qr"
                        playAlertSound(type)
                        result.success(true)
                    }
                    "vibrate" -> {
                        val type = call.argument<String>("type") ?: "qr"
                        performVibration(type)
                        result.success(true)
                    }
                    "startForegroundService" -> {
                        val title = call.argument<String>("title") ?: "ARBPay Bot Running"
                        val text = call.argument<String>("text") ?: "Engine active"
                        BotForegroundService.start(applicationContext, title, text)
                        result.success(true)
                    }
                    "updateForegroundService" -> {
                        val title = call.argument<String>("title") ?: "ARBPay Bot Running"
                        val text = call.argument<String>("text") ?: ""
                        val highPriority = call.argument<Boolean>("highPriority") ?: false
                        BotForegroundService.update(applicationContext, title, text, highPriority)
                        result.success(true)
                    }
                    "stopForegroundService" -> {
                        BotForegroundService.stop(applicationContext)
                        result.success(true)
                    }
                    "requestNotificationPermission" -> {
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                            if (androidx.core.content.ContextCompat.checkSelfPermission(
                                    this,
                                    android.Manifest.permission.POST_NOTIFICATIONS
                                ) != PackageManager.PERMISSION_GRANTED
                            ) {
                                androidx.core.app.ActivityCompat.requestPermissions(
                                    this,
                                    arrayOf(android.Manifest.permission.POST_NOTIFICATIONS),
                                    101
                                )
                            }
                        }
                        result.success(true)
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun launchExternalUrl(url: String): Boolean {
        try {
            // First attempt: Intent.parseUri which handles intent://, upi://, phonepe://, etc.
            val intent: Intent = if (url.startsWith("intent:", ignoreCase = true)) {
                Intent.parseUri(url, Intent.URI_INTENT_SCHEME)
            } else {
                Intent(Intent.ACTION_VIEW, Uri.parse(url))
            }
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)

            try {
                startActivity(intent)
                return true
            } catch (e: Exception) {
                // If intent has a browser fallback url, try that
                val fallbackUrl = intent.getStringExtra("browser_fallback_url")
                if (!fallbackUrl.isNullOrEmpty()) {
                    val fallbackIntent = Intent(Intent.ACTION_VIEW, Uri.parse(fallbackUrl))
                    fallbackIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    startActivity(fallbackIntent)
                    return true
                }
                // If it's a phonepe scheme and app is not installed, open Play Store
                if (url.contains("phonepe", ignoreCase = true)) {
                    val marketIntent = Intent(Intent.ACTION_VIEW, Uri.parse("market://details?id=com.phonepe.app"))
                    marketIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                    try {
                        startActivity(marketIntent)
                        return true
                    } catch (_: Exception) {}
                }
                throw e
            }
        } catch (e: Exception) {
            e.printStackTrace()
            return false
        }
    }

    private fun playAlertSound(type: String) {
        try {
            activeMediaPlayer?.stop()
            activeMediaPlayer?.release()
            activeMediaPlayer = null

            val resId = if (type == "kyc") R.raw.kyc_completed else R.raw.qr_cash
            val mp = MediaPlayer.create(applicationContext, resId) ?: return

            val audioAttributes = android.media.AudioAttributes.Builder()
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                .build()

            mp.setAudioAttributes(audioAttributes)
            mp.setVolume(1.0f, 1.0f)
            activeMediaPlayer = mp
            mp.setOnCompletionListener {
                it.release()
                if (activeMediaPlayer == it) {
                    activeMediaPlayer = null
                }
            }
            mp.start()
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }

    private fun performVibration(type: String) {
        try {
            val vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as? VibratorManager
                vm?.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as? Vibrator
            } ?: return

            if (!vibrator.hasVibrator()) return

            // Cancel any ongoing vibration to reset system state cleanly
            vibrator.cancel()

            val audioAttributes = android.media.AudioAttributes.Builder()
                .setContentType(android.media.AudioAttributes.CONTENT_TYPE_SONIFICATION)
                .setUsage(android.media.AudioAttributes.USAGE_ALARM)
                .build()

            if (type == "kyc") {
                // KYC alert: Triumphant distinct triple pulse
                val timings = longArrayOf(0, 220, 80, 220, 80, 350)
                val amplitudes = intArrayOf(0, 255, 0, 255, 0, 255)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                    vibrator.vibrate(effect, audioAttributes)
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(timings, -1)
                }
            } else {
                // QR ready alert: Buzz thrice loudly ("zor se") with maximum intensity (255)
                val timings = longArrayOf(0, 380, 140, 380, 140, 500)
                val amplitudes = intArrayOf(0, 255, 0, 255, 0, 255)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    val effect = VibrationEffect.createWaveform(timings, amplitudes, -1)
                    vibrator.vibrate(effect, audioAttributes)
                } else {
                    @Suppress("DEPRECATION")
                    vibrator.vibrate(timings, -1)
                }
            }
        } catch (e: Exception) {
            e.printStackTrace()
        }
    }


    private fun applyLauncherIcon(isDark: Boolean) {
        val pm = packageManager
        val pkg = packageName

        val darkAlias  = ComponentName(pkg, "$pkg.MainActivityDark")
        val lightAlias = ComponentName(pkg, "$pkg.MainActivityLight")

        pm.setComponentEnabledSetting(
            if (isDark) darkAlias else lightAlias,
            PackageManager.COMPONENT_ENABLED_STATE_ENABLED,
            PackageManager.DONT_KILL_APP
        )
        pm.setComponentEnabledSetting(
            if (isDark) lightAlias else darkAlias,
            PackageManager.COMPONENT_ENABLED_STATE_DISABLED,
            PackageManager.DONT_KILL_APP
        )
    }
}
