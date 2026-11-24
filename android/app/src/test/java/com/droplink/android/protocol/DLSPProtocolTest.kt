package com.droplink.android.protocol

import com.droplink.android.protocol.DLSPCrypto.toHex
import com.google.gson.Gson
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.io.InputStream
import java.net.ServerSocket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.nio.file.Files
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import javax.crypto.AEADBadTagException

class DLSPProtocolTest {
    private val gson = Gson()

    private data class FrameVec(
        val direction: Int,
        val seq: Long,
        val plaintextHex: String,
        val nonceHex: String,
        val aadHex: String,
        val ciphertextAndTagHex: String
    )

    private data class VectorFile(
        val protocol: String,
        val sessionId: String,
        val mode: String,
        val deviceId: String,
        val pskHex: String,
        val pskBase64Url: String,
        val clientPrivHex: String,
        val clientPubHex: String,
        val serverPrivHex: String,
        val serverPubHex: String,
        val ecdhSharedHex: String,
        val clientNonce: String,
        val serverNonce: String,
        val clientProofHex: String,
        val serverProofHex: String,
        val saltHex: String,
        val c2sKeyHex: String,
        val s2cKeyHex: String,
        val reconnectKeyHex: String,
        val frameC2SSeq0: FrameVec,
        val frameS2CSeq0: FrameVec,
        val qrUri: String
    )

    private fun locateVectorsFile(): File {
        val candidates = listOf(
            File("../protocol/test_vectors.json"),
            File("../../protocol/test_vectors.json"),
            File("protocol/test_vectors.json")
        )
        return candidates.firstOrNull { it.exists() }
            ?: error("Could not find protocol/test_vectors.json from ${File(".").absolutePath}")
    }

    @Test
    fun testCanonicalCryptoVectorsMatchSwiftAndNode() {
        val vec = gson.fromJson(locateVectorsFile().readText(Charsets.UTF_8), VectorFile::class.java)

        val clientPriv = DLSPCrypto.privateKeyFromRawScalar(DLSPCrypto.hexToBytes(vec.clientPrivHex))
        val serverPriv = DLSPCrypto.privateKeyFromRawScalar(DLSPCrypto.hexToBytes(vec.serverPrivHex))

        val sharedClient = DLSPCrypto.computeECDHSharedSecret(clientPriv, DLSPCrypto.hexToBytes(vec.serverPubHex))
        val sharedServer = DLSPCrypto.computeECDHSharedSecret(serverPriv, DLSPCrypto.hexToBytes(vec.clientPubHex))
        assertEquals(vec.ecdhSharedHex, sharedClient.toHex())
        assertEquals(vec.ecdhSharedHex, sharedServer.toHex())

        val psk = DLSPCrypto.hexToBytes(vec.pskHex)
        val cProof = DLSPCrypto.clientAuthProof(psk, vec.sessionId, vec.mode, vec.clientNonce, vec.clientPubHex, vec.deviceId)
        assertEquals(vec.clientProofHex, cProof)

        val sProof = DLSPCrypto.serverAuthProof(psk, vec.sessionId, vec.mode, vec.clientNonce, vec.serverNonce, vec.clientPubHex, vec.serverPubHex)
        assertEquals(vec.serverProofHex, sProof)

        val keys = DLSPCrypto.deriveKeys(sharedClient, psk, vec.sessionId, vec.clientNonce, vec.serverNonce)
        assertEquals(vec.c2sKeyHex, keys.c2sKey.toHex())
        assertEquals(vec.s2cKeyHex, keys.s2cKey.toHex())
        assertEquals(vec.reconnectKeyHex, keys.reconnectKey.toHex())

        val c2sPlain = DLSPCrypto.hexToBytes(vec.frameC2SSeq0.plaintextHex)
        val c2sCipher = DLSPCrypto.encryptFrame(keys.c2sKey, 1, 0L, c2sPlain)
        assertEquals(vec.frameC2SSeq0.ciphertextAndTagHex, c2sCipher.toHex())
        assertEquals(vec.frameC2SSeq0.plaintextHex, DLSPCrypto.decryptFrame(keys.c2sKey, 1, 0L, c2sCipher).toHex())

        val s2cPlain = DLSPCrypto.hexToBytes(vec.frameS2CSeq0.plaintextHex)
        val s2cCipher = DLSPCrypto.encryptFrame(keys.s2cKey, 2, 0L, s2cPlain)
        assertEquals(vec.frameS2CSeq0.ciphertextAndTagHex, s2cCipher.toHex())

        // Verify tampered ciphertext is rejected
        val tampered = c2sCipher.copyOf()
        tampered[0] = (tampered[0].toInt() xor 0xFF).toByte()
        try {
            DLSPCrypto.decryptFrame(keys.c2sKey, 1, 0L, tampered)
            fail("Tampered frame should throw AEADBadTagException")
        } catch (_: AEADBadTagException) {
            // expected
        }

        // QR URI parsing
        val parsed = PairingPayload.parse(vec.qrUri)
        assertNotNull(parsed)
        assertEquals(listOf("192.168.1.42", "10.0.0.5"), parsed!!.hosts)
        assertEquals(54321, parsed.port)
        assertEquals(vec.sessionId, parsed.sessionId)
        assertEquals(vec.pskHex, parsed.pairingSecret.toHex())
        assertEquals("MacBook Air", parsed.deviceName)
    }

