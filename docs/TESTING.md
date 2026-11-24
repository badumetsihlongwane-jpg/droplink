# Testing & Verification Documentation

DropLink is verified across **three independent automated test layers** covering cryptographic equivalence, security rejections, large-file streaming, interruption/resume recovery, and storage safeguards.

## Automated vs. Real-Device Testing Scope

> **Important Distinction**
> No physical Android handset was connected to the build machine during development. All Android functionality and macOS↔Android protocol behavior were validated through:
> 1. **Native macOS Swift automated test suite** (`macos/Sources/DropLinkTests/main.swift`) running real TCP loopback connections against compiled `DropLinkCore`.
> 2. **Cross-platform Node.js ↔ Compiled Swift TCP interoperability suite** (`protocol/interop_test.mjs`), an independent second implementation of `DLSP/1` exchanging real encrypted multi-megabyte files with the compiled macOS Swift server.
> 3. **Android Kotlin JUnit & TCP loopback test suite** (`android/app/src/test/java/com/droplink/android/protocol/DLSPProtocolTest.kt`), executed automatically in GitHub Actions against the exact same shared cryptographic vectors (`protocol/test_vectors.json`) before building the APK.
>
> Hardware-specific Android interactions (physical camera autofocus on QR codes, real OEM Wi-Fi chipset behavior, Android MediaStore UI gallery indexing on a physical handset) should be smoke-tested on your physical Android device after installing the GitHub Actions APK.

## Test Coverage Matrix

| Scenario | Verified In | Method & Assertion |
| :--- | :--- | :--- |
| **Canonical Crypto Vectors** (ECDH P-256, HMAC-SHA256, HKDF-SHA256, AES-256-GCM C2S/S2C, QR URI) | Swift, Kotlin (CI), Node.js | Exact byte-for-byte match against `protocol/test_vectors.json` + tampered ciphertext/tag rejection |
| **Android → Mac transfer** | Swift loopback + Node↔Swift interop + Kotlin loopback | 10 MB & 20 MB streaming uploads verified by full-file SHA-256 on disk |
| **Mac → Android transfer** | Swift loopback + Node↔Swift interop | 2 MB & 3 MB server-initiated streaming downloads verified by full-file SHA-256 |
| **Multiple concurrent files** | Swift loopback | 5 simultaneous files multiplexed over one encrypted TCP channel, all SHA-256 verified |
| **Interrupted transfer + Reconnection + Resume** | Swift loopback + Node↔Swift interop | Mid-stream TCP socket drop, QR expiry forced, reconnect via `reconnectToken`/`reconnectKey`, exact byte-offset resume from `.part` file, verified final SHA-256, `.part` cleanup |
| **Invalid pairing (wrong PSK / wrong session ID)** | Swift loopback + Node↔Swift interop + Kotlin loopback | Rejected immediately with `AUTH_FAILED` / `INVALID_SESSION` |
| **Expired pairing session** | Swift loopback + Node↔Swift interop | Rejected with `EXPIRED_SESSION`; already-paired device still reconnects cleanly via `reconnectToken` |
| **Invalid reconnect token** | Swift loopback | Rejected with `INVALID_RECONNECT` |
| **Corrupted transfer / SHA-256 mismatch** | Node↔Swift interop | Rejected with `verified: false`; `.part` deleted, no corrupted file left in destination |
| **Duplicate filenames** | Swift + Kotlin | Non-overwriting sequential naming (`file.jpg` → `file (1).jpg` → `file (2).jpg`) |
| **Spaces, Unicode, Emoji, Path Traversal, Overlong names** | Swift + Kotlin + Node↔Swift | `../../etc/passwd` → `passwd`; `Report 2026 — Résumé 🚀 日本語.pdf` & `4K Clip — 東京 🎬.mov` preserved byte-for-byte; 300-byte names safely truncated preserving extension |
| **Storage limitations** | Swift loopback | Simulated insufficient free disk space rejected cleanly with `INSUFFICIENT_STORAGE` without writing corrupt partial files |
| **Network changes** | Code verified (`NWPathMonitor` on macOS, `ConnectivityManager.NetworkCallback` on Android) | Dynamic IPv4 re-enumeration on Mac updates QR payload; Android Wi-Fi callback triggers backoff reconnect |
| **macOS App Bundle & DMG Packaging** | Local macOS build | Compiled cleanly for `x86_64-apple-macos12.0`, `codesign --verify --deep --strict`, `hdiutil` UDZO DMG created & SHA-256 checksummed |
| **Android APK Compilation** | GitHub Actions (`ubuntu-latest`) | `gradle testDebugUnitTest` + `gradle assembleRelease assembleDebug` + downloadable APK artifact verified |

## How to Re-Run All Automated Tests

```bash
# 1. Verify canonical vectors generator
node protocol/generate_vectors.mjs

# 2. Build & run macOS Swift tests + package .app and .dmg
./macos/scripts/build_and_package.sh

# 3. Run cross-platform Node.js <-> compiled Swift server interop tests
node protocol/interop_test.mjs
```
