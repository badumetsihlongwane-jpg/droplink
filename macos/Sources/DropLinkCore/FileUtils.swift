import Foundation
import CryptoKit
import UniformTypeIdentifiers

public enum FileUtils {
    /// Sanitizes an untrusted filename from a remote peer while preserving spaces, Unicode, CJK, and emoji.
    public static func sanitizeFilename(_ raw: String) -> String {
        // Take only the last path component across both Unix and Windows separators
        let normalized = raw.replacingOccurrences(of: "\\", with: "/")
        let lastComponent = normalized.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""

        // Strip control chars, NUL, and path-unsafe characters (: is invalid in macOS HFS/APFS UI layer)
        var cleanedScalars: [UnicodeScalar] = []
        for scalar in lastComponent.unicodeScalars {
            let v = scalar.value
            if v < 0x20 || v == 0x7F { continue }
            if scalar == "/" || scalar == "\\" || scalar == ":" {
                cleanedScalars.append("_")
            } else {
                cleanedScalars.append(scalar)
            }
        }

        var result = String(String.UnicodeScalarView(cleanedScalars))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Prevent dot-files or traversal tokens
        while result.hasPrefix(".") {
            result.removeFirst()
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        if result.isEmpty || result == "." || result == ".." {
            return "file"
        }

        // Enforce 200 UTF-8 bytes limit while preserving extension
        if result.utf8.count > 200 {
            let url = URL(fileURLWithPath: result)
            let ext = url.pathExtension
            let base = ext.isEmpty ? result : url.deletingPathExtension().lastPathComponent
            let suffix = ext.isEmpty ? "" : ".\(ext)"
            let maxBaseBytes = max(16, 200 - suffix.utf8.count)
            var truncated = ""
            for ch in base {
                let candidate = truncated + String(ch)
                if candidate.utf8.count > maxBaseBytes { break }
                truncated = candidate
            }
            result = (truncated.isEmpty ? "file" : truncated) + suffix
        }

        return result
    }

    /// Resolves a unique non-overwriting destination URL inside `directory`, e.g., `photo (1).jpg`.
    public static func uniqueDestinationURL(in directory: URL, filename: String) -> URL {
        let safeName = sanitizeFilename(filename)
        let fm = FileManager.default
        let candidate = directory.appendingPathComponent(safeName)
        if !fm.fileExists(atPath: candidate.path) {
            return candidate
        }

        let nsName = safeName as NSString
        let ext = nsName.pathExtension
        let stem = ext.isEmpty ? safeName : nsName.deletingPathExtension

        var index = 1
        while true {
            let nextName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            let nextURL = directory.appendingPathComponent(nextName)
            if !fm.fileExists(atPath: nextURL.path) {
                return nextURL
            }
            index += 1
        }
    }

    /// Returns available disk capacity in bytes for the volume containing `directory`.
    public static func availableDiskSpace(at directory: URL) -> UInt64? {
        do {
            let values = try directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
            if let important = values.volumeAvailableCapacityForImportantUsage, important > 0 {
                return UInt64(important)
            }
            if let standard = values.volumeAvailableCapacity, standard > 0 {
                return UInt64(standard)
            }
        } catch {}

        var stats = statvfs()
        if statvfs(directory.path, &stats) == 0 {
            return UInt64(stats.f_bavail) * UInt64(stats.f_frsize)
        }
        return nil
    }

    /// Computes SHA-256 of a file on disk using constant-memory streaming.
    public static func streamSHA256(url: URL, limitBytes: UInt64? = nil) throws -> (hasher: SHA256, digestHex: String, bytesHashed: UInt64) {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var total: UInt64 = 0
        let bufSize = 262_144

        while true {
            let toRead: Int
            if let limit = limitBytes {
                let remaining = limit > total ? (limit - total) : 0
                if remaining == 0 { break }
                toRead = Int(min(UInt64(bufSize), remaining))
            } else {
                toRead = bufSize
            }
            guard let chunk = try handle.read(upToCount: toRead), !chunk.isEmpty else {
                break
            }
            hasher.update(data: chunk)
            total += UInt64(chunk.count)
        }

        let copy = hasher
        let hex = Data(copy.finalize()).hexEncodedString()
        return (hasher, hex, total)
    }

    public static func mimeType(for url: URL) -> String {
        if let type = UTType(filenameExtension: url.pathExtension),
           let mime = type.preferredMIMEType {
            return mime
        }
        return "application/octet-stream"
    }

    public static func formatBytes(_ bytes: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(bytes)
        var idx = 0
        while value >= 1024.0 && idx < units.count - 1 {
            value /= 1024.0
            idx += 1
        }
        if idx == 0 { return "\(bytes) B" }
        return String(format: "%.1f %@", value, units[idx])
    }

    public static func formatSpeed(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond < 1 { return "0 KB/s" }
        return "\(formatBytes(UInt64(bytesPerSecond)))/s"
    }
}
