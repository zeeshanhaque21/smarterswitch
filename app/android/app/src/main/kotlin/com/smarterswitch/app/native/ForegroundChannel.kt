package com.smarterswitch.app.native

import android.app.Activity
import android.content.Intent
import android.os.Build
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Bridges Dart-side `start` / `stop` calls to the foreground service.
 *
 * Channel: `smarterswitch/foreground`
 */
object ForegroundChannel {
    private const val CHANNEL = "smarterswitch/foreground"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val intent = Intent(activity, TransferForegroundService::class.java).apply {
                        action = TransferForegroundService.ACTION_START
                    }
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                        ContextCompat.startForegroundService(activity, intent)
                    } else {
                        activity.startService(intent)
                    }
                    result.success(true)
                }
                "stop" -> {
                    val intent = Intent(activity, TransferForegroundService::class.java).apply {
                        action = TransferForegroundService.ACTION_STOP
                    }
                    activity.startService(intent)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
