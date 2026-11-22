import Foundation

/// One hypervisor per disk image.
///
/// Two `VZVirtualMachine`s writing the same raw image is two kernels each
/// believing it owns one ext4 filesystem: whatever one caches the other
/// overwrites, and the damage only shows up later as checksum errors on
/// files nobody touched. The pid file cannot rule that out — it is written
/// after the VM is configured and cleared before the process has finished
/// dying — and neither can the daemon alone, because Virtualization.framework
/// opens the disk in its own XPC service
/// (`com.apple.Virtualization.VirtualMachine`), which outlives the daemon by
/// however long launchd takes to reap it.
///
/// So there are two checks, and a start needs both to pass:
///
/// * an exclusive `flock` on `disk.lock`, taken by the daemon before it
///   touches anything and held for its whole life. Two starts racing each
///   other cannot both win it, and the loser exits without having written a
///   pid file, truncated a log or unlinked the winner's console socket;
/// * nobody else having `disk.img` open (`lsof`). That catches the XPC
///   service of a run that has already let go of its lock, a daemon from a
///   vmctl build older than the lock, and an image attached in Finder with
///   `hdiutil`.
public final class DiskLock {
    private let fd: Int32
    public let path: String

    private init(fd: Int32, path: String) {
        self.fd = fd
        self.path = path
    }

    deinit { release() }

    private var released = false

    /// Takes the lock without waiting, or returns nil when someone holds it.
    /// The fd is close-on-exec so nothing this process spawns inherits it.
    public static func tryAcquire(_ path: String) throws -> DiskLock? {
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw VmctlError(
                "Could not open the disk lock \(path): \(String(cString: strerror(errno)))")
        }
        if flock(fd, LOCK_EX | LOCK_NB) != 0 {
            let error = errno
            close(fd)
            if error == EWOULDBLOCK { return nil }
            throw VmctlError(
                "Could not lock \(path): \(String(cString: strerror(error)))")
        }
        return DiskLock(fd: fd, path: path)
    }

    /// Whether someone — this process included, through another open of the
    /// file — holds the lock right now. A probe, so it never blocks.
    public static func isHeld(_ path: String) -> Bool {
        guard FileManager.default.fileExists(atPath: path) else { return false }
        guard let lock = try? tryAcquire(path) else { return true }
        lock.release()
        return false
    }

    public func release() {
        guard !released else { return }
        released = true
        flock(fd, LOCK_UN)
        close(fd)
    }
}

public enum DiskHolders {
    /// Processes that have [path] open, by pid. Empty when there are none or
    /// when `lsof` cannot answer — it is a second line of defence behind the
    /// lock, and a missing `lsof` must not make every VM unbootable.
    public static func pids(_ path: String) -> [Int32] {
        guard FileManager.default.fileExists(atPath: path) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        // -t: pids only; -w: no warnings about filesystems it cannot stat.
        process.arguments = ["-t", "-w", "--", path]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return []
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return parsePids(String(decoding: data, as: UTF8.self))
    }

    static func parsePids(_ text: String) -> [Int32] {
        text.split(whereSeparator: \.isNewline)
            .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }
}

extension VMStore {
    public func diskLockPath(_ name: String) -> URL {
        vmDir(name).appendingPathComponent("disk.lock")
    }

    /// Whether anything still has [name]'s disk: a live daemon, a held lock
    /// or an open file handle. Every operation that reads or rewrites the
    /// image as a file (resize, export, delete) must see false first.
    public func diskInUse(_ name: String) -> Bool {
        isRunning(name)
            || DiskLock.isHeld(diskLockPath(name).path)
            || !DiskHolders.pids(diskPath(name).path).isEmpty
    }

    /// Waits up to [timeout] for [name]'s disk to be released, polling.
    /// Returns whether it was.
    public func waitForDiskRelease(
        _ name: String, timeout: TimeInterval, poll: TimeInterval = 0.5
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !DiskLock.isHeld(diskLockPath(name).path),
               DiskHolders.pids(diskPath(name).path).isEmpty {
                return true
            }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
    }

    /// [waitForDiskRelease] for the daemon that holds the lock itself: only
    /// the open-file check, since its own lock would never read as free.
    public func waitForDiskReleaseByOthers(
        _ name: String, timeout: TimeInterval, poll: TimeInterval = 0.25
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if DiskHolders.pids(diskPath(name).path).isEmpty { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: poll)
        }
    }
}
