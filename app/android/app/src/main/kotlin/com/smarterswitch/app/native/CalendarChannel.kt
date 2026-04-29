package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Calendar channel. Counts events across all visible calendars on the device
 * — the count surfaced on the Select screen reflects what would actually be
 * scanned, not just the primary calendar.
 *
 * Channel: `smarterswitch/calendar`
 */
object CalendarChannel {
    private const val CHANNEL = "smarterswitch/calendar"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasPermission(activity))
                "count" -> {
                    if (!hasPermission(activity)) {
                        result.error("PERMISSION_DENIED", "READ_CALENDAR not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val n = withContext(Dispatchers.IO) { countEvents(activity) }
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
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    private fun countEvents(context: Context): Long {
        return context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.DELETED} = 0",
            null, null,
        )?.use { it.count.toLong() } ?: 0L
    }
}
