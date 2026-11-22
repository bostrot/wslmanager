import Foundation

/// `sockaddr_un.sun_path` holds ~104 bytes on macOS, and a VM store under
/// "~/Library/Application Support/…" can exceed that. Bind/connect through
/// the socket's parent directory with a relative name when the absolute
/// path does not fit. The chdir is momentary and happens before any relay
/// thread exists (bind) or in a single-purpose CLI process (connect).
enum UnixSocketAddress {
    static func withSockaddr<T>(
        _ path: String, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T
    ) throws -> T {
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < capacity else {
            throw VmctlError("Socket path still too long: \(path)")
        }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, size) }
        }
    }

    /// Runs [operation] with a path that fits in sun_path, chdir-ing into
    /// the parent directory when the absolute path is too long.
    static func withUsablePath<T>(
        _ path: String, _ operation: (String) throws -> T
    ) throws -> T {
        let capacity = MemoryLayout.size(ofValue: sockaddr_un().sun_path)
        if path.utf8.count < capacity {
            return try operation(path)
        }
        let dir = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let previous = FileManager.default.currentDirectoryPath
        guard FileManager.default.changeCurrentDirectoryPath(dir) else {
            throw VmctlError("Socket path too long and its directory is unreachable: \(path)")
        }
        defer { _ = FileManager.default.changeCurrentDirectoryPath(previous) }
        return try operation(name)
    }

    static func bind(_ fd: Int32, to path: String) throws {
        let result = try withUsablePath(path) { usable in
            try withSockaddr(usable) { Darwin.bind(fd, $0, $1) }
        }
        guard result == 0 else {
            throw VmctlError("Could not bind \(path): \(String(cString: strerror(errno)))")
        }
    }

    static func connect(_ fd: Int32, to path: String) throws {
        let result = try withUsablePath(path) { usable in
            try withSockaddr(usable) { Darwin.connect(fd, $0, $1) }
        }
        guard result == 0 else {
            throw VmctlError(
                "Could not connect to \(path): \(String(cString: strerror(errno)))")
        }
    }
}

/// Exposes a running VM's serial port on a Unix socket, so a terminal can
/// attach to the console without the VM ever needing a display window.
///
/// The VM's serial device reads and writes one end of a socketpair; this
/// relay pumps the other end. Guest output is teed to `serial.log` (the
/// early-exit diagnostics read its tail) and forwarded to the connected
/// client; client bytes go to the guest. One client at a time — a new
/// connection replaces the previous one, `virsh console` style.
public final class ConsoleRelay {
    /// FD handed to Virtualization.framework for both directions.
    public let vmSideFd: Int32
    private let relayFd: Int32
    private let listenFd: Int32
    private let log: SerialLog
    public let socketPath: String

    private let clientLock = NSLock()
    private var clientFd: Int32 = -1
    private var running = true

    public init(socketPath: String, logPath: String) throws {
        self.socketPath = socketPath

        var fds: [Int32] = [0, 0]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
            throw VmctlError("socketpair failed: \(String(cString: strerror(errno)))")
        }
        vmSideFd = fds[0]
        relayFd = fds[1]

        log = try SerialLog(path: logPath)

