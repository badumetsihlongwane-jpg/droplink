import Foundation

public enum DLSPConstants {
    public static let protocolVersion = "DLSP/1"
    public static let maxHandshakeBytes = 65_536
    public static let maxPlaintextFrameBytes = 1_049_600 // 1 MiB + 1 KiB
    public static let defaultChunkSize = 262_144 // 256 KiB
    public static let gcmTagLength = 16
    public static let directionClientToServer: UInt32 = 1
    public static let directionServerToClient: UInt32 = 2
}

public enum DLSPFrameType: UInt8 {
    case ping = 0x01
    case pong = 0x02
    case transferOffer = 0x10
    case transferAccept = 0x11
    case transferReject = 0x12
    case transferChunk = 0x13
    case transferComplete = 0x14
    case transferAck = 0x15
    case transferCancel = 0x16
    case sessionClose = 0x20
}

public enum DLSPAuthErrorCode: String, Codable, Error {
    case invalidSession = "INVALID_SESSION"
    case expiredSession = "EXPIRED_SESSION"
    case authFailed = "AUTH_FAILED"
    case protocolMismatch = "PROTOCOL_MISMATCH"
    case invalidReconnect = "INVALID_RECONNECT"
}

public struct ClientHello: Codable {
    public let `protocol`: String
    public let sessionId: String
    public let mode: String // "pair" | "reconnect"
    public let reconnectToken: String?
    public let deviceId: String
    public let deviceName: String
    public let clientNonce: String
    public let clientPublicKey: String
    public let authProof: String

    public init(
        protocol: String = DLSPConstants.protocolVersion,
        sessionId: String,
        mode: String,
        reconnectToken: String? = nil,
        deviceId: String,
        deviceName: String,
        clientNonce: String,
        clientPublicKey: String,
        authProof: String
    ) {
        self.`protocol` = `protocol`
        self.sessionId = sessionId
        self.mode = mode
        self.reconnectToken = reconnectToken
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.clientNonce = clientNonce
        self.clientPublicKey = clientPublicKey
        self.authProof = authProof
    }
}

public struct ServerHello: Codable {
    public let ok: Bool
    public let `protocol`: String?
    public let serverName: String?
    public let serverNonce: String?
    public let serverPublicKey: String?
    public let serverProof: String?
    public let reconnectToken: String?
    public let code: String?
    public let message: String?

    public static func success(
        serverName: String,
        serverNonce: String,
        serverPublicKey: String,
        serverProof: String,
        reconnectToken: String
    ) -> ServerHello {
        ServerHello(
            ok: true,
            protocol: DLSPConstants.protocolVersion,
            serverName: serverName,
            serverNonce: serverNonce,
            serverPublicKey: serverPublicKey,
            serverProof: serverProof,
            reconnectToken: reconnectToken,
            code: nil,
            message: nil
        )
    }

    public static func failure(code: DLSPAuthErrorCode, message: String) -> ServerHello {
        ServerHello(
            ok: false,
            protocol: DLSPConstants.protocolVersion,
            serverName: nil,
            serverNonce: nil,
            serverPublicKey: nil,
            serverProof: nil,
            reconnectToken: nil,
            code: code.rawValue,
            message: message
        )
    }
}

public struct PingPongPayload: Codable {
    public let ts: Int64
    public init(ts: Int64) { self.ts = ts }
}

public struct TransferOfferPayload: Codable {
    public let transferId: String
    public let filename: String
    public let size: UInt64
    public let mimeType: String
    public let chunkSize: UInt32

    public init(transferId: String, filename: String, size: UInt64, mimeType: String, chunkSize: UInt32 = UInt32(DLSPConstants.defaultChunkSize)) {
        self.transferId = transferId
        self.filename = filename
        self.size = size
        self.mimeType = mimeType
        self.chunkSize = chunkSize
    }
}

public struct TransferAcceptPayload: Codable {
    public let transferId: String
    public let resumeOffset: UInt64
    public init(transferId: String, resumeOffset: UInt64 = 0) {
        self.transferId = transferId
        self.resumeOffset = resumeOffset
    }
}

public struct TransferRejectPayload: Codable {
    public let transferId: String
    public let code: String
    public let reason: String
    public init(transferId: String, code: String, reason: String) {
        self.transferId = transferId
        self.code = code
        self.reason = reason
    }
}

public struct TransferCompletePayload: Codable {
    public let transferId: String
    public let sha256: String
    public let totalBytes: UInt64
    public init(transferId: String, sha256: String, totalBytes: UInt64) {
        self.transferId = transferId
        self.sha256 = sha256
        self.totalBytes = totalBytes
    }
}

