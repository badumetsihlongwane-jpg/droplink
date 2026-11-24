import Foundation
import CryptoKit

private struct PartialTransferMeta: Codable {
    let transferId: String
    let filename: String
    let size: UInt64
}

public protocol PeerSessionDelegate: AnyObject {
    func peerSession(_ session: PeerSession, didUpdateTransfer item: TransferItem)
    func peerSession(_ session: PeerSession, didUpdateLatencyMs latencyMs: Int)
    func peerSessionDidDisconnect(_ session: PeerSession, reason: String?)
    func peerSessionShouldAcceptIncoming(_ session: PeerSession, offer: TransferOfferPayload) -> (accept: Bool, rejectCode: String?, reason: String?)
}

public final class PeerSession {
    public let deviceId: String
    public let deviceName: String
    public let remoteAddress: String
    public let isServer: Bool

    private let socket: TCPSocket
    private let codec: EncryptedFrameCodec
    private let destinationDirectory: URL
    private let chunkSize: Int
    private let minFreeDiskBufferBytes: UInt64
    private let simulatedFreeDiskBytes: UInt64?

    public weak var delegate: PeerSessionDelegate?

    private let writeQueue = DispatchQueue(label: "com.droplink.peer.write", qos: .userInitiated)
    private let readQueue = DispatchQueue(label: "com.droplink.peer.read", qos: .userInitiated)
    private let sendTransferQueue = DispatchQueue(label: "com.droplink.peer.send", qos: .userInitiated, attributes: .concurrent)
    private let sendSemaphore: DispatchSemaphore
    private let stateLock = NSLock()
    private var closed = false
    private var pingTimer: DispatchSourceTimer?

    private final class OutgoingContext {
        let id: String
        let uuid: UUID
        let fileURL: URL
        let filename: String
        let size: UInt64
        var item: TransferItem
        var cancelled = false
        var acceptedOffset: UInt64?
        var rejectedReason: String?
        var ackReceived: TransferAckPayload?
        let acceptSemaphore = DispatchSemaphore(value: 0)
        let ackSemaphore = DispatchSemaphore(value: 0)
        var lastSpeedTime = Date()
        var lastSpeedBytes: UInt64 = 0

        init(id: String, uuid: UUID, fileURL: URL, filename: String, size: UInt64, item: TransferItem) {
            self.id = id
            self.uuid = uuid
            self.fileURL = fileURL
            self.filename = filename
            self.size = size
            self.item = item
        }
    }

    private final class IncomingContext {
        let id: String
        let filename: String
        let totalBytes: UInt64
        let partURL: URL
        let metaURL: URL
        let fileHandle: FileHandle
        var hasher: SHA256
        var receivedBytes: UInt64
        var item: TransferItem
        var lastSpeedTime = Date()
        var lastSpeedBytes: UInt64
        var lastProgressEmit = Date.distantPast

        init(
            id: String,
            filename: String,
            totalBytes: UInt64,
            partURL: URL,
            metaURL: URL,
            fileHandle: FileHandle,
            hasher: SHA256,
            receivedBytes: UInt64,
            item: TransferItem
        ) {
            self.id = id
            self.filename = filename
            self.totalBytes = totalBytes
            self.partURL = partURL
            self.metaURL = metaURL
            self.fileHandle = fileHandle
            self.hasher = hasher
            self.receivedBytes = receivedBytes
            self.item = item
            self.lastSpeedBytes = receivedBytes
        }
    }

