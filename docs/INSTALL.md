# Installation & First-Time Setup

## Installing DropLink on macOS

1. Open `dist/DropLink-1.0.0-macOS-x86_64.dmg`.
2. Drag **DropLink.app** into the **Applications** folder shortcut inside the DMG window.
3. Eject the disk image and open **DropLink** from Applications.

> **Gatekeeper Note (Ad-Hoc Signed Open-Source Build)**
> Because DropLink is built locally without a paid Apple Developer ID certificate, macOS Gatekeeper may show *"DropLink cannot be opened because the developer cannot be verified"* on first launch.
> To open it safely:
> - **Right-click (Control-click)** `DropLink.app` in Applications → click **Open** → click **Open** in the confirmation dialog.
> - You only need to do this once.

> **macOS Local Network / Firewall Prompt**
> If macOS asks whether to allow DropLink to accept incoming network connections, click **Allow** so your Android phone can connect over Wi-Fi.

## Installing DropLink on Android

1. Download the `DropLink-Android-APK` artifact from the **Actions → Build Android APK** tab on GitHub and extract `DropLink-1.0.0-android.apk`.
2. Tap `DropLink-1.0.0-android.apk` on your Android phone (Android 8.0 / API 26 or newer).
3. If prompted by Android, enable **Install unknown apps** for your browser or Files app, then tap **Install**.
4. Open **DropLink**:
   - Grant **Notifications** permission (Android 13+) so background transfer progress stays visible.
   - Grant **Camera** permission when tapping **Scan Mac** so DropLink can scan the pairing QR code.

## Pairing & Transferring Files

1. Make sure your Mac and Android phone are connected to the **same Wi-Fi network** (guest Wi-Fi networks with AP/client isolation enabled block peer-to-peer LAN connections).
2. Open **DropLink** on your Mac — a session starts automatically with a large QR code.
3. Open **DropLink** on Android and tap **Scan Mac**.
4. Point the camera at the Mac's QR code. Connection completes in under a second with an encrypted lock indicator.
5. **Android → Mac**: Tap **Photos & Videos** or **Files & Docs** to select one or multiple files. You can also use Android's system **Share** menu to send directly to DropLink. Files save to `~/Downloads/DropLink` on your Mac.
6. **Mac → Android**: Drag and drop one or multiple files anywhere onto the DropLink window (or click **Send Files…**). Files save to `Downloads/DropLink` on your Android phone.
