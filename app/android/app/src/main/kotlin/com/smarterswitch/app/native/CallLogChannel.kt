package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.provider.CallLog
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Call log channel.
 *
 * Methods exposed:
 * - hasReadPermission / hasWritePermission: gates the UI permission flow.
 * - count: SELECT COUNT(*) for the Select screen.
 * - readAll: full cursor read; one List<Map> entry per call. Dart serializes
 *   each into a JSON record before streaming to the peer.
 * - writeAll: receives a List<Map> from Dart and inserts each entry into
 *   `CallLog.Calls.CONTENT_URI`. Dedup happens earlier in pure-Dart so this
 *   method just writes whatever it's handed.
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
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CALL_LOG) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasWrite(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CALL_LOG) ==
            PackageManager.PERMISSION_GRANTED

    private fun handleCount(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasRead(activity)) {
            result.error("PERMISSION_DENIED", "READ_CALL_LOG not granted", null)
            return
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

    private fun handleReadAll(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasRead(activity)) {
            result.error("PERMISSION_DENIED", "READ_CALL_LOG not granted", null)
            return
        }
        scope.launch {
            try {
                val rows = withContext(Dispatchers.IO) { readAllCallLog(activity) }
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
            result.error("PERMISSION_DENIED", "WRITE_CALL_LOG not granted", null)
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
                    writeAllCallLog(activity, records)
                }
                result.success(written)
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
        }
    }

    private fun countCallLog(context: Context): Long {
        return context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            arrayOf(CallLog.Calls._ID),
            null, null, null,
        )?.use { it.count.toLong() } ?: 0L
    }

    private fun readAllCallLog(context: Context): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val projection = arrayOf(
            CallLog.Calls.NUMBER,
            CallLog.Calls.DATE,
            CallLog.Calls.DURATION,
            CallLog.Calls.TYPE,
            CallLog.Calls.CACHED_NAME,
        )
        context.contentResolver.query(
            CallLog.Calls.CONTENT_URI,
            projection,
            null, null,
            "${CallLog.Calls.DATE} ASC",
        )?.use { cursor ->
            val numIdx = cursor.getColumnIndexOrThrow(CallLog.Calls.NUMBER)
            val dateIdx = cursor.getColumnIndexOrThrow(CallLog.Calls.DATE)
            val durIdx = cursor.getColumnIndexOrThrow(CallLog.Calls.DURATION)
            val typeIdx = cursor.getColumnIndexOrThrow(CallLog.Calls.TYPE)
            val nameIdx = cursor.getColumnIndexOrThrow(CallLog.Calls.CACHED_NAME)
            while (cursor.moveToNext()) {
                out.add(
                    mapOf(
                        "number" to (cursor.getString(numIdx) ?: ""),
                        "timestampMs" to cursor.getLong(dateIdx),
                        "durationSeconds" to cursor.getInt(durIdx),
                        "type" to cursor.getInt(typeIdx),
                        "cachedName" to cursor.getString(nameIdx),
                    )
                )
            }
        }
        return out
    }

    private fun writeAllCallLog(
        context: Context,
        records: List<Map<String, Any?>>,
    ): Long {
        var written = 0L
        for (record in records) {
            val values = ContentValues().apply {
                put(CallLog.Calls.NUMBER, record["number"] as? String ?: "")
                put(CallLog.Calls.DATE,
                    (record["timestampMs"] as? Number)?.toLong() ?: 0L)
                put(CallLog.Calls.DURATION,
                    (record["durationSeconds"] as? Number)?.toInt() ?: 0)
                put(CallLog.Calls.TYPE,
                    (record["type"] as? Number)?.toInt() ?: CallLog.Calls.INCOMING_TYPE)
                val name = record["cachedName"] as? String
                if (!name.isNullOrEmpty()) {
                    put(CallLog.Calls.CACHED_NAME, name)
                }
                put(CallLog.Calls.NEW, 0) // mark as already-seen
            }
            try {
                context.contentResolver.insert(CallLog.Calls.CONTENT_URI, values)
                written += 1
            } catch (_: Exception) {
                // Skip records the OS rejects (e.g. nullable-number rules);
                // continue with the rest so a single bad row doesn't tank
                // the whole batch.
            }
        }
        return written
    }
}
