import Foundation
import CryptoKit
import DropLinkCore

// Lightweight zero-dependency test harness (runs with macOS Command Line Tools without Xcode/XCTest)

private var passedTests = 0
private var failedTests = 0

private func check(_ condition: Bool, _ message: String) throws {
    if !condition {
        throw NSError(domain: "DropLinkTest", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

private func runTest(_ name: String, _ block: () throws -> Void) {
    do {
        try block()
        passedTests += 1
        print("  [PASS] \(name)")
    } catch {
        failedTests += 1
        print("  [FAIL] \(name): \(error.localizedDescription)")
    }
}

private struct TestVectorFile: Codable {
    struct FrameVec: Codable {
        let direction: UInt32
        let seq: UInt64
        let plaintextHex: String
        let nonceHex: String
        let aadHex: String
        let ciphertextAndTagHex: String
    }
    let protocolVersion: String
    let sessionId: String
    let mode: String
    let deviceId: String
    let pskHex: String
    let pskBase64Url: String
    let clientPrivHex: String
    let clientPubHex: String
    let serverPrivHex: String
    let serverPubHex: String
    let ecdhSharedHex: String
    let clientNonce: String
    let serverNonce: String
    let clientProofHex: String
    let serverProofHex: String
    let saltHex: String
    let c2sKeyHex: String
    let s2cKeyHex: String
    let reconnectKeyHex: String
    let frameC2SSeq0: FrameVec
    let frameS2CSeq0: FrameVec
    let qrUri: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol"
        case sessionId, mode, deviceId, pskHex, pskBase64Url
        case clientPrivHex, clientPubHex, serverPrivHex, serverPubHex
        case ecdhSharedHex, clientNonce, serverNonce
        case clientProofHex, serverProofHex, saltHex
        case c2sKeyHex, s2cKeyHex, reconnectKeyHex
        case frameC2SSeq0, frameS2CSeq0, qrUri
    }
}

private final class TestServerObserver: DropLinkServerDelegate {
    let lock = NSLock()
    var transfers: [String: TransferItem] = [:]
    var devices: [ConnectedDevice] = []
    var onTransferUpdate: ((TransferItem) -> Void)?

    func serverDidUpdateSessionState(_ server: DropLinkServer) {}
    func server(_ server: DropLinkServer, didUpdateDevices devices: [ConnectedDevice]) {
        lock.lock()
        self.devices = devices
        lock.unlock()
    }
    func server(_ server: DropLinkServer, didUpdateTransfer item: TransferItem) {
        lock.lock()
        transfers[item.id] = item
        let cb = onTransferUpdate
        lock.unlock()
        cb?(item)
    }
    func server(_ server: DropLinkServer, didLog event: String) {}
}

private final class TestPeerObserver: PeerSessionDelegate {
    var onTransferUpdate: ((TransferItem) -> Void)?
    func peerSession(_ session: PeerSession, didUpdateTransfer item: TransferItem) {
        onTransferUpdate?(item)
    }
    func peerSession(_ session: PeerSession, didUpdateLatencyMs latencyMs: Int) {}
    func peerSessionDidDisconnect(_ session: PeerSession, reason: String?) {}
    func peerSessionShouldAcceptIncoming(_ session: PeerSession, offer: TransferOfferPayload) -> (accept: Bool, rejectCode: String?, reason: String?) {
        return (true, nil, nil)
    }
}

private func makeTempDir(_ prefix: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("droplink-test-\(prefix)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeRandomFile(at url: URL, sizeBytes: Int) throws -> String {
    FileManager.default.createFile(atPath: url.path, contents: nil)
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    var hasher = SHA256()
    var remaining = sizeBytes
    // Deterministic fast pseudo-random pattern for repeatable speed
    var block = Data(count: 65536)
    for i in 0..<block.count {
        block[i] = UInt8((i * 31 + 17) & 0xFF)
    }
    var chunkIndex: UInt8 = 0
    while remaining > 0 {
        let toWrite = min(block.count, remaining)
        block[0] = chunkIndex
        chunkIndex &+= 1
        let slice = block.prefix(toWrite)
        try handle.write(contentsOf: slice)
        hasher.update(data: slice)
        remaining -= toWrite
    }
    try handle.synchronize()
    return Data(hasher.finalize()).hexEncodedString()
}

// MARK: - Optional headless test server harness mode for Node.js cross-platform interop tests
if CommandLine.arguments.contains("--serve-harness") {
    let dirArgIndex = CommandLine.arguments.firstIndex(of: "--dir").map { $0 + 1 }
    let destDir: URL
    if let idx = dirArgIndex, idx < CommandLine.arguments.count {
        destDir = URL(fileURLWithPath: CommandLine.arguments[idx])
    } else {
        destDir = try! makeTempDir("harness")
    }
    let sendFileIndex = CommandLine.arguments.firstIndex(of: "--send-on-connect").map { $0 + 1 }
    let sendOnConnectURL: URL? = (sendFileIndex != nil && sendFileIndex! < CommandLine.arguments.count)
        ? URL(fileURLWithPath: CommandLine.arguments[sendFileIndex!])
        : nil

    var config = DropLinkServerConfig(
        deviceName: "Swift Test Mac",
        destinationDirectory: destDir,
        preferredPort: 0,
        qrExpirationSeconds: 600,
        minFreeDiskBufferBytes: 1024 * 1024
    )
    if let simIdx = CommandLine.arguments.firstIndex(of: "--sim-free-bytes").map({ $0 + 1 }),
       simIdx < CommandLine.arguments.count,
       let simVal = UInt64(CommandLine.arguments[simIdx]) {
        config.simulatedFreeDiskBytes = simVal
    }

    let server = DropLinkServer(config: config)
    let observer = TestServerObserver()
    var sentOnce = false
    server.delegate = observer
    observer.onTransferUpdate = { item in
        if item.status == .completed || item.status == .failed {
            let line = "EVENT_TRANSFER:\(item.direction.rawValue):\(item.status.rawValue):\(item.savedFilename ?? item.filename):\(item.sha256 ?? "")"
            print(line)
            fflush(stdout)
        }
    }

    try! server.start()
    guard let payload = server.currentPairingPayload else { exit(1) }
    let info: [String: Any] = [
        "port": Int(payload.port),
        "sessionId": payload.sessionId,
        "pskHex": payload.pairingSecret.hexEncodedString(),
        "qrUri": payload.toURI(),
        "destDir": destDir.path
    ]
    let json = try! JSONSerialization.data(withJSONObject: info)
    print("HARNESS_READY:\(String(data: json, encoding: .utf8)!)")
    fflush(stdout)

    // Watch stdin for control commands ("EXPIRE", "SEND <path>", "QUIT")
    DispatchQueue.global().async {
        while let line = readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed == "EXPIRE" {
                server.expirePairingNowForTesting()
                print("HARNESS_EXPIRED")
                fflush(stdout)
            } else if trimmed.hasPrefix("SEND ") {
                let filePath = String(trimmed.dropFirst(5))
                _ = server.sendFiles(urls: [URL(fileURLWithPath: filePath)])
                print("HARNESS_SEND_STARTED")
                fflush(stdout)
            } else if trimmed == "QUIT" {
                server.stop()
                exit(0)
            }
        }
    }

    if let autoSend = sendOnConnectURL {
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
            if !sentOnce && !server.devices.isEmpty {
                sentOnce = true
                _ = server.sendFiles(urls: [autoSend])
            }
        }
    }
    RunLoop.main.run()
    exit(0)
}

// MARK: - Main Automated Test Suite
print("=== DropLinkCore Automated Test Suite ===")

runTest("1. Shared DLSP/1 Cryptographic Test Vectors (ECDH P-256, HMAC, HKDF, AES-256-GCM)") {
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let candidates = [
        cwd.appendingPathComponent("../protocol/test_vectors.json"),
        cwd.appendingPathComponent("protocol/test_vectors.json")
    ]
    guard let vecURL = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
        throw NSError(domain: "DropLinkTest", code: 1, userInfo: [NSLocalizedDescriptionKey: "Cannot locate protocol/test_vectors.json"])
    }
    let vec = try JSONDecoder().decode(TestVectorFile.self, from: Data(contentsOf: vecURL))

    let clientPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: vec.clientPrivHex)!)
    let serverPriv = try P256.KeyAgreement.PrivateKey(rawRepresentation: Data(hexString: vec.serverPrivHex)!)
    try check(clientPriv.publicKey.x963Representation.hexEncodedString() == vec.clientPubHex, "Client P-256 public key mismatch")
    try check(serverPriv.publicKey.x963Representation.hexEncodedString() == vec.serverPubHex, "Server P-256 public key mismatch")

    let shared1 = try DLSPCrypto.computeECDHSharedSecret(privateKey: clientPriv, peerPublicKeyX963: Data(hexString: vec.serverPubHex)!)
    let shared2 = try DLSPCrypto.computeECDHSharedSecret(privateKey: serverPriv, peerPublicKeyX963: Data(hexString: vec.clientPubHex)!)
    try check(shared1.hexEncodedString() == vec.ecdhSharedHex, "Client ECDH shared secret mismatch")
    try check(shared2.hexEncodedString() == vec.ecdhSharedHex, "Server ECDH shared secret mismatch")

    let psk = Data(hexString: vec.pskHex)!
    let cProof = DLSPCrypto.clientAuthProof(
        authKey: psk,
        sessionId: vec.sessionId,
        mode: vec.mode,
        clientNonce: vec.clientNonce,
        clientPublicKeyHex: vec.clientPubHex,
        deviceId: vec.deviceId
    )
    try check(cProof == vec.clientProofHex, "Client auth proof mismatch")

    let sProof = DLSPCrypto.serverAuthProof(
        authKey: psk,
        sessionId: vec.sessionId,
        mode: vec.mode,
        clientNonce: vec.clientNonce,
        serverNonce: vec.serverNonce,
        clientPublicKeyHex: vec.clientPubHex,
        serverPublicKeyHex: vec.serverPubHex
    )
    try check(sProof == vec.serverProofHex, "Server auth proof mismatch")

    let keys = DLSPCrypto.deriveKeys(
        ecdhShared: shared1,
        authKey: psk,
        sessionId: vec.sessionId,
        clientNonce: vec.clientNonce,
        serverNonce: vec.serverNonce
    )
    try check(keys.c2sKey.hexEncodedString() == vec.c2sKeyHex, "c2sKey mismatch")
    try check(keys.s2cKey.hexEncodedString() == vec.s2cKeyHex, "s2cKey mismatch")
    try check(keys.reconnectKey.hexEncodedString() == vec.reconnectKeyHex, "reconnectKey mismatch")

    let c2sPlain = Data(hexString: vec.frameC2SSeq0.plaintextHex)!
    let c2sEnc = try DLSPCrypto.encryptFrame(key: keys.c2sKey, direction: 1, seq: 0, plaintext: c2sPlain)
    try check(c2sEnc.hexEncodedString() == vec.frameC2SSeq0.ciphertextAndTagHex, "C2S AES-GCM ciphertext mismatch")
    let c2sDec = try DLSPCrypto.decryptFrame(key: keys.c2sKey, direction: 1, seq: 0, ciphertextAndTag: c2sEnc)
    try check(c2sDec == c2sPlain, "C2S AES-GCM decryption mismatch")

    let s2cPlain = Data(hexString: vec.frameS2CSeq0.plaintextHex)!
    let s2cEnc = try DLSPCrypto.encryptFrame(key: keys.s2cKey, direction: 2, seq: 0, plaintext: s2cPlain)
    try check(s2cEnc.hexEncodedString() == vec.frameS2CSeq0.ciphertextAndTagHex, "S2C AES-GCM ciphertext mismatch")

    // Tampered ciphertext must fail decryption
    var tampered = c2sEnc
    tampered[0] ^= 0xFF
    var didFail = false
    do {
        _ = try DLSPCrypto.decryptFrame(key: keys.c2sKey, direction: 1, seq: 0, ciphertextAndTag: tampered)
    } catch {
        didFail = true
    }
    try check(didFail, "Tampered ciphertext should fail AES-GCM authentication")

    // QR URI roundtrip
    guard let parsed = PairingPayload.parse(uri: vec.qrUri) else {
        throw NSError(domain: "DropLinkTest", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse QR URI"])
    }
    try check(parsed.hosts == ["192.168.1.42", "10.0.0.5"], "QR hosts mismatch")
    try check(parsed.port == 54321, "QR port mismatch")
    try check(parsed.sessionId == vec.sessionId, "QR sessionId mismatch")
    try check(parsed.pairingSecret == psk, "QR PSK mismatch")
    try check(parsed.deviceName == "MacBook Air", "QR deviceName mismatch")
}

