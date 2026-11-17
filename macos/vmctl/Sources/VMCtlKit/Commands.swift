import Foundation
import Virtualization

/// Minimal argument parsing: `--key value` options, `--flag` booleans and a
/// trailing `--`-separated remainder (for exec).
public struct ArgumentBag {
    public var options: [String: String] = [:]
    public var flags: Set<String> = []
    public var remainder: [String] = []

    public init(_ args: [String], flagNames: Set<String>) {
        var i = 0
        while i < args.count {
            let arg = args[i]
            if arg == "--" {
                remainder = Array(args[(i + 1)...])
                break
            }
            if arg.hasPrefix("--") {
                let key = String(arg.dropFirst(2))
                if flagNames.contains(key) {
                    flags.insert(key)
                } else if i + 1 < args.count {
                    options[key] = args[i + 1]
                    i += 1
                }
            }
            i += 1
        }
    }

    public func require(_ key: String) throws -> String {
        guard let value = options[key], !value.isEmpty else {
            throw VmctlError("Missing required option --\(key)")
        }
        return value
    }

    public func int(_ key: String, default def: Int) -> Int {
        Int(options[key] ?? "") ?? def
    }
}

/// JSON output helpers — everything vmctl prints on success is JSON so the
/// app side never scrapes human text.
func printJson(_ object: [String: Any]) {
    if let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    }
}

public enum VmctlCLI {
    static let sshOptions = [
        "-o", "BatchMode=yes",
        // Only the store key: without this the user's ssh-agent keys are
        // offered first and a guest with default MaxAuthTries (Alpine: 6)
        // disconnects before the right key gets a turn.
        "-o", "IdentitiesOnly=yes",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "-o", "LogLevel=ERROR",
    ]

    /// The full ssh argument vector for a session into `user@ip`, with an
    /// optional remote command after `--`.
    static func sshArguments(
        key: String, user: String, ip: String, remote: [String] = []
    ) -> [String] {
        sshOptions + ["-i", key, "\(user)@\(ip)"]
            + (remote.isEmpty ? [] : ["--"] + remote)
    }

