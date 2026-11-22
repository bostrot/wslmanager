import Foundation
import Testing
@testable import VMCtlKit

/// Host directories shared into a guest (bostrot/ai-tasks#79): the config
/// edits behind `mount`/`unmount`, the tags the devices carry, and the script
/// the daemon runs in a Linux guest to make the shares appear.
@Suite struct MountTests {
    let tempRoot: URL
    let store: VMStore
    let hostDir: URL

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-mounts-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = VMStore(root: tempRoot, hostSshDir: tempRoot.appendingPathComponent("ssh"))
        hostDir = tempRoot.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: hostDir, withIntermediateDirectories: true)
    }

    func linuxConfig(mounts: [VMMount]? = nil) -> VMConfig {
        VMConfig(
            name: "dev", os: .linux, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "dev", macAddress: "aa:bb:cc:dd:ee:01", mounts: mounts)
    }

    // MARK: guest path rules

    @Test func guestPathsAreAbsolutePlainAndOutsideTheSystem() {
        #expect(isValidGuestMountPath("/mnt/project"))
        #expect(isValidGuestMountPath("/home/dev/src-2.0_x"))
        #expect(isValidGuestMountPath("/work"))
        #expect(!isValidGuestMountPath("mnt/project"))
        #expect(!isValidGuestMountPath("/mnt/project/"))
        #expect(!isValidGuestMountPath("/mnt//project"))
        #expect(!isValidGuestMountPath("/mnt/../etc"))
        #expect(!isValidGuestMountPath("/mnt/./x"))
        #expect(!isValidGuestMountPath("/mnt/has space"))
        #expect(!isValidGuestMountPath("/mnt/it's"))
        #expect(!isValidGuestMountPath("/"))
        #expect(!isValidGuestMountPath("/etc"))
        #expect(!isValidGuestMountPath("/usr"))
        // Below a system directory is fine; only the directory itself is not.
        #expect(isValidGuestMountPath("/usr/local/share/project"))
        #expect(!isValidGuestMountPath("/" + String(repeating: "a", count: 300)))
    }

    @Test func shareNamesFollowTheVmNameRule() throws {
        let config = VMConfig(
            name: "mac", os: .macos, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "user", macAddress: "aa:bb:cc:dd:ee:03")
        #expect(try VmctlCLI.normalizedGuestTarget("my-project_2.0", os: .macos) == "my-project_2.0")
        for bad in ["", "a/b", "..", ".hidden", "has space"] {
            #expect(throws: VmctlError.self, "\(bad)") {
                try VmctlCLI.normalizedGuestTarget(bad, os: config.os)
            }
        }
    }

    // MARK: tags and fstab

    @Test func tagsFillTheLowestFreeNumber() {
        #expect(GuestMounts.nextTag(existing: []) == "wslm0")
        let taken = [
            VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: false, tag: "wslm0"),
            VMMount(hostPath: "/c", guestPath: "/mnt/c", readOnly: false, tag: "wslm2"),
        ]
        #expect(GuestMounts.nextTag(existing: taken) == "wslm1")
    }

    @Test func fstabLinesNeverFailTheBootAndCarryReadOnly() {
        let rw = VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: false, tag: "wslm0")
        let ro = VMMount(hostPath: "/b", guestPath: "/mnt/b", readOnly: true, tag: "wslm1")
        #expect(GuestMounts.fstabLine(rw) == "wslm0 /mnt/a virtiofs defaults,nofail 0 0")
        #expect(GuestMounts.fstabLine(ro) == "wslm1 /mnt/b virtiofs defaults,nofail,ro 0 0")
    }

    @Test func syncScriptRewritesTheBlockMountsEachShareAndDropsStaleOnes() {
        let mounts = [
            VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: false, tag: "wslm0"),
            VMMount(hostPath: "/b", guestPath: "/srv/b", readOnly: true, tag: "wslm3"),
        ]
        let script = GuestMounts.syncScript(mounts)
        #expect(script.hasPrefix("#!/bin/sh\n"))
        // The old block goes, whatever it held, before the new one is added.
        #expect(script.contains("sed '/^# >>> wslmanager mounts >>>$/,/^# <<< wslmanager mounts <<<$/d'"))
        #expect(script.contains("  echo '# >>> wslmanager mounts >>>'\n  echo 'wslm0 /mnt/a virtiofs defaults,nofail 0 0'\n  echo 'wslm3 /srv/b virtiofs defaults,nofail,ro 0 0'\n  echo '# <<< wslmanager mounts <<<'\n"))
        // Only our own tags are ever unmounted, and only those not mounted
        // exactly as configured: tag, place and mode all have to match,
        // since a reused tag or a flipped read-only would otherwise leave
        // the boot-time mount from an older fstab in place.
        #expect(script.contains("keep=' wslm0@/mnt/a@rw wslm3@/srv/b@ro '"))
        #expect(script.contains("*\" $tag@$dir@$mode \"*) ;;"))
        #expect(script.contains("wslm[0-9]*)"))
        #expect(script.contains("umount \"$dir\""))
        // Each share is mounted once, read-only where asked, with a mount
        // point made first; a failure is reported, not fatal.
        #expect(script.contains("mkdir -p '/mnt/a'\nmountpoint -q '/mnt/a' || mount -t virtiofs -o rw wslm0 '/mnt/a' || echo 'WSLMANAGER_MOUNT_FAILED wslm0 /mnt/a'"))
        #expect(script.contains("mkdir -p '/srv/b'\nmountpoint -q '/srv/b' || mount -t virtiofs -o ro wslm3 '/srv/b' || echo 'WSLMANAGER_MOUNT_FAILED wslm3 /srv/b'"))
        // `nofail` is an fstab word; on the command line busybox would hand
        // it to the kernel and fail the mount.
        #expect(!script.contains("-o nofail"))
        #expect(!script.contains("-o rw,nofail"))
    }

    @Test func syncScriptWithNoSharesStillCleansTheGuest() {
        let script = GuestMounts.syncScript([])
        #expect(script.contains("sed '/^# >>> wslmanager mounts >>>$/"))
        // Nothing to append, so no block is written back.
        #expect(!script.contains("echo '# >>> wslmanager mounts >>>'"))
        #expect(script.contains("keep='  '"))
        #expect(!script.contains("mount -t virtiofs"))
    }

    @Test func mountFailuresAreReadOffTheScriptOutput() {
        let output = "something else\nWSLMANAGER_MOUNT_FAILED wslm1 /mnt/b\n  WSLMANAGER_MOUNT_FAILED wslm2 /srv/c\n"
        #expect(GuestMounts.failures(in: output) == ["wslm1 /mnt/b", "wslm2 /srv/c"])
        #expect(GuestMounts.failures(in: "") == [])

        #expect(VmctlCLI.syncOutcome(output: "", skipped: []).state == "applied")
        let partial = VmctlCLI.syncOutcome(
            output: output,
            skipped: [VMMount(hostPath: "/gone", guestPath: "/mnt/g", readOnly: false, tag: "wslm0")])
        #expect(partial.state == "partial")
        #expect(partial.error == "host directory missing: /gone; could not mount wslm1 /mnt/b; could not mount wslm2 /srv/c")
    }

    @Test func remoteCommandCarriesTheScriptAsBase64() {
        let mounts = [VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: false, tag: "wslm0")]
        let remote = GuestMounts.remoteCommand(mounts)
        #expect(remote.hasPrefix("printf %s "))
        #expect(remote.hasSuffix(" | base64 -d | sh"))
        let payload = remote.dropFirst("printf %s ".count).dropLast(" | base64 -d | sh".count)
        let decoded = String(data: Data(base64Encoded: String(payload))!, encoding: .utf8)
        #expect(decoded == GuestMounts.syncScript(mounts))
    }

    // MARK: config edits

    @Test func addingAShareAllocatesATagAndReplacingKeepsIt() throws {
        var config = linuxConfig()
        config = try VmctlCLI.addingMount(
            to: config, hostPath: hostDir.path, guestTarget: "/mnt/project", readOnly: false)
        #expect(config.mounts == [
            VMMount(hostPath: hostDir.path, guestPath: "/mnt/project", readOnly: false, tag: "wslm0")
        ])
        // Same mount point again: the entry is updated, not doubled.
        config = try VmctlCLI.addingMount(
            to: config, hostPath: hostDir.path, guestTarget: "/mnt/project", readOnly: true)
        #expect(config.mounts?.count == 1)
        #expect(config.mounts?.first?.readOnly == true)
        #expect(config.mounts?.first?.tag == "wslm0")
        // A second share gets the next tag.
        config = try VmctlCLI.addingMount(
            to: config, hostPath: hostDir.path, guestTarget: "/srv/other", readOnly: false)
        #expect(config.mounts?.map(\.tag) == ["wslm0", "wslm1"])
    }

    @Test func addingRefusesMissingRelativeOrFileHosts() throws {
        let config = linuxConfig()
        #expect(throws: VmctlError.self) {
            try VmctlCLI.addingMount(
                to: config, hostPath: tempRoot.appendingPathComponent("gone").path,
                guestTarget: "/mnt/x", readOnly: false)
        }
        #expect(throws: VmctlError.self) {
            try VmctlCLI.addingMount(
                to: config, hostPath: "project", guestTarget: "/mnt/x", readOnly: false)
        }
        let file = tempRoot.appendingPathComponent("file.txt")
        try Data().write(to: file)
        #expect(throws: VmctlError.self) {
            try VmctlCLI.addingMount(
                to: config, hostPath: file.path, guestTarget: "/mnt/x", readOnly: false)
        }
    }

    @Test func addingRefusesBadGuestPaths() {
        let config = linuxConfig()
        for bad in ["mnt/x", "/etc", "/mnt/../x", "/mnt/a b", ""] {
            #expect(throws: VmctlError.self, "\(bad)") {
                try VmctlCLI.addingMount(
                    to: config, hostPath: hostDir.path, guestTarget: bad, readOnly: false)
            }
        }
    }

    @Test func removingAShareLeavesTheOthersAndTheirTags() throws {
        var config = linuxConfig(mounts: [
            VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: false, tag: "wslm0"),
            VMMount(hostPath: "/b", guestPath: "/mnt/b", readOnly: false, tag: "wslm1"),
        ])
        config = try VmctlCLI.removingMount(from: config, guestTarget: "/mnt/a")
        #expect(config.mounts == [
            VMMount(hostPath: "/b", guestPath: "/mnt/b", readOnly: false, tag: "wslm1")
        ])
        // Gone already: not an error, and the list is empty rather than nil,
        // so the daemon still cleans the guest.
        config = try VmctlCLI.removingMount(from: config, guestTarget: "/mnt/b")
        config = try VmctlCLI.removingMount(from: config, guestTarget: "/mnt/b")
        #expect(config.mounts == [])
    }

    @Test func aMacosGuestTakesAShareNameEitherWay() throws {
        let config = VMConfig(
            name: "mac", os: .macos, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "user", macAddress: "aa:bb:cc:dd:ee:02")
        let bare = try VmctlCLI.addingMount(
            to: config, hostPath: hostDir.path, guestTarget: "project", readOnly: false)
        #expect(bare.mounts?.first?.guestPath == "project")
        // The path `mounts` reports is accepted back, normalised to the name.
        let reported = try VmctlCLI.addingMount(
            to: bare, hostPath: hostDir.path,
            guestTarget: "/Volumes/My Shared Files/project", readOnly: true)
        #expect(reported.mounts?.count == 1)
        #expect(reported.mounts?.first?.readOnly == true)
        #expect(throws: VmctlError.self) {
            try VmctlCLI.addingMount(
                to: config, hostPath: hostDir.path, guestTarget: "/mnt/project", readOnly: false)
        }
        let json = VmctlCLI.mountsJson(store, reported)
        let listed = json["mounts"] as? [[String: Any]]
        #expect(listed?.first?["guestPath"] as? String == "/Volumes/My Shared Files/project")
        #expect(json["os"] as? String == "macos")
    }

    @Test func mountsJsonNamesEveryShareAndTheGuestState() throws {
        let config = linuxConfig(mounts: [
            VMMount(hostPath: "/a", guestPath: "/mnt/a", readOnly: true, tag: "wslm0")
        ])
        try store.saveConfig(config)
        var json = VmctlCLI.mountsJson(store, config)
        #expect(json["name"] as? String == "dev")
        #expect(json["running"] as? Bool == false)
        let listed = json["mounts"] as? [[String: Any]]
        #expect(listed?.count == 1)
        #expect(listed?.first?["hostPath"] as? String == "/a")
        #expect(listed?.first?["guestPath"] as? String == "/mnt/a")
        #expect(listed?.first?["readOnly"] as? Bool == true)
        #expect(listed?.first?["tag"] as? String == "wslm0")
        // The guest's state only means something while the VM runs.
        store.writeMountStatus("dev", GuestMountStatus(state: "failed", error: "no sshd"))
        json = VmctlCLI.mountsJson(store, config)
        #expect(json["guest"] == nil)
        try store.writePid("dev")
        defer { store.clearPid("dev") }
        json = VmctlCLI.mountsJson(store, config)
        let guest = json["guest"] as? [String: Any]
        #expect(guest?["state"] as? String == "failed")
        #expect(guest?["error"] as? String == "no sshd")
    }

    @Test func mountsSurviveAConfigRoundTripAndOldConfigsReadAsNil() throws {
        let config = linuxConfig(mounts: [
            VMMount(hostPath: "/Users/eric/proj", guestPath: "/mnt/proj", readOnly: false, tag: "wslm0")
        ])
        try store.saveConfig(config)
        #expect(try store.loadConfig("dev").mounts == config.mounts)

        let old = #"""
        {"createdAt":"2026-01-02T03:04:05Z","cpus":1,"diskSizeBytes":1,
         "macAddress":"aa:aa:aa:aa:aa:af","memoryBytes":1,"name":"old",
         "os":"linux","user":"dev"}
        """#
        try FileManager.default.createDirectory(
            at: store.vmDir("old"), withIntermediateDirectories: true)
        try old.write(to: store.configPath("old"), atomically: true, encoding: .utf8)
        #expect(try store.loadConfig("old").mounts == nil)
    }

    @Test func mountStatusRoundTrips() {
        #expect(store.readMountStatus("dev") == nil)
        store.writeMountStatus("dev", GuestMountStatus(state: "applied"))
        #expect(store.readMountStatus("dev")?.state == "applied")
        #expect(store.readMountStatus("dev")?.error == nil)
    }

    @Test func editingARunningGuestsSharesMarksItsStatusOutdated() throws {
        try store.saveConfig(linuxConfig(mounts: []))
        store.writeMountStatus("dev", GuestMountStatus(state: "applied"))
        try store.writePid("dev")
        defer { store.clearPid("dev") }
        let bag = ArgumentBag(
            ["--name", "dev", "--host", hostDir.path, "--guest", "/mnt/p"], flagNames: [])
        try VmctlCLI.editMounts(store, bag) { config in
            try VmctlCLI.addingMount(
                to: config, hostPath: hostDir.path, guestTarget: "/mnt/p", readOnly: false)
        }
        #expect(try store.loadConfig("dev").mounts?.map(\.guestPath) == ["/mnt/p"])
        #expect(store.readMountStatus("dev")?.state == "outdated")
    }

    @Test func anEntryWithoutReadOnlyStillDecodes() throws {
        let json = #"{"hostPath":"/a","guestPath":"/mnt/a","tag":"wslm0"}"#
        let mount = try JSONDecoder().decode(VMMount.self, from: Data(json.utf8))
        #expect(mount.readOnly == false)
        #expect(mount.tag == "wslm0")
    }

    @Test func aMissingHostDirectoryIsSkippedNotFatal() {
        let config = linuxConfig(mounts: [
            VMMount(hostPath: hostDir.path, guestPath: "/mnt/a", readOnly: false, tag: "wslm0"),
            VMMount(hostPath: tempRoot.appendingPathComponent("gone").path,
                    guestPath: "/mnt/b", readOnly: false, tag: "wslm1"),
        ])
        #expect(VMFactory.presentMounts(config).map(\.tag) == ["wslm0"])
    }
}