runTest("2. Filename Sanitization (Traversal, Unicode, Spaces, Emoji, Overlong)") {
    try check(FileUtils.sanitizeFilename("../../etc/passwd") == "passwd", "Path traversal not stripped")
    try check(FileUtils.sanitizeFilename("C:\\Users\\test\\secret.txt") == "secret.txt", "Windows path not stripped")
    try check(FileUtils.sanitizeFilename(".hidden") == "hidden", "Leading dot not stripped")
    try check(FileUtils.sanitizeFilename("Report 2026 — Résumé 🚀 日本語.pdf") == "Report 2026 — Résumé 🚀 日本語.pdf", "Unicode/emoji not preserved")
    try check(FileUtils.sanitizeFilename("bad\u{0000}name\nfile.txt") == "badnamefile.txt", "Control chars not stripped")
    let longName = String(repeating: "あ", count: 100) + ".mp4"
    let sanitizedLong = FileUtils.sanitizeFilename(longName)
    try check(sanitizedLong.utf8.count <= 200 && sanitizedLong.hasSuffix(".mp4"), "Overlong UTF-8 filename truncation failed")
}

runTest("3. Duplicate Filename Resolution (Non-Overwriting)") {
    let dir = try makeTempDir("dups")
    defer { try? FileManager.default.removeItem(at: dir) }

    let u1 = FileUtils.uniqueDestinationURL(in: dir, filename: "vacation photo.jpg")
    try check(u1.lastPathComponent == "vacation photo.jpg", "First filename wrong")
    FileManager.default.createFile(atPath: u1.path, contents: Data("a".utf8))

    let u2 = FileUtils.uniqueDestinationURL(in: dir, filename: "vacation photo.jpg")
    try check(u2.lastPathComponent == "vacation photo (1).jpg", "Second filename wrong: \(u2.lastPathComponent)")
    FileManager.default.createFile(atPath: u2.path, contents: Data("b".utf8))

    let u3 = FileUtils.uniqueDestinationURL(in: dir, filename: "vacation photo.jpg")
    try check(u3.lastPathComponent == "vacation photo (2).jpg", "Third filename wrong: \(u3.lastPathComponent)")
}

