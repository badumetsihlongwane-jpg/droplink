import SwiftUI
import DropLinkCore

struct SettingsView: View {
    @ObservedObject var appState: AppState
    @State private var portInput: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Settings")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                    Text("Configure your local DropLink session, storage destination, and security preferences.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }

                settingsCard(title: "General", icon: "macbook") {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Device Name")
                                .frame(width: 160, alignment: .leading)
                            TextField("MacBook Air", text: $appState.deviceName)
                                .textFieldStyle(.roundedBorder)
                        }

                        Divider()

                        HStack {
                            Text("Appearance")
                                .frame(width: 160, alignment: .leading)
                            Picker("Appearance", selection: $appState.appearanceMode) {
                                ForEach(AppearanceMode.allCases) { mode in
                                    Text(mode.rawValue).tag(mode)
                                }
                            }
                            .pickerStyle(.segmented)
                            .labelsHidden()
                        }

                        Divider()

                        HStack(alignment: .center) {
                            Text("Save Destination")
                                .frame(width: 160, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(appState.destinationPath)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 8) {
                                    Button("Choose Folder…") { appState.chooseDestinationFolder() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                    Button("Open in Finder") { appState.openDestinationFolder() }
                                        .buttonStyle(.bordered)
                                        .controlSize(.small)
                                }
                            }
                            Spacer()
                        }
                    }
                }

                settingsCard(title: "Security & Pairing", icon: "lock.shield") {
                    VStack(spacing: 14) {
                        HStack {
                            Text("QR Expiry Window")
                                .frame(width: 160, alignment: .leading)
                            Picker("QR Expiry", selection: $appState.qrExpirationMinutes) {
                                Text("5 minutes").tag(5)
                                Text("10 minutes").tag(10)
                                Text("15 minutes").tag(15)
                                Text("30 minutes").tag(30)
                            }
                            .labelsHidden()
                            .frame(width: 160)
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Transport Encryption")
                                .frame(width: 160, alignment: .leading)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("DLSP/1 — ECDH P-256 + 256-bit QR PSK + AES-256-GCM")
                                    .font(.caption.weight(.semibold))
                                    .foregroundColor(.green)
                                Text("100% local LAN direct TCP. No cloud, no relays, SHA-256 integrity verified.")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                        }

                        Divider()

                        HStack(spacing: 10) {
                            Button("Regenerate Pairing QR") { appState.refreshQRCode() }
                                .buttonStyle(.bordered)
                                .disabled(!appState.isRunning)

                            Button("Disconnect All Devices") { appState.disconnectAllDevices() }
                                .buttonStyle(.bordered)
                                .disabled(appState.devices.isEmpty)

                            Spacer()
                        }
                    }
                }

                settingsCard(title: "Network & Performance", icon: "wifi") {
                    VStack(spacing: 14) {
                        HStack {
                            Text("Active Local IPs")
                                .frame(width: 160, alignment: .leading)
                            Text(appState.activeHosts.isEmpty ? "None detected" : appState.activeHosts.joined(separator: ", "))
                                .font(.system(.caption, design: .monospaced))
                                .foregroundColor(.secondary)
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Listening Port")
                                .frame(width: 160, alignment: .leading)
                            TextField("0 = Automatic", text: $portInput)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 130)
                                .onAppear {
                                    portInput = appState.preferredPort == 0 ? "" : String(appState.preferredPort)
                                }
                            Button("Apply & Restart") {
                                let val = Int(portInput.trimmingCharacters(in: .whitespaces)) ?? 0
                                appState.preferredPort = max(0, min(65535, val))
                                appState.restartSession()
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            Spacer()
                        }

                        Divider()

                        HStack {
                            Text("Concurrent Transfers")
                                .frame(width: 160, alignment: .leading)
                            Stepper("\(appState.maxConcurrentTransfers) simultaneous files", value: $appState.maxConcurrentTransfers, in: 1...6)
                            Spacer()
                        }
                    }
                }
            }
            .padding(24)
        }
    }

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(title, systemImage: icon)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }
}