        // A socket file from a previous (crashed) daemon would block bind.
        unlink(socketPath)
        listenFd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard listenFd >= 0 else {
            throw VmctlError("socket failed: \(String(cString: strerror(errno)))")
        }
        try UnixSocketAddress.bind(listenFd, to: socketPath)
        guard listen(listenFd, 2) == 0 else {
            throw VmctlError("Could not listen on \(socketPath): \(String(cString: strerror(errno)))")
        }
    }

    public func start() {
        // Guest → log + client.
        Thread.detachNewThread { [self] in
            var buffer = [UInt8](repeating: 0, count: 4096)
            while running {
                let count = read(relayFd, &buffer, buffer.count)
                if count <= 0 { break }
                let data = Data(buffer[0..<count])
                log.write(data)
                clientLock.lock()
                let fd = clientFd
                clientLock.unlock()
                if fd >= 0 {
                    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, count) }
                }
            }
        }

        // Clients: accept immediately, hand each connection its own reader
        // thread, and retire the previous client via shutdown() — its reader
        // sees EOF and closes the fd itself, so every fd has exactly one
        // owner and a stuck client can never block the accept loop.
        Thread.detachNewThread { [self] in
            while running {
                let fd = accept(listenFd, nil, nil)
                if fd < 0 { break }
                clientLock.lock()
                let previous = clientFd
                clientFd = fd
                clientLock.unlock()
                if previous >= 0 {
                    Darwin.shutdown(previous, SHUT_RDWR)
                }
                Thread.detachNewThread { [self] in
                    var buffer = [UInt8](repeating: 0, count: 4096)
                    while running {
                        let count = read(fd, &buffer, buffer.count)
                        if count <= 0 { break }
                        _ = write(relayFd, &buffer, count)
                    }
                    clientLock.lock()
                    if clientFd == fd {
                        clientFd = -1
                    }
                    clientLock.unlock()
                    close(fd)
                }
            }
        }
    }

    public func shutdown() {
        running = false
        clientLock.lock()
        let fd = clientFd
        clientLock.unlock()
        if fd >= 0 {
            // The reader owns the close; this only unblocks it.
            Darwin.shutdown(fd, SHUT_RDWR)
        }
        close(listenFd)
        close(relayFd)
        unlink(socketPath)
        log.flush()
    }
}

/// The guest's serial output on disk: `serial.log` for this boot,
/// `serial.log.1` for whatever came before.
///
/// This log is the only record of a boot nobody watched — an fsck that
/// found damage, a root filesystem that would not mount, systemd's
/// emergency shell — so a start must never wipe the previous one (it used to
/// truncate it, which turned "my VM won't come back after a restart" into a
/// guest with no history at all). Two files, each capped at [maxBytes], so a
/// guest that floods its console cannot fill the host disk.
public final class SerialLog {
    public static let defaultMaxBytes: UInt64 = 8 * 1024 * 1024

    public let path: String
    public let maxBytes: UInt64
    private var handle: FileHandle
    private var written: UInt64 = 0

    public static func rotatedPath(_ path: String) -> String { path + ".1" }

    public init(path: String, maxBytes: UInt64 = SerialLog.defaultMaxBytes) throws {
        self.path = path
        self.maxBytes = maxBytes
        handle = try SerialLog.openFresh(path)
    }

    /// Moves the previous boot's log aside (when it has anything in it) and
    /// opens an empty one. Also the installer path's entry point, where
    /// Virtualization.framework writes the handle directly.
    public static func openFresh(_ path: String) throws -> FileHandle {
        let fm = FileManager.default
        let size = (try? fm.attributesOfItem(atPath: path)[.size] as? NSNumber)?
            .uint64Value ?? 0
        if size > 0 {
            let previous = rotatedPath(path)
            try? fm.removeItem(atPath: previous)
            try? fm.moveItem(atPath: path, toPath: previous)
        }
        fm.createFile(atPath: path, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw VmctlError("Could not open \(path) for the serial log")
        }
        return handle
    }

    /// Appends [data], rotating first when it would take the file past the
    /// cap. Called from the relay's single guest-reader thread only.
    public func write(_ data: Data) {
        if written > 0, written + UInt64(data.count) > maxBytes {
            try? handle.close()
            if let fresh = try? SerialLog.openFresh(path) {
                handle = fresh
                written = 0
            }
        }
        try? handle.write(contentsOf: data)
        written += UInt64(data.count)
    }

    /// Pushes what was written to disk. Not a close: the reader thread may
    /// still be mid-write when the daemon shuts down, and the process exit
    /// right after closes the file anyway.
    public func flush() {
        try? handle.synchronize()
    }
}