    private var outgoingTransfers: [String: OutgoingContext] = [:]
    private var incomingTransfers: [String: IncomingContext] = [:]
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(
        deviceId: String,
        deviceName: String,
        socket: TCPSocket,
        codec: EncryptedFrameCodec,
        isServer: Bool,
        destinationDirectory: URL,
        chunkSize: Int = DLSPConstants.defaultChunkSize,
        maxConcurrentTransfers: Int = 3,
        minFreeDiskBufferBytes: UInt64 = 50 * 1024 * 1024,
        simulatedFreeDiskBytes: UInt64? = nil
    ) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.remoteAddress = socket.remoteAddress
        self.socket = socket
        self.codec = codec
        self.isServer = isServer
        self.destinationDirectory = destinationDirectory
        self.chunkSize = chunkSize
        self.sendSemaphore = DispatchSemaphore(value: max(1, maxConcurrentTransfers))
        self.minFreeDiskBufferBytes = minFreeDiskBufferBytes
        self.simulatedFreeDiskBytes = simulatedFreeDiskBytes
    }

    public func start() {
        startReadLoop()
        startKeepalive()
    }

    public func close(reason: String? = nil, notifyPeer: Bool = true) {
        stateLock.lock()
        if closed {
            stateLock.unlock()
            return
        }
        closed = true
        let activeOut = Array(outgoingTransfers.values)
        let activeIn = Array(incomingTransfers.values)
        outgoingTransfers.removeAll()
        incomingTransfers.removeAll()
        pingTimer?.cancel()
        pingTimer = nil
        stateLock.unlock()

        if notifyPeer {
            let payload = (try? jsonEncoder.encode(SessionClosePayload(reason: reason ?? "Closed"))) ?? Data()
            try? sendFrameSync(type: .sessionClose, payload: payload)
        }

        socket.close()

        for out in activeOut {
            out.cancelled = true
            out.rejectedReason = reason ?? "Connection closed"
            out.acceptSemaphore.signal()
            out.ackSemaphore.signal()
            if out.item.status == .pending || out.item.status == .transferring || out.item.status == .verifying {
                out.item.status = .failed
                out.item.errorMessage = reason ?? "Connection interrupted"
                out.item.bytesPerSecond = 0
                delegate?.peerSession(self, didUpdateTransfer: out.item)
            }
        }

        for inc in activeIn {
            try? inc.fileHandle.synchronize()
            try? inc.fileHandle.close()
            // Keep .part and .meta on disk so a reconnect can resume seamlessly!
            if inc.item.status == .pending || inc.item.status == .transferring || inc.item.status == .verifying {
                inc.item.status = .failed
                inc.item.errorMessage = reason ?? "Connection interrupted (resumable)"
                inc.item.bytesPerSecond = 0
                delegate?.peerSession(self, didUpdateTransfer: inc.item)
            }
        }

        delegate?.peerSessionDidDisconnect(self, reason: reason)
    }

    /// Sends a local file to the connected peer. Pass an existing `transferId` to resume an interrupted transfer.
    @discardableResult
    public func sendFile(
        url: URL,
        transferId: String = UUID().uuidString.lowercased(),
        customFilename: String? = nil,
        completion: ((Result<TransferItem, Error>) -> Void)? = nil
    ) -> TransferItem? {
        guard let uuid = UUID(uuidString: transferId) else { return nil }
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let fileSize = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let filename = customFilename ?? url.lastPathComponent
        let mime = FileUtils.mimeType(for: url)

        let item = TransferItem(
            id: transferId,
            direction: .outgoing,
            peerDeviceId: deviceId,
            peerDeviceName: deviceName,
            filename: filename,
            localFileURL: url,
            totalBytes: fileSize,
            status: .pending
        )
        let ctx = OutgoingContext(id: transferId, uuid: uuid, fileURL: url, filename: filename, size: fileSize, item: item)

        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return nil
        }
        outgoingTransfers[transferId] = ctx
        stateLock.unlock()

        delegate?.peerSession(self, didUpdateTransfer: item)

        sendTransferQueue.async { [weak self] in
            guard let self = self else { return }
            self.sendSemaphore.wait()
            defer {
                self.sendSemaphore.signal()
                self.stateLock.lock()
                self.outgoingTransfers.removeValue(forKey: transferId)
                self.stateLock.unlock()
            }
            self.runOutgoingTransfer(ctx: ctx, mime: mime, completion: completion)
        }

        return item
    }

    public func cancelTransfer(id: String, reason: String = "Cancelled by user") {
        stateLock.lock()
        let out = outgoingTransfers[id]
        let inc = incomingTransfers.removeValue(forKey: id)
        stateLock.unlock()

        if let out = out {
            out.cancelled = true
            out.acceptSemaphore.signal()
            out.ackSemaphore.signal()
            out.item.status = .cancelled
            out.item.errorMessage = reason
            out.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: out.item)
            if let data = try? jsonEncoder.encode(TransferCancelPayload(transferId: id, reason: reason)) {
                try? sendFrameSync(type: .transferCancel, payload: data)
            }
        }

        if let inc = inc {
            try? inc.fileHandle.close()
            try? FileManager.default.removeItem(at: inc.partURL)
            try? FileManager.default.removeItem(at: inc.metaURL)
            inc.item.status = .cancelled
            inc.item.errorMessage = reason
            inc.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: inc.item)
            if let data = try? jsonEncoder.encode(TransferCancelPayload(transferId: id, reason: reason)) {
                try? sendFrameSync(type: .transferCancel, payload: data)
            }
        }
    }

    private func runOutgoingTransfer(
        ctx: OutgoingContext,
        mime: String,
        completion: ((Result<TransferItem, Error>) -> Void)?
    ) {
        do {
            // 1. Send TRANSFER_OFFER
            let offer = TransferOfferPayload(
                transferId: ctx.id,
                filename: ctx.filename,
                size: ctx.size,
                mimeType: mime,
                chunkSize: UInt32(chunkSize)
            )
            try sendFrameSync(type: .transferOffer, payload: try jsonEncoder.encode(offer))

            // 2. Wait for TRANSFER_ACCEPT / TRANSFER_REJECT
            if ctx.acceptSemaphore.wait(timeout: .now() + 60) == .timedOut {
                throw NSError(domain: "DropLink", code: -1, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for peer response"])
            }
            if ctx.cancelled {
                if ctx.item.status != .cancelled {
                    ctx.item.status = .cancelled
                    ctx.item.errorMessage = ctx.rejectedReason ?? "Cancelled"
                    delegate?.peerSession(self, didUpdateTransfer: ctx.item)
                }
                completion?(.failure(NSError(domain: "DropLink", code: -2, userInfo: [NSLocalizedDescriptionKey: ctx.item.errorMessage ?? "Cancelled"])))
                return
            }
            if let rej = ctx.rejectedReason {
                throw NSError(domain: "DropLink", code: -3, userInfo: [NSLocalizedDescriptionKey: rej])
            }
            let resumeOffset = min(ctx.acceptedOffset ?? 0, ctx.size)

            // 3. Stream file from disk while computing full-file SHA-256
            let handle = try FileHandle(forReadingFrom: ctx.fileURL)
            defer { try? handle.close() }

            var hasher = SHA256()
            var offset: UInt64 = 0

            // If resuming, hash the prefix [0..<resumeOffset] locally so final SHA-256 covers the whole file
            if resumeOffset > 0 {
                ctx.item.resumedFromBytes = resumeOffset
                while offset < resumeOffset {
                    if ctx.cancelled { break }
                    let toRead = Int(min(UInt64(chunkSize), resumeOffset - offset))
                    guard let prefixChunk = try handle.read(upToCount: toRead), !prefixChunk.isEmpty else { break }
                    hasher.update(data: prefixChunk)
                    offset += UInt64(prefixChunk.count)
                }
            }

            ctx.item.status = .transferring
            ctx.item.transferredBytes = offset
            ctx.lastSpeedBytes = offset
            ctx.lastSpeedTime = Date()
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)

            var lastEmit = Date.distantPast
            while offset < ctx.size {
                if ctx.cancelled {
                    throw NSError(domain: "DropLink", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
                }
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                hasher.update(data: chunk)
                let framePayload = ChunkCodec.encode(transferId: ctx.uuid, offset: offset, data: chunk)
                try sendFrameSync(type: .transferChunk, payload: framePayload)
                offset += UInt64(chunk.count)

                let now = Date()
                if now.timeIntervalSince(lastEmit) >= 0.1 || offset == ctx.size {
                    let dt = now.timeIntervalSince(ctx.lastSpeedTime)
                    if dt >= 0.25 {
                        let delta = Double(offset - ctx.lastSpeedBytes)
                        ctx.item.bytesPerSecond = delta / dt
                        ctx.lastSpeedBytes = offset
                        ctx.lastSpeedTime = now
                    }
                    ctx.item.transferredBytes = offset
                    lastEmit = now
                    delegate?.peerSession(self, didUpdateTransfer: ctx.item)
                }
            }

            if ctx.cancelled {
                throw NSError(domain: "DropLink", code: -2, userInfo: [NSLocalizedDescriptionKey: "Cancelled"])
            }

            // 4. Send TRANSFER_COMPLETE with SHA-256
            let digestHex = Data(hasher.finalize()).hexEncodedString()
            ctx.item.sha256 = digestHex
            ctx.item.status = .verifying
            ctx.item.transferredBytes = ctx.size
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)

            let complete = TransferCompletePayload(transferId: ctx.id, sha256: digestHex, totalBytes: ctx.size)
            try sendFrameSync(type: .transferComplete, payload: try jsonEncoder.encode(complete))

            // 5. Wait for TRANSFER_ACK
            if ctx.ackSemaphore.wait(timeout: .now() + 60) == .timedOut {
                throw NSError(domain: "DropLink", code: -4, userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for integrity confirmation"])
            }
            guard let ack = ctx.ackReceived else {
                throw NSError(domain: "DropLink", code: -5, userInfo: [NSLocalizedDescriptionKey: ctx.rejectedReason ?? "Connection closed before confirmation"])
            }
            if !ack.verified {
                throw NSError(domain: "DropLink", code: -6, userInfo: [NSLocalizedDescriptionKey: ack.error ?? "Integrity verification failed on peer"])
            }

            ctx.item.status = .completed
            ctx.item.verified = true
            ctx.item.savedFilename = ack.savedFilename
            ctx.item.completedAt = Date()
            ctx.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)
            completion?(.success(ctx.item))
        } catch {
            if ctx.item.status != .cancelled {
                ctx.item.status = .failed
                ctx.item.errorMessage = error.localizedDescription
                ctx.item.bytesPerSecond = 0
                delegate?.peerSession(self, didUpdateTransfer: ctx.item)
            }
            completion?(.failure(error))
        }
    }

    private func sendFrameSync(type: DLSPFrameType, payload: Data) throws {
        var sendError: Error?
        writeQueue.sync {
            do {
                let wire = try codec.seal(type: type, payload: payload)
                try socket.writeAll(wire)
            } catch {
                sendError = error
            }
        }
        if let err = sendError {
            throw err
        }
    }

    private func startKeepalive() {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 10, repeating: 10)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
            if let data = try? self.jsonEncoder.encode(PingPongPayload(ts: nowMs)) {
                do {
                    try self.sendFrameSync(type: .ping, payload: data)
                } catch {
                    self.close(reason: "Keepalive failed", notifyPeer: false)
                }
            }
        }
        stateLock.lock()
        pingTimer = timer
        stateLock.unlock()
        timer.resume()
    }

    private func startReadLoop() {
        readQueue.async { [weak self] in
            guard let self = self else { return }
            do {
                let maxWire = DLSPConstants.maxPlaintextFrameBytes + DLSPConstants.gcmTagLength
                while true {
                    let body = try self.socket.readLengthPrefixedFrame(maxBytes: maxWire)
                    let (type, payload) = try self.codec.open(ciphertextAndTag: body)
                    try self.handleFrame(type: type, payload: payload)
                }
            } catch {
                self.close(reason: error.localizedDescription, notifyPeer: false)
            }
        }
    }

    private func handleFrame(type: DLSPFrameType, payload: Data) throws {
        switch type {
        case .ping:
            try sendFrameSync(type: .pong, payload: payload)

        case .pong:
            if let pong = try? jsonDecoder.decode(PingPongPayload.self, from: payload) {
                let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
                let rtt = max(0, Int(nowMs - pong.ts))
                delegate?.peerSession(self, didUpdateLatencyMs: rtt)
            }

        case .transferOffer:
            let offer = try jsonDecoder.decode(TransferOfferPayload.self, from: payload)
            handleTransferOffer(offer)

        case .transferAccept:
            let accept = try jsonDecoder.decode(TransferAcceptPayload.self, from: payload)
            stateLock.lock()
            let ctx = outgoingTransfers[accept.transferId]
            stateLock.unlock()
            if let ctx = ctx {
                ctx.acceptedOffset = accept.resumeOffset
                ctx.acceptSemaphore.signal()
            }

        case .transferReject:
            let reject = try jsonDecoder.decode(TransferRejectPayload.self, from: payload)
            stateLock.lock()
            let ctx = outgoingTransfers[reject.transferId]
            stateLock.unlock()
            if let ctx = ctx {
                ctx.rejectedReason = "\(reject.code): \(reject.reason)"
                ctx.acceptSemaphore.signal()
            }

        case .transferChunk:
            guard let (uuid, offset, chunk) = ChunkCodec.decode(payload) else { return }
            let id = uuid.uuidString.lowercased()
            handleIncomingChunk(transferId: id, offset: offset, chunk: chunk)

        case .transferComplete:
            let complete = try jsonDecoder.decode(TransferCompletePayload.self, from: payload)
            handleIncomingComplete(complete)

        case .transferAck:
            let ack = try jsonDecoder.decode(TransferAckPayload.self, from: payload)
            stateLock.lock()
            let ctx = outgoingTransfers[ack.transferId]
            stateLock.unlock()
            if let ctx = ctx {
                ctx.ackReceived = ack
                ctx.ackSemaphore.signal()
            }

        case .transferCancel:
            let cancel = try jsonDecoder.decode(TransferCancelPayload.self, from: payload)
            handleRemoteCancel(cancel)

        case .sessionClose:
            let closeMsg = try? jsonDecoder.decode(SessionClosePayload.self, from: payload)
            close(reason: closeMsg?.reason ?? "Peer closed session", notifyPeer: false)
        }
    }

    private func handleTransferOffer(_ offer: TransferOfferPayload) {
        let safeFilename = FileUtils.sanitizeFilename(offer.filename)
        do {
            try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        } catch {
            sendReject(transferId: offer.transferId, code: "STORAGE_ERROR", reason: "Cannot access destination directory")
            return
        }

        if let decision = delegate?.peerSessionShouldAcceptIncoming(self, offer: offer), !decision.accept {
            sendReject(
                transferId: offer.transferId,
                code: decision.rejectCode ?? "USER_DECLINED",
                reason: decision.reason ?? "Transfer declined"
            )
            return
        }

        // Check existing partial file for resume
        let cleanId = offer.transferId.lowercased().filter { $0.isHexDigit || $0 == "-" }
        let partURL = destinationDirectory.appendingPathComponent(".droplink-\(cleanId).part")
        let metaURL = destinationDirectory.appendingPathComponent(".droplink-\(cleanId).meta")

        var resumeOffset: UInt64 = 0
        var hasher = SHA256()

        if FileManager.default.fileExists(atPath: partURL.path),
           let metaData = try? Data(contentsOf: metaURL),
           let meta = try? jsonDecoder.decode(PartialTransferMeta.self, from: metaData),
           meta.transferId.lowercased() == offer.transferId.lowercased(),
           meta.size == offer.size,
           meta.filename == safeFilename {
            if let attrs = try? FileManager.default.attributesOfItem(atPath: partURL.path),
               let existingSize = (attrs[.size] as? NSNumber)?.uint64Value,
               existingSize <= offer.size {
                if let streamed = try? FileUtils.streamSHA256(url: partURL, limitBytes: existingSize) {
                    hasher = streamed.hasher
                    resumeOffset = streamed.bytesHashed
                }
            }
        }

        // Storage capacity check (remaining bytes + safety margin)
        let remainingNeeded = offer.size > resumeOffset ? (offer.size - resumeOffset) : 0
        let availableSpace = simulatedFreeDiskBytes ?? FileUtils.availableDiskSpace(at: destinationDirectory)
        if let avail = availableSpace, avail < remainingNeeded + minFreeDiskBufferBytes {
            sendReject(
                transferId: offer.transferId,
                code: "INSUFFICIENT_STORAGE",
                reason: "Not enough disk space (need \(FileUtils.formatBytes(remainingNeeded)), available \(FileUtils.formatBytes(avail)))"
            )
            return
        }

        do {
            if resumeOffset == 0 {
                FileManager.default.createFile(atPath: partURL.path, contents: nil)
            }
            let meta = PartialTransferMeta(transferId: offer.transferId.lowercased(), filename: safeFilename, size: offer.size)
            try jsonEncoder.encode(meta).write(to: metaURL, options: .atomic)

            let handle = try FileHandle(forUpdating: partURL)
            try handle.seek(toOffset: resumeOffset)

            let item = TransferItem(
                id: offer.transferId.lowercased(),
                direction: .incoming,
                peerDeviceId: deviceId,
                peerDeviceName: deviceName,
                filename: safeFilename,
                totalBytes: offer.size,
                transferredBytes: resumeOffset,
                status: .transferring,
                resumedFromBytes: resumeOffset
            )
            let ctx = IncomingContext(
                id: offer.transferId.lowercased(),
                filename: safeFilename,
                totalBytes: offer.size,
                partURL: partURL,
                metaURL: metaURL,
                fileHandle: handle,
                hasher: hasher,
                receivedBytes: resumeOffset,
                item: item
            )

            stateLock.lock()
            incomingTransfers[ctx.id] = ctx
            stateLock.unlock()

            delegate?.peerSession(self, didUpdateTransfer: item)

            let accept = TransferAcceptPayload(transferId: offer.transferId, resumeOffset: resumeOffset)
            try sendFrameSync(type: .transferAccept, payload: try jsonEncoder.encode(accept))
        } catch {
            sendReject(transferId: offer.transferId, code: "STORAGE_ERROR", reason: error.localizedDescription)
        }
    }

    private func handleIncomingChunk(transferId: String, offset: UInt64, chunk: Data) {
        stateLock.lock()
        guard let ctx = incomingTransfers[transferId] else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        guard offset == ctx.receivedBytes else {
            failIncoming(ctx: ctx, reason: "Unexpected chunk offset \(offset), expected \(ctx.receivedBytes)", deletePart: false)
            return
        }
        guard ctx.receivedBytes + UInt64(chunk.count) <= ctx.totalBytes else {
            failIncoming(ctx: ctx, reason: "Received data exceeds declared file size", deletePart: true)
            return
        }

        do {
            try ctx.fileHandle.write(contentsOf: chunk)
            ctx.hasher.update(data: chunk)
            ctx.receivedBytes += UInt64(chunk.count)

            let now = Date()
            if now.timeIntervalSince(ctx.lastProgressEmit) >= 0.1 || ctx.receivedBytes == ctx.totalBytes {
                let dt = now.timeIntervalSince(ctx.lastSpeedTime)
                if dt >= 0.25 {
                    let delta = Double(ctx.receivedBytes - ctx.lastSpeedBytes)
                    ctx.item.bytesPerSecond = delta / dt
                    ctx.lastSpeedBytes = ctx.receivedBytes
                    ctx.lastSpeedTime = now
                }
                ctx.item.transferredBytes = ctx.receivedBytes
                ctx.lastProgressEmit = now
                delegate?.peerSession(self, didUpdateTransfer: ctx.item)
            }
        } catch {
            failIncoming(ctx: ctx, reason: "Disk write error: \(error.localizedDescription)", deletePart: false)
        }
    }

    private func handleIncomingComplete(_ complete: TransferCompletePayload) {
        let id = complete.transferId.lowercased()
        stateLock.lock()
        guard let ctx = incomingTransfers.removeValue(forKey: id) else {
            stateLock.unlock()
            return
        }
        stateLock.unlock()

        do {
            ctx.item.status = .verifying
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)

            try ctx.fileHandle.synchronize()
            try ctx.fileHandle.close()

            guard ctx.receivedBytes == complete.totalBytes && ctx.receivedBytes == ctx.totalBytes else {
                try? FileManager.default.removeItem(at: ctx.partURL)
                try? FileManager.default.removeItem(at: ctx.metaURL)
                let msg = "Size mismatch: received \(ctx.receivedBytes), expected \(complete.totalBytes)"
                ctx.item.status = .failed
                ctx.item.errorMessage = msg
                ctx.item.bytesPerSecond = 0
                delegate?.peerSession(self, didUpdateTransfer: ctx.item)
                sendAck(transferId: complete.transferId, verified: false, savedFilename: nil, error: msg)
                return
            }

            let computedSha = Data(ctx.hasher.finalize()).hexEncodedString()
            guard computedSha.lowercased() == complete.sha256.lowercased() else {
                try? FileManager.default.removeItem(at: ctx.partURL)
                try? FileManager.default.removeItem(at: ctx.metaURL)
                let msg = "SHA-256 integrity mismatch"
                ctx.item.status = .failed
                ctx.item.errorMessage = msg
                ctx.item.bytesPerSecond = 0
                delegate?.peerSession(self, didUpdateTransfer: ctx.item)
                sendAck(transferId: complete.transferId, verified: false, savedFilename: nil, error: msg)
                return
            }

            // Atomic commit to unique non-overwriting final destination
            let finalURL = FileUtils.uniqueDestinationURL(in: destinationDirectory, filename: ctx.filename)
            try FileManager.default.moveItem(at: ctx.partURL, to: finalURL)
            try? FileManager.default.removeItem(at: ctx.metaURL)

            ctx.item.status = .completed
            ctx.item.verified = true
            ctx.item.sha256 = computedSha
            ctx.item.savedFilename = finalURL.lastPathComponent
            ctx.item.localFileURL = finalURL
            ctx.item.transferredBytes = ctx.totalBytes
            ctx.item.bytesPerSecond = 0
            ctx.item.completedAt = Date()
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)

            sendAck(transferId: complete.transferId, verified: true, savedFilename: finalURL.lastPathComponent, error: nil)
        } catch {
            let msg = "Failed to finalize file: \(error.localizedDescription)"
            ctx.item.status = .failed
            ctx.item.errorMessage = msg
            ctx.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: ctx.item)
            sendAck(transferId: complete.transferId, verified: false, savedFilename: nil, error: msg)
        }
    }

    private func handleRemoteCancel(_ cancel: TransferCancelPayload) {
        let id = cancel.transferId.lowercased()
        stateLock.lock()
        let out = outgoingTransfers[id]
        let inc = incomingTransfers.removeValue(forKey: id)
        stateLock.unlock()

        if let out = out {
            out.cancelled = true
            out.rejectedReason = cancel.reason
            out.acceptSemaphore.signal()
            out.ackSemaphore.signal()
            out.item.status = .cancelled
            out.item.errorMessage = cancel.reason
            out.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: out.item)
        }

        if let inc = inc {
            try? inc.fileHandle.close()
            try? FileManager.default.removeItem(at: inc.partURL)
            try? FileManager.default.removeItem(at: inc.metaURL)
            inc.item.status = .cancelled
            inc.item.errorMessage = cancel.reason
            inc.item.bytesPerSecond = 0
            delegate?.peerSession(self, didUpdateTransfer: inc.item)
        }
    }

    private func failIncoming(ctx: IncomingContext, reason: String, deletePart: Bool) {
        stateLock.lock()
        incomingTransfers.removeValue(forKey: ctx.id)
        stateLock.unlock()
        try? ctx.fileHandle.close()
        if deletePart {
            try? FileManager.default.removeItem(at: ctx.partURL)
            try? FileManager.default.removeItem(at: ctx.metaURL)
        }
        ctx.item.status = .failed
        ctx.item.errorMessage = reason
        ctx.item.bytesPerSecond = 0
        delegate?.peerSession(self, didUpdateTransfer: ctx.item)
        sendAck(transferId: ctx.id, verified: false, savedFilename: nil, error: reason)
    }

    private func sendReject(transferId: String, code: String, reason: String) {
        if let data = try? jsonEncoder.encode(TransferRejectPayload(transferId: transferId, code: code, reason: reason)) {
            try? sendFrameSync(type: .transferReject, payload: data)
        }
    }

    private func sendAck(transferId: String, verified: Bool, savedFilename: String?, error: String?) {
        if let data = try? jsonEncoder.encode(TransferAckPayload(transferId: transferId, verified: verified, savedFilename: savedFilename, error: error)) {
            try? sendFrameSync(type: .transferAck, payload: data)
        }
    }
}