    @Test
    fun testFilenameSanitizationAndDeduplication() {
        assertEquals("passwd", FileUtils.sanitizeFilename("../../etc/passwd"))
        assertEquals("secret.txt", FileUtils.sanitizeFilename("C:\\Users\\demo\\secret.txt"))
        assertEquals("hidden", FileUtils.sanitizeFilename(".hidden"))
        assertEquals("Report 2026 — Résumé 🚀 日本語.pdf", FileUtils.sanitizeFilename("Report 2026 — Résumé 🚀 日本語.pdf"))
        assertEquals("badnamefile.txt", FileUtils.sanitizeFilename("bad\u0000name\nfile.txt"))

        val longUnicode = "あ".repeat(100) + ".mp4"
        val truncated = FileUtils.sanitizeFilename(longUnicode)
        assertTrue(truncated.toByteArray(Charsets.UTF_8).size <= 200)
        assertTrue(truncated.endsWith(".mp4"))

        val dir = Files.createTempDirectory("dl-dup-test").toFile()
        try {
            val f1 = FileUtils.uniqueDestinationFile(dir, "clip.mov")
            assertEquals("clip.mov", f1.name)
            f1.writeText("1")
            val f2 = FileUtils.uniqueDestinationFile(dir, "clip.mov")
            assertEquals("clip (1).mov", f2.name)
            f2.writeText("2")
            val f3 = FileUtils.uniqueDestinationFile(dir, "clip.mov")
            assertEquals("clip (2).mov", f3.name)
        } finally {
            dir.deleteRecursively()
        }
    }

