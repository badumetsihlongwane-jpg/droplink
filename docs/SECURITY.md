# Security & Privacy

DropLink is designed so that sharing a Wi-Fi network with other devices **never** grants unauthorized access to your files.

## Privacy Guarantees

- **100% Local Traffic**: All handshake and file data travels directly over TCP between your Mac and Android device on your LAN.
- **No Cloud, No Relays, No Accounts**: DropLink makes zero outbound internet connections, has no telemetry or analytics, and never uploads files or metadata anywhere.
- **Ephemeral Credentials**: Session IDs, 256-bit pairing secrets, ephemeral P-256 keys, and reconnect keys live strictly in memory and are wiped when a session stops or resets.

## Cryptographic Design (`DLSP/1`)

| Property | Mechanism |
| :--- | :--- |
| **Pairing Secret** | 256-bit CSPRNG secret (`SecRandomCopyBytes` on macOS) transferred out-of-band via QR code |
| **Key Exchange** | Ephemeral NIST P-256 (`secp256r1`) ECDH per connection (forward secrecy) |
| **Mutual Authentication** | Constant-time `HMAC-SHA256` proofs (`DLSP1-CLIENT\|...` and `DLSP1-SERVER\|...`) bound to session ID, nonces, ephemeral public keys, and device ID |
| **Key Derivation** | RFC 5869 `HKDF-SHA256` over `ECDH_shared \|\| authKey` with `SHA256(sessionId, nonces)` salt, producing separate `c2sKey`, `s2cKey`, and `reconnectKey` |
| **Transport Encryption** | `AES-256-GCM` on every post-handshake frame |
| **Nonce & Replay Protection** | Deterministic 96-bit nonce `[direction (4B) \|\| strictly-monotonic seq (8B)]` bound into 16-byte AAD `[direction \|\| seq \|\| plaintextLen]` — immune to nonce reuse, replay, reordering, and truncation |
| **File Integrity** | Full-file incremental `SHA-256` verified before atomic commit |

## Threat Mitigations

1. **Unauthorized LAN Peer**: An attacker on the same Wi-Fi network without the QR code cannot forge `ClientHello.authProof` (256-bit HMAC-SHA256) and is rejected immediately with `AUTH_FAILED`.
2. **Rogue Server / MITM**: Android verifies `ServerHello.serverProof` in constant time before deriving keys or sending any data; an attacker without the QR secret cannot impersonate the Mac.
3. **Stale / Photographed QR Code**:
   - QR codes expire automatically after the configured window (default 10 minutes); expired pairing attempts are rejected with `EXPIRED_SESSION`.
   - Even if someone photographs an expired or past QR code, past traffic cannot be decrypted because session keys depend on ephemeral P-256 ECDH secrets (**forward secrecy**).
   - Clicking **New QR** rotates the 256-bit pairing secret immediately; clicking **Stop Session** or **Reset Session** revokes all paired devices and reconnect tokens immediately.
4. **Path Traversal & File Overwrite Attacks**:
   - Filenames are sanitized to remove directory components (`../`, `/`, `\`), control characters, NUL bytes, and hidden dot-prefixes.
   - Existing files in the destination folder are never overwritten (`file (1).ext`).
   - Transfers are strictly confined to the user-selected destination directory (macOS) or `Downloads/DropLink` via MediaStore (Android).
5. **Android Cleartext & Permissions Hygiene**:
   - `android:usesCleartextTraffic="false"` in `AndroidManifest.xml`.
   - Camera permission is used exclusively for live QR scanning (no images saved).
   - Android 10+ uses Scoped Storage (`MediaStore.Downloads`) and SAF (`OpenMultipleDocuments` / `PickMultipleVisualMedia`) — no broad `MANAGE_EXTERNAL_STORAGE` permission is requested.
