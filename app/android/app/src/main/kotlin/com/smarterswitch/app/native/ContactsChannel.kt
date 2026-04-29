package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Contacts channel. Counts unique aggregated contacts (`Contacts.CONTENT_URI`)
 * — this matches what the Contacts app shows the user, not the underlying raw
 * contacts which can include unmerged duplicates from multiple sources.
 *
 * Channel: `smarterswitch/contacts`
 */
object ContactsChannel {
    private const val CHANNEL = "smarterswitch/contacts"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasPermission(activity))
                "count" -> {
                    if (!hasPermission(activity)) {
                        result.error("PERMISSION_DENIED", "READ_CONTACTS not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val n = withContext(Dispatchers.IO) { countContacts(activity) }
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
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    private fun countContacts(context: Context): Long {
        return context.contentResolver.query(
            ContactsContract.Contacts.CONTENT_URI,
            arrayOf(ContactsContract.Contacts._ID),
            null, null, null,
        )?.use { it.count.toLong() } ?: 0L
    }
}