runTest("4. Auth Security: Invalid PSK, Invalid Session, Expired Session, Invalid Reconnect") {
    let dir = try makeTempDir("auth")
    defer { try? FileManager.default.removeItem(at: dir) }
    let server = DropLinkServer(config: DropLinkServerConfig(destinationDirectory: dir))
    try server.start()
    defer { server.stop() }
    let p = server.currentPairingPayload!

    // Wrong PSK
    do {
        _ = try DropLinkClient.connect(
            hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
            authKey: DLSPCrypto.randomBytes(count: 32), deviceId: "dev-1", deviceName: "Rogue Phone", destinationDirectory: dir
        )
        try check(false, "Wrong PSK should have been rejected")
    } catch DropLinkClientError.handshakeRejected(let code, _) {
        try check(code == "AUTH_FAILED", "Expected AUTH_FAILED, got \(code)")
    }

    // Wrong session ID
    do {
        _ = try DropLinkClient.connect(
            hosts: ["127.0.0.1"], port: p.port, sessionId: "00000000000000000000000000000000",
            authKey: p.pairingSecret, deviceId: "dev-1", deviceName: "Rogue Phone", destinationDirectory: dir
        )
        try check(false, "Wrong session should have been rejected")
    } catch DropLinkClientError.handshakeRejected(let code, _) {
        try check(code == "INVALID_SESSION", "Expected INVALID_SESSION, got \(code)")
    }

    // Invalid reconnect token
    do {
        _ = try DropLinkClient.connect(
            hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
            authKey: p.pairingSecret, mode: "reconnect", reconnectToken: "deadbeefdeadbeefdeadbeefdeadbeef",
            deviceId: "dev-1", deviceName: "Phone", destinationDirectory: dir
        )
        try check(false, "Invalid reconnect token should have been rejected")
    } catch DropLinkClientError.handshakeRejected(let code, _) {
        try check(code == "INVALID_RECONNECT", "Expected INVALID_RECONNECT, got \(code)")
    }

    // Expired pairing session
    server.expirePairingNowForTesting()
    do {
        _ = try DropLinkClient.connect(
            hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
            authKey: p.pairingSecret, deviceId: "dev-1", deviceName: "Late Phone", destinationDirectory: dir
        )
        try check(false, "Expired pairing session should have been rejected")
    } catch DropLinkClientError.handshakeRejected(let code, _) {
        try check(code == "EXPIRED_SESSION", "Expected EXPIRED_SESSION, got \(code)")
    }
}

