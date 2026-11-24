import SwiftUI
import AppKit
import UniformTypeIdentifiers
import DropLinkCore

struct TransfersView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.horizontal, 24)
                .padding(.top, 22)
                .padding(.bottom, 14)

            Divider()

            if appState.filteredTransfers.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(appState.filteredTransfers) { item in
                            TransferRowView(
                                item: item,
                                onCancel: { appState.cancelTransfer(item) },
                                onReveal: { appState.revealInFinder(item) }
                            )
                        }
                    }
                    .padding(20)
                }
            }
        }
    }

    private var headerBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Transfer Activity")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    if appState.activeTransferCount > 0 {
                        Text("\(appState.activeTransferCount) in progress • \(FileUtils.formatSpeed(appState.aggregateSpeedBytesPerSec))")
                            .font(.subheadline)
                            .foregroundColor(.accentColor)
                    } else {
                        Text("Incoming files save to \(appState.destinationURL.lastPathComponent)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                HStack(spacing: 8) {
                    Button(action: { appState.pickAndSendFiles() }) {
                        Label("Send Files…", systemImage: "paperplane.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(appState.devices.isEmpty)

                    Button(action: { appState.openDestinationFolder() }) {
                        Label("Open Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
            }

            HStack {
                Picker("Filter", selection: $appState.transferFilter) {
                    ForEach(TransferFilter.allCases) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 260)

                Spacer()

                if appState.transfers.contains(where: { $0.status == .completed || $0.status == .failed || $0.status == .cancelled }) {
                    Button("Clear Finished") {
                        appState.clearCompletedTransfers()
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.medium))
                    .foregroundColor(.secondary)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Spacer()
            Image(systemName: "arrow.up.arrow.down.circle")
                .font(.system(size: 46, weight: .light))
                .foregroundColor(.secondary.opacity(0.6))
            Text("No Transfers Yet")
                .font(.title3.weight(.semibold))
            Text(appState.devices.isEmpty
                 ? "Pair your Android phone on the Pair & Connect screen to start transferring files."
                 : "Drag & drop files onto this window or click Send Files to transfer to \(appState.devices.first?.name ?? "your phone").")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TransferRowView: View {
    let item: TransferItem
    let onCancel: () -> Void
    let onReveal: () -> Void

    private var directionColor: Color {
        item.direction == .incoming ? .blue : .indigo
    }

    private var statusBadge: (text: String, color: Color, icon: String) {
        switch item.status {
        case .pending: return ("Waiting…", .secondary, "clock")
        case .transferring:
            let speed = FileUtils.formatSpeed(item.bytesPerSecond)
            if let eta = item.etaSeconds {
                return ("\(speed) • \(formatETA(eta))", directionColor, item.direction == .incoming ? "arrow.down" : "arrow.up")
            }
            return (speed, directionColor, item.direction == .incoming ? "arrow.down" : "arrow.up")
        case .verifying: return ("Verifying SHA-256…", .orange, "checkmark.shield")
        case .completed: return ("SHA-256 Verified", .green, "checkmark.shield.fill")
        case .cancelled: return ("Cancelled", .secondary, "xmark.circle")
        case .failed: return (item.errorMessage ?? "Failed", .red, "exclamationmark.triangle.fill")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                fileIcon
                    .frame(width: 38, height: 38)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(item.savedFilename ?? item.filename)
                            .font(.system(.body, design: .rounded).weight(.semibold))
                            .lineLimit(1)
                            .truncationMode(.middle)

                        Image(systemName: item.direction == .incoming ? "arrow.down.left" : "arrow.up.right")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(directionColor)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(directionColor.opacity(0.12))
                            .clipShape(Capsule())

                        if item.resumedFromBytes > 0 {
                            Text("Resumed")
                                .font(.caption2.weight(.medium))
                                .foregroundColor(.orange)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.orange.opacity(0.14))
                                .clipShape(Capsule())
                        }
                    }

                    HStack(spacing: 8) {
                        Text("\(FileUtils.formatBytes(item.transferredBytes)) / \(FileUtils.formatBytes(item.totalBytes))")
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)

                        Text("•")
                            .foregroundColor(.secondary)

                        Text(item.peerDeviceName)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    let badge = statusBadge
                    HStack(spacing: 4) {
                        Image(systemName: badge.icon)
                            .font(.caption)
                        Text(badge.text)
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundColor(badge.color)

                    if item.status == .pending || item.status == .transferring {
                        Button(action: onCancel) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Cancel transfer")
                    } else if item.status == .completed && item.direction == .incoming {
                        Button(action: onReveal) {
                            Label("Reveal", systemImage: "magnifyingglass")
                                .labelStyle(.iconOnly)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Reveal in Finder")
                    }
                }
            }

            if item.status == .transferring || item.status == .verifying || item.status == .pending {
                ProgressView(value: item.progress)
                    .progressViewStyle(.linear)
                    .tint(directionColor)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.07), lineWidth: 1)
        )
    }

    private var fileIcon: some View {
        let ext = ((item.savedFilename ?? item.filename) as NSString).pathExtension
        let contentType = ext.isEmpty ? UTType.data : (UTType(filenameExtension: ext) ?? .data)
        let nsIcon = NSWorkspace.shared.icon(for: contentType)
        return Image(nsImage: nsIcon)
            .resizable()
            .scaledToFit()
    }

    private func formatETA(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(max(1, s))s left" }
        let m = s / 60
        let rem = s % 60
        return "\(m)m \(rem)s left"
    }
}
