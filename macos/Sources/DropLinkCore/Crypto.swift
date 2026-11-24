import Foundation
import CryptoKit
import Security

public enum DLSPCryptoError: Error, LocalizedError {
    case invalidKeyFormat
    case invalidHex
    case randomGenerationFailed
    case frameTooLarge
    case authenticationFailed
    case decryptionFailed

    public var errorDescription: String? {
        switch self {
        case .invalidKeyFormat: return "Invalid cryptographic key format"
        case .invalidHex: return "Invalid hex encoding"
        case .randomGenerationFailed: return "Secure random byte generation failed"
        case .frameTooLarge: return "Frame exceeds maximum permitted size"
        case .authenticationFailed: return "Peer authentication proof failed"
        case .decryptionFailed: return "Encrypted frame authentication/decryption failed"
        }
    }
}

public extension Data {
    func hexEncodedString() -> String {
        map { String(format: "%02x", $0) }.joined()
    }

    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var data = Data(capacity: chars.count / 2)
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let byte = UInt8(String(chars[i..<(i + 2)]), radix: 16) else { return nil }
            data.append(byte)
        }
        self = data
    }

    func base64UrlEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    init?(base64UrlEncoded: String) {
        var b64 = base64UrlEncoded
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = b64.count % 4
        if remainder > 0 {
            b64.append(String(repeating: "=", count: 4 - remainder))
        }
        self.init(base64Encoded: b64)
    }
}

public struct DerivedSessionKeys: Equatable {
    public let c2sKey: Data
    public let s2cKey: Data
    public let reconnectKey: Data
}

public enum DLSPCrypto {
    public static func randomBytes(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        if status != errSecSuccess {
            for i in 0..<count {
                bytes[i] = UInt8.random(in: 0...255)
            }
        }
        return Data(bytes)
    }

    public static func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) {
            diff |= x ^ y
        }
        return diff == 0
    }

    public static func hmacSha256(key: Data, message: String) -> Data {
        let symKey = SymmetricKey(data: key)
        let mac = HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: symKey)
        return Data(mac)
    }

    public static func clientAuthProof(
        authKey: Data,
        sessionId: String,
        mode: String,
        clientNonce: String,
        clientPublicKeyHex: String,
        deviceId: String
    ) -> String {
        let msg = "DLSP1-CLIENT|\(sessionId)|\(mode)|\(clientNonce)|\(clientPublicKeyHex)|\(deviceId)"
        return hmacSha256(key: authKey, message: msg).hexEncodedString()
    }

    public static func serverAuthProof(
        authKey: Data,
        sessionId: String,
        mode: String,
        clientNonce: String,
        serverNonce: String,
        clientPublicKeyHex: String,
        serverPublicKeyHex: String
    ) -> String {
        let msg = "DLSP1-SERVER|\(sessionId)|\(mode)|\(clientNonce)|\(serverNonce)|\(clientPublicKeyHex)|\(serverPublicKeyHex)"
        return hmacSha256(key: authKey, message: msg).hexEncodedString()
    }

    public static func computeECDHSharedSecret(
        privateKey: P256.KeyAgreement.PrivateKey,
        peerPublicKeyX963: Data
    ) throws -> Data {
        guard peerPublicKeyX963.count == 65, peerPublicKeyX963.first == 0x04 else {
            throw DLSPCryptoError.invalidKeyFormat
        }
        let peerPub = try P256.KeyAgreement.PublicKey(x963Representation: peerPublicKeyX963)
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: peerPub)
        return shared.withUnsafeBytes { Data($0) }
    }

    public static func deriveKeys(
        ecdhShared: Data,
        authKey: Data,
        sessionId: String,
        clientNonce: String,
        serverNonce: String
    ) -> DerivedSessionKeys {
        var ikm = Data(capacity: ecdhShared.count + authKey.count)
        ikm.append(ecdhShared)
        ikm.append(authKey)

        let saltInput = Data("DLSP1-SALT|\(sessionId)|\(clientNonce)|\(serverNonce)".utf8)
        let salt = Data(SHA256.hash(data: saltInput))

        let prk = HKDF<SHA256>.extract(inputKeyMaterial: SymmetricKey(data: ikm), salt: salt)
        let c2s = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("DLSP1-C2S-KEY".utf8), outputByteCount: 32)
        let s2c = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("DLSP1-S2C-KEY".utf8), outputByteCount: 32)
        let rec = HKDF<SHA256>.expand(pseudoRandomKey: prk, info: Data("DLSP1-RECONNECT".utf8), outputByteCount: 32)

        return DerivedSessionKeys(
            c2sKey: c2s.withUnsafeBytes { Data($0) },
            s2cKey: s2c.withUnsafeBytes { Data($0) },
            reconnectKey: rec.withUnsafeBytes { Data($0) }
        )
    }

    public static func makeNonce(direction: UInt32, seq: UInt64) -> Data {
        var nonce = Data(capacity: 12)
        var d = direction.bigEndian
        var s = seq.bigEndian
        withUnsafeBytes(of: &d) { nonce.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { nonce.append(contentsOf: $0) }
        return nonce
    }

    public static func makeAAD(direction: UInt32, seq: UInt64, plaintextLength: UInt32) -> Data {
        var aad = Data(capacity: 16)
        var d = direction.bigEndian
        var s = seq.bigEndian
        var l = plaintextLength.bigEndian
        withUnsafeBytes(of: &d) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: &s) { aad.append(contentsOf: $0) }
        withUnsafeBytes(of: &l) { aad.append(contentsOf: $0) }
        return aad
    }

    public static func encryptFrame(
        key: Data,
        direction: UInt32,
        seq: UInt64,
        plaintext: Data
    ) throws -> Data {
        guard plaintext.count <= DLSPConstants.maxPlaintextFrameBytes else {
            throw DLSPCryptoError.frameTooLarge
        }
        let nonceData = makeNonce(direction: direction, seq: seq)
        let aad = makeAAD(direction: direction, seq: seq, plaintextLength: UInt32(plaintext.count))
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: SymmetricKey(data: key), nonce: nonce, authenticating: aad)
        var out = Data(capacity: sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    }

    public static func decryptFrame(
        key: Data,
        direction: UInt32,
        seq: UInt64,
        ciphertextAndTag: Data
    ) throws -> Data {
        guard ciphertextAndTag.count >= DLSPConstants.gcmTagLength else {
            throw DLSPCryptoError.decryptionFailed
        }
        let plaintextLen = ciphertextAndTag.count - DLSPConstants.gcmTagLength
        guard plaintextLen <= DLSPConstants.maxPlaintextFrameBytes else {
            throw DLSPCryptoError.frameTooLarge
        }
        let ciphertext = ciphertextAndTag.prefix(plaintextLen)
        let tag = ciphertextAndTag.suffix(DLSPConstants.gcmTagLength)
        let nonceData = makeNonce(direction: direction, seq: seq)
        let aad = makeAAD(direction: direction, seq: seq, plaintextLength: UInt32(plaintextLen))
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertext, tag: tag)
        do {
            return try AES.GCM.open(box, using: SymmetricKey(data: key), authenticating: aad)
        } catch {
            throw DLSPCryptoError.decryptionFailed
        }
    }
}

