import Foundation

public enum TransferDirection: String, Codable {
    case incoming
    case outgoing
}

public enum TransferStatus: String, Codable, Equatable {
    case pending
    case transferring
    case verifying
    case completed
    case cancelled
    case failed
}

public struct TransferItem: Identifiable, Equatable {
    public let id: String // UUID string
    public let direction: TransferDirection
    public let peerDeviceId: String
    public let peerDeviceName: String
    public let filename: String
    public var savedFilename: String?
    public var localFileURL: URL?
    public let totalBytes: UInt64
    public var transferredBytes: UInt64
    public var bytesPerSecond: Double
    public var status: TransferStatus
    public var errorMessage: String?
    public var sha256: String?
    public var verified: Bool
    public var resumedFromBytes: UInt64
    public let startedAt: Date
    public var completedAt: Date?

    public var progress: Double {
        guard totalBytes > 0 else { return status == .completed ? 1.0 : 0.0 }
        return min(1.0, Double(transferredBytes) / Double(totalBytes))
    }

    public var etaSeconds: Double? {
        guard status == .transferring, bytesPerSecond > 1, totalBytes > transferredBytes else { return nil }
        return Double(totalBytes - transferredBytes) / bytesPerSecond
    }

    public init(
        id: String,
        direction: TransferDirection,
        peerDeviceId: String,
        peerDeviceName: String,
        filename: String,
        savedFilename: String? = nil,
        localFileURL: URL? = nil,
        totalBytes: UInt64,
        transferredBytes: UInt64 = 0,
        bytesPerSecond: Double = 0,
        status: TransferStatus = .pending,
        errorMessage: String? = nil,
        sha256: String? = nil,
        verified: Bool = false,
        resumedFromBytes: UInt64 = 0,
        startedAt: Date = Date(),
        completedAt: Date? = nil
    ) {
        self.id = id
        self.direction = direction
        self.peerDeviceId = peerDeviceId
        self.peerDeviceName = peerDeviceName
        self.filename = filename
        self.savedFilename = savedFilename
        self.localFileURL = localFileURL
        self.totalBytes = totalBytes
        self.transferredBytes = transferredBytes
        self.bytesPerSecond = bytesPerSecond
        self.status = status
        self.errorMessage = errorMessage
        self.sha256 = sha256
        self.verified = verified
        self.resumedFromBytes = resumedFromBytes
        self.startedAt = startedAt
        self.completedAt = completedAt
    }
}

public struct ConnectedDevice: Identifiable, Equatable {
    public let id: String // deviceId
    public let name: String
    public let address: String
    public let connectedAt: Date
    public var lastSeenAt: Date
    public var latencyMs: Int?

    public init(
        id: String,
        name: String,
        address: String,
        connectedAt: Date = Date(),
        lastSeenAt: Date = Date(),
        latencyMs: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.address = address
        self.connectedAt = connectedAt
        self.lastSeenAt = lastSeenAt
        self.latencyMs = latencyMs
    }
}

public struct DropLinkServerConfig {
    public var deviceName: String
    public var destinationDirectory: URL
    public var preferredPort: UInt16 // 0 = ephemeral OS port
    public var qrExpirationSeconds: Int64
    public var maxConcurrentTransfers: Int
    public var chunkSize: Int
    public var autoAcceptIncoming: Bool
    public var minFreeDiskBufferBytes: UInt64
    public var simulatedFreeDiskBytes: UInt64? // For automated storage-limit tests

    public init(
        deviceName: String = Host.current().localizedName ?? "Mac",
        destinationDirectory: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads/DropLink"),
        preferredPort: UInt16 = 0,
        qrExpirationSeconds: Int64 = 600,
        maxConcurrentTransfers: Int = 3,
        chunkSize: Int = DLSPConstants.defaultChunkSize,
        autoAcceptIncoming: Bool = true,
        minFreeDiskBufferBytes: UInt64 = 50 * 1024 * 1024,
        simulatedFreeDiskBytes: UInt64? = nil
    ) {
        self.deviceName = deviceName
        self.destinationDirectory = destinationDirectory
        self.preferredPort = preferredPort
        self.qrExpirationSeconds = qrExpirationSeconds
        self.maxConcurrentTransfers = maxConcurrentTransfers
        self.chunkSize = chunkSize
        self.autoAcceptIncoming = autoAcceptIncoming
        self.minFreeDiskBufferBytes = minFreeDiskBufferBytes
        self.simulatedFreeDiskBytes = simulatedFreeDiskBytes
    }
}
