package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.app.role.RoleManager
import android.content.ContentResolver
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.provider.Telephony
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * SMS channel: reads, count, write, and the default-SMS-app role grab
 * required to make writes legal on KitKat+.
 *
 * Channel: `smarterswitch/sms`
 *
 * Methods:
 * - hasReadPermission: Boolean.
 * - count: Long.
 * - readAll: List<Map>. Full SMS dump for the dedup pass.
 * - isDefaultSmsApp: Boolean. True if this app is currently the default
 *   SMS handler.
 * - getDefaultSmsPackage: String? — the package name of whatever app is
 *   default right now. Surfaced so the receiver UI can tell the user
 *   "your previous default was Google Messages — open it after transfer
 *   to switch back."
 * - requestSmsRole: Boolean. Triggers the system "Set as default SMS app"
 *   dialog and resolves once the user accepts or denies. Result is the
 *   accept/deny outcome. Must be called from the UI thread.
 * - writeAll: Long count of records written. Only legal while the app
 *   is the default SMS handler — otherwise returns an error.
 *
 * Default-SMS UX trade-off: Android doesn't offer an API to programmatically
 * restore the previous default, so after we're done the user has to either
 * (a) open their old SMS app — most prompt to be default again on launch,
 * or (b) go to Settings → Default apps → SMS app. The app surfaces this on
 * the Done screen rather than pretending nothing changed.
 */
object SmsChannel {
    private const val CHANNEL = "smarterswitch/sms"
    private const val REQUEST_CODE_DEFAULT_SMS = 27001

    private var pendingRoleResult: MethodChannel.Result? = null

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasReadSmsPermission(activity))
                "isDefaultSmsApp" -> result.success(isDefault(activity))
                "getDefaultSmsPackage" -> result.success(currentDefault(activity))
                "count" -> handleCount(activity, scope, result)
                "readAll" -> handleReadAll(activity, scope, result)
                "requestSmsRole" -> handleRequestRole(activity, result)
                "writeAll" -> handleWriteAll(activity, scope, call, result)
                else -> result.notImplemented()
            }
        }
    }

    /// Called by MainActivity.onActivityResult so we can resolve the
    /// requestSmsRole Future after the system dialog returns.
    fun handleActivityResult(
        activity: Activity,
        requestCode: Int,
        resultCode: Int,
    ): Boolean {
        if (requestCode != REQUEST_CODE_DEFAULT_SMS) return false
        val granted = isDefault(activity)
        // Resolve regardless of resultCode; isDefault is the source of truth
        // (Activity.RESULT_OK is unreliable across OEMs for the role dialog).
        val pending = pendingRoleResult
        pendingRoleResult = null
        pending?.success(granted)
        return true
    }

    private fun hasReadSmsPermission(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_SMS) ==
            PackageManager.PERMISSION_GRANTED

    private fun isDefault(context: Context): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rm = context.getSystemService(RoleManager::class.java)
            rm?.isRoleHeld(RoleManager.ROLE_SMS) == true
        } else {
            Telephony.Sms.getDefaultSmsPackage(context) == context.packageName
        }
    }

    private fun currentDefault(context: Context): String? {
        // On Q+, getDefaultSmsPackage may return null even when role is held
        val pkg = Telephony.Sms.getDefaultSmsPackage(context)
        if (pkg != null) return pkg
        // Fallback: if we hold the role, report ourselves
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val rm = context.getSystemService(RoleManager::class.java)
            if (rm?.isRoleHeld(RoleManager.ROLE_SMS) == true) {
                return context.packageName
            }
        }
        return null
    }

    private fun handleCount(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasReadSmsPermission(activity)) {
            result.error("PERMISSION_DENIED", "READ_SMS not granted", null)
            return
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

    private fun handleReadAll(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasReadSmsPermission(activity)) {
            result.error("PERMISSION_DENIED", "READ_SMS not granted", null)
            return
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

    private fun handleRequestRole(activity: Activity, result: MethodChannel.Result) {
        if (isDefault(activity)) {
            result.success(true)
            return
        }
        if (pendingRoleResult != null) {
            result.error("BUSY", "Another role request is in flight", null)
            return
        }
        pendingRoleResult = result
        try {
            val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                val rm = activity.getSystemService(RoleManager::class.java)
                if (rm == null || !rm.isRoleAvailable(RoleManager.ROLE_SMS)) {
                    pendingRoleResult = null
                    result.success(false)
                    return
                }
                rm.createRequestRoleIntent(RoleManager.ROLE_SMS)
            } else {
                @Suppress("DEPRECATION")
                android.content.Intent(Telephony.Sms.Intents.ACTION_CHANGE_DEFAULT).apply {
                    putExtra(
                        Telephony.Sms.Intents.EXTRA_PACKAGE_NAME,
                        activity.packageName,
                    )
                }
            }
            activity.startActivityForResult(intent, REQUEST_CODE_DEFAULT_SMS)
        } catch (e: Exception) {
            pendingRoleResult = null
            result.error("ROLE_REQUEST_FAILED", e.message, null)
        }
    }

    private fun handleWriteAll(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        if (!isDefault(activity)) {
            result.error(
                "NOT_DEFAULT_SMS",
                "App must be the default SMS app to write messages.",
                null,
            )
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
                    writeAllSms(activity, records)
                }
                result.success(written)
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
        }
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

    private fun writeAllSms(
        context: Context,
        records: List<Map<String, Any?>>,
    ): Long {
        var written = 0L
        val resolver = context.contentResolver
        for (record in records) {
            val type = (record["type"] as? Number)?.toInt() ?: Telephony.Sms.MESSAGE_TYPE_INBOX
            // Pick the right per-type URI so threads form correctly.
            val targetUri: Uri = when (type) {
                Telephony.Sms.MESSAGE_TYPE_SENT -> Telephony.Sms.Sent.CONTENT_URI
                Telephony.Sms.MESSAGE_TYPE_OUTBOX -> Telephony.Sms.Outbox.CONTENT_URI
                Telephony.Sms.MESSAGE_TYPE_DRAFT -> Telephony.Sms.Draft.CONTENT_URI
                else -> Telephony.Sms.Inbox.CONTENT_URI
            }
            val values = ContentValues().apply {
                put(Telephony.Sms.ADDRESS, record["address"] as? String ?: "")
                put(Telephony.Sms.BODY, record["body"] as? String ?: "")
                put(
                    Telephony.Sms.DATE,
                    (record["timestampMs"] as? Number)?.toLong() ?: 0L,
                )
                put(Telephony.Sms.TYPE, type)
                put(Telephony.Sms.READ, 1)
                put(Telephony.Sms.SEEN, 1)
            }
            try {
                resolver.insert(targetUri, values)
                written += 1
            } catch (_: Exception) {
                // Skip rejected rows; continue with the rest.
            }
        }
        return written
    }
}