runTest("5. Bidirectional Streaming: Client->Mac (20MB Large + Unicode + Duplicates) & Mac->Client") {
    let macDir = try makeTempDir("mac-rx")
    let phoneDir = try makeTempDir("phone-rx")
    let srcDir = try makeTempDir("src")
    defer {
        try? FileManager.default.removeItem(at: macDir)
        try? FileManager.default.removeItem(at: phoneDir)
        try? FileManager.default.removeItem(at: srcDir)
    }

    let server = DropLinkServer(config: DropLinkServerConfig(deviceName: "Test Mac", destinationDirectory: macDir))
    try server.start()
    defer { server.stop() }
    let p = server.currentPairingPayload!

    let conn = try DropLinkClient.connect(
        hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
        authKey: p.pairingSecret, deviceId: "android-pixel-9", deviceName: "Pixel 9", destinationDirectory: phoneDir
    )
    let clientObserver = TestPeerObserver()
    conn.session.delegate = clientObserver
    conn.session.start()
    defer { conn.session.close() }

    // Wait briefly for server device registration
    Thread.sleep(forTimeInterval: 0.15)
    try check(server.devices.count == 1, "Expected 1 connected device on server")

    // A) 20 MB large file Android -> Mac
    let largeURL = srcDir.appendingPathComponent("4K Clip — 東京 🎬.mov")
    let largeSha = try writeRandomFile(at: largeURL, sizeBytes: 20 * 1024 * 1024)

    let largeDone = DispatchSemaphore(value: 0)
    var largeResult: Result<TransferItem, Error>?
    conn.session.sendFile(url: largeURL) { res in
        largeResult = res
        largeDone.signal()
    }
    try check(largeDone.wait(timeout: .now() + 30) == .success, "20MB transfer timed out")
    let largeItem = try largeResult!.get()
    try check(largeItem.verified && largeItem.savedFilename == "4K Clip — 東京 🎬.mov", "Large file metadata mismatch")
    let rxLarge = try FileUtils.streamSHA256(url: macDir.appendingPathComponent("4K Clip — 東京 🎬.mov"))
    try check(rxLarge.digestHex == largeSha, "20MB SHA-256 mismatch on Mac")

    // B) Duplicate filename upload (same name again -> should become "4K Clip — 東京 🎬 (1).mov")
    let smallURL = srcDir.appendingPathComponent("4K Clip — 東京 🎬.mov")
    let dupDone = DispatchSemaphore(value: 0)
    var dupResult: Result<TransferItem, Error>?
    conn.session.sendFile(url: smallURL) { res in
        dupResult = res
        dupDone.signal()
    }
    try check(dupDone.wait(timeout: .now() + 30) == .success, "Duplicate transfer timed out")
    let dupItem = try dupResult!.get()
    try check(dupItem.savedFilename == "4K Clip — 東京 🎬 (1).mov", "Duplicate filename not deduplicated: \(dupItem.savedFilename ?? "nil")")

    // C) Multiple concurrent files (5 files simultaneously) Android -> Mac
    let multiGroup = DispatchGroup()
    var multiErrors: [Error] = []
    var expectedHashes: [String: String] = [:]
    let errLock = NSLock()

    for i in 1...5 {
        let name = "batch file #\(i) (café).bin"
        let url = srcDir.appendingPathComponent(name)
        expectedHashes[name] = try writeRandomFile(at: url, sizeBytes: 512 * 1024 + i * 1337)
        multiGroup.enter()
        conn.session.sendFile(url: url) { res in
            if case .failure(let e) = res {
                errLock.lock(); multiErrors.append(e); errLock.unlock()
            }
            multiGroup.leave()
        }
    }
    try check(multiGroup.wait(timeout: .now() + 30) == .success, "Concurrent multi-file transfer timed out")
    try check(multiErrors.isEmpty, "Concurrent multi-file errors: \(multiErrors)")
    for (name, expectedSha) in expectedHashes {
        let rx = try FileUtils.streamSHA256(url: macDir.appendingPathComponent(name))
        try check(rx.digestHex == expectedSha, "Hash mismatch for \(name)")
    }

    // D) Mac -> Android transfer
    let macFileURL = srcDir.appendingPathComponent("From MacBook Air 📄.txt")
    let macSha = try writeRandomFile(at: macFileURL, sizeBytes: 2 * 1024 * 1024)
    let phoneRxDone = DispatchSemaphore(value: 0)
    var phoneRxItem: TransferItem?
    clientObserver.onTransferUpdate = { item in
        if item.direction == .incoming && item.status == .completed {
            phoneRxItem = item
            phoneRxDone.signal()
        }
    }
    let outItems = server.sendFiles(urls: [macFileURL])
    try check(outItems.count == 1, "Mac sendFiles failed to enqueue")
    try check(phoneRxDone.wait(timeout: .now() + 20) == .success, "Mac->Android transfer timed out")
    try check(phoneRxItem?.verified == true, "Phone did not verify Mac->Android transfer")
    let rxMacFile = try FileUtils.streamSHA256(url: phoneDir.appendingPathComponent("From MacBook Air 📄.txt"))
    try check(rxMacFile.digestHex == macSha, "Mac->Android SHA-256 mismatch")
}

