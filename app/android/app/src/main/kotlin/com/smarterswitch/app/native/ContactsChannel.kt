package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.ContentProviderOperation
import android.content.Context
import android.content.pm.PackageManager
import android.provider.ContactsContract
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Contacts channel.
 *
 * - readAll returns one entry per aggregated contact, each with its
 *   display name, phones, emails, and (when available) account type so
 *   the Dart-side dedup engine can route Google-synced contacts to the
 *   "delegated to cloud sync" bucket.
 * - writeAll inserts a raw contact per record using a batch
 *   ContentProviderOperation so the structured-name + each phone + each
 *   email lands atomically. Records are written with a null account
 *   type so they're stored as on-device "Phone" contacts; users who
 *   want them sync'd to Google can move them later via the Contacts app.
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
        ContextCompat.checkSelfPermission(context, Manifest.permission.READ_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    private fun hasWrite(context: Context): Boolean =
        ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_CONTACTS) ==
            PackageManager.PERMISSION_GRANTED

    private fun handleCount(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasRead(activity)) {
            result.error("PERMISSION_DENIED", "READ_CONTACTS not granted", null)
            return
        }
        scope.launch {
            try {
                val n = withContext(Dispatchers.IO) {
                    activity.contentResolver.query(
                        ContactsContract.Contacts.CONTENT_URI,
                        arrayOf(ContactsContract.Contacts._ID),
                        null, null, null,
                    )?.use { it.count.toLong() } ?: 0L
                }
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
            result.error("PERMISSION_DENIED", "READ_CONTACTS not granted", null)
            return
        }
        scope.launch {
            try {
                val rows = withContext(Dispatchers.IO) { readAllContacts(activity) }
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
            result.error("PERMISSION_DENIED", "WRITE_CONTACTS not granted", null)
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
                    writeAllContacts(activity, records)
                }
                result.success(written)
            } catch (e: Exception) {
                result.error("WRITE_FAILED", e.message, null)
            }
        }
    }

    private fun readAllContacts(context: Context): List<Map<String, Any?>> {
        // Single pass over the Data table, aggregating by raw-contact +
        // contact id. Cheaper than N+1 queries per contact.
        data class Acc(
            var displayName: String = "",
            var account: String? = null,
            val phones: MutableSet<String> = mutableSetOf(),
            val emails: MutableSet<String> = mutableSetOf(),
        )
        val byContactId = mutableMapOf<Long, Acc>()

        // First pass: account type per raw contact, so we can attribute
        // contacts to com.google vs everything else.
        val rawAccountByContactId = mutableMapOf<Long, String?>()
        context.contentResolver.query(
            ContactsContract.RawContacts.CONTENT_URI,
            arrayOf(
                ContactsContract.RawContacts.CONTACT_ID,
                ContactsContract.RawContacts.ACCOUNT_TYPE,
            ),
            null, null, null,
        )?.use { cursor ->
            val cidIdx = cursor.getColumnIndexOrThrow(ContactsContract.RawContacts.CONTACT_ID)
            val accIdx = cursor.getColumnIndexOrThrow(ContactsContract.RawContacts.ACCOUNT_TYPE)
            while (cursor.moveToNext()) {
                val cid = cursor.getLong(cidIdx)
                val acc = cursor.getString(accIdx)
                // Prefer com.google attribution if any raw contact for this
                // aggregated contact is Google-synced.
                val existing = rawAccountByContactId[cid]
                if (existing == null || (existing != "com.google" && acc == "com.google")) {
                    rawAccountByContactId[cid] = acc
                }
            }
        }

        // Second pass: data rows.
        context.contentResolver.query(
            ContactsContract.Data.CONTENT_URI,
            arrayOf(
                ContactsContract.Data.CONTACT_ID,
                ContactsContract.Data.MIMETYPE,
                ContactsContract.Data.DATA1,
                ContactsContract.Contacts.DISPLAY_NAME,
            ),
            null, null, null,
        )?.use { cursor ->
            val cidIdx = cursor.getColumnIndexOrThrow(ContactsContract.Data.CONTACT_ID)
            val mimeIdx = cursor.getColumnIndexOrThrow(ContactsContract.Data.MIMETYPE)
            val data1Idx = cursor.getColumnIndexOrThrow(ContactsContract.Data.DATA1)
            val nameIdx = cursor.getColumnIndexOrThrow(ContactsContract.Contacts.DISPLAY_NAME)
            while (cursor.moveToNext()) {
                val cid = cursor.getLong(cidIdx)
                val acc = byContactId.getOrPut(cid) { Acc() }
                val name = cursor.getString(nameIdx)
                if (!name.isNullOrEmpty() && acc.displayName.isEmpty()) {
                    acc.displayName = name
                }
                acc.account = rawAccountByContactId[cid]
                val data1 = cursor.getString(data1Idx) ?: continue
                when (cursor.getString(mimeIdx)) {
                    ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE ->
                        acc.phones.add(data1)
                    ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE ->
                        acc.emails.add(data1)
                }
            }
        }

        return byContactId.values
            .filter { it.displayName.isNotEmpty() }
            .map {
                mapOf(
                    "displayName" to it.displayName,
                    "sourceAccountType" to it.account,
                    "phones" to it.phones.toList(),
                    "emails" to it.emails.toList(),
                )
            }
    }

    private fun writeAllContacts(
        context: Context,
        records: List<Map<String, Any?>>,
    ): Long {
        var written = 0L
        for (record in records) {
            val displayName = record["displayName"] as? String ?: continue
            @Suppress("UNCHECKED_CAST")
            val phones = (record["phones"] as? List<String>) ?: emptyList()
            @Suppress("UNCHECKED_CAST")
            val emails = (record["emails"] as? List<String>) ?: emptyList()

            val ops = ArrayList<ContentProviderOperation>()
            // Raw contact insert. Null account type stores as on-device only.
            ops.add(
                ContentProviderOperation.newInsert(ContactsContract.RawContacts.CONTENT_URI)
                    .withValue(ContactsContract.RawContacts.ACCOUNT_TYPE, null)
                    .withValue(ContactsContract.RawContacts.ACCOUNT_NAME, null)
                    .build()
            )
            // Structured name. Refers to the raw contact via the operation
            // backreference (index 0 = the insert above).
            ops.add(
                ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                    .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                    .withValue(
                        ContactsContract.Data.MIMETYPE,
                        ContactsContract.CommonDataKinds.StructuredName.CONTENT_ITEM_TYPE,
                    )
                    .withValue(
                        ContactsContract.CommonDataKinds.StructuredName.DISPLAY_NAME,
                        displayName,
                    )
                    .build()
            )
            for (phone in phones) {
                ops.add(
                    ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                        .withValue(
                            ContactsContract.Data.MIMETYPE,
                            ContactsContract.CommonDataKinds.Phone.CONTENT_ITEM_TYPE,
                        )
                        .withValue(ContactsContract.CommonDataKinds.Phone.NUMBER, phone)
                        .withValue(
                            ContactsContract.CommonDataKinds.Phone.TYPE,
                            ContactsContract.CommonDataKinds.Phone.TYPE_MOBILE,
                        )
                        .build()
                )
            }
            for (email in emails) {
                ops.add(
                    ContentProviderOperation.newInsert(ContactsContract.Data.CONTENT_URI)
                        .withValueBackReference(ContactsContract.Data.RAW_CONTACT_ID, 0)
                        .withValue(
                            ContactsContract.Data.MIMETYPE,
                            ContactsContract.CommonDataKinds.Email.CONTENT_ITEM_TYPE,
                        )
                        .withValue(ContactsContract.CommonDataKinds.Email.ADDRESS, email)
                        .withValue(
                            ContactsContract.CommonDataKinds.Email.TYPE,
                            ContactsContract.CommonDataKinds.Email.TYPE_OTHER,
                        )
                        .build()
                )
            }
            try {
                context.contentResolver.applyBatch(ContactsContract.AUTHORITY, ops)
                written += 1
            } catch (_: Exception) {
                // Skip records the OS rejects; continue with the rest.
            }
        }
        return written
    }
}
