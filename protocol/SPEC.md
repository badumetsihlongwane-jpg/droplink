# DropLink Secure Protocol v1 (`DLSP/1`)

## Overview

`DLSP/1` is a direct, local-network, TCP-based encrypted file transfer protocol designed for fast, reliable, resumable, and integrity-verified transfers between macOS and Android devices without cloud services, relay servers, or user accounts.

## 1. QR Pairing Payload

When DropLink starts a session on macOS, it generates:
- `sessionId`: 16 random bytes encoded as 32 lowercase hex characters.
- `pairingSecret` (`PSK`): 32 random bytes (256-bit entropy) encoded as URL-safe Base64 without padding (`base64url`).
- `expiresAt`: Unix timestamp in seconds (default: `now + 600` seconds).
- `port`: Ephemeral or configured local TCP listening port.
- `hosts`: Comma-separated list of active local IPv4 addresses (prioritizing Wi-Fi `en0`).

The QR code encodes a compact URI:

```text
droplink://pair?v=1&h=<ip1,ip2>&p=<port>&s=<sessionId>&k=<base64url_psk>&e=<expiresUnix>&n=<urlEncodedName>
```

## 2. Handshake (Pre-Encryption)

Handshake messages are framed as:

```text
[4-byte big-endian uint32 length][UTF-8 JSON payload]
```

Maximum handshake message length: `65,536` bytes.

### Step 1: `ClientHello` (Android → macOS)

Client generates a fresh 32-byte `clientNonce` and an ephemeral NIST P-256 (`secp256r1`) key pair. Public keys are encoded as 65-byte uncompressed SEC1 points (`0x04 || X(32) || Y(32)`) in lowercase hex (130 hex chars).

```json
{
  "protocol": "DLSP/1",
  "sessionId": "<32-char lowercase hex>",
  "mode": "pair",
  "reconnectToken": null,
  "deviceId": "<stable UUID string>",
  "deviceName": "<human-readable device name>",
  "clientNonce": "<64-char lowercase hex>",
  "clientPublicKey": "<130-char lowercase hex>",
  "authProof": "<64-char lowercase hex>"
}
```

`authKey` is the 32-byte `pairingSecret` (when `mode == "pair"`) or the 32-byte `reconnectKey` derived during initial pairing (when `mode == "reconnect"`).

```text
authProof = HMAC-SHA256(
  key = authKey,
  msg = UTF8("DLSP1-CLIENT|" + sessionId + "|" + mode + "|" + clientNonce + "|" + clientPublicKey + "|" + deviceId)
)
```

### Step 2: Verification & `ServerHello` (macOS → Android)

macOS verifies:
1. `protocol == "DLSP/1"`
2. `sessionId` matches the active session.
3. For `mode == "pair"`, current Unix time <= `expiresAt` (pairing window not expired).
4. For `mode == "reconnect"`, `reconnectToken` maps to a valid paired device in the current active session.
5. `authProof` matches expected HMAC in constant time.

If any check fails, macOS sends an error response and closes the TCP connection:

```json
{
  "ok": false,
  "code": "INVALID_SESSION | EXPIRED_SESSION | AUTH_FAILED | PROTOCOL_MISMATCH | INVALID_RECONNECT",
  "message": "<description>"
}
```

On success, macOS generates a 32-byte `serverNonce` and ephemeral P-256 key pair, computes `ecdhShared = ECDH(serverPriv, clientPub)` (32-byte raw X coordinate), derives session keys, and replies:

```json
{
  "ok": true,
  "protocol": "DLSP/1",
  "serverName": "<mac display name>",
  "serverNonce": "<64-char lowercase hex>",
  "serverPublicKey": "<130-char lowercase hex>",
  "serverProof": "<64-char lowercase hex>",
  "reconnectToken": "<32-char lowercase hex>"
}
```

```text
serverProof = HMAC-SHA256(
  key = authKey,
  msg = UTF8("DLSP1-SERVER|" + sessionId + "|" + mode + "|" + clientNonce + "|" + serverNonce + "|" + clientPublicKey + "|" + serverPublicKey)
)
```

The client verifies `serverProof` in constant time before deriving keys.

## 3. Key Derivation (HKDF-SHA256, RFC 5869)