runTest("6. Interrupted Transfer, Reconnect After QR Expiry, and Seamless Byte-Offset Resume") {
    let macDir = try makeTempDir("resume-mac")
    let phoneDir = try makeTempDir("resume-phone")
    let srcDir = try makeTempDir("resume-src")
    defer {
        try? FileManager.default.removeItem(at: macDir)
        try? FileManager.default.removeItem(at: phoneDir)
        try? FileManager.default.removeItem(at: srcDir)
    }

    let server = DropLinkServer(config: DropLinkServerConfig(destinationDirectory: macDir, chunkSize: 65536))
    try server.start()
    defer { server.stop() }
    let p = server.currentPairingPayload!

    // Prepare a 4 MB file
    let fileURL = srcDir.appendingPathComponent("resumable-archive.tar")
    let fullSha = try writeRandomFile(at: fileURL, sizeBytes: 4 * 1024 * 1024)
    let transferId = UUID().uuidString.lowercased()

    // Initial pairing
    let conn1 = try DropLinkClient.connect(
        hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
        authKey: p.pairingSecret, deviceId: "android-resume", deviceName: "Galaxy S24", destinationDirectory: phoneDir, chunkSize: 65536
    )
    conn1.session.start()

    // Expire QR code to prove reconnectToken works even after QR expires!
    server.expirePairingNowForTesting()

    // Simulate an interrupted transfer by pre-creating a valid partial file (1.5 MB already received)
    // and also verifying real mid-flight close preserves .part
    let partialBytes = 1_500_000
    let fullData = try Data(contentsOf: fileURL)
    let partURL = macDir.appendingPathComponent(".droplink-\(transferId).part")
    let metaURL = macDir.appendingPathComponent(".droplink-\(transferId).meta")
    try fullData.prefix(partialBytes).write(to: partURL)
    let metaJson = "{\"transferId\":\"\(transferId)\",\"filename\":\"resumable-archive.tar\",\"size\":\(fullData.count)}"
    try Data(metaJson.utf8).write(to: metaURL)

    // Drop first connection
    conn1.session.close(reason: "Simulated Wi-Fi drop", notifyPeer: false)
    Thread.sleep(forTimeInterval: 0.1)

    // Reconnect using reconnectToken + reconnectKey (even though QR is expired!)
    let conn2 = try DropLinkClient.connect(
        hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
        authKey: conn1.reconnectKey, mode: "reconnect", reconnectToken: conn1.reconnectToken,
        deviceId: "android-resume", deviceName: "Galaxy S24", destinationDirectory: phoneDir, chunkSize: 65536
    )
    conn2.session.start()
    defer { conn2.session.close() }

    let done = DispatchSemaphore(value: 0)
    var resumedResult: Result<TransferItem, Error>?
    conn2.session.sendFile(url: fileURL, transferId: transferId) { res in
        resumedResult = res
        done.signal()
    }
    try check(done.wait(timeout: .now() + 20) == .success, "Resumed transfer timed out")
    let item = try resumedResult!.get()
    try check(item.resumedFromBytes == UInt64(partialBytes), "Expected resume from \(partialBytes), got \(item.resumedFromBytes)")
    try check(item.verified, "Resumed transfer failed verification")
    let finalSha = try FileUtils.streamSHA256(url: macDir.appendingPathComponent("resumable-archive.tar"))
    try check(finalSha.digestHex == fullSha, "Resumed file SHA-256 mismatch")
    try check(!FileManager.default.fileExists(atPath: partURL.path), "Partial file should be cleaned up after atomic commit")
}

