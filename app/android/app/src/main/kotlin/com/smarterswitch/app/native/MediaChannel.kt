package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/**
 * Photos + videos channel.
 *
 * - `count` returns the combined image+video count.
 * - `summary` returns `{count, totalBytes}` so the Select screen can show an
 *   estimated transfer size (this is the only category where bytes are a
 *   meaningful number to surface — SMS/contacts/calendar are negligible).
 *
 * Permission model:
 * - API 33+: READ_MEDIA_IMAGES + READ_MEDIA_VIDEO (split granted permissions).
 * - API 32 and below: READ_EXTERNAL_STORAGE.
 *
 * Channel: `smarterswitch/media`
 */
object MediaChannel {
    private const val CHANNEL = "smarterswitch/media"

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasPermission(activity))
                "count" -> {
                    if (!hasPermission(activity)) {
                        result.error("PERMISSION_DENIED", "Media read permission not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val n = withContext(Dispatchers.IO) { countMedia(activity) }
                            result.success(n)
                        } catch (e: Exception) {
                            result.error("COUNT_FAILED", e.message, null)
                        }
                    }
                }
                "summary" -> {
                    if (!hasPermission(activity)) {
                        result.error("PERMISSION_DENIED", "Media read permission not granted", null)
                        return@setMethodCallHandler
                    }
                    scope.launch {
                        try {
                            val s = withContext(Dispatchers.IO) { summaryMedia(activity) }
                            result.success(s)
                        } catch (e: Exception) {
                            result.error("SUMMARY_FAILED", e.message, null)
                        }
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun hasPermission(context: Context): Boolean {
        val grants = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        return grants.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun countMedia(context: Context): Long {
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
        return context.contentResolver.query(
            uri,
            arrayOf(MediaStore.Files.FileColumns._ID),
            selection, args, null,
        )?.use { it.count.toLong() } ?: 0L
    }

    private fun summaryMedia(context: Context): Map<String, Long> {
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
        var count = 0L
        var bytes = 0L
        context.contentResolver.query(
            uri,
            arrayOf(MediaStore.Files.FileColumns._ID, MediaStore.Files.FileColumns.SIZE),
            selection, args, null,
        )?.use { cursor ->
            val sizeIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            while (cursor.moveToNext()) {
                count += 1
                bytes += cursor.getLong(sizeIdx)
            }
        }
        return mapOf("count" to count, "totalBytes" to bytes)
    }
}
