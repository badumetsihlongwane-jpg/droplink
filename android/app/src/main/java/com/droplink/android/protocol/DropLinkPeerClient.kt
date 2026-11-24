package com.droplink.android.protocol

import com.droplink.android.protocol.DLSPCrypto.toHex
import com.google.gson.Gson
import java.io.BufferedInputStream
import java.io.BufferedOutputStream
import java.io.DataInputStream
import java.io.EOFException
import java.io.File
import java.io.InputStream
import java.io.RandomAccessFile
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.ByteOrder
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CountDownLatch
import java.util.concurrent.Executors
import java.util.concurrent.ScheduledExecutorService
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

enum class TransferDirection { INCOMING, OUTGOING }
enum class TransferStatus { PENDING, TRANSFERRING, VERIFYING, COMPLETED, CANCELLED, FAILED }

data class TransferRecord(
    val id: String,
    val direction: TransferDirection,
    val filename: String,
    val savedFilename: String? = null,
    val savedUriString: String? = null,
    val totalBytes: Long,
    val transferredBytes: Long = 0L,
    val bytesPerSecond: Double = 0.0,
    val status: TransferStatus = TransferStatus.PENDING,
    val errorMessage: String? = null,
    val sha256: String? = null,
    val verified: Boolean = false,
    val resumedFromBytes: Long = 0L,
    val startedAtMs: Long = System.currentTimeMillis(),
    val completedAtMs: Long? = null
) {
    val progress: Float
        get() = if (totalBytes <= 0L) {
            if (status == TransferStatus.COMPLETED) 1f else 0f
        } else {
            (transferredBytes.toDouble() / totalBytes.toDouble()).coerceIn(0.0, 1.0).toFloat()
        }
}

interface OutgoingFileSource {
    val filename: String
    val size: Long
    val mimeType: String
    fun openInputStream(): InputStream
}

interface IncomingFileCommitter {
    /** Called once SHA-256 is verified on the temporary part file; returns (savedFilename, optionalUriString). */
    fun commitVerifiedFile(partFile: File, sanitizedFilename: String, mimeType: String): Pair<String, String?>
    fun availableBytes(): Long
}

class DirectoryFileCommitter(private val destinationDir: File) : IncomingFileCommitter {
    override fun commitVerifiedFile(partFile: File, sanitizedFilename: String, mimeType: String): Pair<String, String?> {
        destinationDir.mkdirs()
        val finalFile = FileUtils.uniqueDestinationFile(destinationDir, sanitizedFilename)
        if (!partFile.renameTo(finalFile)) {
            partFile.copyTo(finalFile, overwrite = false)
            partFile.delete()
        }
        return finalFile.name to finalFile.toURI().toString()
    }

    override fun availableBytes(): Long = destinationDir.usableSpace.takeIf { it > 0L } ?: Long.MAX_VALUE
}

interface PeerClientListener {
    fun onTransferUpdated(record: TransferRecord)
    fun onLatencyUpdated(latencyMs: Int)
    fun onDisconnected(reason: String?)
}

class HandshakeRejectedException(val code: String, message: String) : Exception("$code: $message")

data class ConnectSessionInfo(
    val client: DropLinkPeerClient,
    val serverName: String,
    val connectedHost: String,
    val reconnectToken: String,
    val reconnectKey: ByteArray
)

private data class PartialMeta(val transferId: String, val filename: String, val size: Long, val mimeType: String)

