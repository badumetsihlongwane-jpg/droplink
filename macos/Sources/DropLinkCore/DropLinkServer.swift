import Foundation
import CryptoKit

public protocol DropLinkServerDelegate: AnyObject {
    func serverDidUpdateSessionState(_ server: DropLinkServer)
    func server(_ server: DropLinkServer, didUpdateDevices devices: [ConnectedDevice])
    func server(_ server: DropLinkServer, didUpdateTransfer item: TransferItem)
    func server(_ server: DropLinkServer, didLog event: String)
}

private struct PairedDeviceRecord {
    let deviceId: String
    let deviceName: String
    let reconnectKey: Data
}

public final class DropLinkServer: PeerSessionDelegate {
    public var config: DropLinkServerConfig
    public weak var delegate: DropLinkServerDelegate?

    private let listener = TCPListener()
    private let networkMonitor = LocalNetworkMonitor()
    private let lock = NSLock()
    private let handshakeQueue = DispatchQueue(label: "com.droplink.server.handshake", qos: .userInitiated, attributes: .concurrent)

    public private(set) var isRunning = false
    public private(set) var sessionId: String = ""
    public private(set) var pairingSecret: Data = Data()
    public private(set) var expiresAt: Int64 = 0
    public private(set) var port: UInt16 = 0
    public private(set) var activeHosts: [String] = []
    public private(set) var isNetworkReachable: Bool = true

    private var pairedRecords: [String: PairedDeviceRecord] = [:] // reconnectToken -> record
    private var activeSessions: [String: PeerSession] = [:] // deviceId -> session
    private var connectedDevices: [String: ConnectedDevice] = [:] // deviceId -> metadata

    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()

    public init(config: DropLinkServerConfig = DropLinkServerConfig()) {
        self.config = config
    }

    deinit {
        stop()
    }

    public var currentPairingPayload: PairingPayload? {
        lock.lock()
        defer { lock.unlock() }
        guard isRunning, port > 0 else { return nil }
        let hosts = activeHosts.isEmpty ? ["127.0.0.1"] : activeHosts
        return PairingPayload(
            hosts: hosts,
            port: port,
            sessionId: sessionId,
            pairingSecret: pairingSecret,
            expiresAt: expiresAt,
            deviceName: config.deviceName
        )
    }

    public var devices: [ConnectedDevice] {
        lock.lock()
        defer { lock.unlock() }
        return Array(connectedDevices.values).sorted { $0.connectedAt < $1.connectedAt }
    }

    public func start(forceExpiresAt: Int64? = nil) throws {
        stop()

        try FileManager.default.createDirectory(at: config.destinationDirectory, withIntermediateDirectories: true)

        let newSessionId = DLSPCrypto.randomBytes(count: 16).hexEncodedString()
        let newPsk = DLSPCrypto.randomBytes(count: 32)
        let expiry = forceExpiresAt ?? (Int64(Date().timeIntervalSince1970) + config.qrExpirationSeconds)
        let hosts = LocalNetworkMonitor.activeIPv4Addresses()

        try listener.start(port: config.preferredPort) { [weak self] clientSocket in
            self?.handleIncomingSocket(clientSocket)
        }

        lock.lock()
        self.sessionId = newSessionId
        self.pairingSecret = newPsk
        self.expiresAt = expiry
        self.port = listener.port
        self.activeHosts = hosts
        self.isRunning = true
        self.isNetworkReachable = !hosts.isEmpty
        self.pairedRecords.removeAll()
        lock.unlock()

        networkMonitor.onNetworkChange = { [weak self] updatedHosts, reachable in
            guard let self = self else { return }
            self.lock.lock()
            let wasRunning = self.isRunning
            self.activeHosts = updatedHosts
            self.isNetworkReachable = reachable && !updatedHosts.isEmpty
            self.lock.unlock()
            if wasRunning {
                self.delegate?.server(self, didLog: "Network changed: \(updatedHosts.joined(separator: ", "))")
                self.delegate?.serverDidUpdateSessionState(self)
            }
        }
        networkMonitor.start()

        delegate?.server(self, didLog: "Session started on port \(listener.port)")
        delegate?.serverDidUpdateSessionState(self)
    }

    public func stop() {
        networkMonitor.stop()
        listener.stop()

        lock.lock()
        let sessionsToClose = Array(activeSessions.values)
        activeSessions.removeAll()
        connectedDevices.removeAll()
        pairedRecords.removeAll()
        isRunning = false
        port = 0
        lock.unlock()

        for session in sessionsToClose {
            session.close(reason: "Session stopped by host", notifyPeer: true)
        }

        delegate?.server(self, didUpdateDevices: [])
        delegate?.serverDidUpdateSessionState(self)
    }