    @Test
    fun testFullEncryptedLoopbackTransferAndAuthRejection() {
        val tempRoot = Files.createTempDirectory("dl-loopback").toFile()
        val serverDir = File(tempRoot, "server_rx").apply { mkdirs() }
        val clientDir = File(tempRoot, "client_rx").apply { mkdirs() }
        val stagingDir = File(tempRoot, "staging").apply { mkdirs() }
        val srcFile = File(tempRoot, "Holiday Video — 東京 🎬.bin")
        val content = ByteArray(1_500_000) { i -> ((i * 29 + 7) and 0xFF).toByte() }
        srcFile.writeBytes(content)
        val expectedSha = FileUtils.streamSha256(srcFile).second

        val sessionId = DLSPCrypto.randomBytes(16).toHex()
        val psk = DLSPCrypto.randomBytes(32)
        val serverSocket = ServerSocket(0)
        val port = serverSocket.localPort

        // Minimal inline DLSP/1 server accepting 2 connections (1 wrong PSK, 1 valid pair + file upload)
        val serverThread = Thread {
            repeat(2) {
                val sock = serverSocket.accept()
                val din = DataInputStream(BufferedInputStream(sock.getInputStream()))
                val dout = BufferedOutputStream(sock.getOutputStream())
                val len = din.readInt()
                val helloBytes = ByteArray(len)
                din.readFully(helloBytes)
                val hello = gson.fromJson(String(helloBytes, Charsets.UTF_8), ClientHello::class.java)

                val expectedProof = DLSPCrypto.clientAuthProof(psk, hello.sessionId, hello.mode, hello.clientNonce, hello.clientPublicKey, hello.deviceId)
                if (!DLSPCrypto.constantTimeEquals(DLSPCrypto.hexToBytes(hello.authProof), DLSPCrypto.hexToBytes(expectedProof))) {
                    val rej = gson.toJson(ServerHello(ok = false, code = "AUTH_FAILED", message = "Bad PSK")).toByteArray(Charsets.UTF_8)
                    dout.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(rej.size).array())
                    dout.write(rej)
                    dout.flush()
                    sock.close()
                } else {
                    val srvKp = DLSPCrypto.generateP256KeyPair()
                    val srvPubHex = DLSPCrypto.encodePublicKeyX963(srvKp.public).toHex()
                    val srvNonce = DLSPCrypto.randomBytes(32).toHex()
                    val ecdh = DLSPCrypto.computeECDHSharedSecret(srvKp.private, DLSPCrypto.hexToBytes(hello.clientPublicKey))
                    val derived = DLSPCrypto.deriveKeys(ecdh, psk, hello.sessionId, hello.clientNonce, srvNonce)
                    val srvProof = DLSPCrypto.serverAuthProof(psk, hello.sessionId, hello.mode, hello.clientNonce, srvNonce, hello.clientPublicKey, srvPubHex)
                    val reply = gson.toJson(
                        ServerHello(
                            ok = true,
                            protocol = DLSPConstants.PROTOCOL_VERSION,
                            serverName = "Test Mac",
                            serverNonce = srvNonce,
                            serverPublicKey = srvPubHex,
                            serverProof = srvProof,
                            reconnectToken = DLSPCrypto.randomBytes(16).toHex()
                        )
                    ).toByteArray(Charsets.UTF_8)
                    dout.write(ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(reply.size).array())
                    dout.write(reply)
                    dout.flush()

                    val serverPeer = DropLinkPeerClient(
                        socket = sock,
                        input = din,
                        output = dout,
                        codec = EncryptedFrameCodec(isServer = true, keys = derived),
                        stagingDir = File(tempRoot, "srv_stage"),
                        committer = DirectoryFileCommitter(serverDir)
                    )
                    serverPeer.start()
                }
            }
        }
        serverThread.start()

        try {
            // 1. Verify wrong PSK is cleanly rejected
            try {
                DropLinkPeerClient.connect(
                    hosts = listOf("127.0.0.1"),
                    port = port,
                    sessionId = sessionId,
                    authKey = DLSPCrypto.randomBytes(32),
                    deviceId = UUID.randomUUID().toString(),
                    deviceName = "Rogue",
                    stagingDir = stagingDir,
                    committer = DirectoryFileCommitter(clientDir)
                )
                fail("Wrong PSK should be rejected")
            } catch (e: HandshakeRejectedException) {
                assertEquals("AUTH_FAILED", e.code)
            }

            // 2. Valid connection + 1.5 MB Unicode filename upload + SHA-256 verification
            val conn = DropLinkPeerClient.connect(
                hosts = listOf("127.0.0.1"),
                port = port,
                sessionId = sessionId,
                authKey = psk,
                deviceId = UUID.randomUUID().toString(),
                deviceName = "Pixel 9",
                stagingDir = stagingDir,
                committer = DirectoryFileCommitter(clientDir)
            )
            conn.client.start()

            val latch = CountDownLatch(1)
            var resultRecord: TransferRecord? = null
            conn.client.sendFile(object : OutgoingFileSource {
                override val filename: String = srcFile.name
                override val size: Long = srcFile.length()
                override val mimeType: String = "application/octet-stream"
                override fun openInputStream(): InputStream = FileInputStream(srcFile)
            }) { res ->
                resultRecord = res.getOrNull()
                latch.countDown()
            }

            assertTrue("Transfer timed out", latch.await(15, TimeUnit.SECONDS))
            assertNotNull(resultRecord)
            assertTrue(resultRecord!!.verified)
            assertEquals("Holiday Video — 東京 🎬.bin", resultRecord!!.savedFilename)

            val savedFile = File(serverDir, "Holiday Video — 東京 🎬.bin")
            assertTrue(savedFile.exists())
            assertEquals(expectedSha, FileUtils.streamSha256(savedFile).second)

            conn.client.close()
        } finally {
            runCatching { serverSocket.close() }
            tempRoot.deleteRecursively()
        }
    }
}