class DropLinkPeerClient(
    private val socket: Socket,
    private val input: DataInputStream,
    private val output: BufferedOutputStream,
    private val codec: EncryptedFrameCodec,
    private val stagingDir: File,
    private val committer: IncomingFileCommitter,
    private val maxConcurrentTransfers: Int = 3,
    private val chunkSize: Int = DLSPConstants.DEFAULT_CHUNK_SIZE,
    private val minFreeSpaceBufferBytes: Long = 25L * 1024L * 1024L
) {
    var listener: PeerClientListener? = null

    private val gson = Gson()
    private val writeLock = Any()
    private val closed = AtomicBoolean(false)
    private val sendPool = Executors.newCachedThreadPool()
    private val sendLimiter = Semaphore(maxOf(1, maxConcurrentTransfers))
    private val readExecutor = Executors.newSingleThreadExecutor()
    private val pingScheduler: ScheduledExecutorService = Executors.newSingleThreadScheduledExecutor()

    private class OutgoingCtx(
        val id: String,
        val uuid: UUID,
        val source: OutgoingFileSource,
        @Volatile var record: TransferRecord,
        @Volatile var cancelled: Boolean = false,
        @Volatile var resumeOffset: Long = 0L,
        @Volatile var rejectedReason: String? = null,
        @Volatile var ack: TransferAckPayload? = null,
        val acceptLatch: CountDownLatch = CountDownLatch(1),
        val ackLatch: CountDownLatch = CountDownLatch(1)
    )

    private class IncomingCtx(
        val id: String,
        val filename: String,
        val mimeType: String,
        val totalBytes: Long,
        val partFile: File,
        val metaFile: File,
        val raf: RandomAccessFile,
        val digest: MessageDigest,
        var receivedBytes: Long,
        var record: TransferRecord,
        var lastSpeedTimeMs: Long = System.currentTimeMillis(),
        var lastSpeedBytes: Long = receivedBytes,
        var lastEmitMs: Long = 0L
    )

    private val outgoing = ConcurrentHashMap<String, OutgoingCtx>()
    private val incoming = ConcurrentHashMap<String, IncomingCtx>()

    fun start() {
        readExecutor.submit { readLoop() }
        pingScheduler.scheduleAtFixedRate({
            if (!closed.get()) {
                try {
                    sendFrame(DLSPFrameType.PING, gson.toJson(PingPongPayload(System.currentTimeMillis())).toByteArray(Charsets.UTF_8))
                } catch (e: Exception) {
                    close("Keepalive failed: ${e.message}", notifyPeer = false)
                }
            }
        }, 10, 10, TimeUnit.SECONDS)
    }

    fun sendFile(
        source: OutgoingFileSource,
        transferId: String = UUID.randomUUID().toString().lowercase(),
        onComplete: ((Result<TransferRecord>) -> Unit)? = null
    ): TransferRecord {
        val uuid = UUID.fromString(transferId)
        val initial = TransferRecord(
            id = transferId,
            direction = TransferDirection.OUTGOING,
            filename = source.filename,
            totalBytes = source.size,
            status = TransferStatus.PENDING
        )
        val ctx = OutgoingCtx(transferId, uuid, source, initial)
        outgoing[transferId] = ctx
        listener?.onTransferUpdated(initial)

        sendPool.submit {
            sendLimiter.acquire()
            try {
                runOutgoingTransfer(ctx, onComplete)
            } finally {
                sendLimiter.release()
                outgoing.remove(transferId)
            }
        }
        return initial
    }

    fun cancelTransfer(transferId: String, reason: String = "Cancelled by user") {
        outgoing[transferId]?.let { ctx ->
            ctx.cancelled = true
            ctx.rejectedReason = reason
            ctx.acceptLatch.countDown()
            ctx.ackLatch.countDown()
            ctx.record = ctx.record.copy(status = TransferStatus.CANCELLED, errorMessage = reason, bytesPerSecond = 0.0)
            listener?.onTransferUpdated(ctx.record)
            runCatching {
                sendFrame(DLSPFrameType.TRANSFER_CANCEL, gson.toJson(TransferCancelPayload(transferId, reason)).toByteArray(Charsets.UTF_8))
            }
        }
        incoming.remove(transferId)?.let { ctx ->
            runCatching { ctx.raf.close() }
            ctx.partFile.delete()
            ctx.metaFile.delete()
            ctx.record = ctx.record.copy(status = TransferStatus.CANCELLED, errorMessage = reason, bytesPerSecond = 0.0)
            listener?.onTransferUpdated(ctx.record)
            runCatching {
                sendFrame(DLSPFrameType.TRANSFER_CANCEL, gson.toJson(TransferCancelPayload(transferId, reason)).toByteArray(Charsets.UTF_8))
            }
        }
    }

    fun close(reason: String? = null, notifyPeer: Boolean = true) {
        if (!closed.compareAndSet(false, true)) return
        if (notifyPeer) {
            runCatching {
                sendFrame(DLSPFrameType.SESSION_CLOSE, gson.toJson(SessionClosePayload(reason ?: "Closed")).toByteArray(Charsets.UTF_8))
            }
        }
        pingScheduler.shutdownNow()
        runCatching { socket.close() }
        readExecutor.shutdownNow()
        sendPool.shutdownNow()

        outgoing.values.forEach { ctx ->
            ctx.cancelled = true
            ctx.rejectedReason = reason ?: "Connection interrupted"
            ctx.acceptLatch.countDown()
            ctx.ackLatch.countDown()
            if (ctx.record.status == TransferStatus.PENDING || ctx.record.status == TransferStatus.TRANSFERRING || ctx.record.status == TransferStatus.VERIFYING) {
                ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = reason ?: "Connection interrupted", bytesPerSecond = 0.0)
                listener?.onTransferUpdated(ctx.record)
            }
        }
        outgoing.clear()

        incoming.values.forEach { ctx ->
            runCatching {
                ctx.raf.fd.sync()
                ctx.raf.close()
            }
            // Keep .part and .meta on disk to allow resume after reconnection
            if (ctx.record.status == TransferStatus.PENDING || ctx.record.status == TransferStatus.TRANSFERRING || ctx.record.status == TransferStatus.VERIFYING) {
                ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = reason ?: "Connection interrupted (resumable)", bytesPerSecond = 0.0)
                listener?.onTransferUpdated(ctx.record)
            }
        }
        incoming.clear()
        listener?.onDisconnected(reason)
    }

    private fun runOutgoingTransfer(ctx: OutgoingCtx, onComplete: ((Result<TransferRecord>) -> Unit)?) {
        try {
            val offer = TransferOfferPayload(
                transferId = ctx.id,
                filename = ctx.source.filename,
                size = ctx.source.size,
                mimeType = ctx.source.mimeType,
                chunkSize = chunkSize
            )
            sendFrame(DLSPFrameType.TRANSFER_OFFER, gson.toJson(offer).toByteArray(Charsets.UTF_8))

            if (!ctx.acceptLatch.await(60, TimeUnit.SECONDS)) {
                throw Exception("Timed out waiting for Mac to accept transfer")
            }
            if (ctx.cancelled) {
                onComplete?.invoke(Result.failure(Exception(ctx.rejectedReason ?: "Cancelled")))
                return
            }
            ctx.rejectedReason?.let { throw Exception(it) }

            val resumeOffset = ctx.resumeOffset.coerceIn(0L, ctx.source.size)
            val digest = MessageDigest.getInstance("SHA-256")
            val buf = ByteArray(chunkSize)
            var offset = 0L

            ctx.source.openInputStream().use { rawStream ->
                val stream = BufferedInputStream(rawStream, chunkSize)

                // Hash skipped prefix locally if resuming
                while (offset < resumeOffset) {
                    if (ctx.cancelled) throw Exception("Cancelled")
                    val toRead = minOf(buf.size.toLong(), resumeOffset - offset).toInt()
                    val n = stream.read(buf, 0, toRead)
                    if (n <= 0) break
                    digest.update(buf, 0, n)
                    offset += n
                }

                ctx.record = ctx.record.copy(
                    status = TransferStatus.TRANSFERRING,
                    transferredBytes = offset,
                    resumedFromBytes = resumeOffset
                )
                listener?.onTransferUpdated(ctx.record)

                var lastSpeedTime = System.currentTimeMillis()
                var lastSpeedBytes = offset
                var lastEmit = 0L

                while (offset < ctx.source.size) {
                    if (ctx.cancelled) throw Exception("Cancelled")
                    val n = stream.read(buf, 0, buf.size)
                    if (n <= 0) break
                    digest.update(buf, 0, n)
                    val chunkPayload = ChunkCodec.encode(ctx.uuid, offset, buf, n)
                    sendFrame(DLSPFrameType.TRANSFER_CHUNK, chunkPayload)
                    offset += n

                    val now = System.currentTimeMillis()
                    if (now - lastEmit >= 100L || offset == ctx.source.size) {
                        var speed = ctx.record.bytesPerSecond
                        val dtMs = now - lastSpeedTime
                        if (dtMs >= 250L) {
                            speed = ((offset - lastSpeedBytes) * 1000.0) / dtMs.toDouble()
                            lastSpeedBytes = offset
                            lastSpeedTime = now
                        }
                        ctx.record = ctx.record.copy(transferredBytes = offset, bytesPerSecond = speed)
                        lastEmit = now
                        listener?.onTransferUpdated(ctx.record)
                    }
                }
            }

            if (ctx.cancelled) throw Exception("Cancelled")

            val shaHex = digest.digest().toHex()
            ctx.record = ctx.record.copy(status = TransferStatus.VERIFYING, sha256 = shaHex, transferredBytes = ctx.source.size)
            listener?.onTransferUpdated(ctx.record)

            val complete = TransferCompletePayload(ctx.id, shaHex, ctx.source.size)
            sendFrame(DLSPFrameType.TRANSFER_COMPLETE, gson.toJson(complete).toByteArray(Charsets.UTF_8))

            if (!ctx.ackLatch.await(60, TimeUnit.SECONDS)) {
                throw Exception("Timed out waiting for Mac SHA-256 verification")
            }
            val ack = ctx.ack ?: throw Exception(ctx.rejectedReason ?: "Connection closed before verification")
            if (!ack.verified) {
                throw Exception(ack.error ?: "Mac integrity verification failed")
            }

            ctx.record = ctx.record.copy(
                status = TransferStatus.COMPLETED,
                verified = true,
                savedFilename = ack.savedFilename,
                bytesPerSecond = 0.0,
                completedAtMs = System.currentTimeMillis()
            )
            listener?.onTransferUpdated(ctx.record)
            onComplete?.invoke(Result.success(ctx.record))
        } catch (e: Exception) {
            if (ctx.record.status != TransferStatus.CANCELLED) {
                ctx.record = ctx.record.copy(
                    status = TransferStatus.FAILED,
                    errorMessage = e.message ?: "Transfer failed",
                    bytesPerSecond = 0.0
                )
                listener?.onTransferUpdated(ctx.record)
            }
            onComplete?.invoke(Result.failure(e))
        }
    }

    private fun sendFrame(type: DLSPFrameType, payload: ByteArray) {
        synchronized(writeLock) {
            val wire = codec.seal(type, payload)
            output.write(wire)
            output.flush()
        }
    }

    private fun readLoop() {
        try {
            val maxWire = DLSPConstants.MAX_PLAINTEXT_FRAME_BYTES + DLSPConstants.GCM_TAG_LENGTH
            while (!closed.get()) {
                val len = input.readInt()
                if (len < 0 || len > maxWire) throw IllegalStateException("Invalid frame length: $len")
                val body = ByteArray(len)
                input.readFully(body)
                val (type, payload) = codec.open(body)
                handleFrame(type, payload)
            }
        } catch (e: EOFException) {
            close("Peer closed connection", notifyPeer = false)
        } catch (e: Exception) {
            close(e.message ?: "Connection lost", notifyPeer = false)
        }
    }

    private fun handleFrame(type: DLSPFrameType, payload: ByteArray) {
        when (type) {
            DLSPFrameType.PING -> sendFrame(DLSPFrameType.PONG, payload)
            DLSPFrameType.PONG -> {
                runCatching {
                    val pong = gson.fromJson(String(payload, Charsets.UTF_8), PingPongPayload::class.java)
                    val rtt = (System.currentTimeMillis() - pong.ts).coerceAtLeast(0L).toInt()
                    listener?.onLatencyUpdated(rtt)
                }
            }
            DLSPFrameType.TRANSFER_OFFER -> {
                val offer = gson.fromJson(String(payload, Charsets.UTF_8), TransferOfferPayload::class.java)
                handleIncomingOffer(offer)
            }
            DLSPFrameType.TRANSFER_ACCEPT -> {
                val accept = gson.fromJson(String(payload, Charsets.UTF_8), TransferAcceptPayload::class.java)
                outgoing[accept.transferId]?.let { ctx ->
                    ctx.resumeOffset = accept.resumeOffset
                    ctx.acceptLatch.countDown()
                }
            }
            DLSPFrameType.TRANSFER_REJECT -> {
                val reject = gson.fromJson(String(payload, Charsets.UTF_8), TransferRejectPayload::class.java)
                outgoing[reject.transferId]?.let { ctx ->
                    ctx.rejectedReason = "${reject.code}: ${reject.reason}"
                    ctx.acceptLatch.countDown()
                }
            }
            DLSPFrameType.TRANSFER_CHUNK -> {
                val decoded = ChunkCodec.decode(payload) ?: return
                handleIncomingChunk(decoded.transferId.toString().lowercase(), decoded.offset, decoded.data)
            }
            DLSPFrameType.TRANSFER_COMPLETE -> {
                val complete = gson.fromJson(String(payload, Charsets.UTF_8), TransferCompletePayload::class.java)
                handleIncomingComplete(complete)
            }
            DLSPFrameType.TRANSFER_ACK -> {
                val ack = gson.fromJson(String(payload, Charsets.UTF_8), TransferAckPayload::class.java)
                outgoing[ack.transferId]?.let { ctx ->
                    ctx.ack = ack
                    ctx.ackLatch.countDown()
                }
            }
            DLSPFrameType.TRANSFER_CANCEL -> {
                val cancel = gson.fromJson(String(payload, Charsets.UTF_8), TransferCancelPayload::class.java)
                handleRemoteCancel(cancel)
            }
            DLSPFrameType.SESSION_CLOSE -> {
                val msg = runCatching { gson.fromJson(String(payload, Charsets.UTF_8), SessionClosePayload::class.java).reason }.getOrNull()
                close(msg ?: "Mac ended session", notifyPeer = false)
            }
        }
    }

    private fun handleIncomingOffer(offer: TransferOfferPayload) {
        val safeName = FileUtils.sanitizeFilename(offer.filename)
        stagingDir.mkdirs()
        val cleanId = offer.transferId.lowercase().filter { it.isLetterOrDigit() || it == '-' }
        val partFile = File(stagingDir, ".droplink-$cleanId.part")
        val metaFile = File(stagingDir, ".droplink-$cleanId.meta")

        var resumeOffset = 0L
        var digest = MessageDigest.getInstance("SHA-256")

        if (partFile.exists() && metaFile.exists()) {
            runCatching {
                val meta = gson.fromJson(metaFile.readText(Charsets.UTF_8), PartialMeta::class.java)
                if (meta.transferId.equals(offer.transferId, ignoreCase = true) &&
                    meta.size == offer.size &&
                    meta.filename == safeName &&
                    partFile.length() <= offer.size
                ) {
                    val (md, _, hashed) = FileUtils.streamSha256(partFile, partFile.length())
                    digest = md
                    resumeOffset = hashed
                }
            }
        }

        val remainingNeeded = (offer.size - resumeOffset).coerceAtLeast(0L)
        val avail = committer.availableBytes()
        if (avail < remainingNeeded + minFreeSpaceBufferBytes) {
            sendReject(offer.transferId, "INSUFFICIENT_STORAGE", "Not enough storage on Android device")
            return
        }

        try {
            if (resumeOffset == 0L && partFile.exists()) {
                partFile.delete()
            }
            metaFile.writeText(gson.toJson(PartialMeta(offer.transferId.lowercase(), safeName, offer.size, offer.mimeType)), Charsets.UTF_8)
            val raf = RandomAccessFile(partFile, "rw")
            raf.seek(resumeOffset)

            val rec = TransferRecord(
                id = offer.transferId.lowercase(),
                direction = TransferDirection.INCOMING,
                filename = safeName,
                totalBytes = offer.size,
                transferredBytes = resumeOffset,
                status = TransferStatus.TRANSFERRING,
                resumedFromBytes = resumeOffset
            )
            val ctx = IncomingCtx(
                id = offer.transferId.lowercase(),
                filename = safeName,
                mimeType = offer.mimeType,
                totalBytes = offer.size,
                partFile = partFile,
                metaFile = metaFile,
                raf = raf,
                digest = digest,
                receivedBytes = resumeOffset,
                record = rec
            )
            incoming[ctx.id] = ctx
            listener?.onTransferUpdated(rec)

            val accept = TransferAcceptPayload(offer.transferId, resumeOffset)
            sendFrame(DLSPFrameType.TRANSFER_ACCEPT, gson.toJson(accept).toByteArray(Charsets.UTF_8))
        } catch (e: Exception) {
            sendReject(offer.transferId, "STORAGE_ERROR", e.message ?: "Cannot create staging file")
        }
    }

    private fun handleIncomingChunk(transferId: String, offset: Long, chunk: ByteArray) {
        val ctx = incoming[transferId] ?: return
        if (offset != ctx.receivedBytes) {
            failIncoming(ctx, "Unexpected chunk offset $offset (expected ${ctx.receivedBytes})", deletePart = false)
            return
        }
        if (ctx.receivedBytes + chunk.size > ctx.totalBytes) {
            failIncoming(ctx, "Received bytes exceed declared file size", deletePart = true)
            return
        }
        try {
            ctx.raf.write(chunk)
            ctx.digest.update(chunk)
            ctx.receivedBytes += chunk.size

            val now = System.currentTimeMillis()
            if (now - ctx.lastEmitMs >= 100L || ctx.receivedBytes == ctx.totalBytes) {
                var speed = ctx.record.bytesPerSecond
                val dt = now - ctx.lastSpeedTimeMs
                if (dt >= 250L) {
                    speed = ((ctx.receivedBytes - ctx.lastSpeedBytes) * 1000.0) / dt.toDouble()
                    ctx.lastSpeedBytes = ctx.receivedBytes
                    ctx.lastSpeedTimeMs = now
                }
                ctx.record = ctx.record.copy(transferredBytes = ctx.receivedBytes, bytesPerSecond = speed)
                ctx.lastEmitMs = now
                listener?.onTransferUpdated(ctx.record)
            }
        } catch (e: Exception) {
            failIncoming(ctx, "Storage write failed: ${e.message}", deletePart = false)
        }
    }

    private fun handleIncomingComplete(complete: TransferCompletePayload) {
        val ctx = incoming.remove(complete.transferId.lowercase()) ?: return
        try {
            ctx.record = ctx.record.copy(status = TransferStatus.VERIFYING)
            listener?.onTransferUpdated(ctx.record)

            ctx.raf.fd.sync()
            ctx.raf.close()

            if (ctx.receivedBytes != complete.totalBytes || ctx.receivedBytes != ctx.totalBytes) {
                ctx.partFile.delete()
                ctx.metaFile.delete()
                val msg = "Size mismatch: got ${ctx.receivedBytes}, expected ${complete.totalBytes}"
                ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = msg, bytesPerSecond = 0.0)
                listener?.onTransferUpdated(ctx.record)
                sendAck(complete.transferId, false, null, msg)
                return
            }

            val computedSha = ctx.digest.digest().toHex()
            if (!computedSha.equals(complete.sha256, ignoreCase = true)) {
                ctx.partFile.delete()
                ctx.metaFile.delete()
                val msg = "SHA-256 integrity mismatch"
                ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = msg, bytesPerSecond = 0.0)
                listener?.onTransferUpdated(ctx.record)
                sendAck(complete.transferId, false, null, msg)
                return
            }

            val (savedName, savedUri) = committer.commitVerifiedFile(ctx.partFile, ctx.filename, ctx.mimeType)
            ctx.metaFile.delete()

            ctx.record = ctx.record.copy(
                status = TransferStatus.COMPLETED,
                verified = true,
                sha256 = computedSha,
                savedFilename = savedName,
                savedUriString = savedUri,
                transferredBytes = ctx.totalBytes,
                bytesPerSecond = 0.0,
                completedAtMs = System.currentTimeMillis()
            )
            listener?.onTransferUpdated(ctx.record)
            sendAck(complete.transferId, true, savedName, null)
        } catch (e: Exception) {
            val msg = "Failed to save file: ${e.message}"
            ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = msg, bytesPerSecond = 0.0)
            listener?.onTransferUpdated(ctx.record)
            sendAck(complete.transferId, false, null, msg)
        }
    }

    private fun handleRemoteCancel(cancel: TransferCancelPayload) {
        val id = cancel.transferId.lowercase()
        outgoing[id]?.let { ctx ->
            ctx.cancelled = true
            ctx.rejectedReason = cancel.reason
            ctx.acceptLatch.countDown()
            ctx.ackLatch.countDown()
            ctx.record = ctx.record.copy(status = TransferStatus.CANCELLED, errorMessage = cancel.reason, bytesPerSecond = 0.0)
            listener?.onTransferUpdated(ctx.record)
        }
        incoming.remove(id)?.let { ctx ->
            runCatching { ctx.raf.close() }
            ctx.partFile.delete()
            ctx.metaFile.delete()
            ctx.record = ctx.record.copy(status = TransferStatus.CANCELLED, errorMessage = cancel.reason, bytesPerSecond = 0.0)
            listener?.onTransferUpdated(ctx.record)
        }
    }

    private fun failIncoming(ctx: IncomingCtx, reason: String, deletePart: Boolean) {
        incoming.remove(ctx.id)
        runCatching { ctx.raf.close() }
        if (deletePart) {
            ctx.partFile.delete()
            ctx.metaFile.delete()
        }
        ctx.record = ctx.record.copy(status = TransferStatus.FAILED, errorMessage = reason, bytesPerSecond = 0.0)
        listener?.onTransferUpdated(ctx.record)
        sendAck(ctx.id, false, null, reason)
    }

    private fun sendReject(transferId: String, code: String, reason: String) {
        runCatching {
            sendFrame(DLSPFrameType.TRANSFER_REJECT, gson.toJson(TransferRejectPayload(transferId, code, reason)).toByteArray(Charsets.UTF_8))
        }
    }

    private fun sendAck(transferId: String, verified: Boolean, savedFilename: String?, error: String?) {
        runCatching {
            sendFrame(DLSPFrameType.TRANSFER_ACK, gson.toJson(TransferAckPayload(transferId, verified, savedFilename, error)).toByteArray(Charsets.UTF_8))
        }
    }

    companion object {
        fun connect(
            hosts: List<String>,
            port: Int,
            sessionId: String,
            authKey: ByteArray,
            mode: String = "pair",
            reconnectToken: String? = null,
            deviceId: String,
            deviceName: String,
            stagingDir: File,
            committer: IncomingFileCommitter,
            connectTimeoutMs: Int = 5000
        ): ConnectSessionInfo {
            var connectedSocket: Socket? = null
            var chosenHost = ""
            var lastError: Exception? = null

            for (host in hosts) {
                try {
                    val s = Socket()
                    s.tcpNoDelay = true
                    s.sendBufferSize = 512 * 1024
                    s.receiveBufferSize = 512 * 1024
                    s.connect(InetSocketAddress(host, port), connectTimeoutMs)
                    connectedSocket = s
                    chosenHost = host
                    break
                } catch (e: Exception) {
                    lastError = e
                }
            }

            val socket = connectedSocket ?: throw Exception("Unable to reach Mac (${hosts.joinToString()}): ${lastError?.message}")

            try {
                socket.soTimeout = 15_000
                val input = DataInputStream(BufferedInputStream(socket.getInputStream(), 256 * 1024))
                val output = BufferedOutputStream(socket.getOutputStream(), 256 * 1024)
                val gson = Gson()

                val keyPair = DLSPCrypto.generateP256KeyPair()
                val clientPubHex = DLSPCrypto.encodePublicKeyX963(keyPair.public).toHex()
                val clientNonceHex = DLSPCrypto.randomBytes(32).toHex()
                val authProofHex = DLSPCrypto.clientAuthProof(
                    authKey = authKey,
                    sessionId = sessionId,
                    mode = mode,
                    clientNonce = clientNonceHex,
                    clientPublicKeyHex = clientPubHex,
                    deviceId = deviceId
                )

                val hello = ClientHello(
                    sessionId = sessionId,
                    mode = mode,
                    reconnectToken = reconnectToken,
                    deviceId = deviceId,
                    deviceName = deviceName,
                    clientNonce = clientNonceHex,
                    clientPublicKey = clientPubHex,
                    authProof = authProofHex
                )
                val helloBytes = gson.toJson(hello).toByteArray(Charsets.UTF_8)
                val header = ByteBuffer.allocate(4).order(ByteOrder.BIG_ENDIAN).putInt(helloBytes.size).array()
                output.write(header)
                output.write(helloBytes)
                output.flush()

                val replyLen = input.readInt()
                if (replyLen <= 0 || replyLen > DLSPConstants.MAX_HANDSHAKE_BYTES) {
                    throw IllegalStateException("Malformed handshake response length: $replyLen")
                }
                val replyBytes = ByteArray(replyLen)
                input.readFully(replyBytes)
                val reply = gson.fromJson(String(replyBytes, Charsets.UTF_8), ServerHello::class.java)

                if (!reply.ok) {
                    throw HandshakeRejectedException(reply.code ?: "UNKNOWN", reply.message ?: "Pairing rejected")
                }

                val serverNonce = reply.serverNonce ?: throw IllegalStateException("Missing serverNonce")
                val serverPubHex = reply.serverPublicKey ?: throw IllegalStateException("Missing serverPublicKey")
                val serverProofHex = reply.serverProof ?: throw IllegalStateException("Missing serverProof")
                val newReconnectToken = reply.reconnectToken ?: throw IllegalStateException("Missing reconnectToken")
                val serverName = reply.serverName ?: "DropLink Mac"

                val expectedServerProofHex = DLSPCrypto.serverAuthProof(
                    authKey = authKey,
                    sessionId = sessionId,
                    mode = mode,
                    clientNonce = clientNonceHex,
                    serverNonce = serverNonce,
                    clientPublicKeyHex = clientPubHex,
                    serverPublicKeyHex = serverPubHex
                )
                if (!DLSPCrypto.constantTimeEquals(DLSPCrypto.hexToBytes(serverProofHex), DLSPCrypto.hexToBytes(expectedServerProofHex))) {
                    throw SecurityException("Server identity verification failed")
                }

                val ecdhShared = DLSPCrypto.computeECDHSharedSecret(keyPair.private, DLSPCrypto.hexToBytes(serverPubHex))
                val derived = DLSPCrypto.deriveKeys(ecdhShared, authKey, sessionId, clientNonceHex, serverNonce)

                socket.soTimeout = 0
                val codec = EncryptedFrameCodec(isServer = false, keys = derived)
                val client = DropLinkPeerClient(
                    socket = socket,
                    input = input,
                    output = output,
                    codec = codec,
                    stagingDir = stagingDir,
                    committer = committer
                )

                return ConnectSessionInfo(
                    client = client,
                    serverName = serverName,
                    connectedHost = chosenHost,
                    reconnectToken = newReconnectToken,
                    reconnectKey = derived.reconnectKey
                )
            } catch (e: Exception) {
                runCatching { socket.close() }
                throw e
            }
        }
    }
}
