import Foundation

/// One host directory shared into a guest (bostrot/ai-tasks#79).
///
/// On the host it is a virtio-fs device carrying [tag]; a Linux guest mounts
/// that tag at [guestPath], a macOS guest gets every share under
/// `/Volumes/My Shared Files/<name>` through the automount tag, in which case
/// [guestPath] is the share's name.
public struct VMMount: Codable, Equatable {
    public var hostPath: String
    public var guestPath: String
    public var readOnly: Bool
    /// The virtio-fs tag the device carries and the guest mounts by. Stable
    /// for the life of the entry, so a guest's fstab keeps matching it.
    public var tag: String

    public init(hostPath: String, guestPath: String, readOnly: Bool, tag: String) {
        self.hostPath = hostPath
        self.guestPath = guestPath
        self.readOnly = readOnly
        self.tag = tag
    }

    enum CodingKeys: String, CodingKey {
        case hostPath, guestPath, readOnly, tag
    }

    /// `readOnly` is optional on the way in: a hand-edited entry without it
    /// must not make the whole store unreadable (`list` loads every config).
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hostPath = try container.decode(String.self, forKey: .hostPath)
        guestPath = try container.decode(String.self, forKey: .guestPath)
        readOnly = try container.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        tag = try container.decode(String.self, forKey: .tag)
    }

    public func asJson() -> [String: Any] {
        [
            "hostPath": hostPath,
            "guestPath": guestPath,
            "readOnly": readOnly,
            "tag": tag,
        ]
    }
}

/// Where a macOS guest shows shared directories; the name of each share is
/// the last path component.
public let macOSSharedFilesRoot = "/Volumes/My Shared Files"

/// Directories a share must never be mounted over: the guest would lose its
/// own system underneath and stop booting or answering SSH.
public let reservedGuestMountPaths: Set<String> = [
    "/", "/bin", "/boot", "/dev", "/etc", "/lib", "/lib64", "/proc", "/root",
    "/run", "/sbin", "/sys", "/usr", "/var",
]

/// A guest mount point this tool accepts: absolute, plain characters, no
/// `.`/`..` segments and not one of the system directories.
///
/// The path reaches an fstab line and a shell script in the guest, so
/// anything outside this set is refused instead of quoted.
public func isValidGuestMountPath(_ path: String) -> Bool {
    guard path.hasPrefix("/"), path.count <= 255, !path.hasSuffix("/"),
          !path.contains("//"),
          path.range(of: "^/[A-Za-z0-9._/-]+$", options: .regularExpression) != nil
    else { return false }
    let segments = path.split(separator: "/")
    guard !segments.contains("."), !segments.contains("..") else { return false }
    return !reservedGuestMountPaths.contains(path)
}

/// The guest side of Linux mounts: the `/etc/fstab` block vmctl owns and the
/// script the daemon runs over SSH after every boot to bring the guest in
/// line with the VM's config.
///
/// A script rather than cloud-init's `mounts` module for two reasons. cloud-init
/// only re-reads its seed under a new instance id, and a fresh id makes it
/// replay everything else in the seed too — regenerated SSH host keys, a
/// re-run of the user's own first-boot document. And its mounts module drops
/// any device that is not a path under /dev, which a virtio-fs tag is not.
public enum GuestMounts {
    public static let fstabBegin = "# >>> wslmanager mounts >>>"
    public static let fstabEnd = "# <<< wslmanager mounts <<<"
    /// Every tag vmctl hands out starts with this, so the sync script can
    /// tell its own mounts from anything the user mounted by hand.
    public static let tagPrefix = "wslm"
    /// What the sync script prints for a share it could not mount, followed
    /// by the tag and the mount point. Printed rather than exiting non-zero:
    /// the daemon must not keep retrying a share whose host directory is
    /// simply gone.
    public static let failureMarker = "WSLMANAGER_MOUNT_FAILED"

    /// The next free tag: the smallest number not taken by [existing].
    public static func nextTag(existing: [VMMount]) -> String {
        let taken = Set(existing.map(\.tag))
        var n = 0
        while taken.contains("\(tagPrefix)\(n)") { n += 1 }
        return "\(tagPrefix)\(n)"
    }

