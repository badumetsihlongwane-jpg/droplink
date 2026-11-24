package com.droplink.android.protocol

import java.math.BigInteger
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.AlgorithmParameters
import java.security.KeyFactory
import java.security.KeyPair
import java.security.KeyPairGenerator
import java.security.MessageDigest
import java.security.PrivateKey
import java.security.PublicKey
import java.security.SecureRandom
import java.security.interfaces.ECPublicKey
import java.security.spec.ECGenParameterSpec
import java.security.spec.ECParameterSpec
import java.security.spec.ECPoint
import java.security.spec.ECPrivateKeySpec
import java.security.spec.ECPublicKeySpec
import javax.crypto.Cipher
import javax.crypto.KeyAgreement
import javax.crypto.Mac
import javax.crypto.spec.GCMParameterSpec
import javax.crypto.spec.SecretKeySpec

data class DerivedSessionKeys(
    val c2sKey: ByteArray,
    val s2cKey: ByteArray,
    val reconnectKey: ByteArray
)

object DLSPCrypto {
    private val secureRandom = SecureRandom()

    private val p256ParamSpec: ECParameterSpec by lazy {
        val params = AlgorithmParameters.getInstance("EC")
        params.init(ECGenParameterSpec("secp256r1"))
        params.getParameterSpec(ECParameterSpec::class.java)
    }

    fun randomBytes(count: Int): ByteArray = ByteArray(count).also { secureRandom.nextBytes(it) }

    fun ByteArray.toHex(): String = joinToString("") { "%02x".format(it) }

    fun hexToBytes(hex: String): ByteArray {
        require(hex.length % 2 == 0) { "Hex string must have even length" }
        return ByteArray(hex.length / 2) { i ->
            hex.substring(i * 2, i * 2 + 2).toInt(16).toByte()
        }
    }

    fun constantTimeEquals(a: ByteArray, b: ByteArray): Boolean = MessageDigest.isEqual(a, b)

    fun sha256(data: ByteArray): ByteArray = MessageDigest.getInstance("SHA-256").digest(data)

    fun hmacSha256(key: ByteArray, data: ByteArray): ByteArray {
        val mac = Mac.getInstance("HmacSHA256")
        mac.init(SecretKeySpec(key, "HmacSHA256"))
        return mac.doFinal(data)
    }

    fun clientAuthProof(
        authKey: ByteArray,
        sessionId: String,
        mode: String,
        clientNonce: String,
        clientPublicKeyHex: String,
        deviceId: String
    ): String {
        val msg = "DLSP1-CLIENT|$sessionId|$mode|$clientNonce|$clientPublicKeyHex|$deviceId"
        return hmacSha256(authKey, msg.toByteArray(Charsets.UTF_8)).toHex()
    }

    fun serverAuthProof(
        authKey: ByteArray,
        sessionId: String,
        mode: String,
        clientNonce: String,
        serverNonce: String,
        clientPublicKeyHex: String,
        serverPublicKeyHex: String
    ): String {
        val msg = "DLSP1-SERVER|$sessionId|$mode|$clientNonce|$serverNonce|$clientPublicKeyHex|$serverPublicKeyHex"
        return hmacSha256(authKey, msg.toByteArray(Charsets.UTF_8)).toHex()
    }

    fun generateP256KeyPair(): KeyPair {
        val kpg = KeyPairGenerator.getInstance("EC")
        kpg.initialize(ECGenParameterSpec("secp256r1"), secureRandom)
        return kpg.generateKeyPair()
    }

    fun privateKeyFromRawScalar(raw32: ByteArray): PrivateKey {
        val s = BigInteger(1, raw32)
        val spec = ECPrivateKeySpec(s, p256ParamSpec)
        return KeyFactory.getInstance("EC").generatePrivate(spec)
    }

    fun encodePublicKeyX963(publicKey: PublicKey): ByteArray {
        val ecPub = publicKey as ECPublicKey
        val x = bigIntToUnsigned32(ecPub.w.affineX)
        val y = bigIntToUnsigned32(ecPub.w.affineY)
        val out = ByteArray(65)
        out[0] = 0x04
        System.arraycopy(x, 0, out, 1, 32)
        System.arraycopy(y, 0, out, 33, 32)
        return out
    }

    fun decodePublicKeyX963(raw65: ByteArray): PublicKey {
        require(raw65.size == 65 && raw65[0] == 0x04.toByte()) { "Invalid P-256 uncompressed public key" }
        val x = BigInteger(1, raw65.copyOfRange(1, 33))
        val y = BigInteger(1, raw65.copyOfRange(33, 65))
        val spec = ECPublicKeySpec(ECPoint(x, y), p256ParamSpec)
        return KeyFactory.getInstance("EC").generatePublic(spec)
    }

    fun computeECDHSharedSecret(privateKey: PrivateKey, peerPublicKeyX963: ByteArray): ByteArray {
        val peerPub = decodePublicKeyX963(peerPublicKeyX963)
        val ka = KeyAgreement.getInstance("ECDH")
        ka.init(privateKey)
        ka.doPhase(peerPub, true)
        val raw = ka.generateSecret()
        return padTo32(raw)
    }

    fun hkdfSha256Expand32(prk: ByteArray, info: String): ByteArray {
        val infoBytes = info.toByteArray(Charsets.UTF_8)
        val input = ByteArray(infoBytes.size + 1)
        System.arraycopy(infoBytes, 0, input, 0, infoBytes.size)
        input[infoBytes.size] = 0x01
        return hmacSha256(prk, input)
    }

