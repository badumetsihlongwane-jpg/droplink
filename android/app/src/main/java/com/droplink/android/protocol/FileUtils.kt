package com.droplink.android.protocol

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.util.Locale

object FileUtils {
    fun sanitizeFilename(raw: String): String {
        val normalized = raw.replace('\\', '/')
        val lastComponent = normalized.split('/').lastOrNull { it.isNotEmpty() } ?: ""
        val sb = StringBuilder()
        var i = 0
        while (i < lastComponent.length) {
            val cp = lastComponent.codePointAt(i)
            val charCount = Character.charCount(cp)
            if (cp >= 0x20 && cp != 0x7F) {
                when (cp) {
                    '/'.code, '\\'.code, ':'.code -> sb.append('_')
                    else -> sb.appendCodePoint(cp)
                }
            }
            i += charCount
        }
        var result = sb.toString().trim()
        while (result.startsWith(".")) {
            result = result.drop(1)
        }
        result = result.trim()
        if (result.isEmpty() || result == "." || result == "..") {
            return "file"
        }

        val utf8Bytes = result.toByteArray(Charsets.UTF_8)
        if (utf8Bytes.size > 200) {
            val dotIdx = result.lastIndexOf('.')
            val hasExt = dotIdx > 0 && dotIdx < result.length - 1
            val ext = if (hasExt) result.substring(dotIdx) else ""
            val base = if (hasExt) result.substring(0, dotIdx) else result
            val maxBaseBytes = maxOf(16, 200 - ext.toByteArray(Charsets.UTF_8).size)
            val out = StringBuilder()
            var used = 0
            var idx = 0
            while (idx < base.length) {
                val cp = base.codePointAt(idx)
                val count = Character.charCount(cp)
                val seg = base.substring(idx, idx + count)
                val segBytes = seg.toByteArray(Charsets.UTF_8).size
                if (used + segBytes > maxBaseBytes) break
                out.append(seg)
                used += segBytes
                idx += count
            }
            val finalBase = if (out.isEmpty()) "file" else out.toString()
            result = finalBase + ext
        }
        return result
    }

    fun uniqueDestinationFile(directory: File, filename: String): File {
        val safe = sanitizeFilename(filename)
        val direct = File(directory, safe)
        if (!direct.exists()) return direct

        val dotIdx = safe.lastIndexOf('.')
        val hasExt = dotIdx > 0 && dotIdx < safe.length - 1
        val stem = if (hasExt) safe.substring(0, dotIdx) else safe
        val ext = if (hasExt) safe.substring(dotIdx) else ""

        var index = 1
        while (true) {
            val candidate = File(directory, "$stem ($index)$ext")
            if (!candidate.exists()) return candidate
            index++
        }
    }

    fun streamSha256(file: File, limitBytes: Long? = null): Triple<MessageDigest, String, Long> {
        val md = MessageDigest.getInstance("SHA-256")
        var total = 0L
        val buf = ByteArray(262_144)
        FileInputStream(file).use { fis ->
            while (true) {
                val maxToRead = if (limitBytes != null) {
                    val rem = limitBytes - total
                    if (rem <= 0) break
                    minOf(buf.size.toLong(), rem).toInt()
                } else {
                    buf.size
                }
                val n = fis.read(buf, 0, maxToRead)
                if (n <= 0) break
                md.update(buf, 0, n)
                total += n
            }
        }
        val clone = md.clone() as MessageDigest
        val hex = clone.digest().joinToString("") { "%02x".format(it) }
        return Triple(md, hex, total)
    }

    fun formatBytes(bytes: Long): String {
        val units = arrayOf("B", "KB", "MB", "GB", "TB")
        var value = bytes.toDouble()
        var idx = 0
        while (value >= 1024.0 && idx < units.lastIndex) {
            value /= 1024.0
            idx++
        }
        return if (idx == 0) "$bytes B" else String.format(Locale.US, "%.1f %s", value, units[idx])
    }

    fun formatSpeed(bytesPerSec: Double): String {
        if (bytesPerSec < 1.0) return "0 KB/s"
        return "${formatBytes(bytesPerSec.toLong())}/s"
    }
}
