package com.smarterswitch.app.native

import android.Manifest
import android.app.Activity
import android.content.ContentValues
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.core.content.ContextCompat
import kotlin.math.cos
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.OutputStream
import java.security.MessageDigest

/**
 * Photos + videos channel.
 *
 * Read side (sender):
 * - hasReadPermission, count, summary (existing).
 * - readMetadata: list per-file metadata (uri, fileName, byteSize, mimeType,
 *   takenAtMs, kind). No file bytes yet — that's what readSha256 and
 *   readChunk are for.
 * - readSha256(uri): compute sha256 of file bytes off the main thread.
 * - readChunk(uri, offset, length): return a slice of file bytes; Dart
 *   side base64-encodes for transport.
 *
 * Write side (receiver):
 * - writeStart(metadata): MediaStore.Images/Video insert, open OutputStream,
 *   stash by sha256.
 * - writeChunk(sha256, bytes): append to the stashed stream.
 * - writeEnd(sha256): close the stream, clear IS_PENDING (API 29+) so the
 *   file becomes visible to the gallery.
 *
 * Channel: `smarterswitch/media`
 */
object MediaChannel {
    private const val CHANNEL = "smarterswitch/media"

    /// Per-active-write state. Keyed by sha256 of the source file. Lives only
    /// while a single file's chunks are streaming through the receiver.
    private data class PendingWrite(
        val uri: Uri,
        val outputStream: OutputStream,
    )

    private val pendingWrites = mutableMapOf<String, PendingWrite>()

