import SwiftUI
import DropLinkCore

struct ConnectView: View {
    @ObservedObject var appState: AppState

    private var formattedExpiry: String {
        let mins = appState.remainingQRSeconds / 60
        let secs = appState.remainingQRSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    private var isQRExpired: Bool {
        appState.isRunning && appState.remainingQRSeconds == 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection

                if let err = appState.sessionError {
                    errorBanner(err)
                }

                if appState.isRunning && !appState.isNetworkReachable {
                    networkWarningBanner
                }

                HStack(alignment: .top, spacing: 20) {
                    qrCard
                        .frame(minWidth: 280, maxWidth: 320)

                    VStack(spacing: 16) {
                        connectedDevicesCard
                        if appState.activeTransferCount > 0 {
                            activeTransfersSummaryCard
                        }
                        quickSendDropCard
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(24)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Pair & Connect")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                Text("Scan the QR code from DropLink on Android to establish a direct encrypted Wi-Fi link.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 10) {
                Button(action: { appState.openDestinationFolder() }) {
                    Label("Open Folder", systemImage: "folder")
                }
                .buttonStyle(.bordered)

                if appState.isRunning {
                    Button(action: { appState.stopSession() }) {
                        Label("Stop Session", systemImage: "stop.circle")
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button(action: { appState.startSession() }) {
                        Label("Start Session", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var qrCard: some View {
        VStack(spacing: 16) {
            HStack {
                statusPill
                Spacer()
                if appState.isRunning {
                    HStack(spacing: 4) {
                        Image(systemName: isQRExpired ? "exclamationmark.triangle.fill" : "timer")
                            .font(.caption2)
                        Text(isQRExpired ? "Expired" : formattedExpiry)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                    }
                    .foregroundColor(isQRExpired ? .orange : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.primary.opacity(0.06))
                    .clipShape(Capsule())
                }
            }

            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(Color.white)
                    .shadow(color: Color.black.opacity(0.08), radius: 12, x: 0, y: 4)
                    .frame(width: 244, height: 244)

                QRCodeView(content: appState.isRunning ? appState.pairingURI : "", size: 212)
                    .opacity(isQRExpired ? 0.2 : 1.0)

                if isQRExpired {
                    VStack(spacing: 10) {
                        Image(systemName: "clock.badge.exclamationmark")
                            .font(.system(size: 28))
                            .foregroundColor(.orange)
                        Text("QR Code Expired")
                            .font(.headline)
                            .foregroundColor(.black)
                        Button("Refresh QR") {
                            appState.refreshQRCode()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
            }

            VStack(spacing: 6) {
                Text(appState.deviceName)
                    .font(.headline)

                if appState.isRunning {
                    let hostText = appState.activeHosts.first ?? "No Wi-Fi IP"
                    HStack(spacing: 6) {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                            .font(.caption)
                        Text("\(hostText):\(appState.port)")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("Session stopped")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Divider()

            HStack(spacing: 10) {
                Button(action: { appState.refreshQRCode() }) {
                    Label("New QR", systemImage: "arrow.clockwise")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!appState.isRunning)

                Button(action: { appState.restartSession() }) {
                    Label("Reset Session", systemImage: "arrow.triangle.2.circlepath")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var statusPill: some View {
        let color: Color = {
            if !appState.isRunning { return .gray }
            if !appState.devices.isEmpty { return .green }
            if !appState.isNetworkReachable { return .orange }
            return .blue
        }()
        let text: String = {
            if !appState.isRunning { return "Paused" }
            if !appState.devices.isEmpty { return "Connected" }
            if !appState.isNetworkReachable { return "No Wi-Fi" }
            return "Listening"
        }()

        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(text)
                .font(.caption.weight(.semibold))
                .foregroundColor(color)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(color.opacity(0.12))
        .clipShape(Capsule())
    }

    private var connectedDevicesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Connected Devices", systemImage: "iphone.gen3.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                if !appState.devices.isEmpty {
                    Text("\(appState.devices.count) paired")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            if appState.devices.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    stepRow(number: "1", title: "Open DropLink on Android", subtitle: "Ensure your phone and Mac are on the same Wi-Fi network.")
                    stepRow(number: "2", title: "Tap Scan Mac", subtitle: "Point your phone's camera at the QR code on the left.")
                    stepRow(number: "3", title: "Transfer Instantly", subtitle: "Send photos, videos, and files directly — zero cloud, end-to-end encrypted.")
                }
                .padding(.vertical, 4)
            } else {
                VStack(spacing: 10) {
                    ForEach(appState.devices) { device in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.accentColor.opacity(0.14))
                                    .frame(width: 40, height: 40)
                                Image(systemName: "smartphone")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundColor(.accentColor)
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 6) {
                                    Text(device.name)
                                        .font(.system(.body, design: .rounded).weight(.semibold))
                                    Image(systemName: "checkmark.seal.fill")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                                HStack(spacing: 8) {
                                    Text(device.address)
                                        .font(.system(.caption, design: .monospaced))
                                        .foregroundColor(.secondary)
                                    if let ms = device.latencyMs {
                                        Text("• \(ms) ms")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    Text("• AES-256-GCM")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                }
                            }

                            Spacer()

                            Button(action: { appState.pickAndSendFiles(to: device) }) {
                                Label("Send Files…", systemImage: "paperplane.fill")
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Button(action: { appState.disconnectDevice(device) }) {
                                Image(systemName: "xmark.circle")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Disconnect device")
                        }
                        .padding(12)
                        .background(Color.primary.opacity(0.035))
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private func stepRow(number: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(.accentColor)
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    private var activeTransfersSummaryCard: some View {
        Button(action: { appState.selectedTab = .transfers }) {
            HStack(spacing: 12) {
                ProgressView()
                    .scaleEffect(0.75)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(appState.activeTransferCount) active transfer\(appState.activeTransferCount == 1 ? "" : "s")")
                        .font(.subheadline.weight(.semibold))
                        .foregroundColor(.primary)
                    Text(FileUtils.formatSpeed(appState.aggregateSpeedBytesPerSec))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("View Activity")
                    .font(.caption.weight(.semibold))
                    .foregroundColor(.accentColor)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.accentColor)
            }
            .padding(14)
            .background(Color.accentColor.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.accentColor.opacity(0.25), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }

    private var quickSendDropCard: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.up.doc.on.clipboard")
                .font(.system(size: 24, weight: .medium))
                .foregroundColor(appState.devices.isEmpty ? .secondary : .accentColor)
            Text(appState.devices.isEmpty ? "Pair a device to drag & drop files" : "Drop files anywhere to send to \(appState.devices.first?.name ?? "Android")")
                .font(.subheadline.weight(.medium))
                .foregroundColor(appState.devices.isEmpty ? .secondary : .primary)
            Text("Supports multiple files, large videos, photos, and documents with SHA-256 verification.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            if !appState.devices.isEmpty {
                Button(action: { appState.pickAndSendFiles() }) {
                    Label("Choose Files to Send…", systemImage: "plus.circle.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
                .padding(.top, 2)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                .foregroundColor(appState.devices.isEmpty ? Color.primary.opacity(0.12) : Color.accentColor.opacity(0.4))
        )
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.octagon.fill")
                .foregroundColor(.red)
            Text(message)
                .font(.subheadline)
            Spacer()
            Button("Retry") { appState.startSession() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.red.opacity(0.1))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var networkWarningBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .foregroundColor(.orange)
            Text("No active Wi-Fi or local network IP detected. Connect your Mac to Wi-Fi and DropLink will update automatically.")
                .font(.caption)
            Spacer()
            Button("Refresh") { appState.refreshQRCode() }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
