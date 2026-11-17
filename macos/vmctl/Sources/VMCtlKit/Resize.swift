import Foundation
import Virtualization

/// Changing a VM's hardware after it was created (bostrot/ai-tasks#103).
///
/// `create` is the only place that ever chose a VM's CPU count, memory and
/// disk size, and nothing could change them afterwards: a guest created with
/// the 32 GB default and then filled up had to be recreated from scratch. The
/// three knobs are not equally reversible, so they are not treated alike:
///
/// * **CPUs and memory** are config only. Nothing on disk depends on the old
///   values, so either direction is fine and the VM picks the new ones up the
///   next time `VMFactory` builds its configuration — that is, on its next
///   start.
/// * **The disk only grows.** The image is a raw disk with a partition table
///   and a filesystem inside it; truncating it shorter cuts through whatever
///   the guest put at the end, and nothing here can know what that is. A
///   shrink is refused rather than attempted.
///
/// Growing the *image* is not the same as growing the guest's filesystem: the
/// guest sees a bigger block device and a partition table that still describes
/// the old extent. A Linux guest seeded by this app fixes that itself —
/// cloud-init's `growpart` module runs on every boot (`PER_ALWAYS`) and
/// resizes the root partition and filesystem to fill the device. A macOS
/// guest, or a Linux guest installed from an ISO without cloud-init, needs the
/// user to do it once from inside; the JSON says which case the VM is in so
/// the app can say so too.
extension VmctlCLI {
    /// What a caller asked to change; nil means "leave it alone".
    public struct VMResizeRequest: Equatable {
        public var cpus: Int?
        public var memoryBytes: UInt64?
        public var diskSizeBytes: UInt64?

        public init(
            cpus: Int? = nil, memoryBytes: UInt64? = nil, diskSizeBytes: UInt64? = nil
        ) {
            self.cpus = cpus
            self.memoryBytes = memoryBytes
            self.diskSizeBytes = diskSizeBytes
        }

        public var isEmpty: Bool {
            cpus == nil && memoryBytes == nil && diskSizeBytes == nil
        }
    }

    /// What this Mac's Virtualization.framework will accept. Taken from the
    /// framework by default and injectable so the rules can be tested without
    /// the host's own RAM deciding what the expected answer is.
    public struct VMResizeLimits {
        public var minimumCpus: Int
        public var maximumCpus: Int
        public var minimumMemoryBytes: UInt64
        public var maximumMemoryBytes: UInt64

        public init(
            minimumCpus: Int, maximumCpus: Int,
            minimumMemoryBytes: UInt64, maximumMemoryBytes: UInt64
        ) {
            self.minimumCpus = minimumCpus
            self.maximumCpus = maximumCpus
            self.minimumMemoryBytes = minimumMemoryBytes
            self.maximumMemoryBytes = maximumMemoryBytes
        }

        public static var host: VMResizeLimits {
            VMResizeLimits(
                minimumCpus: VZVirtualMachineConfiguration.minimumAllowedCPUCount,
                maximumCpus: VZVirtualMachineConfiguration.maximumAllowedCPUCount,
                minimumMemoryBytes: VZVirtualMachineConfiguration.minimumAllowedMemorySize,
                maximumMemoryBytes: VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        }
    }

    // MARK: config edit (pure, tested)

    /// [config] with [request] applied, or a `VmctlError` naming what the
    /// user has to change about their request.
    ///
    /// Out-of-range CPU and memory values are refused here rather than
    /// clamped the way `VMFactory` clamps them at start: a clamp is the right
    /// answer for a config that already exists and has to boot *somehow*, and
    /// the wrong one for a number someone just typed — silently getting a
    /// different machine than you asked for is how "I set it to 64 GB and it
    /// is still 8" happens.
    /// [currentDiskSizeBytes] is what the disk really is today, which is not
    /// always what the config says: `import` writes `diskSizeBytes: 0` and
    /// copies in an image of whatever size the caller handed it. Measuring
    /// the image itself is what keeps a "grow" from quietly writing a smaller
    /// number over a bigger disk.
    public static func resizedConfig(
        _ config: VMConfig,
        request: VMResizeRequest,
        currentDiskSizeBytes: UInt64? = nil,
        limits: VMResizeLimits = .host
    ) throws -> VMConfig {
        let currentDisk = currentDiskSizeBytes ?? config.diskSizeBytes
        guard !request.isEmpty else {
            throw VmctlError(
                "Nothing to change: pass at least one of --disk-size, --cpus, --memory.")
        }
        var updated = config
        if let cpus = request.cpus {
            guard (limits.minimumCpus...limits.maximumCpus).contains(cpus) else {
                throw VmctlError(
                    "--cpus must be between \(limits.minimumCpus) and \(limits.maximumCpus) on this Mac, got \(cpus).")
            }
            updated.cpus = cpus
        }
        if let memoryBytes = request.memoryBytes {
            guard memoryBytes >= limits.minimumMemoryBytes,
                  memoryBytes <= limits.maximumMemoryBytes
            else {
                throw VmctlError(
                    "--memory must be between \(sizeLabel(limits.minimumMemoryBytes)) and \(sizeLabel(limits.maximumMemoryBytes)) on this Mac, got \(sizeLabel(memoryBytes)).")
            }
            updated.memoryBytes = memoryBytes
        }
        if let diskSizeBytes = request.diskSizeBytes {
            guard diskSizeBytes >= currentDisk else {
                throw VmctlError(
                    "A disk can only grow: \(config.name) is \(sizeLabel(currentDisk)) and --disk-size asked for \(sizeLabel(diskSizeBytes)). Shrinking a raw disk image would cut through the guest's own partitions.")
            }
            updated.diskSizeBytes = diskSizeBytes
        }
        return updated
    }

