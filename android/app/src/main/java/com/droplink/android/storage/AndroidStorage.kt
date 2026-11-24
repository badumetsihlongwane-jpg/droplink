package com.droplink.android.storage

import android.content.ContentValues
import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.os.StatFs
import android.provider.MediaStore
import android.provider.OpenableColumns
import com.droplink.android.protocol.FileUtils
import com.droplink.android.protocol.IncomingFileCommitter
import com.droplink.android.protocol.OutgoingFileSource
import java.io.File
import java.io.FileInputStream
import java.io.InputStream

class ContentUriFileSource(
    private val context: Context,
    val uri: Uri
) : OutgoingFileSource {
    override val filename: String
    override val size: Long
    override val mimeType: String

    init {
        var resolvedName = "file"
        var resolvedSize = -1L
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                val nameIdx = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                val sizeIdx = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (nameIdx >= 0) {
                    cursor.getString(nameIdx)?.takeIf { it.isNotBlank() }?.let { resolvedName = it }
                }
                if (sizeIdx >= 0 && !cursor.isNull(sizeIdx)) {
                    resolvedSize = cursor.getLong(sizeIdx)
                }
            }
        }
        if (resolvedSize < 0L) {
            resolvedSize = runCatching {
                context.contentResolver.openAssetFileDescriptor(uri, "r")?.use { it.length } ?: 0L
            }.getOrDefault(0L).coerceAtLeast(0L)
        }
        filename = resolvedName
        size = resolvedSize
        mimeType = context.contentResolver.getType(uri) ?: "application/octet-stream"
    }

    override fun openInputStream(): InputStream {
        return context.contentResolver.openInputStream(uri)
            ?: throw IllegalStateException("Unable to open selected file: $filename")
    }
}

class AndroidMediaStoreCommitter(private val context: Context) : IncomingFileCommitter {
    override fun commitVerifiedFile(partFile: File, sanitizedFilename: String, mimeType: String): Pair<String, String?> {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            val resolver = context.contentResolver
            val safeMime = mimeType.ifBlank { "application/octet-stream" }
            val values = ContentValues().apply {
                put(MediaStore.Downloads.DISPLAY_NAME, sanitizedFilename)
                put(MediaStore.Downloads.MIME_TYPE, safeMime)
                put(MediaStore.Downloads.RELATIVE_PATH, "${Environment.DIRECTORY_DOWNLOADS}/DropLink")
                put(MediaStore.Downloads.IS_PENDING, 1)
            }
            val collection = MediaStore.Downloads.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
            val uri = resolver.insert(collection, values)
                ?: throw IllegalStateException("Failed to create MediaStore download entry")

            try {
                resolver.openOutputStream(uri)?.use { out ->
                    FileInputStream(partFile).use { input ->
                        input.copyTo(out, bufferSize = 262_144)
                    }
                    out.flush()
                } ?: throw IllegalStateException("Unable to open MediaStore output stream")

                val doneValues = ContentValues().apply {
                    put(MediaStore.Downloads.IS_PENDING, 0)
                }
                resolver.update(uri, doneValues, null, null)
                partFile.delete()

                // Read back the actual display name assigned by MediaStore (handles OS deduplication)
                var finalName = sanitizedFilename
                resolver.query(uri, arrayOf(MediaStore.Downloads.DISPLAY_NAME), null, null, null)?.use { c ->
                    if (c.moveToFirst()) {
                        c.getString(0)?.takeIf { it.isNotBlank() }?.let { finalName = it }
                    }
                }
                return finalName to uri.toString()
            } catch (e: Exception) {
                resolver.delete(uri, null, null)
                throw e
            }
        } else {
            @Suppress("DEPRECATION")
            val downloadsDir = File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS),
                "DropLink"
            )
            downloadsDir.mkdirs()
            val finalFile = FileUtils.uniqueDestinationFile(downloadsDir, sanitizedFilename)
            if (!partFile.renameTo(finalFile)) {
                partFile.copyTo(finalFile, overwrite = false)
                partFile.delete()
            }
            return finalFile.name to Uri.fromFile(finalFile).toString()
        }
    }

    override fun availableBytes(): Long {
        return runCatching {
            val stat = StatFs(context.cacheDir.absolutePath)
            stat.availableBytes
        }.getOrDefault(Long.MAX_VALUE)
    }
}