    fun register(flutterEngine: FlutterEngine, activity: Activity) {
        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        val scope = CoroutineScope(Dispatchers.Main)
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "hasReadPermission" -> result.success(hasReadPermission(activity))
                "count" -> handleCount(activity, scope, result)
                "summary" -> handleSummary(activity, scope, result)
                "readMetadata" -> handleReadMetadata(activity, scope, result)
                "readSha256" -> handleReadSha256(activity, scope, call, result)
                "computePHash" -> handleComputePHash(activity, scope, call, result)
                "readChunk" -> handleReadChunk(activity, scope, call, result)
                "writeStart" -> handleWriteStart(activity, scope, call, result)
                "writeChunk" -> handleWriteChunk(scope, call, result)
                "writeEnd" -> handleWriteEnd(activity, scope, call, result)
                else -> result.notImplemented()
            }
        }
    }

    private fun hasReadPermission(context: Context): Boolean {
        val grants = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            listOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            listOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }
        return grants.all {
            ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
        }
    }

    private fun handleCount(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasReadPermission(activity)) {
            result.error("PERMISSION_DENIED", "Media read permission not granted", null)
            return
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

    private fun handleSummary(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasReadPermission(activity)) {
            result.error("PERMISSION_DENIED", "Media read permission not granted", null)
            return
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

    private fun handleReadMetadata(
        activity: Activity,
        scope: CoroutineScope,
        result: MethodChannel.Result,
    ) {
        if (!hasReadPermission(activity)) {
            result.error("PERMISSION_DENIED", "Media read permission not granted", null)
            return
        }
        scope.launch {
            try {
                val rows = withContext(Dispatchers.IO) { readMetadata(activity) }
                result.success(rows)
            } catch (e: Exception) {
                result.error("READ_FAILED", e.message, null)
            }
        }
    }

    private fun handleReadSha256(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("BAD_ARGUMENT", "uri required", null)
            return
        }
        scope.launch {
            try {
                val hex = withContext(Dispatchers.IO) {
                    sha256Hex(activity, Uri.parse(uriString))
                }
                result.success(hex)
            } catch (e: Exception) {
                result.error("SHA_FAILED", e.message, null)
            }
        }
    }

    private fun handleComputePHash(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val uriString = call.argument<String>("uri")
        if (uriString == null) {
            result.error("BAD_ARGUMENT", "uri required", null)
            return
        }
        scope.launch {
            try {
                val hash = withContext(Dispatchers.IO) {
                    computePHash(activity, Uri.parse(uriString))
                }
                // Dart receives a Long; null on failures (decode error,
                // unsupported format, etc).
                result.success(hash)
            } catch (e: Exception) {
                result.error("PHASH_FAILED", e.message, null)
            }
        }
    }

    private fun handleReadChunk(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val uriString = call.argument<String>("uri")
        val offset = call.argument<Number>("offset")?.toLong()
        val length = call.argument<Number>("length")?.toInt()
        if (uriString == null || offset == null || length == null) {
            result.error("BAD_ARGUMENT", "uri/offset/length required", null)
            return
        }
        scope.launch {
            try {
                val bytes = withContext(Dispatchers.IO) {
                    readChunk(activity, Uri.parse(uriString), offset, length)
                }
                result.success(bytes)
            } catch (e: Exception) {
                result.error("READ_CHUNK_FAILED", e.message, null)
            }
        }
    }

    private fun handleWriteStart(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val sha = call.argument<String>("sha256")
        val fileName = call.argument<String>("fileName")
        val mimeType = call.argument<String>("mimeType")
        val kind = call.argument<String>("kind") // "image" or "video"
        val takenAtMs = call.argument<Number>("takenAtMs")?.toLong()
        if (sha == null || fileName == null || mimeType == null || kind == null) {
            result.error("BAD_ARGUMENT", "sha256/fileName/mimeType/kind required", null)
            return
        }
        scope.launch {
            try {
                val opened = withContext(Dispatchers.IO) {
                    writeStart(activity, sha, fileName, mimeType, kind, takenAtMs)
                }
                result.success(opened)
            } catch (e: Exception) {
                result.error("WRITE_START_FAILED", e.message, null)
            }
        }
    }

    private fun handleWriteChunk(
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val sha = call.argument<String>("sha256")
        val bytes = call.argument<ByteArray>("bytes")
        if (sha == null || bytes == null) {
            result.error("BAD_ARGUMENT", "sha256/bytes required", null)
            return
        }
        scope.launch {
            try {
                val ok = withContext(Dispatchers.IO) {
                    val pending = pendingWrites[sha]
                        ?: throw IllegalStateException("No open write for $sha")
                    pending.outputStream.write(bytes)
                    true
                }
                result.success(ok)
            } catch (e: Exception) {
                result.error("WRITE_CHUNK_FAILED", e.message, null)
            }
        }
    }

    private fun handleWriteEnd(
        activity: Activity,
        scope: CoroutineScope,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        val sha = call.argument<String>("sha256")
        if (sha == null) {
            result.error("BAD_ARGUMENT", "sha256 required", null)
            return
        }
        scope.launch {
            try {
                val ok = withContext(Dispatchers.IO) {
                    val pending = pendingWrites.remove(sha) ?: return@withContext false
                    pending.outputStream.flush()
                    pending.outputStream.close()
                    // Clear IS_PENDING so the file becomes visible to other
                    // apps (gallery, file managers).
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                        val values = ContentValues().apply {
                            put(MediaStore.MediaColumns.IS_PENDING, 0)
                        }
                        try {
                            activity.contentResolver.update(pending.uri, values, null, null)
                        } catch (_: Exception) {}
                    }
                    true
                }
                result.success(ok)
            } catch (e: Exception) {
                result.error("WRITE_END_FAILED", e.message, null)
            }
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

    private fun readMetadata(context: Context): List<Map<String, Any?>> {
        val out = mutableListOf<Map<String, Any?>>()
        val uri = MediaStore.Files.getContentUri(MediaStore.VOLUME_EXTERNAL)
        val selection = "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ? OR " +
            "${MediaStore.Files.FileColumns.MEDIA_TYPE} = ?"
        val args = arrayOf(
            MediaStore.Files.FileColumns.MEDIA_TYPE_IMAGE.toString(),
            MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO.toString(),
        )
        val projection = arrayOf(
            MediaStore.Files.FileColumns._ID,
            MediaStore.Files.FileColumns.DISPLAY_NAME,
            MediaStore.Files.FileColumns.SIZE,
            MediaStore.Files.FileColumns.MIME_TYPE,
            MediaStore.Files.FileColumns.MEDIA_TYPE,
            MediaStore.Files.FileColumns.DATE_TAKEN,
        )
        context.contentResolver.query(uri, projection, selection, args, null)?.use { cursor ->
            val idIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns._ID)
            val nameIdx =
                cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DISPLAY_NAME)
            val sizeIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.SIZE)
            val mimeIdx = cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MIME_TYPE)
            val typeIdx =
                cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.MEDIA_TYPE)
            val takenIdx =
                cursor.getColumnIndexOrThrow(MediaStore.Files.FileColumns.DATE_TAKEN)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idIdx)
                val isVideo = cursor.getInt(typeIdx) ==
                    MediaStore.Files.FileColumns.MEDIA_TYPE_VIDEO
                val baseUri = if (isVideo) {
                    MediaStore.Video.Media.EXTERNAL_CONTENT_URI
                } else {
                    MediaStore.Images.Media.EXTERNAL_CONTENT_URI
                }
                val rowUri = baseUri.buildUpon().appendPath(id.toString()).build()
                out.add(
                    mapOf(
                        "uri" to rowUri.toString(),
                        "fileName" to (cursor.getString(nameIdx) ?: ""),
                        "byteSize" to cursor.getLong(sizeIdx),
                        "mimeType" to (cursor.getString(mimeIdx) ?: "application/octet-stream"),
                        "kind" to if (isVideo) "video" else "image",
                        "takenAtMs" to (if (cursor.isNull(takenIdx)) null else cursor.getLong(takenIdx)),
                    )
                )
            }
        }
        return out
    }

    /// 64-bit perceptual hash via the standard DCT pHash algorithm:
    /// 1. Decode bitmap, scale to 32×32.
    /// 2. Convert to grayscale.
    /// 3. 2D DCT-II.
    /// 4. Take top-left 8×8 (low-frequency components).
    /// 5. Compute mean (excluding the [0][0] DC term — heavy bias).
    /// 6. Bit per coefficient: 1 if > mean, 0 otherwise.
    /// 7. Pack into a 64-bit Long.
    ///
    /// Returns `null` if the bitmap can't be decoded (e.g. videos, RAW
    /// formats Android doesn't natively support). Dart-side then treats
    /// the photo as having no pHash and falls back to sha256-only dedup.
    private fun computePHash(context: Context, uri: Uri): Long? {
        val bitmap = context.contentResolver.openInputStream(uri)?.use { stream ->
            BitmapFactory.decodeStream(stream)
        } ?: return null
        val scaled = Bitmap.createScaledBitmap(bitmap, 32, 32, true)
        if (scaled !== bitmap) bitmap.recycle()
        val gray = DoubleArray(32 * 32)
        for (y in 0 until 32) {
            for (x in 0 until 32) {
                val c = scaled.getPixel(x, y)
                // Luminance via the BT.601 weights — close enough for pHash;
                // any reasonable grayscale conversion produces stable hashes.
                val r = Color.red(c)
                val g = Color.green(c)
                val b = Color.blue(c)
                gray[y * 32 + x] = 0.299 * r + 0.587 * g + 0.114 * b
            }
        }
        scaled.recycle()
        // 2D DCT-II — separable. Compute row DCTs first, then column DCTs
        // on the result. We only need the top-left 8×8 of the output, but
        // computing the full 32×32 keeps the code simple; perf is fine
        // (sub-millisecond per photo on modern Android hardware).
        val temp = DoubleArray(32 * 32)
        for (y in 0 until 32) {
            for (u in 0 until 32) {
                var sum = 0.0
                for (x in 0 until 32) {
                    sum += gray[y * 32 + x] * cos((2 * x + 1) * u * Math.PI / 64.0)
                }
                temp[y * 32 + u] = sum
            }
        }
        val dct = DoubleArray(32 * 32)
        for (u in 0 until 32) {
            for (v in 0 until 32) {
                var sum = 0.0
                for (y in 0 until 32) {
                    sum += temp[y * 32 + u] *
                        cos((2 * y + 1) * v * Math.PI / 64.0)
                }
                // Normalization: scaling by sqrt(2/N) per DCT axis. Doesn't
                // affect the final hash bits since we threshold at the
                // mean — but keeps the values in a sensible range.
                dct[v * 32 + u] = sum / 16.0
            }
        }
        // Top-left 8×8, skip DC.
        val low = DoubleArray(64)
        for (y in 0 until 8) {
            for (x in 0 until 8) {
                low[y * 8 + x] = dct[y * 32 + x]
            }
        }
        var sum = 0.0
        for (i in 1 until 64) sum += low[i]
        val mean = sum / 63.0
        var hash = 0L
        for (i in 0 until 64) {
            if (low[i] > mean) hash = hash or (1L shl i)
        }
        return hash
    }

    private fun sha256Hex(context: Context, uri: Uri): String {
        val md = MessageDigest.getInstance("SHA-256")
        context.contentResolver.openInputStream(uri)?.use { stream ->
            val buf = ByteArray(64 * 1024)
            while (true) {
                val n = stream.read(buf)
                if (n <= 0) break
                md.update(buf, 0, n)
            }
        } ?: throw IllegalStateException("Could not open $uri")
        return md.digest().joinToString("") { "%02x".format(it) }
    }

    private fun readChunk(
        context: Context,
        uri: Uri,
        offset: Long,
        length: Int,
    ): ByteArray {
        context.contentResolver.openInputStream(uri)?.use { stream ->
            // Skip to offset; InputStream.skip can short-skip, so loop.
            var skipped = 0L
            while (skipped < offset) {
                val n = stream.skip(offset - skipped)
                if (n <= 0) break
                skipped += n
            }
            val out = ByteArray(length)
            var read = 0
            while (read < length) {
                val n = stream.read(out, read, length - read)
                if (n <= 0) break
                read += n
            }
            return if (read == length) out else out.copyOf(read)
        } ?: throw IllegalStateException("Could not open $uri")
    }

    private fun writeStart(
        context: Context,
        sha: String,
        fileName: String,
        mimeType: String,
        kind: String,
        takenAtMs: Long?,
    ): Boolean {
        if (pendingWrites.containsKey(sha)) {
            // Already streaming — caller error, but be forgiving.
            return false
        }
        val baseUri = if (kind == "video") {
            MediaStore.Video.Media.EXTERNAL_CONTENT_URI
        } else {
            MediaStore.Images.Media.EXTERNAL_CONTENT_URI
        }
        val values = ContentValues().apply {
            put(MediaStore.MediaColumns.DISPLAY_NAME, fileName)
            put(MediaStore.MediaColumns.MIME_TYPE, mimeType)
            if (takenAtMs != null) {
                put(MediaStore.MediaColumns.DATE_ADDED, takenAtMs / 1000)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                    put(MediaStore.MediaColumns.DATE_TAKEN, takenAtMs)
                }
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                put(MediaStore.MediaColumns.IS_PENDING, 1)
                val relativePath = if (kind == "video") {
                    "Movies/SmarterSwitch"
                } else {
                    "Pictures/SmarterSwitch"
                }
                put(MediaStore.MediaColumns.RELATIVE_PATH, relativePath)
            }
        }
        val uri = context.contentResolver.insert(baseUri, values) ?: return false
        val out = context.contentResolver.openOutputStream(uri) ?: return false
        pendingWrites[sha] = PendingWrite(uri, out)
        return true
    }
}