    public func refreshQRCode() {
        lock.lock()
        guard isRunning else {
            lock.unlock()
            return
        }
        pairingSecret = DLSPCrypto.randomBytes(count: 32)
        expiresAt = Int64(Date().timeIntervalSince1970) + config.qrExpirationSeconds
        activeHosts = LocalNetworkMonitor.activeIPv4Addresses()
        isNetworkReachable = !activeHosts.isEmpty
        lock.unlock()

        delegate?.server(self, didLog: "QR pairing credentials refreshed")
        delegate?.serverDidUpdateSessionState(self)
    }

    public func expirePairingNowForTesting() {
        lock.lock()
        expiresAt = Int64(Date().timeIntervalSince1970) - 10
        lock.unlock()
        delegate?.serverDidUpdateSessionState(self)
    }

    public func disconnectDevice(deviceId: String) {
        lock.lock()
        let session = activeSessions.removeValue(forKey: deviceId)
        connectedDevices.removeValue(forKey: deviceId)
        pairedRecords = pairedRecords.filter { $0.value.deviceId != deviceId }
        let currentDevices = Array(connectedDevices.values)
        lock.unlock()

        session?.close(reason: "Disconnected by host", notifyPeer: true)
        delegate?.server(self, didUpdateDevices: currentDevices)
    }

    public func disconnectAll() {
        lock.lock()
        let sessions = Array(activeSessions.values)
        activeSessions.removeAll()
        connectedDevices.removeAll()
        pairedRecords.removeAll()
        lock.unlock()

        for s in sessions {
            s.close(reason: "All devices disconnected", notifyPeer: true)
        }
        delegate?.server(self, didUpdateDevices: [])
    }

    @discardableResult
    public func sendFiles(urls: [URL], to deviceId: String? = nil) -> [TransferItem] {
        lock.lock()
        let targetSession: PeerSession?
        if let id = deviceId {
            targetSession = activeSessions[id]
        } else {
            targetSession = activeSessions.values.first
        }
        lock.unlock()

        guard let session = targetSession else { return [] }
        var items: [TransferItem] = []
        for url in urls {
            if let item = session.sendFile(url: url) {
                items.append(item)
            }
        }
        return items
    }

    public func cancelTransfer(id: String) {
        lock.lock()
        let sessions = Array(activeSessions.values)
        lock.unlock()
        for session in sessions {
            session.cancelTransfer(id: id)
        }
    }

    private func handleIncomingSocket(_ socket: TCPSocket) {
        handshakeQueue.async { [weak self] in
            self?.performServerHandshake(socket: socket)
        }
    }