    fun deriveKeys(
        ecdhShared: ByteArray,
        authKey: ByteArray,
        sessionId: String,
        clientNonce: String,
        serverNonce: String
    ): DerivedSessionKeys {
        val ikm = ByteArray(ecdhShared.size + authKey.size)
        System.arraycopy(ecdhShared, 0, ikm, 0, ecdhShared.size)
        System.arraycopy(authKey, 0, ikm, ecdhShared.size, authKey.size)

        val salt = sha256("DLSP1-SALT|$sessionId|$clientNonce|$serverNonce".toByteArray(Charsets.UTF_8))
        val prk = hmacSha256(salt, ikm)

        return DerivedSessionKeys(
            c2sKey = hkdfSha256Expand32(prk, "DLSP1-C2S-KEY"),
            s2cKey = hkdfSha256Expand32(prk, "DLSP1-S2C-KEY"),
            reconnectKey = hkdfSha256Expand32(prk, "DLSP1-RECONNECT")
        )
    }

    fun makeNonce(direction: Int, seq: Long): ByteArray =
        ByteBuffer.allocate(12).order(ByteOrder.BIG_ENDIAN)
            .putInt(direction)
            .putLong(seq)
            .array()

    fun makeAAD(direction: Int, seq: Long, plaintextLength: Int): ByteArray =
        ByteBuffer.allocate(16).order(ByteOrder.BIG_ENDIAN)
            .putInt(direction)
            .putLong(seq)
            .putInt(plaintextLength)
            .array()

    fun encryptFrame(key: ByteArray, direction: Int, seq: Long, plaintext: ByteArray): ByteArray {
        require(plaintext.size <= DLSPConstants.MAX_PLAINTEXT_FRAME_BYTES) { "Frame too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = makeNonce(direction, seq)
        val aad = makeAAD(direction, seq, plaintext.size)
        cipher.init(Cipher.ENCRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(plaintext)
    }

    fun decryptFrame(key: ByteArray, direction: Int, seq: Long, ciphertextAndTag: ByteArray): ByteArray {
        require(ciphertextAndTag.size >= DLSPConstants.GCM_TAG_LENGTH) { "Ciphertext too short" }
        val plaintextLen = ciphertextAndTag.size - DLSPConstants.GCM_TAG_LENGTH
        require(plaintextLen <= DLSPConstants.MAX_PLAINTEXT_FRAME_BYTES) { "Frame too large" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        val nonce = makeNonce(direction, seq)
        val aad = makeAAD(direction, seq, plaintextLen)
        cipher.init(Cipher.DECRYPT_MODE, SecretKeySpec(key, "AES"), GCMParameterSpec(128, nonce))
        cipher.updateAAD(aad)
        return cipher.doFinal(ciphertextAndTag)
    }

    private fun bigIntToUnsigned32(bi: BigInteger): ByteArray {
        val raw = bi.toByteArray()
        return padTo32(raw)
    }

    private fun padTo32(raw: ByteArray): ByteArray {
        if (raw.size == 32) return raw
        val out = ByteArray(32)
        if (raw.size > 32) {
            // Strip leading sign byte(s)
            System.arraycopy(raw, raw.size - 32, out, 0, 32)
        } else {
            System.arraycopy(raw, 0, out, 32 - raw.size, raw.size)
        }
        return out
    }
}

class EncryptedFrameCodec(isServer: Boolean, keys: DerivedSessionKeys) {
    private val sendKey: ByteArray = if (isServer) keys.s2cKey else keys.c2sKey
    private val recvKey: ByteArray = if (isServer) keys.c2sKey else keys.s2cKey
    private val sendDirection: Int = if (isServer) DLSPConstants.DIRECTION_SERVER_TO_CLIENT else DLSPConstants.DIRECTION_CLIENT_TO_SERVER
    private val recvDirection: Int = if (isServer) DLSPConstants.DIRECTION_CLIENT_TO_SERVER else DLSPConstants.DIRECTION_SERVER_TO_CLIENT
    private var sendSeq: Long = 0L
    private var recvSeq: Long = 0L
    private val sendLock = Any()
    private val recvLock = Any()

    fun seal(type: DLSPFrameType, payload: ByteArray): ByteArray {
        val seq = synchronized(sendLock) { sendSeq++ }
        val plaintext = ByteArray(1 + payload.size)
        plaintext[0] = type.code
        System.arraycopy(payload, 0, plaintext, 1, payload.size)
        val body = DLSPCrypto.encryptFrame(sendKey, sendDirection, seq, plaintext)
        val wire = ByteBuffer.allocate(4 + body.size).order(ByteOrder.BIG_ENDIAN)
        wire.putInt(body.size)
        wire.put(body)
        return wire.array()
    }

    fun open(ciphertextAndTag: ByteArray): Pair<DLSPFrameType, ByteArray> {
        val seq = synchronized(recvLock) { recvSeq++ }
        val plaintext = DLSPCrypto.decryptFrame(recvKey, recvDirection, seq, ciphertextAndTag)
        require(plaintext.isNotEmpty()) { "Empty decrypted frame" }
        val type = DLSPFrameType.fromByte(plaintext[0]) ?: throw IllegalArgumentException("Unknown frame type: ${plaintext[0]}")
        return type to plaintext.copyOfRange(1, plaintext.size)
    }
}
