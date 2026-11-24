import Foundation
import SwiftUI
import AppKit
import DropLinkCore

public enum SidebarTab: String, CaseIterable, Identifiable {
    case connect = "Pair & Connect"
    case transfers = "Transfers"
    case settings = "Settings"

    public var id: String { rawValue }
    public var icon: String {
        switch self {
        case .connect: return "qrcode"
        case .transfers: return "arrow.up.arrow.down.circle"
        case .settings: return "gearshape"
        }
    }
}

public enum TransferFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case incoming = "Incoming"
    case outgoing = "Outgoing"
    public var id: String { rawValue }
}

public enum AppearanceMode: String, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
    public var id: String { rawValue }
}

@MainActor
public final class AppState: ObservableObject {
    @Published public var selectedTab: SidebarTab = .connect
    @Published public var transferFilter: TransferFilter = .all
    @Published public var isDraggingFiles: Bool = false

    @Published public var isRunning: Bool = false
    @Published public var pairingURI: String = ""
    @Published public var activeHosts: [String] = []
    @Published public var port: UInt16 = 0
    @Published public var expiresAt: Int64 = 0
    @Published public var remainingQRSeconds: Int = 0
    @Published public var isNetworkReachable: Bool = true
    @Published public var sessionError: String?
    @Published public var toastMessage: String?

    @Published public var devices: [ConnectedDevice] = []
    @Published public var transfers: [TransferItem] = []
    @Published public var activityLog: [String] = []

    // Persisted settings
    @Published public var deviceName: String {
        didSet {
            UserDefaults.standard.set(deviceName, forKey: "dl_deviceName")
            server.config.deviceName = deviceName
            syncSessionState()
        }
    }
    @Published public var destinationPath: String {
        didSet {
            UserDefaults.standard.set(destinationPath, forKey: "dl_destinationPath")
            server.config.destinationDirectory = URL(fileURLWithPath: destinationPath)
        }
    }
    @Published public var qrExpirationMinutes: Int {
        didSet {
            UserDefaults.standard.set(qrExpirationMinutes, forKey: "dl_qrExpirationMinutes")
            server.config.qrExpirationSeconds = Int64(qrExpirationMinutes * 60)
        }
    }
    @Published public var preferredPort: Int {
        didSet {
            UserDefaults.standard.set(preferredPort, forKey: "dl_preferredPort")
            server.config.preferredPort = UInt16(clamping: max(0, min(65535, preferredPort)))
        }
    }
    @Published public var maxConcurrentTransfers: Int {
        didSet {
            UserDefaults.standard.set(maxConcurrentTransfers, forKey: "dl_maxConcurrent")
            server.config.maxConcurrentTransfers = maxConcurrentTransfers
        }
    }
    @Published public var appearanceMode: AppearanceMode {
        didSet {
            UserDefaults.standard.set(appearanceMode.rawValue, forKey: "dl_appearance")
            applyAppearance()
        }
    }

    private let server: DropLinkServer
    private var serverBridge: ServerDelegateBridge?
    private var countdownTimer: Timer?
    private var toastTask: DispatchWorkItem?

    public var destinationURL: URL {
        URL(fileURLWithPath: destinationPath)
    }

    public var activeTransferCount: Int {
        transfers.filter { $0.status == .pending || $0.status == .transferring || $0.status == .verifying }.count
    }

    public var aggregateSpeedBytesPerSec: Double {
        transfers
            .filter { $0.status == .transferring }
            .reduce(0.0) { $0 + $1.bytesPerSecond }
    }

    public var filteredTransfers: [TransferItem] {
        switch transferFilter {
        case .all: return transfers
        case .incoming: return transfers.filter { $0.direction == .incoming }
        case .outgoing: return transfers.filter { $0.direction == .outgoing }
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        let defaultName = Host.current().localizedName ?? "MacBook Air"
        let defaultDest = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads/DropLink").path

        let savedName = defaults.string(forKey: "dl_deviceName") ?? defaultName
        let savedDest = defaults.string(forKey: "dl_destinationPath") ?? defaultDest
        let savedExp = defaults.object(forKey: "dl_qrExpirationMinutes") as? Int ?? 10
        let savedPort = defaults.object(forKey: "dl_preferredPort") as? Int ?? 0
        let savedMax = defaults.object(forKey: "dl_maxConcurrent") as? Int ?? 3
        let savedApp = AppearanceMode(rawValue: defaults.string(forKey: "dl_appearance") ?? "") ?? .system

        self.deviceName = savedName
        self.destinationPath = savedDest
        self.qrExpirationMinutes = savedExp
        self.preferredPort = savedPort
        self.maxConcurrentTransfers = savedMax
        self.appearanceMode = savedApp

        let config = DropLinkServerConfig(
            deviceName: savedName,
            destinationDirectory: URL(fileURLWithPath: savedDest),
            preferredPort: UInt16(clamping: max(0, min(65535, savedPort))),
            qrExpirationSeconds: Int64(savedExp * 60),
            maxConcurrentTransfers: savedMax
        )
        self.server = DropLinkServer(config: config)
        let bridge = ServerDelegateBridge(appState: self)
        self.serverBridge = bridge
        self.server.delegate = bridge

        applyAppearance()
        startSession()
        startCountdownTimer()
    }

    public func applyAppearance() {
        switch appearanceMode {
        case .system: NSApp?.appearance = nil
        case .light: NSApp?.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp?.appearance = NSAppearance(named: .darkAqua)
        }
    }

    public func startSession() {
        sessionError = nil
        do {
            try server.start()
            syncSessionState()
        } catch {
            sessionError = error.localizedDescription
            isRunning = false
        }
    }

    public func stopSession() {
        server.stop()
        syncSessionState()
    }

    public func restartSession() {
        stopSession()
        startSession()
        showToast("Started a fresh secure session")
    }

    public func refreshQRCode() {
        server.refreshQRCode()
        syncSessionState()
        showToast("Generated fresh pairing QR code")
    }

    public func disconnectDevice(_ device: ConnectedDevice) {
        server.disconnectDevice(deviceId: device.id)
        showToast("Disconnected \(device.name)")
    }

    public func disconnectAllDevices() {
        server.disconnectAll()
        showToast("Disconnected all devices")
    }

    public func cancelTransfer(_ item: TransferItem) {
        server.cancelTransfer(id: item.id)
    }

    public func clearCompletedTransfers() {
        transfers.removeAll { $0.status == .completed || $0.status == .cancelled || $0.status == .failed }
    }

    public func openDestinationFolder() {
        try? FileManager.default.createDirectory(at: destinationURL, withIntermediateDirectories: true)
        NSWorkspace.shared.open(destinationURL)
    }

    public func revealInFinder(_ item: TransferItem) {
        if let url = item.localFileURL, FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            openDestinationFolder()
        }
    }