```text
ikm          = ecdhShared (32 bytes) || authKey (32 bytes)
salt         = SHA256(UTF8("DLSP1-SALT|" + sessionId + "|" + clientNonce + "|" + serverNonce))
prk          = HKDF-Extract(salt, ikm)
c2sKey       = HKDF-Expand(prk, UTF8("DLSP1-C2S-KEY"), 32)
s2cKey       = HKDF-Expand(prk, UTF8("DLSP1-S2C-KEY"), 32)
reconnectKey = HKDF-Expand(prk, UTF8("DLSP1-RECONNECT"), 32)
```

Combining ephemeral P-256 ECDH with the QR PSK provides both **forward secrecy** (past traffic cannot be decrypted even if the QR code is photographed later) and **mutual authentication / MITM resistance** (an active attacker on the same Wi-Fi cannot forge either proof or derive keys).

## 4. Encrypted Framing (AES-256-GCM)

After a successful `ServerHello`, every message in both directions is encrypted with AES-256-GCM:

```text
Wire format:  [4-byte BE uint32 bodyLen][ciphertext (plaintextLen bytes)][16-byte GCM tag]
              where bodyLen = plaintextLen + 16
Nonce (12 B): [4-byte BE uint32 direction][8-byte BE uint64 seq]
AAD   (16 B): [4-byte BE uint32 direction][8-byte BE uint64 seq][4-byte BE uint32 plaintextLen]
```

- `direction = 1` (`0x00000001`): Client → Server, encrypted with `c2sKey`.
- `direction = 2` (`0x00000002`): Server → Client, encrypted with `s2cKey`.
- `seq` starts at `0` for each direction and increments strictly by `1` per frame.
- Maximum plaintext frame size: `1,049,600` bytes (1 MiB + 1 KiB).

## 5. Inner Frame Types

Plaintext format: `[1-byte frameType][payload]`

| Type | Name | Format | Description |
| :--- | :--- | :--- | :--- |
| `0x01` | `PING` | JSON `{"ts": <int64>}` | Keepalive request |
| `0x02` | `PONG` | JSON `{"ts": <int64>}` | Keepalive response |
| `0x10` | `TRANSFER_OFFER` | JSON `{"transferId","filename","size","mimeType","chunkSize"}` | Propose a file transfer |
| `0x11` | `TRANSFER_ACCEPT` | JSON `{"transferId","resumeOffset"}` | Accept file (optionally resuming from byte offset) |
| `0x12` | `TRANSFER_REJECT` | JSON `{"transferId","code","reason"}` | Reject file (`INSUFFICIENT_STORAGE`, `USER_DECLINED`, `INVALID_REQUEST`) |
| `0x13` | `TRANSFER_CHUNK` | Binary `[16B UUID][8B BE uint64 offset][bytes]` | Raw streaming file chunk (default 256 KiB) |
| `0x14` | `TRANSFER_COMPLETE` | JSON `{"transferId","sha256","totalBytes"}` | Signals end of file with full-file SHA-256 |
| `0x15` | `TRANSFER_ACK` | JSON `{"transferId","verified","savedFilename","error"}` | Receiver confirms integrity & atomic save |
| `0x16` | `TRANSFER_CANCEL` | JSON `{"transferId","reason"}` | Cancels an in-flight transfer |
| `0x20` | `SESSION_CLOSE` | JSON `{"reason"}` | Graceful session shutdown |

## 6. Reliability & Storage Semantics

- **Streaming**: Files are read and written in 256 KiB chunks; entire files are never buffered in RAM.
- **Atomic writes**: Incoming bytes are written to `.droplink-<transferId>.part`. Only after `bytesReceived == size` and incremental `SHA-256 == offered sha256` is the file atomically renamed to its final destination.
- **Resumable transfers**: If a connection drops mid-transfer, the `.part` file + metadata sidecar remain available for the active session. Upon reconnection, re-offering the same `transferId` causes the receiver to reply with `resumeOffset = currentPartFileSize`, re-hash the existing bytes, and continue streaming seamlessly.
- **Duplicate resolution**: Existing files are never overwritten; conflicts resolve deterministically as `name (1).ext`, `name (2).ext`, etc.
- **Filename sanitization**: Path separators (`/`, `\`), traversal segments (`..`), NUL bytes, and ASCII control characters are stripped while preserving spaces, Unicode, CJK, accented characters, and emoji.