    /// fstab options: `nofail` so a share whose host directory has gone
    /// missing never holds up the boot.
    public static func fstabOptions(_ mount: VMMount) -> String {
        mount.readOnly ? "defaults,nofail,ro" : "defaults,nofail"
    }

    public static func fstabLine(_ mount: VMMount) -> String {
        "\(mount.tag) \(mount.guestPath) virtiofs \(fstabOptions(mount)) 0 0"
    }

    static func mode(_ mount: VMMount) -> String { mount.readOnly ? "ro" : "rw" }

    /// POSIX sh, run as root in the guest: rewrites vmctl's fstab block,
    /// unmounts every share of ours that is not exactly as configured
    /// (gone, moved, or a tag that now means another directory, since tags
    /// are reused) and mounts every configured one that is not mounted yet.
    /// Idempotent, so it can run after every boot and again whenever the
    /// config changes.
    ///
    /// A mount that fails is reported with [failureMarker] on stdout and the
    /// script still exits 0; see the daemon's `syncGuestMounts`.
    public static func syncScript(_ mounts: [VMMount]) -> String {
        var lines = [
            "#!/bin/sh",
            "modprobe virtiofs 2>/dev/null || true",
            "fstab=/etc/fstab",
            "tmp=$(mktemp)",
            "if [ -f \"$fstab\" ]; then",
            "  sed '/^\(fstabBegin)$/,/^\(fstabEnd)$/d' \"$fstab\" > \"$tmp\"",
            "fi",
        ]
        if !mounts.isEmpty {
            lines.append("{")
            lines.append("  echo '\(fstabBegin)'")
            for mount in mounts {
                lines.append("  echo '\(fstabLine(mount))'")
            }
            lines.append("  echo '\(fstabEnd)'")
            lines.append("} >> \"$tmp\"")
        }
        lines.append("cat \"$tmp\" > \"$fstab\" && rm -f \"$tmp\"")
        // Ours that are no longer configured, or not configured *this way*:
        // the fstab the guest booted with may predate the config, so a tag
        // can be mounted at an old path or in the old mode. Anything the
        // user mounted themselves has no wslm tag and is left alone.
        let keep = mounts.map { "\($0.tag)@\($0.guestPath)@\(mode($0))" }.joined(separator: " ")
        lines.append("keep=' \(keep) '")
        lines.append(
            "awk '$3 == \"virtiofs\" {split($4, o, \",\"); print $1, $2, o[1]}' /proc/mounts | while read -r tag dir mode; do")
        lines.append("  case \"$tag\" in")
        lines.append("    \(tagPrefix)[0-9]*)")
        lines.append("      case \"$keep\" in")
        lines.append("        *\" $tag@$dir@$mode \"*) ;;")
        lines.append("        *) umount \"$dir\" 2>/dev/null || true ;;")
        lines.append("      esac ;;")
        lines.append("  esac")
        lines.append("done")
        for mount in mounts {
            lines.append("mkdir -p '\(mount.guestPath)'")
            lines.append(
                "mountpoint -q '\(mount.guestPath)' || mount -t virtiofs -o \(mode(mount)) \(mount.tag) '\(mount.guestPath)' || echo '\(failureMarker) \(mount.tag) \(mount.guestPath)'")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The remote command that runs [syncScript] in the guest: the script
    /// travels base64-encoded, so nothing in it meets the guest shell's
    /// parser on the way in.
    public static func remoteCommand(_ mounts: [VMMount]) -> String {
        let payload = Data(syncScript(mounts).utf8).base64EncodedString()
        return "printf %s \(payload) | base64 -d | sh"
    }

    /// The shares [syncScript]'s output says could not be mounted, as
    /// `tag guestPath` pairs.
    public static func failures(in output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let text = line.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix(failureMarker + " ") else { return nil }
            return String(text.dropFirst(failureMarker.count + 1))
        }
    }
}

/// What the daemon last did about a Linux guest's mounts, kept under the
/// VM's run directory so `mounts` can say whether the guest has them yet.
public struct GuestMountStatus: Codable, Equatable {
    /// `pending` while the daemon is still trying, `applied` once the guest
    /// has every share, `partial` when it has some (the rest are named in
    /// [error]), `failed` when the guest could not be reached at all, and
    /// `outdated` once the config changed under a running guest.
    public var state: String
    public var error: String?
    public var at: Date