    public func chooseDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Save Folder"
        panel.directoryURL = destinationURL
        if panel.runModal() == .OK, let url = panel.url {
            destinationPath = url.path
            showToast("Save folder updated to \(url.lastPathComponent)")
        }
    }

    public func pickAndSendFiles(to device: ConnectedDevice? = nil) {
        guard !devices.isEmpty else {
            showToast("Pair an Android device first to send files")
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Send via DropLink"
        if panel.runModal() == .OK, !panel.urls.isEmpty {
            sendFiles(urls: panel.urls, to: device?.id)
        }
    }

    public func handleDroppedURLs(_ urls: [URL]) {
        let regularFiles = urls.filter { url in
            var isDir: ObjCBool = false
            return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && !isDir.boolValue
        }
        guard !regularFiles.isEmpty else {
            showToast("Drop individual files (folders are not supported yet)")
            return
        }
        guard !devices.isEmpty else {
            showToast("Scan the QR code with Android first to send files")
            return
        }
        sendFiles(urls: regularFiles, to: nil)
    }

    public func sendFiles(urls: [URL], to deviceId: String?) {
        let sent = server.sendFiles(urls: urls, to: deviceId)
        if !sent.isEmpty {
            selectedTab = .transfers
            let label = sent.count == 1 ? sent[0].filename : "\(sent.count) files"
            showToast("Sending \(label)…")
        }
    }

    public func showToast(_ message: String) {
        toastTask?.cancel()
        withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
            toastMessage = message
        }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) {
                self?.toastMessage = nil
            }
        }
        toastTask = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2, execute: work)
    }

    private func startCountdownTimer() {
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self = self, self.isRunning else { return }
                let now = Int64(Date().timeIntervalSince1970)
                self.remainingQRSeconds = max(0, Int(self.expiresAt - now))
            }
        }
    }

    fileprivate func syncSessionState() {
        isRunning = server.isRunning
        activeHosts = server.activeHosts
        port = server.port
        expiresAt = server.expiresAt
        isNetworkReachable = server.isNetworkReachable
        pairingURI = server.currentPairingPayload?.toURI() ?? ""
        let now = Int64(Date().timeIntervalSince1970)
        remainingQRSeconds = isRunning ? max(0, Int(expiresAt - now)) : 0
    }

    fileprivate func updateDevices(_ newDevices: [ConnectedDevice]) {
        withAnimation(.easeInOut(duration: 0.2)) {
            devices = newDevices
        }
    }

    fileprivate func upsertTransfer(_ item: TransferItem) {
        if let idx = transfers.firstIndex(where: { $0.id == item.id }) {
            transfers[idx] = item
        } else {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) {
                transfers.insert(item, at: 0)
            }
        }
    }

    fileprivate func appendLog(_ event: String) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        activityLog.insert("[\(formatter.string(from: Date()))] \(event)", at: 0)
        if activityLog.count > 50 { activityLog.removeLast() }
    }
}

private final class ServerDelegateBridge: DropLinkServerDelegate {
    weak var appState: AppState?
    init(appState: AppState) { self.appState = appState }

    func serverDidUpdateSessionState(_ server: DropLinkServer) {
        Task { @MainActor [weak self] in
            self?.appState?.syncSessionState()
        }
    }

    func server(_ server: DropLinkServer, didUpdateDevices devices: [ConnectedDevice]) {
        Task { @MainActor [weak self] in
            self?.appState?.updateDevices(devices)
        }
    }

    func server(_ server: DropLinkServer, didUpdateTransfer item: TransferItem) {
        Task { @MainActor [weak self] in
            self?.appState?.upsertTransfer(item)
        }
    }

    func server(_ server: DropLinkServer, didLog event: String) {
        Task { @MainActor [weak self] in
            self?.appState?.appendLog(event)
        }
    }
}