public final class EncryptedFrameCodec {
    private let sendKey: Data
    private let recvKey: Data
    private let sendDirection: UInt32
    private let recvDirection: UInt32
    private var sendSeq: UInt64 = 0
    private var recvSeq: UInt64 = 0
    private let sendLock = NSLock()
    private let recvLock = NSLock()

    public init(isServer: Bool, keys: DerivedSessionKeys) {
        if isServer {
            self.sendKey = keys.s2cKey
            self.recvKey = keys.c2sKey
            self.sendDirection = DLSPConstants.directionServerToClient
            self.recvDirection = DLSPConstants.directionClientToServer
        } else {
            self.sendKey = keys.c2sKey
            self.recvKey = keys.s2cKey
            self.sendDirection = DLSPConstants.directionClientToServer
            self.recvDirection = DLSPConstants.directionServerToClient
        }
    }

    public func seal(type: DLSPFrameType, payload: Data) throws -> Data {
        sendLock.lock()
        let seq = sendSeq
        sendSeq += 1
        sendLock.unlock()

        var plaintext = Data(capacity: 1 + payload.count)
        plaintext.append(type.rawValue)
        plaintext.append(payload)

        let body = try DLSPCrypto.encryptFrame(
            key: sendKey,
            direction: sendDirection,
            seq: seq,
            plaintext: plaintext
        )

        var wire = Data(capacity: 4 + body.count)
        var lenBE = UInt32(body.count).bigEndian
        withUnsafeBytes(of: &lenBE) { wire.append(contentsOf: $0) }
        wire.append(body)
        return wire
    }

    public func open(ciphertextAndTag: Data) throws -> (type: DLSPFrameType, payload: Data) {
        recvLock.lock()
        let seq = recvSeq
        recvSeq += 1
        recvLock.unlock()

        let plaintext = try DLSPCrypto.decryptFrame(
            key: recvKey,
            direction: recvDirection,
            seq: seq,
            ciphertextAndTag: ciphertextAndTag
        )
        guard let first = plaintext.first, let frameType = DLSPFrameType(rawValue: first) else {
            throw DLSPCryptoError.decryptionFailed
        }
        return (frameType, Data(plaintext.dropFirst()))
    }
}
