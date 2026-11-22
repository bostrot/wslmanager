import Foundation
import Testing
@testable import VMCtlKit

/// Changing a VM's hardware after it was created (bostrot/ai-tasks#103): the
/// rules behind `resize`, the disk image it grows and the report it prints.
@Suite struct ResizeTests {
    let tempRoot: URL
    let store: VMStore

    /// Fixed limits so the expectations do not depend on how much RAM the
    /// machine running the tests happens to have: 1-8 CPUs, 1-16 GB.
    let limits = VmctlCLI.VMResizeLimits(
        minimumCpus: 1, maximumCpus: 8,
        minimumMemoryBytes: gb(1), maximumMemoryBytes: gb(16))

    static func gb(_ count: UInt64) -> UInt64 { count * 1024 * 1024 * 1024 }

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-resize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = VMStore(root: tempRoot, hostSshDir: tempRoot.appendingPathComponent("ssh"))
    }

    func config(
        _ name: String = "dev", os: GuestOS = .linux,
        cpus: Int = 2, memoryGb: UInt64 = 4, diskGb: UInt64 = 32
    ) -> VMConfig {
        VMConfig(
            name: name, os: os, cpus: cpus,
            memoryBytes: Self.gb(memoryGb), diskSizeBytes: Self.gb(diskGb),
            user: "dev", macAddress: "aa:bb:cc:dd:ee:01")
    }

    // MARK: the config edit

    @Test func changesOnlyWhatWasAskedFor() throws {
        let updated = try VmctlCLI.resizedConfig(
            config(), request: .init(cpus: 6), limits: limits)
        #expect(updated.cpus == 6)
        #expect(updated.memoryBytes == Self.gb(4))
        #expect(updated.diskSizeBytes == Self.gb(32))
        // Everything else the VM is rides along untouched.
        #expect(updated.macAddress == "aa:bb:cc:dd:ee:01")
        #expect(updated.user == "dev")
    }

    @Test func appliesAllThreeAtOnce() throws {
        let updated = try VmctlCLI.resizedConfig(
            config(),
            request: .init(cpus: 8, memoryBytes: Self.gb(16), diskSizeBytes: Self.gb(64)),
            limits: limits)
        #expect(updated.cpus == 8)
        #expect(updated.memoryBytes == Self.gb(16))
        #expect(updated.diskSizeBytes == Self.gb(64))
    }

    @Test func anEmptyRequestIsRefused() {
        #expect(throws: VmctlError.self) {
            try VmctlCLI.resizedConfig(config(), request: .init(), limits: limits)
        }
    }

    @Test func cpusAndMemoryAreRefusedOutsideTheHostLimits() throws {
        // Refused, not clamped: someone who types 99 should hear about it
        // rather than quietly get 8.
        for cpus in [0, 9, -1] {
            #expect(throws: VmctlError.self, "\(cpus) CPUs") {
                try VmctlCLI.resizedConfig(
                    config(), request: .init(cpus: cpus), limits: limits)
            }
        }
        for memoryGb in [UInt64(0), UInt64(32)] {
            #expect(throws: VmctlError.self, "\(memoryGb) GB") {
                try VmctlCLI.resizedConfig(
                    config(), request: .init(memoryBytes: Self.gb(memoryGb)),
                    limits: limits)
            }
        }
        // The edges themselves are allowed.
        #expect(try VmctlCLI.resizedConfig(
            config(), request: .init(cpus: 1), limits: limits).cpus == 1)
        #expect(try VmctlCLI.resizedConfig(
            config(), request: .init(memoryBytes: Self.gb(16)),
            limits: limits).memoryBytes == Self.gb(16))
    }

    @Test func memoryMayShrinkButTheDiskMayNot() throws {
        // Memory is config only, so down is as safe as up.
        let smaller = try VmctlCLI.resizedConfig(
            config(memoryGb: 8), request: .init(memoryBytes: Self.gb(2)),
            limits: limits)
        #expect(smaller.memoryBytes == Self.gb(2))

        // A raw disk image holds the guest's partition table; truncating it
        // shorter cuts through whatever lives at the end.
        #expect(throws: VmctlError.self) {
            try VmctlCLI.resizedConfig(
                config(diskGb: 32), request: .init(diskSizeBytes: Self.gb(16)),
                limits: limits)
        }
        // The same size is not a shrink, so it is allowed and does nothing.
        #expect(try VmctlCLI.resizedConfig(
            config(diskGb: 32), request: .init(diskSizeBytes: Self.gb(32)),
            limits: limits).diskSizeBytes == Self.gb(32))
    }

    @Test func theShrinkMessageNamesBothSizes() {
        do {
            _ = try VmctlCLI.resizedConfig(
                config(diskGb: 64), request: .init(diskSizeBytes: Self.gb(32)),
                limits: limits)
            Issue.record("expected a shrink to be refused")
        } catch let error as VmctlError {
            #expect(error.message.contains("64 GB"))
            #expect(error.message.contains("32 GB"))
        } catch {
            Issue.record("unexpected error \(error)")
        }
    }

    // MARK: option parsing

    @Test func gigabyteOptionsTakeWholePositiveNumbersOnly() throws {
        let bag = ArgumentBag(["--disk-size", "64"], flagNames: [])
        #expect(try VmctlCLI.gigabyteOption(bag, "disk-size") == Self.gb(64))
        #expect(try VmctlCLI.gigabyteOption(bag, "memory") == nil)

        for bad in ["0", "-4", "2.5", "64GB", ""] {
            let badBag = ArgumentBag(["--disk-size", bad], flagNames: [])
            #expect(throws: VmctlError.self, "\(bad)") {
                try VmctlCLI.gigabyteOption(badBag, "disk-size")
            }
        }
    }

    // MARK: the command

    @Test func growsTheImageAndSavesTheConfig() throws {
        var vm = config(diskGb: 1)
        try store.saveConfig(vm)
        try store.createDiskImage(at: store.diskPath(vm.name), sizeBytes: Self.gb(1))

        try VmctlCLI.resize(store, ["--name", "dev", "--disk-size", "2", "--cpus", "4"])

        vm = try store.loadConfig("dev")
        #expect(vm.diskSizeBytes == Self.gb(2))
        #expect(vm.cpus == 4)
        #expect(vm.memoryBytes == Self.gb(4))
        // The file itself, not only the number in the config: a config that
        // promises more than the image holds is what the guest trips over.
        #expect(store.fileSize(store.diskPath("dev")) == Self.gb(2))
    }

    @Test func aRunningVmIsRefusedAndNothingChanges() throws {
        let vm = config()
        try store.saveConfig(vm)
        try FileManager.default.createDirectory(
            at: store.runDir(vm.name), withIntermediateDirectories: true)
        // This process is alive by definition, so the store reads it as
        // running.
        try String(ProcessInfo.processInfo.processIdentifier)
            .write(to: store.pidPath(vm.name), atomically: true, encoding: .utf8)

        #expect(throws: VmctlError.self) {
            try VmctlCLI.resize(store, ["--name", "dev", "--cpus", "4"])
        }
        #expect(try store.loadConfig("dev").cpus == 2)
    }

    @Test func aRefusedResizeLeavesTheImageAlone() throws {
        let vm = config(diskGb: 2)
        try store.saveConfig(vm)
        try store.createDiskImage(at: store.diskPath(vm.name), sizeBytes: Self.gb(2))

        #expect(throws: VmctlError.self) {
            try VmctlCLI.resize(store, ["--name", "dev", "--disk-size", "1"])
        }
        #expect(store.fileSize(store.diskPath("dev")) == Self.gb(2))
        #expect(try store.loadConfig("dev").diskSizeBytes == Self.gb(2))
    }

    @Test func anImportedVmIsMeasuredByItsImageNotItsConfig() throws {
        // `import` saves diskSizeBytes: 0 and copies in an image of whatever
        // size it was handed. Judging a grow by the config alone would call
        // 4 GB a grow over an 8 GB image, do nothing to the file, and write
        // the smaller number over it.
        var vm = config("imported", diskGb: 32)
        vm.diskSizeBytes = 0
        try store.saveConfig(vm)
        try store.createDiskImage(at: store.diskPath("imported"), sizeBytes: Self.gb(8))

        #expect(throws: VmctlError.self) {
            try VmctlCLI.resize(store, ["--name", "imported", "--disk-size", "4"])
        }
        #expect(store.fileSize(store.diskPath("imported")) == Self.gb(8))

        // A resize that leaves the disk alone still repairs the placeholder,
        // so the config stops understating the image.
        try VmctlCLI.resize(store, ["--name", "imported", "--cpus", "4"])
        #expect(try store.loadConfig("imported").diskSizeBytes == Self.gb(8))

        // And a real grow is measured from the image.
        try VmctlCLI.resize(store, ["--name", "imported", "--disk-size", "16"])
        #expect(store.fileSize(store.diskPath("imported")) == Self.gb(16))
        #expect(try store.loadConfig("imported").diskSizeBytes == Self.gb(16))
    }

    @Test func anUnknownVmIsReportedRatherThanCreated() {
        #expect(throws: VmctlError.self) {
            try VmctlCLI.resize(store, ["--name", "nope", "--cpus", "2"])
        }
        #expect(!store.exists("nope"))
    }

    // MARK: who grows the filesystem

    @Test func onlyASeededLinuxGuestGrowsItsOwnFilesystem() throws {
        let linux = config("seeded")
        try store.saveConfig(linux)
        #expect(!VmctlCLI.guestGrowsItself(store, linux))

        // cloud-init's growpart is what does it, and it arrives on the seed.
        try Data().write(to: store.seedIsoPath("seeded"))
        #expect(VmctlCLI.guestGrowsItself(store, linux))

        let mac = config("mac", os: .macos)
        try store.saveConfig(mac)
        try Data().write(to: store.seedIsoPath("mac"))
        #expect(!VmctlCLI.guestGrowsItself(store, mac))
    }

    @Test func sizeLabelsReadTheWayTheyAreTyped() {
        #expect(VmctlCLI.sizeLabel(Self.gb(64)) == "64 GB")
        #expect(VmctlCLI.sizeLabel(Self.gb(1)) == "1 GB")
        #expect(VmctlCLI.sizeLabel(Self.gb(1) + Self.gb(1) / 2) == "1.5 GB")
        // The framework's own memory minimum is 128 MB; as gigabytes it
        // rounds to "0.0 GB" and the message it lands in says nothing.
        #expect(VmctlCLI.sizeLabel(128 * 1024 * 1024) == "128 MB")
    }
}
