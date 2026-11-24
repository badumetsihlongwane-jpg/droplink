import Foundation
import Network
import Darwin

public struct NetworkInterfaceInfo: Equatable, Hashable {
    public let name: String
    public let address: String
    public let isWiFiPrimary: Bool

    public init(name: String, address: String, isWiFiPrimary: Bool) {
        self.name = name
        self.address = address
        self.isWiFiPrimary = isWiFiPrimary
    }
}

public final class LocalNetworkMonitor {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.droplink.networkmonitor")
    private var lastAddresses: [String] = []
    public var onNetworkChange: (([String], Bool) -> Void)?

    public init() {}

    public func start() {
        lastAddresses = Self.activeIPv4Addresses()
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self = self else { return }
            let connected = path.status == .satisfied
            let current = Self.activeIPv4Addresses()
            if current != self.lastAddresses || !connected {
                self.lastAddresses = current
                self.onNetworkChange?(current, connected)
            }
        }
        monitor.start(queue: queue)
    }

    public func stop() {
        monitor.cancel()
    }

    /// Returns active local IPv4 addresses, prioritizing Wi-Fi (`en0`) then Ethernet/hotspot (`en*`, `bridge*`).
    public static func activeIPv4Addresses() -> [String] {
        var interfaces: [NetworkInterfaceInfo] = []
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return []
        }
        defer { freeifaddrs(ifaddrPtr) }

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let ifa = cursor?.pointee {
            defer { cursor = ifa.ifa_next }
            let flags = Int32(ifa.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback, let addr = ifa.ifa_addr else { continue }
            guard addr.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: ifa.ifa_name)
            // Skip Apple AWDL / utun / llw / virtual non-LAN interfaces unless no en* exists
            if name.hasPrefix("utun") || name.hasPrefix("awdl") || name.hasPrefix("llw") || name.hasPrefix("lo") {
                continue
            }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let ip = String(cString: hostname)
                // Ignore link-local 169.254.x.x
                if ip.hasPrefix("169.254.") || ip.hasPrefix("127.") { continue }
                interfaces.append(NetworkInterfaceInfo(name: name, address: ip, isWiFiPrimary: name == "en0"))
            }
        }

        // Prioritize en0 (Wi-Fi on MacBook Air), then en*, then everything else
        let sorted = interfaces.sorted { a, b in
            if a.isWiFiPrimary != b.isWiFiPrimary { return a.isWiFiPrimary }
            let aEn = a.name.hasPrefix("en")
            let bEn = b.name.hasPrefix("en")
            if aEn != bEn { return aEn }
            return a.name < b.name
        }

        var seen = Set<String>()
        var result: [String] = []
        for item in sorted {
            if seen.insert(item.address).inserted {
                result.append(item.address)
            }
        }
        return result
    }
}
