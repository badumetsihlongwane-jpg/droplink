import Foundation
import CryptoKit

public enum DropLinkClientError: Error, LocalizedError {
    case noReachableHost
    case handshakeRejected(code: String, message: String)
    case serverAuthenticationFailed
    case malformedServerHello

    public var errorDescription: String? {
        switch self {
        case .noReachableHost: return "Could not connect to any advertised host address"
        case .handshakeRejected(let code, let msg): return "\(code): \(msg)"
        case .serverAuthenticationFailed: return "Server identity proof verification failed (possible MITM)"
        case .malformedServerHello: return "Malformed ServerHello response"
        }
    }
}

public struct ClientConnectResult {
    public let session: PeerSession
    public let serverName: String
    public let reconnectToken: String
    public let reconnectKey: Data
}

public enum DropLinkClient {
    public static func connect(
        hosts: [String],
        port: UInt16,
        sessionId: String,
        authKey: Data,
        mode: String = "pair",
        reconnectToken: String? = nil,
        deviceId: String,
        deviceName: String,
        destinationDirectory: URL,
        chunkSize: Int = DLSPConstants.defaultChunkSize
    ) throws -> ClientConnectResult {
        var connectedSocket: TCPSocket?
        for host in hosts {
            if let sock = try? TCPSocket.connect(host: host, port: port, timeoutSeconds: 5) {
                connectedSocket = sock
                break
            }
        }
        guard let socket = connectedSocket else {
            throw DropLinkClientError.noReachableHost
        }

        do {
            socket.setReadTimeout(seconds: 15)
            let clientPriv = P256.KeyAgreement.PrivateKey()
            let clientPubHex = clientPriv.publicKey.x963Representation.hexEncodedString()
            let clientNonceHex = DLSPCrypto.randomBytes(count: 32).hexEncodedString()
            let authProofHex = DLSPCrypto.clientAuthProof(
                authKey: authKey,
                sessionId: sessionId,
                mode: mode,
                clientNonce: clientNonceHex,
                clientPublicKeyHex: clientPubHex,
                deviceId: deviceId
            )

            let hello = ClientHello(
                sessionId: sessionId,
                mode: mode,
                reconnectToken: reconnectToken,
                deviceId: deviceId,
                deviceName: deviceName,
                clientNonce: clientNonceHex,
                clientPublicKey: clientPubHex,
                authProof: authProofHex
            )

            let encoder = JSONEncoder()
            let decoder = JSONDecoder()
            try socket.writeLengthPrefixedFrame(try encoder.encode(hello))

            let rawReply = try socket.readLengthPrefixedFrame(maxBytes: DLSPConstants.maxHandshakeBytes)
            let reply = try decoder.decode(ServerHello.self, from: rawReply)

            guard reply.ok else {
                socket.close()
                throw DropLinkClientError.handshakeRejected(
                    code: reply.code ?? "UNKNOWN",
                    message: reply.message ?? "Handshake failed"
                )
            }

            guard let serverNonce = reply.serverNonce,
                  let serverPubHex = reply.serverPublicKey,
                  let serverPubData = Data(hexString: serverPubHex), serverPubData.count == 65,
                  let serverProofHex = reply.serverProof,
                  let serverProofData = Data(hexString: serverProofHex),
                  let newReconnectToken = reply.reconnectToken,
                  let serverName = reply.serverName else {
                socket.close()
                throw DropLinkClientError.malformedServerHello
            }

            let expectedServerProofHex = DLSPCrypto.serverAuthProof(
                authKey: authKey,
                sessionId: sessionId,
                mode: mode,
                clientNonce: clientNonceHex,
                serverNonce: serverNonce,
                clientPublicKeyHex: clientPubHex,
                serverPublicKeyHex: serverPubHex
            )
            guard let expectedData = Data(hexString: expectedServerProofHex),
                  DLSPCrypto.constantTimeEqual(serverProofData, expectedData) else {
                socket.close()
                throw DropLinkClientError.serverAuthenticationFailed
            }

            let ecdhShared = try DLSPCrypto.computeECDHSharedSecret(
                privateKey: clientPriv,
                peerPublicKeyX963: serverPubData
            )
            let derived = DLSPCrypto.deriveKeys(
                ecdhShared: ecdhShared,
                authKey: authKey,
                sessionId: sessionId,
                clientNonce: clientNonceHex,
                serverNonce: serverNonce
            )

            socket.setReadTimeout(seconds: 0)
            let codec = EncryptedFrameCodec(isServer: false, keys: derived)
            let session = PeerSession(
                deviceId: "host-\(sessionId)",
                deviceName: serverName,
                socket: socket,
                codec: codec,
                isServer: false,
                destinationDirectory: destinationDirectory,
                chunkSize: chunkSize
            )
            return ClientConnectResult(
                session: session,
                serverName: serverName,
                reconnectToken: newReconnectToken,
                reconnectKey: derived.reconnectKey
            )
        } catch {
            socket.close()
            throw error
        }
    }
}
