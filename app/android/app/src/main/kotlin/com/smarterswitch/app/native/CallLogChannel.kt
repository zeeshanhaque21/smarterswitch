package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Call log channel. Phase 1 surface: count + permission probe so the Select
 * screen can render an honest number. Full read/write lands when the call-log
 * dedup matcher (`call_log_dedup.dart`) is wired into the transfer pipeline.
 *
 * Channel: `smarterswitch/calllog`
 */
object CallLogChannel {
    private const val CHANNEL = "smarterswitch/calllog"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasPermission(activity))
                "count" -> {
                    if (!hasPermission(activity)) {
                        result.error("PERMISSION_DENIED", "READ_CALL_LOG not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val n = withContext(Dispatchers.IO) { countCallLog(activity) }
                            result.success(n)
                        } catch (e: Exception) {
                            result.error("COUNT_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) ==
            PackageManager.PERMISSION_GRANTED

    private fun countCallLog(context: Context): Long {
        return context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID),
            null, null, null,
        )?.use { it.count.toLong() } ?: 0L
    }
}
