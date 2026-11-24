import Foundation
import Darwin

public enum TCPError: Error, LocalizedError {
    case socketCreationFailed(Int32)
    case bindFailed(Int32)
    case listenFailed(Int32)
    case connectFailed(String, Int32)
    case closed
    case readFailed(Int32)
    case writeFailed(Int32)
    case frameTooLarge(Int)
    case timeout

    public var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let e): return "Socket creation failed (errno \(e))"
        case .bindFailed(let e): return "Socket bind failed (errno \(e))"
        case .listenFailed(let e): return "Socket listen failed (errno \(e))"
        case .connectFailed(let h, let e): return "Connect to \(h) failed (errno \(e))"
        case .closed: return "Connection closed"
        case .readFailed(let e): return "Socket read failed (errno \(e))"
        case .writeFailed(let e): return "Socket write failed (errno \(e))"
        case .frameTooLarge(let n): return "Frame too large (\(n) bytes)"
        case .timeout: return "Socket operation timed out"
        }
    }
}

public final class TCPSocket {
    private var fd: Int32
    private let stateLock = NSLock()
    private var isClosed = false
    public let remoteAddress: String

    public init(fd: Int32, remoteAddress: String) {
        self.fd = fd
        self.remoteAddress = remoteAddress
        Self.configureSocket(fd: fd)
    }

    deinit {
        close()
    }

    private static func configureSocket(fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        var bufSize: Int32 = 512 * 1024
        setsockopt(fd, SOL_SOCKET, SO_SNDBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &bufSize, socklen_t(MemoryLayout<Int32>.size))
    }

    public static func connect(host: String, port: UInt16, timeoutSeconds: Int = 8) throws -> TCPSocket {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var resPtr: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &resPtr)
        guard status == 0, let res = resPtr else {
            throw TCPError.connectFailed(host, errno)
        }
        defer { freeaddrinfo(resPtr) }

        let sock = Darwin.socket(res.pointee.ai_family, res.pointee.ai_socktype, res.pointee.ai_protocol)
        guard sock >= 0 else {
            throw TCPError.socketCreationFailed(errno)
        }
        configureSocket(fd: sock)

        // Set non-blocking for connect timeout
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)

        let connRes = Darwin.connect(sock, res.pointee.ai_addr, res.pointee.ai_addrlen)
        if connRes != 0 {
            if errno != EINPROGRESS {
                let err = errno
                Darwin.close(sock)
                throw TCPError.connectFailed(host, err)
            }
            var pfd = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
            let pollRes = Darwin.poll(&pfd, 1, Int32(timeoutSeconds * 1000))
            if pollRes <= 0 {
                Darwin.close(sock)
                throw pollRes == 0 ? TCPError.timeout : TCPError.connectFailed(host, errno)
            }
            var soError: Int32 = 0
            var soLen = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(sock, SOL_SOCKET, SO_ERROR, &soError, &soLen)
            if soError != 0 {
                Darwin.close(sock)
                throw TCPError.connectFailed(host, soError)
            }
        }

        // Restore blocking mode
        _ = fcntl(sock, F_SETFL, flags)
        return TCPSocket(fd: sock, remoteAddress: host)
    }

    public func setReadTimeout(seconds: Int) {
        stateLock.lock()
        let currentFd = fd
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { return }
        var tv = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(currentFd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    public func writeAll(_ data: Data) throws {
        stateLock.lock()
        let currentFd = fd
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw TCPError.closed }

        try data.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var totalSent = 0
            while totalSent < data.count {
                let sent = Darwin.send(currentFd, base.advanced(by: totalSent), data.count - totalSent, 0)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw TCPError.writeFailed(errno)
                }
                if sent == 0 {
                    throw TCPError.closed
                }
                totalSent += sent
            }
        }
    }

    public func readExact(_ count: Int) throws -> Data {
        if count == 0 { return Data() }
        stateLock.lock()
        let currentFd = fd
        let closed = isClosed
        stateLock.unlock()
        guard !closed else { throw TCPError.closed }

        var buffer = Data(count: count)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            while totalRead < count {
                let n = Darwin.recv(currentFd, base.advanced(by: totalRead), count - totalRead, 0)
                if n < 0 {
                    if errno == EINTR { continue }
                    if errno == EAGAIN || errno == EWOULDBLOCK { throw TCPError.timeout }
                    throw TCPError.readFailed(errno)
                }
                if n == 0 {
                    throw TCPError.closed
                }
                totalRead += n
            }
        }
        return buffer
    }

    public func readLengthPrefixedFrame(maxBytes: Int) throws -> Data {
        let lenData = try readExact(4)
        let length = lenData.withUnsafeBytes { ptr -> UInt32 in
            var val: UInt32 = 0
            memcpy(&val, ptr.baseAddress!, 4)
            return UInt32(bigEndian: val)
        }
        let intLen = Int(length)
        guard intLen <= maxBytes else {
            throw TCPError.frameTooLarge(intLen)
        }
        return try readExact(intLen)
    }

    public func writeLengthPrefixedFrame(_ payload: Data) throws {
        var packet = Data(capacity: 4 + payload.count)
        var lenBE = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: &lenBE) { packet.append(contentsOf: $0) }
        packet.append(payload)
        try writeAll(packet)
    }

    public func close() {
        stateLock.lock()
        if !isClosed {
            isClosed = true
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        stateLock.unlock()
    }
}

public final class TCPListener {
    private var fd: Int32 = -1
    private let stateLock = NSLock()
    private var running = false
    public private(set) var port: UInt16 = 0
    private let acceptQueue = DispatchQueue(label: "com.droplink.tcp.accept", qos: .userInitiated)

    public init() {}

    deinit {
        stop()
    }

    public func start(port preferredPort: UInt16 = 0, onAccept: @escaping (TCPSocket) -> Void) throws {
        let sock = Darwin.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard sock >= 0 else { throw TCPError.socketCreationFailed(errno) }

        var one: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(sock, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = preferredPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY)

        let bindRes = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if bindRes != 0 {
            let err = errno
            Darwin.close(sock)
            throw TCPError.bindFailed(err)
        }

        if Darwin.listen(sock, 32) != 0 {
            let err = errno
            Darwin.close(sock)
            throw TCPError.listenFailed(err)
        }

        var boundAddr = sockaddr_in()
        var boundLen = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &boundAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = Darwin.getsockname(sock, sockPtr, &boundLen)
            }
        }

        stateLock.lock()
        self.fd = sock
        self.port = UInt16(bigEndian: boundAddr.sin_port)
        self.running = true
        stateLock.unlock()

        acceptQueue.async { [weak self] in
            while let self = self {
                self.stateLock.lock()
                let active = self.running
                let listenFd = self.fd
                self.stateLock.unlock()
                if !active || listenFd < 0 { break }

                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let clientFd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        Darwin.accept(listenFd, sockPtr, &clientLen)
                    }
                }
                if clientFd < 0 {
                    if errno == EINTR { continue }
                    break
                }

                var hostBuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                var addrCopy = clientAddr.sin_addr
                inet_ntop(AF_INET, &addrCopy, &hostBuf, socklen_t(INET_ADDRSTRLEN))
                let remoteIP = String(cString: hostBuf)
                onAccept(TCPSocket(fd: clientFd, remoteAddress: remoteIP))
            }
        }
    }

    public func stop() {
        stateLock.lock()
        running = false
        if fd >= 0 {
            Darwin.shutdown(fd, SHUT_RDWR)
            Darwin.close(fd)
            fd = -1
        }
        stateLock.unlock()
    }
}
