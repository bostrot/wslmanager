import Foundation
import Testing
import Virtualization
@testable import VMCtlKit

/// Linux guests losing their filesystem under write load: the disk
/// attachment's caching, one hypervisor per image, the stop that waits for
/// the disk to be released, the boot log that survives a restart and the
/// lease that is only an address while something answers on it.
@Suite(.serialized) final class DiskSafetyTests {
    let tempRoot: URL
    let store: VMStore

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-disk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = VMStore(root: tempRoot, hostSshDir: tempRoot.appendingPathComponent("ssh"))
    }

    deinit {
        VmctlCLI.reachability = { GuestReachability.answers($0) }
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func makeVm(_ name: String = "dev", os: GuestOS = .linux) throws -> VMConfig {
        let config = VMConfig(
            name: name, os: os, cpus: 2, memoryBytes: 1 << 30, diskSizeBytes: 1 << 20,
            user: "dev", macAddress: "aa:bb:cc:dd:ee:01")
        try store.saveConfig(config)
        try store.createDiskImage(at: store.diskPath(name), sizeBytes: 1 << 20)
        return config
    }

    // MARK: attachment

    @Test func linuxDiskIsCachedWithFullSync() throws {
        let config = try makeVm()
        let attachment = try VMFactory.linuxDiskAttachment(store.diskPath(config.name))
        #expect(attachment.cachingMode == .cached)
        #expect(attachment.synchronizationMode == .full)
        #expect(attachment.isReadOnly == false)
    }

    // MARK: one VM per disk

    @Test func aHeldLockRefusesASecondTaker() throws {
        let config = try makeVm()
        let path = store.diskLockPath(config.name).path
        #expect(!DiskLock.isHeld(path))

        let first = try #require(try DiskLock.tryAcquire(path))
        #expect(try DiskLock.tryAcquire(path) == nil)
        #expect(DiskLock.isHeld(path))
        #expect(store.diskInUse(config.name))

        first.release()
        #expect(!DiskLock.isHeld(path))
        #expect(!store.diskInUse(config.name))
        let again = try #require(try DiskLock.tryAcquire(path))
        again.release()
    }

    @Test func aLockHeldByAnotherProcessIsSeenAndWaitedOut() throws {
        let config = try makeVm()
        let path = store.diskLockPath(config.name).path
        FileManager.default.createFile(atPath: path, contents: nil)
        // A second process holding the lock the way a daemon does.
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        holder.arguments = [
            "-e",
            "use Fcntl ':flock'; open(my $f, '<', $ARGV[0]) or die; flock($f, LOCK_EX) or die; print \"locked\\n\"; $| = 1; sleep 2;",
            path,
        ]
        let out = Pipe()
        holder.standardOutput = out
        try holder.run()
        _ = out.fileHandleForReading.availableData // "locked"

        #expect(DiskLock.isHeld(path))
        #expect(try DiskLock.tryAcquire(path) == nil)
        // The holder exits after 2 s; the wait sees the release.
        #expect(store.waitForDiskRelease(config.name, timeout: 10, poll: 0.1))
        holder.waitUntilExit()
        #expect(!DiskLock.isHeld(path))
    }

    @Test func anOpenImageCountsAsInUse() throws {
        let config = try makeVm()
        let path = store.diskPath(config.name).path
        #expect(DiskHolders.pids(path).isEmpty)
        let handle = try #require(FileHandle(forUpdatingAtPath: path))
        #expect(DiskHolders.pids(path).contains(getpid()))
        #expect(store.diskInUse(config.name))
        #expect(!store.waitForDiskRelease(config.name, timeout: 0.3, poll: 0.1))
        try handle.close()
        #expect(!store.diskInUse(config.name))
    }

    @Test func lsofOutputParsesToPids() {
        #expect(DiskHolders.parsePids("123\n456\n\n") == [123, 456])
        #expect(DiskHolders.parsePids("").isEmpty)
    }

    @Test func resizeRefusesAnImageSomeoneHasOpen() throws {
        let config = try makeVm()
        let handle = try #require(FileHandle(forUpdatingAtPath: store.diskPath(config.name).path))
        defer { try? handle.close() }
        #expect(throws: VmctlError.self) {
            try VmctlCLI.resize(store, ["--name", config.name, "--disk-size", "2"])
        }
        #expect(store.fileSize(store.diskPath(config.name)) == 1 << 20)
    }

    // MARK: stop

    @Test func aForcedStopIsReadFromThisStopsPartOfTheLog() throws {
        let config = try makeVm()
        try FileManager.default.createDirectory(
            at: store.runDir(config.name), withIntermediateDirectories: true)
        let log = store.daemonLogPath(config.name)
        try "VM dev started\n\(VMRunner.forcedStopMarker)\n"
            .write(to: log, atomically: true, encoding: .utf8)
        // A previous stop's marker is not this one's.
        let offset = store.fileSize(log)
        #expect(!VmctlCLI.daemonReportedForcedStop(store, config.name, since: offset))
        let handle = try FileHandle(forWritingTo: log)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\(VMRunner.forcedStopMarker)\n".utf8))
        try handle.close()
        #expect(VmctlCLI.daemonReportedForcedStop(store, config.name, since: offset))
    }

    @Test func theGraceWindowOutlastsSystemdsStopTimeout() {
        #expect(VMRunner.gracefulStopTimeout > 90)
    }

    // MARK: serial log

    @Test func aNewBootKeepsThePreviousBootsLog() throws {
        let path = tempRoot.appendingPathComponent("serial.log").path
        let first = try SerialLog(path: path)
        first.write(Data("EXT4-fs error: bad checksum\n".utf8))
        first.flush()

        let second = try SerialLog(path: path)
        second.write(Data("login: ".utf8))
        second.flush()

        #expect(try String(contentsOfFile: path, encoding: .utf8) == "login: ")
        #expect(try String(contentsOfFile: SerialLog.rotatedPath(path), encoding: .utf8)
            == "EXT4-fs error: bad checksum\n")
    }

    @Test func aFloodingGuestIsCappedAtTwoFiles() throws {
        let path = tempRoot.appendingPathComponent("serial.log").path
        let log = try SerialLog(path: path, maxBytes: 100)
        for _ in 0..<50 { log.write(Data(repeating: 0x41, count: 30)) }
        log.flush()
        #expect(store.fileSize(URL(fileURLWithPath: path)) <= 100)
        #expect(store.fileSize(URL(fileURLWithPath: SerialLog.rotatedPath(path))) <= 100)
    }

    @Test func anEmptyLogIsNotRotatedOverAUsefulOne() throws {
        let path = tempRoot.appendingPathComponent("serial.log").path
        let first = try SerialLog(path: path)
        first.write(Data("kernel panic\n".utf8))
        first.flush()
        _ = try SerialLog(path: path)   // boot that printed nothing
        _ = try SerialLog(path: path)   // and another
        #expect(try String(contentsOfFile: SerialLog.rotatedPath(path), encoding: .utf8)
            == "kernel panic\n")
    }

    // MARK: kernel console on hvc0

    private func runConsoleArg(cmdline: String, devices: [String], withUpdateGrub: Bool) throws
        -> (conf: String?, updateGrubRan: Bool)
    {
        let fm = FileManager.default
        let dir = tempRoot.appendingPathComponent("console-\(UUID().uuidString)")
        let devDir = dir.appendingPathComponent("dev")
        let binDir = dir.appendingPathComponent("bin")
        let grubD = dir.appendingPathComponent("grub.d")
        try fm.createDirectory(at: devDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        for device in devices {
            fm.createFile(atPath: devDir.appendingPathComponent(device).path, contents: nil)
        }
        let cmdlineURL = dir.appendingPathComponent("cmdline")
        try cmdline.write(to: cmdlineURL, atomically: true, encoding: .utf8)
        let marker = dir.appendingPathComponent("update-grub-ran")
        if withUpdateGrub {
            let fake = binDir.appendingPathComponent("update-grub")
            try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: fake, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)
        }
        let script = dir.appendingPathComponent("console.sh")
        try CloudInit.consoleKernelArgScript.write(to: script, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path]
        process.environment = [
            "PATH": "\(binDir.path):/usr/bin:/bin",
            "WSLMANAGER_DEV": devDir.path,
            "WSLMANAGER_CMDLINE": cmdlineURL.path,
            "WSLMANAGER_GRUB_D": grubD.path,
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        let conf = try? String(
            contentsOf: grubD.appendingPathComponent("99-wslmanager-console.cfg"), encoding: .utf8)
        return (conf, fm.fileExists(atPath: marker.path))
    }

    @Test func aGrubGuestGetsHvc0AsItsLastConsole() throws {
        let result = try runConsoleArg(
            cmdline: "BOOT_IMAGE=/vmlinuz root=UUID=x console=tty0 console=ttyS0,115200",
            devices: ["hvc0"], withUpdateGrub: true)
        let conf = try #require(result.conf)
        #expect(conf.contains(#"GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} console=hvc0""#))
        #expect(result.updateGrubRan)
    }

    @Test func aKernelAlreadyOnHvc0IsLeftAlone() throws {
        let result = try runConsoleArg(
            cmdline: "root=UUID=x console=hvc0", devices: ["hvc0"], withUpdateGrub: true)
        #expect(result.conf == nil)
        #expect(!result.updateGrubRan)
    }

    @Test func noHvc0OrNoGrubMeansNoChange() throws {
        let noDevice = try runConsoleArg(
            cmdline: "console=ttyS0", devices: [], withUpdateGrub: true)
        #expect(noDevice.conf == nil)
        let noGrub = try runConsoleArg(
            cmdline: "console=ttyS0", devices: ["hvc0"], withUpdateGrub: false)
        #expect(noGrub.conf == nil)
    }

    @Test func userDataCarriesTheConsoleFix() {
        let text = CloudInit.userData(
            user: "eric", publicKeys: ["ssh-ed25519 AAAA test"], hostname: "dev")
        #expect(text.contains("\n    vmctl_console_on_hvc0() {\n"))
        #expect(text.contains("\n    vmctl_console_on_hvc0\n"))
    }

    // MARK: leases

    /// bootpd's own layout: newest block first, renewed blocks rewritten in
    /// place. Taken from a real host, MACs changed.
    static let leaseFile = """
    {
    \tname=runner
    \tip_address=192.168.64.15
    \thw_address=1,5a:46:22:2:70:6c
    \tidentifier=1,5a:46:22:2:70:6c
    \tlease=0x3000
    }
    {
    \tname=runner
    \tip_address=192.168.64.9
    \thw_address=1,fe:4:9a:7d:db:4d
    \tidentifier=1,fe:4:9a:7d:db:4d
    \tlease=0x2800
    }
    {
    \tname=runner
    \tip_address=192.168.64.7
    \thw_address=1,5a:46:22:2:70:6c
    \tidentifier=1,5a:46:22:2:70:6c
    \tlease=0x2500
    }
    """

    @Test func theNewestLeaseForTheMacWinsWhateverTheOrder() {
        let now = Date(timeIntervalSince1970: 0x2000)
        #expect(DHCPLeases.ipFor(mac: "5a:46:22:02:70:6c", hostname: "runner",
                                 in: Self.leaseFile, now: now) == "192.168.64.15")
        let reversed = Self.leaseFile.components(separatedBy: "}\n")
            .reversed().joined(separator: "}\n")
        #expect(DHCPLeases.ipFor(mac: "5a:46:22:02:70:6c", hostname: "runner",
                                 in: reversed, now: now) == "192.168.64.15")
    }

    @Test func aRecreatedVmIsNotGivenItsPredecessorsAddressByName() {
        // Same name, a new MAC that has no lease yet: the plain-MAC blocks
        // under that name belong to other interfaces.
        let now = Date(timeIntervalSince1970: 0x2000)
        #expect(DHCPLeases.ipFor(mac: "12:34:56:78:9a:bc", hostname: "runner",
                                 in: Self.leaseFile, now: now) == nil)
    }

    @Test func aDeadGuestHasNoAddressWhileAMacGuestKeepsItsLease() throws {
        let linux = try makeVm("runner")
        let leases = Self.leaseFile.replacingOccurrences(of: "0x", with: "0xff00")
        var probed: [String] = []
        VmctlCLI.reachability = { probed.append($0); return false }
        var config = linux
        config.macAddress = "5a:46:22:02:70:6c"
        #expect(VmctlCLI.liveIp(config, leases: leases) == nil)
        #expect(probed == ["192.168.64.15"])

        VmctlCLI.reachability = { _ in true }
        #expect(VmctlCLI.liveIp(config, leases: leases) == "192.168.64.15")

        // A macOS guest's stealth firewall would drop the probe; its lease
        // stands on its own.
        VmctlCLI.reachability = { _ in false }
        config.os = .macos
        #expect(VmctlCLI.liveIp(config, leases: leases) == "192.168.64.15")
    }

    @Test func reachabilityCountsAcceptsAndRefusalsButNotSilence() throws {
        // Something listening on loopback answers.
        let listener = socket(AF_INET, SOCK_STREAM, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var bound = addr
        _ = withUnsafePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        listen(listener, 1)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &bound) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(listener, $0, &length)
            }
        }
        let port = UInt16(bigEndian: bound.sin_port)
        #expect(GuestReachability.answers("127.0.0.1", port: port))

        // Close it: the port now refuses, which still proves a live stack.
        close(listener)
        #expect(GuestReachability.answers("127.0.0.1", port: port))

        // TEST-NET-1 never answers.
        #expect(!GuestReachability.answers("192.0.2.1", port: 22, timeout: 0.3))
        #expect(!GuestReachability.answers("not an ip"))
    }
}
