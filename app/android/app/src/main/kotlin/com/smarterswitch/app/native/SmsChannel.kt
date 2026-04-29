package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.ContentResolver
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.provider.Telephony
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * MethodChannel handler for SMS reads. Dedup runs on the receiver in pure Dart;
 * this module exists only to surface raw records from `content://sms` to the
 * Dart side as plain maps.
 *
 * Channel: `smarterswitch/sms`
 *
 * Methods:
 * - `hasReadPermission`: Boolean. The Select screen calls this before
 *   showing the inline "Tap to allow" CTA.
 * - `count`: Long. Single SELECT COUNT(*) over content://sms; used to render
 *   the number on the Select screen.
 * - `readAll`: List<Map<String, Any?>>. Full cursor read. Heavyweight; only
 *   the dedup pass calls this.
 *
 * MMS read and default-SMS-app role grab land in a follow-up.
 */
object SmsChannel {
    private const val CHANNEL = "smarterswitch/sms"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasReadSmsPermission(activity))
                "count" -> {
                    if (!hasReadSmsPermission(activity)) {
                        result.error("PERMISSION_DENIED", "READ_SMS not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val n = withContext(Dispatchers.IO) { countSms(activity) }
                            result.success(n)
                        } catch (e: Exception) {
                            result.error("COUNT_FAILED", e.message, null)
                        }
                    }
                }
                "readAll" -> {
                    if (!hasReadSmsPermission(activity)) {
                        result.error("PERMISSION_DENIED", "READ_SMS not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val records = withContext(Dispatchers.IO) { readAllSms(activity) }
                            result.success(records)
                        } catch (e: Exception) {
                            result.error("READ_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasReadSmsPermission(context: Context): Boolean {
        return ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun countSms(context: Context): Long {
        val resolver: ContentResolver = context.contentResolver
        return resolver.query(
            Telephony.Sms.CONTENT_URI,
            arrayOf(Telephony.Sms._ID),
            null, null, null,
        )?.use { it.count.toLong() } ?: 0L
    }

    private fun readAllSms(context: Context): List<Map<String, Any?>> {
        val records = mutableListOf<Map<String, Any?>>()
        val resolver: ContentResolver = context.contentResolver
        // `content://sms` covers inbox + sent + drafts in one query.
        val uri: Uri = Telephony.Sms.CONTENT_URI
        val projection = arrayOf(
            Telephony.Sms._ID,
            Telephony.Sms.ADDRESS,
            Telephony.Sms.BODY,
            Telephony.Sms.DATE,
            Telephony.Sms.TYPE,
            Telephony.Sms.THREAD_ID,
        )
        resolver.query(uri, projection, null, null, "${Telephony.Sms.DATE} ASC")?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(Telephony.Sms._ID)
            val addrIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.ADDRESS)
            val bodyIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.BODY)
            val dateIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.DATE)
            val typeIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.TYPE)
            val threadIdx = cursor.getColumnIndexOrThrow(Telephony.Sms.THREAD_ID)
            while (cursor.moveToNext()) {
                records.add(
                    mapOf(
                        "id" to cursor.getLong(idIdx),
                        "address" to (cursor.getString(addrIdx) ?: ""),
                        "body" to (cursor.getString(bodyIdx) ?: ""),
                        "timestampMs" to cursor.getLong(dateIdx),
                        "type" to cursor.getInt(typeIdx),
                        "threadId" to cursor.getLong(threadIdx),
                    )
                )
            }
        }
        return records
    }
}