    private func performServerHandshake(socket: TCPSocket) {
        do {
            socket.setReadTimeout(seconds: 15)
            let rawHello = try socket.readLengthPrefixedFrame(maxBytes: DLSPConstants.maxHandshakeBytes)
            let hello = try jsonDecoder.decode(ClientHello.self, from: rawHello)

            guard hello.protocol == DLSPConstants.protocolVersion else {
                try sendFailure(socket: socket, code: .protocolMismatch, message: "Unsupported protocol version")
                return
            }

            lock.lock()
            let active = isRunning
            let currentSessionId = sessionId
            let currentPsk = pairingSecret
            let currentExpiry = expiresAt
            let currentName = config.deviceName
            let reconnectRecord = hello.reconnectToken.flatMap { pairedRecords[$0] }
            lock.unlock()

            guard active, hello.sessionId == currentSessionId else {
                try sendFailure(socket: socket, code: .invalidSession, message: "Invalid or inactive session ID")
                return
            }

            let authKey: Data
            if hello.mode == "pair" {
                let now = Int64(Date().timeIntervalSince1970)
                if now > currentExpiry {
                    try sendFailure(socket: socket, code: .expiredSession, message: "Pairing QR code has expired — refresh on Mac")
                    return
                }
                authKey = currentPsk
            } else if hello.mode == "reconnect" {
                guard let record = reconnectRecord, record.deviceId == hello.deviceId else {
                    try sendFailure(socket: socket, code: .invalidReconnect, message: "Reconnect token invalid or revoked")
                    return
                }
                authKey = record.reconnectKey
            } else {
                try sendFailure(socket: socket, code: .authFailed, message: "Unknown handshake mode")
                return
            }

            guard let clientNonceData = Data(hexString: hello.clientNonce), clientNonceData.count == 32,
                  let clientPubData = Data(hexString: hello.clientPublicKey), clientPubData.count == 65,
                  let receivedProof = Data(hexString: hello.authProof), receivedProof.count == 32 else {
                try sendFailure(socket: socket, code: .authFailed, message: "Malformed handshake parameters")
                return
            }

            let expectedProofHex = DLSPCrypto.clientAuthProof(
                authKey: authKey,
                sessionId: hello.sessionId,
                mode: hello.mode,
                clientNonce: hello.clientNonce,
                clientPublicKeyHex: hello.clientPublicKey,
                deviceId: hello.deviceId
            )
            guard let expectedProofData = Data(hexString: expectedProofHex),
                  DLSPCrypto.constantTimeEqual(receivedProof, expectedProofData) else {
                try sendFailure(socket: socket, code: .authFailed, message: "Authentication failed — invalid pairing secret")
                return
            }

            // Generate ephemeral server P-256 keypair and nonce
            let serverPriv = P256.KeyAgreement.PrivateKey()
            let serverPubHex = serverPriv.publicKey.x963Representation.hexEncodedString()
            let serverNonceHex = DLSPCrypto.randomBytes(count: 32).hexEncodedString()
            let ecdhShared = try DLSPCrypto.computeECDHSharedSecret(privateKey: serverPriv, peerPublicKeyX963: clientPubData)

            let derived = DLSPCrypto.deriveKeys(
                ecdhShared: ecdhShared,
                authKey: authKey,
                sessionId: hello.sessionId,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonceHex
            )

            let serverProofHex = DLSPCrypto.serverAuthProof(
                authKey: authKey,
                sessionId: hello.sessionId,
                mode: hello.mode,
                clientNonce: hello.clientNonce,
                serverNonce: serverNonceHex,
                clientPublicKeyHex: hello.clientPublicKey,
                serverPublicKeyHex: serverPubHex
            )

            let newReconnectToken = DLSPCrypto.randomBytes(count: 16).hexEncodedString()
            let reply = ServerHello.success(
                serverName: currentName,
                serverNonce: serverNonceHex,
                serverPublicKey: serverPubHex,
                serverProof: serverProofHex,
                reconnectToken: newReconnectToken
            )
            try socket.writeLengthPrefixedFrame(try jsonEncoder.encode(reply))

            // Disable short handshake timeout for streaming session
            socket.setReadTimeout(seconds: 0)

            let codec = EncryptedFrameCodec(isServer: true, keys: derived)
            let session = PeerSession(
                deviceId: hello.deviceId,
                deviceName: hello.deviceName,
                socket: socket,
                codec: codec,
                isServer: true,
                destinationDirectory: config.destinationDirectory,
                chunkSize: config.chunkSize,
                maxConcurrentTransfers: config.maxConcurrentTransfers,
                minFreeDiskBufferBytes: config.minFreeDiskBufferBytes,
                simulatedFreeDiskBytes: config.simulatedFreeDiskBytes
            )
            session.delegate = self

            let device = ConnectedDevice(
                id: hello.deviceId,
                name: hello.deviceName,
                address: socket.remoteAddress
            )

            lock.lock()
            let oldSession = activeSessions[hello.deviceId]
            activeSessions[hello.deviceId] = session
            connectedDevices[hello.deviceId] = device
            pairedRecords[newReconnectToken] = PairedDeviceRecord(
                deviceId: hello.deviceId,
                deviceName: hello.deviceName,
                reconnectKey: derived.reconnectKey
            )
            let allDevices = Array(connectedDevices.values).sorted { $0.connectedAt < $1.connectedAt }
            lock.unlock()

            oldSession?.close(reason: "Replaced by reconnected session", notifyPeer: false)

            delegate?.server(self, didLog: "Device paired: \(hello.deviceName) (\(socket.remoteAddress))")
            delegate?.server(self, didUpdateDevices: allDevices)
            session.start()
        } catch {
            socket.close()
        }
    }

    private func sendFailure(socket: TCPSocket, code: DLSPAuthErrorCode, message: String) throws {
        let reply = ServerHello.failure(code: code, message: message)
        try? socket.writeLengthPrefixedFrame(try jsonEncoder.encode(reply))
        socket.close()
    }

    // MARK: - PeerSessionDelegate

    public func peerSession(_ session: PeerSession, didUpdateTransfer item: TransferItem) {
        delegate?.server(self, didUpdateTransfer: item)
    }

    public func peerSession(_ session: PeerSession, didUpdateLatencyMs latencyMs: Int) {
        lock.lock()
        if var dev = connectedDevices[session.deviceId] {
            dev.latencyMs = latencyMs
            dev.lastSeenAt = Date()
            connectedDevices[session.deviceId] = dev
            let all = Array(connectedDevices.values).sorted { $0.connectedAt < $1.connectedAt }
            lock.unlock()
            delegate?.server(self, didUpdateDevices: all)
        } else {
            lock.unlock()
        }
    }

    public func peerSessionDidDisconnect(_ session: PeerSession, reason: String?) {
        lock.lock()
        if activeSessions[session.deviceId] === session {
            activeSessions.removeValue(forKey: session.deviceId)
            connectedDevices.removeValue(forKey: session.deviceId)
        }
        let all = Array(connectedDevices.values).sorted { $0.connectedAt < $1.connectedAt }
        lock.unlock()
        delegate?.server(self, didLog: "Device disconnected: \(session.deviceName)")
        delegate?.server(self, didUpdateDevices: all)
    }

    public func peerSessionShouldAcceptIncoming(_ session: PeerSession, offer: TransferOfferPayload) -> (accept: Bool, rejectCode: String?, reason: String?) {
        return (true, nil, nil)
    }
}