    /// The ssh argument vector for `forward`: this Mac's `127.0.0.1:localPort`
    /// carried to `127.0.0.1:remotePort` inside the guest.
    ///
    /// Both ends are loopback. A guest service keeps the bind it chose, so a
    /// dashboard with no authentication of its own (OpenCode's) is never put
    /// on vmnet, and the browser sees a loopback origin. That origin is what
    /// OpenClaw's Control UI insists on before it will pair over plain HTTP
    /// (bostrot/ai-tasks#70).
    ///
    /// The remote command reads stdin until EOF instead of `-N`: the session
    /// then lasts exactly as long as whoever holds our stdin pipe. When the app
    /// quits, even uncleanly, the pipe closes and the forward goes with it,
    /// rather than an orphaned ssh holding the Mac's port until the next
    /// reboot.
    static func forwardArguments(
        key: String, user: String, ip: String, localPort: Int, remotePort: Int
    ) -> [String] {
        sshOptions + [
            // Without the forward this session is pointless; die rather than
            // idle on with the local port taken by someone else.
            "-o", "ExitOnForwardFailure=yes",
            // A stopped guest or a lapsed lease has to end the session, so
            // the app notices the forward is gone and opens a fresh one.
            "-o", "ServerAliveInterval=5",
            "-o", "ServerAliveCountMax=3",
            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)",
            "-i", key, "\(user)@\(ip)",
            "--", "cat >/dev/null",
        ]
    }

    /// Reads a TCP port option, `def` when absent. A port outside 1-65535
    /// would reach ssh as a forward spec it rejects with a far vaguer message.
    static func tcpPort(_ bag: ArgumentBag, _ key: String, default def: Int?) throws -> Int {
        guard let raw = bag.options[key] else {
            if let def { return def }
            throw VmctlError("Missing required option --\(key)")
        }
        guard let port = Int(raw), (1...65535).contains(port) else {
            throw VmctlError("--\(key) must be a TCP port (1-65535), got \(raw)")
        }
        return port
    }

    /// Replace this process with ssh instead of spawning it as a child.
    ///
    /// Foundation's `Process` starts its child in a process group of its own,
    /// so ssh run from a Terminal window is never that terminal's foreground
    /// job: the first time an interactive session touches the tty it takes
    /// SIGTTIN and stops, leaving a window that prints nothing and answers
    /// nothing (bostrot/ai-tasks#60 — three sessions found in state `T`).
    /// `execv` keeps the pid, the process group and the foreground status
    /// Terminal already granted, and ssh's exit status becomes this process's.
    ///
    /// Only `authorize` still spawns ssh as a child, and must: it feeds the
    /// guest password to ssh's stdin and reads the report back off stdout.
    static func execSsh(_ arguments: [String]) -> Int32 {
        var argv: [UnsafeMutablePointer<CChar>?] =
            (["ssh"] + arguments).map { strdup($0) }
        argv.append(nil)
        execv("/usr/bin/ssh", &argv)
        // Reached only when execv failed and the image was never replaced.
        FileHandle.standardError.write(Data(
            "Could not run ssh: \(String(cString: strerror(errno)))\n".utf8))
        return 1
    }

    public static func defaultStoreRoot() -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return home
            .appendingPathComponent("Library/Application Support/WSLManager/vms")
    }

    /// Entry point. Returns the process exit code.
    public static func run(_ arguments: [String]) -> Int32 {
        var args = arguments
        var storeRoot = defaultStoreRoot()
        if let storeIndex = args.firstIndex(of: "--store"), storeIndex + 1 < args.count {
            storeRoot = URL(fileURLWithPath: args[storeIndex + 1])
            args.removeSubrange(storeIndex...(storeIndex + 1))
        }
        guard let command = args.first else {
            FileHandle.standardError.write(Data(usage.utf8))
            return 2
        }
        let rest = Array(args.dropFirst())
        let store = VMStore(root: storeRoot)

        do {
            switch command {
            case "list":
                try list(store)
            case "create":
                try create(store, rest)
            case "start":
                try start(store, rest)
            case "__run":
                try runDaemon(store, rest)
            case "stop":
                try stop(store, rest)
            case "delete":
                try delete(store, rest)
            case "status":
                try status(store, rest)
            case "ip":
                try ip(store, rest)
            case "reseed":
                try reseed(store, rest)
            case "export":
                try exportVm(store, rest)
            case "import":
                try importVm(store, rest)
            case "exec":
                return try exec(store, rest)
            case "forward":
                return try forward(store, rest)
            case "authorize":
                try authorize(store, rest)
            case "credentials":
                try credentials(store, rest)
            case "console":
                return try console(store, rest)
            case "show":
                try show(store, rest)
            case "shell":
                return try shell(store, rest)
            case "mounts":
                try mounts(store, rest)
            case "mount":
                try mount(store, rest)
            case "unmount":
                try unmount(store, rest)
            case "resize":
                try resize(store, rest)
            case "help", "--help", "-h":
                print(usage)
            default:
                throw VmctlError("Unknown command: \(command)\n\(usage)")
            }
            return 0
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            return 1
        }
    }

    static let usage = """
    vmctl — manage Linux/macOS VMs via Apple Virtualization.framework

    Usage: vmctl [--store DIR] COMMAND [options]
      list                                  List VMs as JSON
      create --name N --os linux [--iso PATH] [--image PATH]
             [--disk-size GB] [--cpus N] [--memory GB] [--user NAME]
             [--password PW] [--user-data PATH]
                                            --user-data: a cloud-init
                                            document applied on first boot
                                            next to the seeded account
      create --name N --os macos [--restore-image PATH.ipsw]
             [--disk-size GB] [--cpus N] [--memory GB]
      start --name N [--gui]                Start a VM (detached daemon)
      reseed --name N                       Rewrite the cloud-init seed
      stop --name N [--force] [--timeout S] Stop a VM: ACPI shutdown, power
                                            off after 120s; waits until the
                                            disk is released
      status --name N                       One VM's state as JSON
      ip --name N                           Guest IP as JSON
      delete --name N                       Delete a stopped VM
      export --name N --output PATH         Copy the raw disk image out
      import --name N --input PATH          New VM from a raw disk image
      exec --name N [--user U] -- CMD...    Run a command in the guest (SSH)
      forward --name N --port P [--local-port L] [--user U]
                                            Carry the guest's 127.0.0.1:P to
                                            this Mac's 127.0.0.1:L (default P)
                                            until stdin closes (SSH)
      authorize --name N [--user U]         Install the store's SSH key in a
                                            guest via password login; reads
                                            the password from
                                            $VMCTL_GUEST_PASSWORD
      credentials --name N                  Guest login account, console
                                            password and SSH key as JSON
      shell --name N [--user U]             Interactive guest shell (SSH)
      console --name N                      Attach to the serial console
      show --name N                         Open/front the VM's screen window
      mounts --name N                       Shared host directories as JSON
      mount --name N --host DIR --guest PATH [--read-only]
                                            Share a host directory; a Linux
                                            guest mounts it at PATH, a macOS
                                            guest under /Volumes/My Shared
                                            Files/PATH. Takes effect on the
                                            VM's next start
      unmount --name N --guest PATH         Stop sharing a directory
      resize --name N [--disk-size GB] [--cpus N] [--memory GB]
                                            Change a stopped VM's hardware.
                                            Takes effect on its next start.
                                            The disk can only grow; a Linux
                                            guest seeded by this app then
                                            grows its own filesystem on that
                                            boot, anything else has to be
                                            grown from inside the guest

    """

    // MARK: commands

    static func list(_ store: VMStore) throws {
        let entries = try store.listEntries { liveIp($0) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(["vms": entries])
        print(String(data: data, encoding: .utf8) ?? "{\"vms\":[]}")
    }

    static func create(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        guard isValidVmName(name) else {
            throw VmctlError("Invalid VM name \"\(name)\": use letters, digits, . _ -")
        }
        guard !store.exists(name) else {
            throw VmctlError("A VM named \"\(name)\" already exists.")
        }
        let osName = bag.options["os"] ?? "linux"
        guard let os = GuestOS(rawValue: osName) else {
            throw VmctlError("Unknown --os \(osName); use linux or macos.")
        }
        let diskSizeGb = bag.int("disk-size", default: os == .macos ? 64 : 32)
        let cpus = bag.int("cpus", default: os == .macos ? 4 : 2)
        let memoryGb = bag.int("memory", default: os == .macos ? 8 : 4)
        let diskSizeBytes = UInt64(diskSizeGb) * 1024 * 1024 * 1024

        try store.ensureExists()
        let user = bag.options["user"] ?? "user"
        guard os == .macos || isValidGuestUser(user) else {
            throw VmctlError(
                "Invalid --user \"\(user)\": use a lower-case Linux account name.")
        }
        // Without a password the seeded account cannot answer the login
        // prompt on the VM's own screen, which is the whole of
        // bostrot/ai-tasks#60. --password exists for a caller that wants to
        // choose one; everything else gets a generated one it can read back
        // with `credentials`.
        let password = os == .linux && guestTakesPassword(user: user)
            ? (bag.options["password"] ?? generateGuestPassword())
            : nil
        // Read before anything is created, so a bad path fails with nothing
        // to clean up. Only a Linux guest boots a cloud-init seed at all.
        var customUserData: String? = nil
        if let userDataPath = bag.options["user-data"], !userDataPath.isEmpty {
            guard os == .linux else {
                throw VmctlError("--user-data only applies to a Linux guest.")
            }
            customUserData = try readCustomUserData(at: userDataPath)
        }
        var config = VMConfig(
            name: name,
            os: os,
            cpus: cpus,
            memoryBytes: UInt64(memoryGb) * 1024 * 1024 * 1024,
            diskSizeBytes: diskSizeBytes,
            user: user,
            password: password,
            macAddress: VMFactory.randomMacAddress(),
            isoPath: bag.options["iso"]
        )

        do {
            switch os {
            case .linux:
                try createLinux(store, config: config, imagePath: bag.options["image"],
                                diskSizeBytes: diskSizeBytes, customUserData: customUserData)
            case .macos:
                try createMacos(store, config: &config,
                                restoreImagePath: bag.options["restore-image"],
                                diskSizeBytes: diskSizeBytes)
            }
            try store.saveConfig(config)
        } catch {
            // Leave no half-created VM behind.
            try? FileManager.default.removeItem(at: store.vmDir(name))
            throw error
        }
        printJson(["created": name])
    }

    /// A caller's cloud-init document: readable, UTF-8 and not blank. What
    /// cloud-init makes of it is the app's concern — it validates the
    /// header and the YAML before a document is ever saved — and a second,
    /// hand-copied version of that rule here would only ever disagree with
    /// the first.
    static func readCustomUserData(at path: String) throws -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw VmctlError("cloud-init user-data not found: \(path)")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw VmctlError("cloud-init user-data is not UTF-8 text: \(path)")
        }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw VmctlError("cloud-init user-data is empty: \(path)")
        }
        return text
    }

    static func createLinux(
        _ store: VMStore, config: VMConfig, imagePath: String?, diskSizeBytes: UInt64,
        customUserData: String? = nil
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.vmDir(config.name), withIntermediateDirectories: true)
        // Kept in the VM's directory as the record of what the guest was
        // provisioned with; the seed ISO is rebuilt from scratch on every
        // reseed, without it (see `writeSeed`).
        if let customUserData {
            try customUserData.write(
                to: store.userDataPath(config.name), atomically: true, encoding: .utf8)
        }

        if let imagePath, !imagePath.isEmpty {
            guard fm.fileExists(atPath: imagePath) else {
                throw VmctlError("Disk image not found: \(imagePath)")
            }
            if Qcow2.isQcow2(imagePath) {
                // Most distros publish arm64 cloud images only as qcow2;
                // convert while seeding so they Just Work as --image.
                try Qcow2.convert(from: imagePath, to: store.diskPath(config.name).path)
            } else {
                try fm.copyItem(
                    at: URL(fileURLWithPath: imagePath), to: store.diskPath(config.name))
            }
        }
        // Creates the file when there was no image and grows it either way.
        try store.createDiskImage(at: store.diskPath(config.name), sizeBytes: diskSizeBytes)

        if let isoPath = config.isoPath, !isoPath.isEmpty, !fm.fileExists(atPath: isoPath) {
            throw VmctlError("Installer ISO not found: \(isoPath)")
        }

        try CloudInit.writeSeedIso(
            to: store.seedIsoPath(config.name),
            user: config.user,
            publicKeys: store.authorizedKeys(),
            hostname: config.name,
            password: config.password,
            customUserData: customUserData)
    }

    static func createMacos(
        _ store: VMStore, config: inout VMConfig, restoreImagePath: String?,
        diskSizeBytes: UInt64
    ) throws {
        #if arch(arm64)
        try MacInstaller.createAndInstall(
            store: store, config: &config,
            restoreImagePath: restoreImagePath, diskSizeBytes: diskSizeBytes)
        #else
        throw VmctlError("macOS guests require an Apple Silicon host.")
        #endif
    }

    static func start(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: ["gui"])
        let name = try bag.require("name")
        _ = try store.loadConfig(name)
        if let pid = store.runningPid(name) {
            // Already up: with --gui the intent is "see it", so front the
            // window instead of doing nothing.
            if bag.flags.contains("gui") {
                kill(pid, SIGUSR1)
            }
            printJson(["started": name, "alreadyRunning": true])
            return
        }
        // A restart lands here while the previous run may still be letting
        // go of the image — its daemon gone, its XPC service not yet. Wait
        // that out instead of opening the disk a second time; the daemon
        // checks again under its lock, which is what settles a race.
        guard store.waitForDiskRelease(name, timeout: diskReleaseTimeout) else {
            let holders = DiskHolders.pids(store.diskPath(name).path)
            throw VmctlError(
                "The disk of \(name) is still in use"
                + (holders.isEmpty ? "" : " by process \(holders.map(String.init).joined(separator: ", "))")
                + " after \(Int(diskReleaseTimeout))s; not starting a second instance on it. If it is attached in Finder, eject it first.")
        }

        // Spawn a detached copy of this binary to own the VM's lifetime.
        // Bundle.main resolves the absolute executable path even when vmctl
        // was invoked through PATH as a bare name.
        let selfPath = URL(
            fileURLWithPath: Bundle.main.executablePath ?? CommandLine.arguments[0]
        ).resolvingSymlinksInPath()
        try FileManager.default.createDirectory(
            at: store.runDir(name), withIntermediateDirectories: true)
        let log = store.daemonLogPath(name)
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: log)

        let process = Process()
        process.executableURL = selfPath
        var daemonArgs = ["--store", store.root.path, "__run", "--name", name]
        if bag.flags.contains("gui") { daemonArgs.append("--gui") }
        process.arguments = daemonArgs
        process.standardOutput = logHandle
        process.standardError = logHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()

        // Give the daemon a moment to fail fast (bad config, missing
        // entitlement) so the caller hears about it now, not on next list.
        for _ in 0..<20 {
            if store.isRunning(name) {
                printJson(["started": name])
                return
            }
            if !process.isRunning {
                let logText = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
                // A guest can power itself off within this window (nothing
                // bootable). That is a successful start followed by a stop —
                // callers detect it via status — not a failure to start.
                if logText.contains("VM \(name) started") {
                    printJson(["started": name])
                    return
                }
                throw VmctlError("VM failed to start: \(logText.suffix(2000))")
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        printJson(["started": name])
    }

    static func runDaemon(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: ["gui"])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        let runner = VMRunner(store: store, config: config, gui: bag.flags.contains("gui"))
        try runner.run()
    }

    /// How long a start waits for a previous run to release the disk, and a
    /// stop waits for the release after the daemon is gone.
    static let diskReleaseTimeout: TimeInterval = 30

    /// `stop --name N [--force] [--timeout S]`
    ///
    /// SIGTERM makes the daemon press the guest's power button and wait up
    /// to `VMRunner.gracefulStopTimeout` before powering it off itself; this
    /// waits a little longer than that, so the daemon's own fallback — not a
    /// SIGKILL from here — is what normally ends a guest that will not shut
    /// down. `--force` is the last resort for a daemon that is itself stuck.
    ///
    /// "Stopped" means the disk is free again, not only that the daemon is
    /// gone: a restart starts straight after this returns.
    static func stop(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: ["force"])
        let name = try bag.require("name")
        _ = try store.loadConfig(name)
        guard let pid = store.runningPid(name) else {
            printJson(["stopped": name, "alreadyStopped": true])
            return
        }
        let logOffset = store.fileSize(store.daemonLogPath(name))
        kill(pid, SIGTERM)
        let timeout = TimeInterval(
            bag.int("timeout", default: Int(VMRunner.gracefulStopTimeout) + 30))
        let deadline = Date().addingTimeInterval(timeout)
        var stopped = false
        while Date() < deadline {
            if store.runningPid(name) == nil {
                stopped = true
                break
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        var forced = false
        if !stopped {
            guard bag.flags.contains("force") else {
                throw VmctlError("VM \(name) did not stop in time; retry with --force.")
            }
            kill(pid, SIGKILL)
            // Reaped by launchd, not us; wait for it to be gone for real.
            let killDeadline = Date().addingTimeInterval(10)
            while kill(pid, 0) == 0, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.2)
            }
            store.clearPid(name)
            forced = true
        }
        forced = forced || daemonReportedForcedStop(store, name, since: logOffset)
        let released = store.waitForDiskRelease(name, timeout: diskReleaseTimeout)
        printJson(["stopped": name, "forced": forced, "diskReleased": released])
    }

    /// Whether the daemon wrote `VMRunner.forcedStopMarker` after [offset]
    /// in its log, i.e. during this stop.
    static func daemonReportedForcedStop(_ store: VMStore, _ name: String, since offset: UInt64) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: store.daemonLogPath(name).path) else {
            return false
        }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        let tail = (try? handle.readToEnd()).map { String(decoding: $0, as: UTF8.self) } ?? ""
        return tail.contains(VMRunner.forcedStopMarker)
    }

    static func delete(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        _ = try store.loadConfig(name)
        guard !store.diskInUse(name) else {
            throw VmctlError("VM \(name) is running or its disk is still in use; stop it before deleting.")
        }
        try FileManager.default.removeItem(at: store.vmDir(name))
        printJson(["deleted": name])
    }

    static func status(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        let running = store.isRunning(name)
        var out: [String: Any] = ["name": name, "state": running ? "running" : "stopped"]
        if running, let ip = liveIp(config) {
            out["ip"] = ip
        }
        printJson(out)
    }

    /// Rewrites a VM's cloud-init seed with the current template and a fresh
    /// instance id, so the guest reapplies it on the next boot.
    ///
    /// VMs created by older builds carry a seed with no network config at
    /// all: their DHCP client sends a DUID that macOS never answers, so they
    /// boot without an address and nothing can reach them. Recreating the VM
    /// would work but throws the disk away; this repairs it in place. Older
    /// seeds also lack the getty repair, so an Alpine guest made by one goes
    /// on flooding its console with "can't open /dev/ttyAMA0" until reseeded.
    static func reseed(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        var config = try store.loadConfig(name)
        if try ensureGuestPassword(store, &config) { try store.saveConfig(config) }
        try writeSeed(store, config, fresh: true)
        printJson(["reseeded": name])
    }

    /// Gives [config] a console password when it has none and its user can
    /// take one, reporting whether it changed. VMs made before passwords
    /// existed pick one up the first time anything asks.
    @discardableResult
    static func ensureGuestPassword(_ store: VMStore, _ config: inout VMConfig) throws -> Bool {
        guard config.os == .linux, config.password == nil,
              guestTakesPassword(user: config.user) else { return false }
        config.password = generateGuestPassword()
        return true
    }

    /// (Re)writes a VM's cloud-init seed from its current config. [fresh]
    /// stamps a new instance id, which is what makes cloud-init apply the
    /// seed again on the next boot instead of skipping it as already done.
    ///
    /// vmctl's own document only. A caller's `--user-data` is applied once,
    /// at creation: a reseed is a repair (the app runs one on its own when a
    /// VM stops answering), and replaying a user's `runcmd`, `write_files`
    /// and package list under a new instance id would re-provision a guest
    /// somebody has been working in.
    static func writeSeed(_ store: VMStore, _ config: VMConfig, fresh: Bool) throws {
        try CloudInit.writeSeedIso(
            to: store.seedIsoPath(config.name),
            user: config.user,
            publicKeys: store.authorizedKeys(),
            hostname: config.name,
            password: config.password,
            instanceId: fresh
                ? "iid-\(config.name)-\(Int(Date().timeIntervalSince1970))"
                : nil)
    }

    /// Everything needed to sign in to a guest by hand: the account, its
    /// console password and the key a plain `ssh` would use.
    ///
    /// A VM that has no password yet (created before they existed) is given
    /// one here and reseeded, so the answer is never "there isn't one" —
    /// `appliedOnNextBoot` says the guest has not read it yet.
    static func credentials(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        var config = try store.loadConfig(name)
        var pending = false
        if try ensureGuestPassword(store, &config) {
            try store.saveConfig(config)
            try writeSeed(store, config, fresh: true)
            pending = true
        }
        var out: [String: Any] = [
            "name": name,
            "user": config.user,
            "sshKey": store.sshKeyPath().path,
            "appliedOnNextBoot": pending,
        ]
        if let password = config.password { out["password"] = password }
        if store.isRunning(name), let ip = liveIp(config) {
            out["ip"] = ip
        }
        printJson(out)
    }

    static func ip(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        // A stopped VM has no address, whatever bootpd still has on file.
        let ip = store.isRunning(name) ? liveIp(config) : nil
        printJson(["ip": ip as Any])
    }

    /// Probe behind [liveIp]; replaceable so tests never dial a real host.
    nonisolated(unsafe) static var reachability: (String) -> Bool = {
        GuestReachability.answers($0)
    }

    /// The guest's address, or nil when it has none *that answers*.
    ///
    /// The lease alone was the answer before, and a lease stays current for
    /// its whole term after the guest has gone quiet: a Linux VM whose
    /// filesystem broke under it kept being reported at 192.168.64.9 by
    /// `ip` and `vm_restart` while nothing there responded. A Linux guest is
    /// probed on its SSH port, where an accept or a refusal both prove a
    /// live network stack. A macOS guest is not: its firewall in stealth
    /// mode drops the probe silently, and it would lose an address it holds.
    static func liveIp(_ config: VMConfig, leases: String? = nil) -> String? {
        let candidate = leases.map {
            DHCPLeases.ipFor(mac: config.macAddress, hostname: config.name, in: $0)
        } ?? DHCPLeases.ipFor(mac: config.macAddress, hostname: config.name)
        guard let ip = candidate else { return nil }
        guard config.os == .linux else { return ip }
        return reachability(ip) ? ip : nil
    }

    static func exportVm(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let output = try bag.require("output")
        _ = try store.loadConfig(name)
        // A copy of an image a guest is writing is a torn filesystem.
        guard !store.diskInUse(name) else {
            throw VmctlError("VM \(name) is running or its disk is still in use; stop it before exporting.")
        }
        let fm = FileManager.default
        try? fm.removeItem(atPath: output)
        try fm.copyItem(at: store.diskPath(name), to: URL(fileURLWithPath: output))
        printJson(["exported": name, "output": output])
    }

    static func importVm(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let input = try bag.require("input")
        guard isValidVmName(name) else {
            throw VmctlError("Invalid VM name \"\(name)\": use letters, digits, . _ -")
        }
        guard !store.exists(name) else {
            throw VmctlError("A VM named \"\(name)\" already exists.")
        }
        guard FileManager.default.fileExists(atPath: input) else {
            throw VmctlError("Disk image not found: \(input)")
        }
        try store.ensureExists()
        let user = bag.options["user"] ?? "user"
        guard isValidGuestUser(user) else {
            throw VmctlError(
                "Invalid --user \"\(user)\": use a lower-case Linux account name.")
        }
        let config = VMConfig(
            name: name,
            os: .linux,
            cpus: bag.int("cpus", default: 2),
            memoryBytes: UInt64(bag.int("memory", default: 4)) * 1024 * 1024 * 1024,
            diskSizeBytes: 0,
            user: user,
            password: guestTakesPassword(user: user) ? generateGuestPassword() : nil,
            macAddress: VMFactory.randomMacAddress())
        do {
            try FileManager.default.createDirectory(
                at: store.vmDir(name), withIntermediateDirectories: true)
            try FileManager.default.copyItem(
                at: URL(fileURLWithPath: input), to: store.diskPath(name))
            // A fresh seed re-provisions cloud-init guests under the new
            // name; guests without cloud-init just ignore the ISO.
            try CloudInit.writeSeedIso(
                to: store.seedIsoPath(name),
                user: config.user,
                publicKeys: store.authorizedKeys(),
                hostname: name,
                password: config.password)
            try store.saveConfig(config)
        } catch {
            try? FileManager.default.removeItem(at: store.vmDir(name))
            throw error
        }
        printJson(["imported": name])
    }

    static func exec(_ store: VMStore, _ rest: [String]) throws -> Int32 {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        guard store.isRunning(name) else {
            throw VmctlError("VM \(name) is not running.")
        }
        guard !bag.remainder.isEmpty else {
            throw VmctlError("No command given; pass it after --")
        }
        let user = bag.options["user"] ?? config.user
        guard let ip = waitForIp(config) else {
            throw VmctlError("VM \(name) has no IP address yet (no DHCP lease).")
        }
        return execSsh(sshArguments(
            key: store.sshKeyPath().path, user: user, ip: ip,
            remote: bag.remainder))
    }

    /// Long-running: holds a port forward into the guest open until stdin
    /// closes or the guest goes away. See `forwardArguments`.
    static func forward(_ store: VMStore, _ rest: [String]) throws -> Int32 {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let remotePort = try tcpPort(bag, "port", default: nil)
        let localPort = try tcpPort(bag, "local-port", default: remotePort)
        let config = try store.loadConfig(name)
        guard store.isRunning(name) else {
            throw VmctlError("VM \(name) is not running.")
        }
        let user = bag.options["user"] ?? config.user
        guard let ip = waitForIp(config) else {
            throw VmctlError("VM \(name) has no IP address yet (no DHCP lease).")
        }
        return execSsh(forwardArguments(
            key: store.sshKeyPath().path, user: user, ip: ip,
            localPort: localPort, remotePort: remotePort))
    }

    /// Installs the store's public key in a guest that never got it from
    /// cloud-init (installer-ISO installs, imported disks), so `exec` and
    /// `shell` work by key afterwards. Signs in once with the password from
    /// `$VMCTL_GUEST_PASSWORD` — an env var, not an argument, so it is never
    /// visible in `ps` — and reports which accounts (login user, root) took
    /// the key.
    static func authorize(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        guard store.isRunning(name) else {
            throw VmctlError("VM \(name) is not running.")
        }
        let user = bag.options["user"] ?? config.user
        guard let password = ProcessInfo.processInfo.environment[GuestAccess.passwordEnvVar],
              !password.isEmpty else {
            throw VmctlError(
                "Set \(GuestAccess.passwordEnvVar) to the password of \(user) in the guest.")
        }
        guard let ip = waitForIp(config) else {
            throw VmctlError("VM \(name) has no IP address yet (no DHCP lease).")
        }
        let report = try GuestAccess.install(
            publicKeys: store.authorizedKeys(),
            user: user,
            ip: ip,
            password: password,
            askpassPath: store.askpassPath())
        printJson(["authorized": name, "user": user, "root": report.rootInstalled])
    }

    static func shell(_ store: VMStore, _ rest: [String]) throws -> Int32 {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        guard store.isRunning(name) else {
            throw VmctlError("VM \(name) is not running.")
        }
        let user = bag.options["user"] ?? config.user
        guard let ip = waitForIp(config) else {
            throw VmctlError("VM \(name) has no IP address yet (no DHCP lease).")
        }
        return execSsh(sshArguments(
            key: store.sshKeyPath().path, user: user, ip: ip))
    }

    /// Ask a running VM's daemon to present its display window.
    static func show(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        _ = try store.loadConfig(name)
        guard let pid = store.runningPid(name) else {
            throw VmctlError("VM \(name) is not running.")
        }
        kill(pid, SIGUSR1)
        printJson(["shown": name])
    }

    /// Bridge this terminal to the VM's serial console socket, raw-mode, until
    /// the socket closes or the user detaches with Ctrl-].
    static func console(_ store: VMStore, _ rest: [String]) throws -> Int32 {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        guard config.os == .linux else {
            throw VmctlError("Serial console is only available for Linux guests.")
        }
        guard store.isRunning(name) else {
            throw VmctlError("VM \(name) is not running.")
        }

        let path = store.consoleSocketPath(name).path
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw VmctlError("socket failed: \(String(cString: strerror(errno)))")
        }
        do {
            try UnixSocketAddress.connect(fd, to: path)
        } catch {
            close(fd)
            throw VmctlError("Could not attach to the console of \(name): \(error)")
        }

        FileHandle.standardError.write(Data((
            "Connected to the serial console of \(name). Detach with Ctrl-].\n"
            + "If nothing appears, the guest may not put a console on hvc0 "
            + "(kernel arg console=hvc0, or a getty on /dev/hvc0).\n").utf8))

        // Raw mode, so keystrokes (including Ctrl-C) go to the guest.
        var savedTermios = termios()
        let stdinIsTty = isatty(STDIN_FILENO) == 1
        if stdinIsTty {
            tcgetattr(STDIN_FILENO, &savedTermios)
            var raw = savedTermios
            cfmakeraw(&raw)
            tcsetattr(STDIN_FILENO, TCSANOW, &raw)
        }
        defer {
            if stdinIsTty {
                tcsetattr(STDIN_FILENO, TCSANOW, &savedTermios)
                FileHandle.standardError.write(Data("\nDetached.\n".utf8))
            }
            close(fd)
        }

        // One poll loop pumping both directions, so a VM that exits ends the
        // session immediately instead of waiting for the next keypress.
        var buffer = [UInt8](repeating: 0, count: 4096)
        var watched = [
            pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0),
            pollfd(fd: fd, events: Int16(POLLIN), revents: 0),
        ]
        while true {
            watched[0].revents = 0
            watched[1].revents = 0
            guard poll(&watched, 2, -1) >= 0 else { break }
            if watched[1].revents != 0 {
                let count = read(fd, &buffer, buffer.count)
                if count <= 0 { break }
                _ = buffer.withUnsafeBytes {
                    write(STDOUT_FILENO, $0.baseAddress, count)
                }
            }
            if watched[0].revents != 0 {
                let count = read(STDIN_FILENO, &buffer, buffer.count)
                if count <= 0 { break }
                if buffer[0..<count].contains(0x1D) { break } // Ctrl-]
                _ = write(fd, &buffer, count)
            }
        }
        return 0
    }

    /// The lease can lag a fresh boot; poll briefly instead of failing the
    /// first exec after start.
    static func waitForIp(_ config: VMConfig, timeout: TimeInterval = 20) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let ip = liveIp(config) {
                return ip
            }
            Thread.sleep(forTimeInterval: 1)
        }
        return nil
    }
}