    /// Bytes as the whole-or-one-decimal GB the user typed them in, and as MB
    /// below a gigabyte — Virtualization.framework's own memory minimum is
    /// 128 MB, which as gigabytes reads "0.0 GB" and makes the message it
    /// appears in say nothing at all.
    static func sizeLabel(_ bytes: UInt64) -> String {
        let mb = Double(bytes) / 1024 / 1024
        if mb < 1024 { return "\(Int(mb.rounded())) MB" }
        let gb = mb / 1024
        return gb == gb.rounded()
            ? "\(Int(gb)) GB"
            : String(format: "%.1f GB", gb)
    }

    /// Whether the guest grows its own root filesystem after the image grew.
    ///
    /// Only a Linux guest this app seeded: `growpart` comes from the
    /// cloud-init seed, so a VM imported from a raw disk or installed from an
    /// ISO (no `seed.iso` in its directory) is on its own, as is every macOS
    /// guest.
    static func guestGrowsItself(_ store: VMStore, _ config: VMConfig) -> Bool {
        config.os == .linux
            && FileManager.default.fileExists(atPath: store.seedIsoPath(config.name).path)
    }

    /// Gigabytes from a `--disk-size`/`--memory` option, nil when absent.
    /// Whole gigabytes only — the same unit `create` takes, and the same one
    /// the UI offers.
    static func gigabyteOption(_ bag: ArgumentBag, _ key: String) throws -> UInt64? {
        guard let raw = bag.options[key] else { return nil }
        guard let gb = Int(raw), gb > 0 else {
            throw VmctlError("--\(key) must be a whole number of gigabytes, got \(raw)")
        }
        return UInt64(gb) * 1024 * 1024 * 1024
    }

    // MARK: command

    /// `resize --name N [--disk-size GB] [--cpus N] [--memory GB]`
    ///
    /// Refused while the VM runs. A running guest holds the disk image open
    /// through `VZDiskImageStorageDeviceAttachment` and has already been told
    /// how big it is, and its CPU count and memory are fixed for the life of
    /// the configuration — applying any of this underneath it would at best
    /// be ignored and at worst corrupt the image.
    public static func resize(_ store: VMStore, _ rest: [String]) throws {
        let bag = ArgumentBag(rest, flagNames: [])
        let name = try bag.require("name")
        let config = try store.loadConfig(name)
        // Not only the daemon: an image is never truncated while anything —
        // a lingering XPC service, an `hdiutil` attach — still has it open.
        guard !store.diskInUse(name) else {
            throw VmctlError("VM \(name) is running or its disk is still in use; stop it before resizing.")
        }
        // What the guest actually sees, which an imported VM's config does
        // not record (it is saved as 0). The app reads the same number, off
        // `list`, so both sides judge a grow by the same measure.
        let currentDisk = max(config.diskSizeBytes, store.fileSize(store.diskPath(name)))
        let request = VMResizeRequest(
            cpus: bag.options["cpus"].flatMap { Int($0) },
            memoryBytes: try gigabyteOption(bag, "memory"),
            diskSizeBytes: try gigabyteOption(bag, "disk-size"))
        if bag.options["cpus"] != nil, request.cpus == nil {
            throw VmctlError(
                "--cpus must be a whole number, got \(bag.options["cpus"] ?? "")")
        }
        var updated = try resizedConfig(
            config, request: request, currentDiskSizeBytes: currentDisk)

        // The image first: a config that promises 64 GB over a 32 GB file is
        // the one inconsistency the guest would actually trip over, so the
        // file is grown before the config claims it. Growing is a truncate,
        // so the file stays sparse and costs nothing until the guest writes.
        let diskGrew = updated.diskSizeBytes > currentDisk
        if diskGrew {
            try store.createDiskImage(
                at: store.diskPath(name), sizeBytes: updated.diskSizeBytes)
        } else {
            // Nothing was asked of the disk, or it was asked for exactly what
            // it already is. Either way the config must keep describing the
            // image that exists rather than an imported VM's placeholder 0.
            updated.diskSizeBytes = currentDisk
        }
        try store.saveConfig(updated)

        printJson([
            "name": name,
            "os": updated.os.rawValue,
            "cpus": updated.cpus,
            "memoryBytes": updated.memoryBytes,
            "diskSizeBytes": updated.diskSizeBytes,
            "diskPath": store.diskPath(name).path,
            // Every change here is read when the VM next starts.
            "appliesAtNextStart": true,
            // False means: the block device grows but the guest's own
            // partition and filesystem do not, and someone has to say so.
            "guestGrowsFilesystem":
                diskGrew ? guestGrowsItself(store, updated) : true,
        ])
    }
}
