package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CalendarContract
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Calendar channel.
 *
 * Counts and reads events across all visible calendars; writes go to the
 * first writable calendar (typically the primary Google account calendar).
 * UID-based dedup happens in pure Dart on the receiver — the writer here
 * just inserts whatever it's handed.
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
                "hasReadPermission" -> result.success(hasRead(activity))
                "hasWritePermission" -> result.success(hasWrite(activity))
                "count" -> handleCount(activity, scope, result)
                "readAll" -> handleReadAll(activity, scope, result)
                "writeAll" -> handleWriteAll(activity, scope, call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun hasRead(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasWrite(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALENDAR) ==
            PackageManager.PERMISSION_GRANTED

    private fun handleCount(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasRead(activity)) {
            result.error("PERMISSION_DENIED", "READ_CALENDAR not granted", null)
            return
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

    private fun handleReadAll(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasRead(activity)) {
            result.error("PERMISSION_DENIED", "READ_CALENDAR not granted", null)
            return
        }
        scope.launch {
            try {
                val rows = withContext(Dispatchers.IO) { readAllEvents(activity) }
                result.success(rows)
            } catch (e: Exception) {
                result.error("READ_FAILED", e.message, null)
            }
        }
    }

    private fun handleWriteAll(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!hasWrite(activity)) {
            result.error("PERMISSION_DENIED", "WRITE_CALENDAR not granted", null)
            return
        }
        @Suppress("UNCHECKED_CAST")
        val records = call.arguments as? List<Map<String, Any?>>
        if (records == null) {
            result.error("BAD_ARGUMENT", "Expected List<Map>", null)
            return
        }
        scope.launch {
            try {
                val written = withContext(Dispatchers.IO) {
                    writeAllEvents(activity, records)
                }
                result.success(written)
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
        }
    }

    private fun countEvents(context: Context): Long {
        return context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            arrayOf(CalendarContract.Events._ID),
            "${CalendarContract.Events.DELETED} = 0",
            null, null,
        )?.use { it.count.toLong() } ?: 0L
    }

    private fun readAllEvents(context: Context): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            CalendarContract.Events._ID,
            CalendarContract.Events.UID_2445,
            CalendarContract.Events.TITLE,
            CalendarContract.Events.EVENT_LOCATION,
            CalendarContract.Events.DTSTART,
            CalendarContract.Events.DTEND,
            CalendarContract.Events.ALL_DAY,
            CalendarContract.Events.RRULE,
            CalendarContract.Events.DURATION,
        )
        context.contentResolver.query(
            CalendarContract.Events.CONTENT_URI,
            projection,
            "${CalendarContract.Events.DELETED} = 0",
            null,
            "${CalendarContract.Events.DTSTART} ASC",
        )?.use { cursor ->
            val uidIdx = cursor.getColumnIndex(CalendarContract.Events.UID_2445)
            val titleIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.TITLE)
            val locIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.EVENT_LOCATION)
            val startIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.DTSTART)
            val endIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.DTEND)
            val allDayIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.ALL_DAY)
            val rruleIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.RRULE)
            val durIdx = cursor.getColumnIndexOrThrow(CalendarContract.Events.DURATION)
            while (cursor.moveToNext()) {
                val start = cursor.getLong(startIdx)
                val end = if (!cursor.isNull(endIdx)) cursor.getLong(endIdx) else 0L
                out.add(
                    mapOf(
                        "uid" to (if (uidIdx >= 0) cursor.getString(uidIdx) else null),
                        "title" to (cursor.getString(titleIdx) ?: ""),
                        "location" to (cursor.getString(locIdx) ?: ""),
                        "startUtcMs" to start,
                        "endUtcMs" to end,
                        "allDay" to (cursor.getInt(allDayIdx) == 1),
                        "recurrence" to cursor.getString(rruleIdx),
                        "duration" to cursor.getString(durIdx),
                    )
                )
            }
        }
        return out
    }

    /// Pick the first writable calendar (highest access level). Most users
    /// have one obvious "primary" calendar; if not, the first writable one is
    /// a reasonable default — they can move events later via the Calendar
    /// app if it lands on the wrong calendar.
    private fun firstWritableCalendarId(context: Context): Long? {
        val projection = arrayOf(
            CalendarContract.Calendars._ID,
            CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL,
            CalendarContract.Calendars.IS_PRIMARY,
        )
        var best: Pair<Long, Int>? = null // (id, accessLevel)
        context.contentResolver.query(
            CalendarContract.Calendars.CONTENT_URI,
            projection,
            null, null, null,
        )?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(CalendarContract.Calendars._ID)
            val accIdx =
                cursor.getColumnIndexOrThrow(CalendarContract.Calendars.CALENDAR_ACCESS_LEVEL)
            val primIdx = cursor.getColumnIndex(CalendarContract.Calendars.IS_PRIMARY)
            while (cursor.moveToNext()) {
                val access = cursor.getInt(accIdx)
                if (access < CalendarContract.Calendars.CAL_ACCESS_CONTRIBUTOR) continue
                val id = cursor.getLong(idIdx)
                val isPrimary =
                    primIdx >= 0 && cursor.getInt(primIdx) == 1
                if (isPrimary) return id
                if (best == null || access > best!!.second) best = id to access
            }
        }
        return best?.first
    }

    private fun writeAllEvents(
        context: Context,
        records: List<Map<String, Any?>>,
    ): Long {
        val calendarId = firstWritableCalendarId(context) ?: return 0L
        var written = 0L
        for (record in records) {
            val title = record["title"] as? String ?: continue
            val start = (record["startUtcMs"] as? Number)?.toLong() ?: continue
            val end = (record["endUtcMs"] as? Number)?.toLong() ?: 0L
            val allDay = record["allDay"] as? Boolean ?: false
            val location = record["location"] as? String
            val uid = record["uid"] as? String
            val rrule = record["recurrence"] as? String
            val duration = record["duration"] as? String

            val values = ContentValues().apply {
                put(CalendarContract.Events.CALENDAR_ID, calendarId)
                put(CalendarContract.Events.TITLE, title)
                put(CalendarContract.Events.EVENT_LOCATION, location ?: "")
                put(CalendarContract.Events.DTSTART, start)
                if (rrule != null) {
                    put(CalendarContract.Events.RRULE, rrule)
                    // RRULE events use DURATION instead of DTEND.
                    put(
                        CalendarContract.Events.DURATION,
                        duration ?: "P${(end - start) / 1000}S",
                    )
                } else if (end > 0L) {
                    put(CalendarContract.Events.DTEND, end)
                }
                put(CalendarContract.Events.ALL_DAY, if (allDay) 1 else 0)
                put(
                    CalendarContract.Events.EVENT_TIMEZONE,
                    java.util.TimeZone.getDefault().id,
                )
                if (!uid.isNullOrEmpty()) {
                    put(CalendarContract.Events.UID_2445, uid)
                }
            }
            try {
                context.contentResolver.insert(
                    CalendarContract.Events.CONTENT_URI,
                    values,
                )
                written += 1
            } catch (_: Exception) {
                // Skip rejected rows; continue.
            }
        }
        return written
    }
}