public struct TransferAckPayload: Codable {
    public let transferId: String
    public let verified: Bool
    public let savedFilename: String?
    public let error: String?
    public init(transferId: String, verified: Bool, savedFilename: String? = nil, error: String? = nil) {
        self.transferId = transferId
        self.verified = verified
        self.savedFilename = savedFilename
        self.error = error
    }
}

public struct TransferCancelPayload: Codable {
    public let transferId: String
    public let reason: String
    public init(transferId: String, reason: String) {
        self.transferId = transferId
        self.reason = reason
    }
}

public struct SessionClosePayload: Codable {
    public let reason: String
    public init(reason: String) { self.reason = reason }
}

public struct PairingPayload: Equatable {
    public let version: Int
    public let hosts: [String]
    public let port: UInt16
    public let sessionId: String
    public let pairingSecret: Data
    public let expiresAt: Int64
    public let deviceName: String

    public init(
        version: Int = 1,
        hosts: [String],
        port: UInt16,
        sessionId: String,
        pairingSecret: Data,
        expiresAt: Int64,
        deviceName: String
    ) {
        self.version = version
        self.hosts = hosts
        self.port = port
        self.sessionId = sessionId
        self.pairingSecret = pairingSecret
        self.expiresAt = expiresAt
        self.deviceName = deviceName
    }

    public func toURI() -> String {
        let hostParam = hosts.joined(separator: ",")
        let keyB64 = pairingSecret.base64UrlEncodedString()
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        let encodedName = deviceName.addingPercentEncoding(withAllowedCharacters: allowed) ?? "Mac"
        return "droplink://pair?v=\(version)&h=\(hostParam)&p=\(port)&s=\(sessionId)&k=\(keyB64)&e=\(expiresAt)&n=\(encodedName)"
    }

    public static func parse(uri: String) -> PairingPayload? {
        guard let components = URLComponents(string: uri),
              components.scheme == "droplink",
              components.host == "pair",
              let items = components.queryItems else {
            return nil
        }
        var dict: [String: String] = [:]
        for item in items {
            if let v = item.value { dict[item.name] = v }
        }
        guard let vStr = dict["v"], let version = Int(vStr), version == 1,
              let hStr = dict["h"], !hStr.isEmpty,
              let pStr = dict["p"], let port = UInt16(pStr), port > 0,
              let sessionId = dict["s"], sessionId.count == 32,
              let kStr = dict["k"], let psk = Data(base64UrlEncoded: kStr), psk.count == 32,
              let eStr = dict["e"], let expiresAt = Int64(eStr) else {
            return nil
        }
        let hosts = hStr.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        let name = dict["n"] ?? "DropLink Mac"
        return PairingPayload(
            version: version,
            hosts: hosts,
            port: port,
            sessionId: sessionId,
            pairingSecret: psk,
            expiresAt: expiresAt,
            deviceName: name
        )
    }
}

public enum ChunkCodec {
    public static func encode(transferId: UUID, offset: UInt64, data: Data) -> Data {
        var out = Data(capacity: 24 + data.count)
        var uuidBytes = transferId.uuid
        withUnsafeBytes(of: &uuidBytes) { out.append(contentsOf: $0) }
        var beOffset = offset.bigEndian
        withUnsafeBytes(of: &beOffset) { out.append(contentsOf: $0) }
        out.append(data)
        return out
    }

    public static func decode(_ payload: Data) -> (transferId: UUID, offset: UInt64, chunk: Data)? {
        let bytes = Data(payload)
        guard bytes.count >= 24 else { return nil }
        let uuidData = bytes.subdata(in: 0..<16)
        let uuidTuple: uuid_t = (
            uuidData[0], uuidData[1], uuidData[2], uuidData[3],
            uuidData[4], uuidData[5], uuidData[6], uuidData[7],
            uuidData[8], uuidData[9], uuidData[10], uuidData[11],
            uuidData[12], uuidData[13], uuidData[14], uuidData[15]
        )
        let transferId = UUID(uuid: uuidTuple)
        let offset = bytes.subdata(in: 16..<24).withUnsafeBytes { ptr -> UInt64 in
            var val: UInt64 = 0
            memcpy(&val, ptr.baseAddress!, 8)
            return UInt64(bigEndian: val)
        }
        let chunk = bytes.subdata(in: 24..<bytes.count)
        return (transferId, offset, chunk)
    }
}
