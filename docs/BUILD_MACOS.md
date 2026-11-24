# Building DropLink for macOS Locally

DropLink for macOS is designed to build cleanly on **Intel macOS 12+ (Monterey and newer)** — including older MacBook Airs — with **zero external dependencies**.

## System Requirements

- **macOS 12.0+** (tested on macOS 12.7.6 Monterey, Intel x86_64)
- **macOS Command Line Tools** (`/Library/Developer/CommandLineTools`), which provides:
  - `swiftc` (Swift 5.7+)
  - `codesign`, `iconutil`, `sips`, `hdiutil`
- Built-in `python3` (only used to render the app icon PNGs from stdlib `zlib`/`struct` — no `pip` packages required)

**Not required:**
- No full Xcode installation
- No Homebrew
- No Rust / Cargo
- No Node.js / npm (Node.js is only used if running the optional cross-platform `protocol/interop_test.mjs`)
- No Android Studio / Android SDK / Android NDK

If Command Line Tools are not installed yet:

```bash
xcode-select --install
```

## One-Command Build, Test, and DMG Package

From the repository root:

```bash
./macos/scripts/build_and_package.sh
```

This script performs five steps automatically:

1. Compiles `DropLinkCore` as an optimized static Swift module targeting `${ARCH}-apple-macos12.0`.
2. Compiles and runs `DropLinkTests` (all 7 automated crypto, security, streaming, resume, and storage-limit tests).
3. Compiles the native SwiftUI/AppKit `DropLink` desktop executable.
4. Generates `AppIcon.icns`, writes `Info.plist`, assembles `dist/DropLink.app`, and applies an ad-hoc signature (`codesign --force --deep --sign -`).
5. Packages `dist/DropLink-1.0.0-macOS-<arch>.dmg` with an `Applications` symlink for drag-and-drop installation.

## Build Outputs

- Application bundle: `dist/DropLink.app`
- Distributable disk image: `dist/DropLink-1.0.0-macOS-x86_64.dmg` (or `arm64` on Apple Silicon)

## Running Tests Manually

```bash
# 1. Run Swift unit & integration tests (built by build_and_package.sh)
./macos/.build/release-manual/DropLinkTests

# 2. Optional: run cross-platform Node.js <-> Swift TCP interoperability suite
node protocol/interop_test.mjs
```
