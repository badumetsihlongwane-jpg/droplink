import SwiftUI
import AppKit
import UniformTypeIdentifiers

final class DropLinkAppDelegate: NSObject, NSApplicationDelegate {
    var onTerminate: (() -> Void)?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        onTerminate?()
    }
}

struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

struct MainContentView: View {
    @ObservedObject var appState: AppState

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                sidebar
                    .frame(width: 215)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(NSColor.windowBackgroundColor))
            }

            if appState.isDraggingFiles {
                dropOverlay
                    .transition(.opacity)
            }

            if let toast = appState.toastMessage {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.accentColor)
                        Text(toast)
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.ultraThinMaterial)
                    .clipShape(Capsule())
                    .shadow(color: Color.black.opacity(0.18), radius: 10, x: 0, y: 4)
                    .padding(.bottom, 22)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onDrop(of: [UTType.fileURL], isTargeted: $appState.isDraggingFiles) { providers in
            handleDrop(providers: providers)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(LinearGradient(colors: [Color.blue, Color.indigo], startPoint: .topLeading, endPoint: .bottomTrailing))
                        .frame(width: 32, height: 32)
                    Image(systemName: "arrow.left.arrow.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("DropLink")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                    Text("Local Encrypted")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 18)

            VStack(spacing: 4) {
                ForEach(SidebarTab.allCases) { tab in
                    sidebarItem(tab)
                }
            }
            .padding(.horizontal, 10)

            Spacer()

            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 8) {
                    Circle()
                        .fill(appState.isRunning ? (appState.devices.isEmpty ? Color.blue : Color.green) : Color.gray)
                        .frame(width: 8, height: 8)
                    Text(appState.isRunning
                         ? (appState.devices.isEmpty ? "Ready to pair" : "\(appState.devices.count) connected")
                         : "Session stopped")
                        .font(.caption.weight(.medium))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
            }
        }
        .background(VisualEffectBackground(material: .sidebar, blendingMode: .behindWindow))
    }

    private func sidebarItem(_ tab: SidebarTab) -> some View {
        let selected = appState.selectedTab == tab
        return Button(action: { appState.selectedTab = tab }) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 14, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .accentColor : .secondary)
                    .frame(width: 20)
                Text(tab.rawValue)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(selected ? .primary : .secondary)
                Spacer()
                if tab == .transfers && appState.activeTransferCount > 0 {
                    Text("\(appState.activeTransferCount)")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Color.accentColor)
                        .clipShape(Capsule())
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detailPane: some View {
        switch appState.selectedTab {
        case .connect:
            ConnectView(appState: appState)
        case .transfers:
            TransfersView(appState: appState)
        case .settings:
            SettingsView(appState: appState)
        }
    }

    private var dropOverlay: some View {
        ZStack {
            Color.accentColor.opacity(0.14)
                .background(.ultraThinMaterial)
            VStack(spacing: 14) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 56))
                    .foregroundColor(.accentColor)
                Text(appState.devices.isEmpty ? "Pair Android First" : "Drop to Send to \(appState.devices.first?.name ?? "Android")")
                    .font(.title2.weight(.bold))
                Text("Encrypted direct transfer over your local Wi-Fi")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            .padding(36)
            .background(Color(NSColor.windowBackgroundColor).opacity(0.92))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8, 6]))
                    .foregroundColor(.accentColor)
            )
            .shadow(radius: 20)
        }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        let group = DispatchGroup()
        var urls: [URL] = []
        let lock = NSLock()

        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                    defer { group.leave() }
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        lock.lock(); urls.append(url); lock.unlock()
                    } else if let url = item as? URL {
                        lock.lock(); urls.append(url); lock.unlock()
                    }
                }
            }
        }

        group.notify(queue: .main) {
            if !urls.isEmpty {
                appState.handleDroppedURLs(urls)
            }
        }
        return true
    }
}

@main
struct DropLinkDesktopApp: App {
    @NSApplicationDelegateAdaptor(DropLinkAppDelegate.self) var appDelegate
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("DropLink") {
            MainContentView(appState: appState)
                .frame(minWidth: 780, minHeight: 540)
                .onAppear {
                    appDelegate.onTerminate = {
                        appState.stopSession()
                    }
                }
        }
        .windowStyle(.titleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Send Files…") {
                    appState.pickAndSendFiles()
                }
                .keyboardShortcut("o", modifiers: [.command])
                .disabled(appState.devices.isEmpty)

                Button("Open Downloads Folder") {
                    appState.openDestinationFolder()
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])

                Divider()

                Button("Refresh Pairing QR") {
                    appState.refreshQRCode()
                }
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(!appState.isRunning)

                Button(appState.isRunning ? "Stop Session" : "Start Session") {
                    if appState.isRunning { appState.stopSession() } else { appState.startSession() }
                }
                .keyboardShortcut(".", modifiers: [.command, .shift])
            }
        }
    }
}
