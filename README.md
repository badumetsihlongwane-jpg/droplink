# DropLink

**Fast, private, end-to-end encrypted local file transfer between macOS and Android.**

Open DropLink on your Mac, open DropLink on your Android phone, scan the QR code, and transfer photos, videos, and large files directly over your local Wi-Fi network — with zero cloud servers, zero accounts, and zero third-party relays.

## Highlights

- **100% Local Direct TCP (`DLSP/1`)**: Transfers stream directly between your Mac and Android phone over your shared Wi-Fi network at full LAN speeds.
- **Strong End-to-End Security**: Ephemeral **ECDH P-256** key exchange combined with a 256-bit temporary **QR pairing secret (PSK)** via **HKDF-SHA256** and **AES-256-GCM** per-frame authenticated encryption. Being on the same Wi-Fi never grants access without scanning the QR code.
- **Streaming & Large-File Safe**: Reads and writes in 256 KiB chunks directly to disk (constant low memory usage even for multi-gigabyte videos).
- **Resumable & Atomic**: Writes to `.droplink-*.part` staging files, verifies full-file **SHA-256** integrity before atomically committing, automatically deduplicates conflicting filenames (`photo (1).jpg`), and resumes interrupted transfers from the exact byte offset after reconnection.
- **Zero-Dependency Local macOS Build**: Built natively with Swift, SwiftUI, AppKit, CryptoKit, and CoreImage — compiles directly on Intel macOS 12+ using **only** macOS Command Line Tools (no full Xcode, no Rust, no Homebrew, no Android SDK on your Mac).
- **Cloud-Free Android Compilation via GitHub Actions**: Native Kotlin + Jetpack Compose (Material 3) + CameraX + ML Kit QR scanner + Foreground Service + MediaStore/SAF storage — compiled automatically in GitHub Actions to produce a downloadable APK.

## Repository Layout

```text
DropLink/
├── protocol/
│   ├── SPEC.md                 # Formal DLSP/1 wire protocol specification
│   ├── generate_vectors.mjs    # Deterministic canonical crypto vector generator
│   ├── test_vectors.json       # Shared crypto vectors verified by Swift, Kotlin & Node.js
│   └── interop_test.mjs        # Cross-platform TCP interoperability test suite
├── macos/
│   ├── Package.swift           # SwiftPM manifest (macOS 12+)
│   ├── Sources/DropLinkCore/   # Protocol, CryptoKit, TCP transport, PeerSession, DropLinkServer
│   ├── Sources/DropLinkApp/    # Native SwiftUI/AppKit macOS desktop app
│   ├── Sources/DropLinkTests/  # Standalone automated test suite + interop server harness
│   └── scripts/
│       ├── build_and_package.sh # Builds .app bundle + .dmg installer locally
│       └── generate_icon.py     # Zero-dependency AppIcon.icns generator
├── android/
│   ├── app/src/main/java/com/droplink/android/
│   │   ├── protocol/           # DLSP/1 crypto, framing, streaming client
│   │   ├── storage/            # Android SAF + MediaStore Downloads/DropLink integration
│   │   ├── service/            # Data-sync ForegroundService for background transfers
│   │   ├── state/              # Connection lifecycle, Wi-Fi monitoring, auto-reconnect
│   │   └── ui/                 # Jetpack Compose Material 3 screens + CameraX QR scanner
│   └── app/src/test/           # JUnit crypto vector & loopback protocol tests
├── .github/workflows/
│   ├── android-build.yml       # Tests & builds downloadable Android APK on GitHub Actions
│   └── protocol-ci.yml         # Verifies deterministic canonical protocol vectors
└── docs/
    ├── ARCHITECTURE.md
    ├── SECURITY.md
    ├── BUILD_MACOS.md
    ├── BUILD_ANDROID_GITHUB_ACTIONS.md
    ├── INSTALL.md
    └── TESTING.md
```

## Quick Start

1. **Install on macOS**: Mount `dist/DropLink-1.0.0-macOS-x86_64.dmg` (or build locally with `./macos/scripts/build_and_package.sh`) and drag **DropLink** into `Applications`.
2. **Install on Android**: Download `DropLink-Android-APK` from the latest **Build Android APK** run in GitHub Actions and install `DropLink-1.0.0-android.apk` on your phone.
3. **Transfer**:
   - Launch **DropLink** on your Mac — a local encrypted session starts automatically and displays a large QR code.
   - Launch **DropLink** on Android, tap **Scan Mac**, and point the camera at the QR code.
   - Drag and drop files onto the Mac window or pick photos/files on Android to transfer bidirectionally.

## Documentation

- [Architecture & Protocol Overview](docs/ARCHITECTURE.md)
- [DLSP/1 Wire Specification](protocol/SPEC.md)
- [Security & Privacy Model](docs/SECURITY.md)
- [Building macOS Locally (Zero Extra Dependencies)](docs/BUILD_MACOS.md)
- [Building Android APK via GitHub Actions](docs/BUILD_ANDROID_GITHUB_ACTIONS.md)
- [Installation Guide](docs/INSTALL.md)
- [Testing & Verification Report](docs/TESTING.md)