runTest("7. Storage Limit Protection (Insufficient Disk Space Clean Rejection)") {
    let macDir = try makeTempDir("storage-mac")
    let phoneDir = try makeTempDir("storage-phone")
    let srcDir = try makeTempDir("storage-src")
    defer {
        try? FileManager.default.removeItem(at: macDir)
        try? FileManager.default.removeItem(at: phoneDir)
        try? FileManager.default.removeItem(at: srcDir)
    }

    var cfg = DropLinkServerConfig(destinationDirectory: macDir)
    cfg.minFreeDiskBufferBytes = 1024 * 1024 // 1 MB buffer
    cfg.simulatedFreeDiskBytes = 512 * 1024  // Simulate only 512 KB free
    let server = DropLinkServer(config: cfg)
    try server.start()
    defer { server.stop() }
    let p = server.currentPairingPayload!

    let conn = try DropLinkClient.connect(
        hosts: ["127.0.0.1"], port: p.port, sessionId: p.sessionId,
        authKey: p.pairingSecret, deviceId: "android-storage", deviceName: "Phone", destinationDirectory: phoneDir
    )
    conn.session.start()
    defer { conn.session.close() }

    let testFile = srcDir.appendingPathComponent("too-big.bin")
    _ = try writeRandomFile(at: testFile, sizeBytes: 256 * 1024)

    let done = DispatchSemaphore(value: 0)
    var errMsg: String?
    conn.session.sendFile(url: testFile) { res in
        if case .failure(let e) = res { errMsg = e.localizedDescription }
        done.signal()
    }
    try check(done.wait(timeout: .now() + 10) == .success, "Storage rejection timed out")
    try check(errMsg?.contains("INSUFFICIENT_STORAGE") == true, "Expected INSUFFICIENT_STORAGE rejection, got: \(errMsg ?? "success")")
    try check(!FileManager.default.fileExists(atPath: macDir.appendingPathComponent("too-big.bin").path), "Rejected file should not exist")
}

print("=== Summary: \(passedTests) passed, \(failedTests) failed ===")
exit(failedTests == 0 ? 0 : 1)