    public init(state: String, error: String? = nil, at: Date = Date()) {
        self.state = state
        self.error = error
        self.at = at
    }
}

extension VMStore {
    public func mountStatusPath(_ name: String) -> URL {
        runDir(name).appendingPathComponent("mounts-status.json")
    }

    public func writeMountStatus(_ name: String, _ status: GuestMountStatus) {
        try? FileManager.default.createDirectory(
            at: runDir(name), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(status) {
            try? data.write(to: mountStatusPath(name), options: .atomic)
        }
    }

    public func readMountStatus(_ name: String) -> GuestMountStatus? {
        guard let data = try? Data(contentsOf: mountStatusPath(name)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(GuestMountStatus.self, from: data)
    }
}

extension VmctlCLI {
    // MARK: config edits (pure, tested)

    /// The config with [hostPath] shared at [guestTarget]; an entry already at
    /// that target is replaced and keeps its tag.
    static func addingMount(
        to config: VMConfig, hostPath: String, guestTarget: String, readOnly: Bool
    ) throws -> VMConfig {
        guard hostPath.hasPrefix("/") else {
            throw VmctlError("--host must be an absolute path, got \(hostPath)")
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: hostPath, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw VmctlError("Host directory not found: \(hostPath)")
        }
        let guestPath = try normalizedGuestTarget(guestTarget, os: config.os)
        var mounts = config.mounts ?? []
        var updated = config
        if let index = mounts.firstIndex(where: { $0.guestPath == guestPath }) {
            mounts[index].hostPath = hostPath
            mounts[index].readOnly = readOnly
        } else {
            mounts.append(VMMount(
                hostPath: hostPath, guestPath: guestPath, readOnly: readOnly,
                tag: GuestMounts.nextTag(existing: mounts)))
        }
        updated.mounts = mounts
        return updated
    }

    /// The config without the share at [guestTarget]. Removing what is not
    /// there is not an error: the caller's picture of the config may be older
    /// than the config.
    static func removingMount(from config: VMConfig, guestTarget: String) throws -> VMConfig {
        let guestPath = try normalizedGuestTarget(guestTarget, os: config.os)
        var updated = config
        updated.mounts = (config.mounts ?? []).filter { $0.guestPath != guestPath }
        return updated
    }

    /// A Linux guest takes an absolute mount point; a macOS guest takes a
    /// share name, given bare or as the `/Volumes/My Shared Files/<name>`
    /// path `mounts` reports it under. A share name follows the VM-name
    /// rule: one plain path component, not starting with a dot.
    static func normalizedGuestTarget(_ raw: String, os: GuestOS) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch os {
        case .linux:
            guard isValidGuestMountPath(trimmed) else {
                throw VmctlError(
                    "Invalid --guest \"\(trimmed)\": use an absolute path with letters, digits, . _ - outside the system directories.")
            }
            return trimmed
        case .macos:
            var name = trimmed
            let prefix = macOSSharedFilesRoot + "/"
            if name.hasPrefix(prefix) { name = String(name.dropFirst(prefix.count)) }
            guard isValidVmName(name) else {
                throw VmctlError(
                    "Invalid --guest \"\(trimmed)\": a macOS guest takes a share name (letters, digits, . _ -).")
            }
            return name
        }
    }

    /// The `guestPath` a caller sees: the real mount point on Linux, the
    /// automount location on macOS.
    static func reportedGuestPath(_ mount: VMMount, os: GuestOS) -> String {
        os == .macos ? "\(macOSSharedFilesRoot)/\(mount.guestPath)" : mount.guestPath
    }

    static func mountsJson(_ store: VMStore, _ config: VMConfig) -> [String: Any] {
        let running = store.isRunning(config.name)
        var out: [String: Any] = [
            "name": config.name,
            "os": config.os.rawValue,
            "running": running,
            "mounts": (config.mounts ?? []).map { mount -> [String: Any] in
                var json = mount.asJson()
                json["guestPath"] = reportedGuestPath(mount, os: config.os)
                return json
            },
        ]
        if running, config.os == .linux, let status = store.readMountStatus(config.name) {
            var guest: [String: Any] = ["state": status.state]
            if let error = status.error { guest["error"] = error }
            out["guest"] = guest
        }
        return out
    }

    // MARK: commands

    static func mounts(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let config = try store.loadConfig(try bag.require("name"))
        printJson(mountsJson(store, config))
    }

    /// Adds (or replaces) a share. The device joins the VM on its next start:
    /// Virtualization.framework cannot attach one to a running VM.
    static func mount(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: ["read-only"])
        try editMounts(store, bag) { config in
            try addingMount(
                to: config,
                hostPath: try bag.require("host"),
                guestTarget: try bag.require("guest"),
                readOnly: bag.flags.contains("read-only"))
        }
    }

