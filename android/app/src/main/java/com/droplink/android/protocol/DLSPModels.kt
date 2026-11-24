package com.droplink.android.protocol

import java.net.URI
import java.net.URLDecoder
import java.net.URLEncoder
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.util.Base64
import java.util.UUID

object DLSPConstants {
    const val PROTOCOL_VERSION = "DLSP/1"
    const val MAX_HANDSHAKE_BYTES = 65_536
    const val MAX_PLAINTEXT_FRAME_BYTES = 1_049_600 // 1 MiB + 1 KiB
    const val DEFAULT_CHUNK_SIZE = 262_144 // 256 KiB
    const val GCM_TAG_LENGTH = 16
    const val DIRECTION_CLIENT_TO_SERVER = 1
    const val DIRECTION_SERVER_TO_CLIENT = 2
}

enum class DLSPFrameType(val code: Byte) {
    PING(0x01),
    PONG(0x02),
    TRANSFER_OFFER(0x10),
    TRANSFER_ACCEPT(0x11),
    TRANSFER_REJECT(0x12),
    TRANSFER_CHUNK(0x13),
    TRANSFER_COMPLETE(0x14),
    TRANSFER_ACK(0x15),
    TRANSFER_CANCEL(0x16),
    SESSION_CLOSE(0x20);

    companion object {
        fun fromByte(b: Byte): DLSPFrameType? = entries.firstOrNull { it.code == b }
    }
}

data class ClientHello(
    val protocol: String = DLSPConstants.PROTOCOL_VERSION,
    val sessionId: String,
    val mode: String,
    val reconnectToken: String? = null,
    val deviceId: String,
    val deviceName: String,
    val clientNonce: String,
    val clientPublicKey: String,
    val authProof: String
)

data class ServerHello(
    val ok: Boolean = false,
    val protocol: String? = null,
    val serverName: String? = null,
    val serverNonce: String? = null,
    val serverPublicKey: String? = null,
    val serverProof: String? = null,
    val reconnectToken: String? = null,
    val code: String? = null,
    val message: String? = null
)

data class PingPongPayload(val ts: Long)

data class TransferOfferPayload(
    val transferId: String,
    val filename: String,
    val size: Long,
    val mimeType: String,
    val chunkSize: Int = DLSPConstants.DEFAULT_CHUNK_SIZE
)

data class TransferAcceptPayload(
    val transferId: String,
    val resumeOffset: Long = 0L
)

data class TransferRejectPayload(
    val transferId: String,
    val code: String,
    val reason: String
)

data class TransferCompletePayload(
    val transferId: String,
    val sha256: String,
    val totalBytes: Long
)

data class TransferAckPayload(
    val transferId: String,
    val verified: Boolean,
    val savedFilename: String? = null,
    val error: String? = null
)

data class TransferCancelPayload(
    val transferId: String,
    val reason: String
)

data class SessionClosePayload(val reason: String)

data class PairingPayload(
    val version: Int = 1,
    val hosts: List<String>,
    val port: Int,
    val sessionId: String,
    val pairingSecret: ByteArray,
    val expiresAt: Long,
    val deviceName: String
) {
    fun toUri(): String {
        val encodedName = URLEncoder.encode(deviceName, "UTF-8").replace("+", "%20")
        val keyB64 = Base64.getUrlEncoder().withoutPadding().encodeToString(pairingSecret)
        return "droplink://pair?v=$version&h=${hosts.joinToString(",")}&p=$port&s=$sessionId&k=$keyB64&e=$expiresAt&n=$encodedName"
    }

    override fun equals(other: Any?): Boolean {
        if (this === other) return true
        if (other !is PairingPayload) return false
        return version == other.version &&
            hosts == other.hosts &&
            port == other.port &&
            sessionId == other.sessionId &&
            pairingSecret.contentEquals(other.pairingSecret) &&
            expiresAt == other.expiresAt &&
            deviceName == other.deviceName
    }

    override fun hashCode(): Int {
        var result = version
        result = 31 * result + hosts.hashCode()
        result = 31 * result + port
        result = 31 * result + sessionId.hashCode()
        result = 31 * result + pairingSecret.contentHashCode()
        result = 31 * result + expiresAt.hashCode()
        result = 31 * result + deviceName.hashCode()
        return result
    }

    companion object {
        fun parse(uriString: String): PairingPayload? {
            return try {
                val uri = URI(uriString.trim())
                if (uri.scheme != "droplink" || uri.host != "pair") return null
                val rawQuery = uri.rawQuery ?: return null
                val params = mutableMapOf<String, String>()
                for (pair in rawQuery.split("&")) {
                    val idx = pair.indexOf('=')
                    if (idx > 0) {
                        val k = URLDecoder.decode(pair.substring(0, idx), "UTF-8")
                        val v = URLDecoder.decode(pair.substring(idx + 1), "UTF-8")
                        params[k] = v
                    }
                }
                val version = params["v"]?.toIntOrNull() ?: return null
                if (version != 1) return null
                val hosts = params["h"]?.split(",")?.map { it.trim() }?.filter { it.isNotEmpty() } ?: return null
                if (hosts.isEmpty()) return null
                val port = params["p"]?.toIntOrNull() ?: return null
                if (port <= 0 || port > 65535) return null
                val sessionId = params["s"] ?: return null
                if (sessionId.length != 32) return null
                val keyB64 = params["k"] ?: return null
                val psk = Base64.getUrlDecoder().decode(keyB64)
                if (psk.size != 32) return null
                val expiresAt = params["e"]?.toLongOrNull() ?: return null
                val name = params["n"]?.takeIf { it.isNotBlank() } ?: "DropLink Mac"
                PairingPayload(version, hosts, port, sessionId, psk, expiresAt, name)
            } catch (_: Exception) {
                null
            }
        }
    }
}

object ChunkCodec {
    fun encode(transferId: UUID, offset: Long, data: ByteArray, length: Int = data.size): ByteArray {
        val buf = ByteBuffer.allocate(24 + length).order(ByteOrder.BIG_ENDIAN)
        buf.putLong(transferId.mostSignificantBits)
        buf.putLong(transferId.leastSignificantBits)
        buf.putLong(offset)
        buf.put(data, 0, length)
        return buf.array()
    }

    data class DecodedChunk(val transferId: UUID, val offset: Long, val data: ByteArray)

    fun decode(payload: ByteArray): DecodedChunk? {
        if (payload.size < 24) return null
        val buf = ByteBuffer.wrap(payload).order(ByteOrder.BIG_ENDIAN)
        val msb = buf.long
        val lsb = buf.long
        val offset = buf.long
        val chunk = ByteArray(payload.size - 24)
        buf.get(chunk)
        return DecodedChunk(UUID(msb, lsb), offset, chunk)
    }
}
