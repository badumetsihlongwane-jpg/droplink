# Building DropLink for Android via GitHub Actions

DropLink's Android application is compiled **entirely in GitHub Actions** on free GitHub-hosted `ubuntu-latest` runners. You do **not** need Android Studio, the Android SDK, the Android NDK, Java, or Gradle installed on your Mac.

## How the Workflow Works

The workflow is defined in [`.github/workflows/android-build.yml`](../.github/workflows/android-build.yml) and runs:

1. **JDK 17** (`actions/setup-java@v4`, Eclipse Temurin)
2. **Gradle 8.7** (`gradle/actions/setup-gradle@v4`) with automatic dependency & build caching
3. **Android SDK licenses** acceptance on the pre-installed runner SDK
4. **Automated unit & protocol tests**: `gradle testDebugUnitTest` (verifies Kotlin `DLSP/1` cryptography against shared `protocol/test_vectors.json`, filename sanitization, deduplication, auth rejection, and loopback encrypted file transfers)
5. **APK builds**: `gradle assembleRelease assembleDebug`
6. **Artifact upload**: uploads `DropLink-Android-APK` containing:
   - `DropLink-1.0.0-android.apk` (recommended installable release APK)
   - `DropLink-1.0.0-android-debug.apk` (debuggable APK)
   - `SHA256SUMS.txt`

## Triggering a Build Manually

1. Open your DropLink repository on GitHub.
2. Click the **Actions** tab.
3. Select **Build Android APK** in the left sidebar.
4. Click **Run workflow** → choose branch `main` → click **Run workflow**.

Builds also run automatically whenever changes are pushed to `main` under `android/**`, `protocol/**`, or `.github/workflows/android-build.yml`.

## Downloading the APK

1. Open the completed **Build Android APK** workflow run in GitHub Actions.
2. Scroll down to the **Artifacts** section.
3. Click **DropLink-Android-APK** to download the zip archive.
4. Unzip and transfer `DropLink-1.0.0-android.apk` to your Android phone (or download directly from GitHub on your phone's browser!).

## Release Signing Note

For frictionless open-source sideloading without requiring paid accounts or manual keystore secrets, the default release build signs with the Android debug key so the downloaded APK installs directly on any Android 8.0+ phone. If you later publish to Google Play, configure a release `signingConfigs` block referencing encrypted GitHub Actions secrets (`KEYSTORE_BASE64`, `KEYSTORE_PASSWORD`, `KEY_ALIAS`, `KEY_PASSWORD`).