    static func unmount(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        try editMounts(store, bag) { config in
            try removingMount(from: config, guestTarget: try bag.require("guest"))
        }
    }

    /// Saves [edit]'s result and prints the new list. A running guest still
    /// has the old one, and its status says so until the next start.
    static func editMounts(
        _ store: VMStore, _ bag: ArgumentBag, _ edit: (VMConfig) throws -> VMConfig
    ) throws {
        let name = try bag.require("name")
        let updated = try edit(try store.loadConfig(name))
        try store.saveConfig(updated)
        if updated.os == .linux, store.isRunning(name) {
            store.writeMountStatus(name, GuestMountStatus(
                state: "outdated", error: "Restart the VM to apply the changed shares."))
        }
        printJson(mountsJson(store, updated))
    }

    // MARK: guest sync (daemon)

    /// Brings a running Linux guest's mounts in line with [mounts] over SSH:
    /// waits for the guest's address and its sshd, then runs
    /// [GuestMounts.syncScript] as root. Called by the daemon once the VM has
    /// started, with the shares whose devices it attached; [skipped] are the
    /// ones it could not (host directory missing), which the guest is not
    /// told about and the status names. The outcome lands in the VM's run
    /// directory for `mounts`.
    ///
    /// Retries until [timeout]: a cloud image's first boot seeds the SSH key
    /// and starts sshd well after the VM itself is up. A refused key is not
    /// retried — the guest is up and answering, it just will not let root
    /// in (an ISO install without the store key), and sixty more attempts
    /// would only trip a login guard like fail2ban.
    static func syncGuestMounts(
        store: VMStore, config: VMConfig, mounts: [VMMount], skipped: [VMMount] = [],
        timeout: TimeInterval = 300, retryInterval: TimeInterval = 5
    ) {
        guard config.os == .linux else { return }
        store.writeMountStatus(config.name, GuestMountStatus(state: "pending"))
        let deadline = Date().addingTimeInterval(timeout)
        var lastError = "no DHCP lease for \(config.name)"
        let remote = GuestMounts.remoteCommand(mounts)
        while Date() < deadline {
            guard let ip = waitForIp(config, timeout: retryInterval) else { continue }
            let (status, output) = runSsh(sshArguments(
                key: store.sshKeyPath().path, user: "root", ip: ip, remote: [remote]))
            if status == 0 {
                store.writeMountStatus(config.name, syncOutcome(
                    output: output, skipped: skipped))
                return
            }
            lastError = output.trimmingCharacters(in: .whitespacesAndNewlines)
            if lastError.isEmpty { lastError = "ssh exited with status \(status)" }
            if lastError.contains("Permission denied") { break }
            Thread.sleep(forTimeInterval: retryInterval)
        }
        FileHandle.standardError.write(
            Data("Could not apply mounts in \(config.name): \(lastError)\n".utf8))
        store.writeMountStatus(
            config.name, GuestMountStatus(state: "failed", error: lastError))
    }

    /// The status a successful run of the sync script amounts to, from what
    /// it printed and what the host left out.
    static func syncOutcome(output: String, skipped: [VMMount]) -> GuestMountStatus {
        var problems = skipped.map { "host directory missing: \($0.hostPath)" }
        problems += GuestMounts.failures(in: output).map { "could not mount \($0)" }
        guard !problems.isEmpty else { return GuestMountStatus(state: "applied") }
        return GuestMountStatus(state: "partial", error: problems.joined(separator: "; "))
    }

    /// ssh as a child process with its output captured — the daemon has no
    /// terminal to hand over and needs to know how the command ended.
    static func runSsh(_ arguments: [String]) -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return (1, "\(error)")
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }
}
