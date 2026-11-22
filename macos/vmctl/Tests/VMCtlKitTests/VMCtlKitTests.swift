import Foundation
import Testing
@testable import VMCtlKit

@Suite struct VMNameTests {
    @Test func validNames() {
        #expect(isValidVmName("ubuntu"))
        #expect(isValidVmName("my-vm_2.0"))
        #expect(!(isValidVmName("")))
        #expect(!(isValidVmName(".hidden")))
        #expect(!(isValidVmName("has space")))
        #expect(!(isValidVmName("../escape")))
        #expect(!(isValidVmName(String(repeating: "a", count: 65))))
    }
}

@Suite struct DHCPLeasesTests {
    @Test func parsesLeaseBlocks() {
        let sample = """
        {
        \tname=ubuntu
        \tip_address=192.168.64.5
        \thw_address=1,aa:bb:cc:d:ee:ff
        \tidentifier=1,aa:bb:cc:d:ee:ff
        \tlease=0x66aa
        }
        {
        \tname=other
        \tip_address=192.168.64.9
        \thw_address=1,11:22:33:44:55:66
        }
        """
        let leases = DHCPLeases.parse(sample)
        // Octets are zero-padded on the way in.
        #expect(leases["aa:bb:cc:0d:ee:ff"] == "192.168.64.5")
        #expect(leases["11:22:33:44:55:66"] == "192.168.64.9")
    }

    @Test func rfc4361IdentifierMatchesByMacSuffix() {
        // Alpine's dhcpcd sends a DUID client-id; macOS records it as a long
        // hw_address whose final six octets are the interface MAC.
        let sample = """
        {
        	name=alpine
        	ip_address=192.168.64.3
        	hw_address=ff,d1:c1:6c:8e:0:1:0:1:32:29:d4:58:ea:fd:d1:c1:6c:8e
        }
        {
        	name=plain
        	ip_address=192.168.64.9
        	hw_address=1,ea:fd:d1:c1:6c:8e
        }
        """
        // The exact-MAC lease outranks the DUID one when both exist.
        #expect(DHCPLeases.ipForMac("EA:FD:D1:C1:6C:8E", in: sample) == "192.168.64.9")
        // With only the DUID lease present, the suffix match resolves it.
        let duidOnly = sample.components(separatedBy: "{").prefix(2).joined(separator: "{")
        #expect(DHCPLeases.ipForMac("EA:FD:D1:C1:6C:8E", in: duidOnly) == "192.168.64.3")
        // A MAC that merely shares trailing octets must not match.
        #expect(DHCPLeases.ipForMac("00:00:d1:c1:6c:8e", in: duidOnly) == nil)
    }

    @Test func networkdDuidLeaseResolvesByHostname() {
        // systemd-networkd's default DUID is machine-id-derived: the MAC
        // appears nowhere in the lease, so the hostname (pinned to the VM
        // name by the seed) is the only key left.
        let sample = """
        {
        	name=dtest
        	ip_address=192.168.64.10
        	hw_address=ff,f1:f5:dd:7f:0:2:0:0:ab:11:e5:db:f0:13:5d:b2:72:c8
        }
        """
        #expect(DHCPLeases.ipFor(
            mac: "fa:38:02:78:c3:e1", hostname: "dtest", in: sample)
            == "192.168.64.10")
        #expect(DHCPLeases.ipFor(
            mac: "fa:38:02:78:c3:e1", hostname: "other", in: sample) == nil)
        #expect(DHCPLeases.ipFor(
            mac: "fa:38:02:78:c3:e1", in: sample) == nil)
    }

    @Test func expiredLeaseIsNotAnAddress() {
        // Seen on a real host: the guest got 192.168.64.21 at boot, never
        // renewed, and bootpd kept the block on file for days. `list`
        // showed the address, ARP said "incomplete", ssh dialled it anyway.
        let sample = """
        {
        	name=ai-workspace
        	ip_address=192.168.64.21
        	hw_address=1,96:93:65:58:99:14
        	identifier=1,96:93:65:58:99:14
        	lease=0x6a9b25a0
        }
        """
        let expiry = Date(timeIntervalSince1970: 0x6a9b25a0)
        let mac = "96:93:65:58:99:14"
        #expect(DHCPLeases.ipFor(
            mac: mac, hostname: "ai-workspace", in: sample,
            now: expiry.addingTimeInterval(-60)) == "192.168.64.21")
        #expect(DHCPLeases.ipFor(
            mac: mac, hostname: "ai-workspace", in: sample,
            now: expiry.addingTimeInterval(60)) == nil)
        // Neither the DUID-suffix nor the hostname path may revive it.
        let duid = sample.replacingOccurrences(
            of: "1,96:93:65:58:99:14",
            with: "ff,57:82:9b:d0:0:1:0:1:32:2c:86:78:96:93:65:58:99:14")
        #expect(DHCPLeases.ipFor(
            mac: mac, hostname: "ai-workspace", in: duid,
            now: expiry.addingTimeInterval(60)) == nil)
    }

    @Test func expiredLeaseYieldsToACurrentOne() {
        // A guest that rebooted gets a fresh block; the stale one for the
        // same MAC must not shadow it whichever order bootpd wrote them.
        let sample = """
        {
        	name=box
        	ip_address=192.168.64.30
        	hw_address=1,aa:bb:cc:dd:ee:ff
        	lease=0x1000
        }
        {
        	name=box
        	ip_address=192.168.64.31
        	hw_address=1,aa:bb:cc:dd:ee:ff
        	lease=0x3000
        }
        """
        let now = Date(timeIntervalSince1970: 0x2000)
        #expect(DHCPLeases.ipFor(mac: "aa:bb:cc:dd:ee:ff", in: sample, now: now)
            == "192.168.64.31")
    }

    @Test func leaseWithoutExpiryStaysValid() {
        // No `lease=` line (older files, hand-written fixtures) and an
        // unparseable one both mean "unknown", never "expired".
        let sample = """
        {
        	ip_address=192.168.64.40
        	hw_address=1,aa:bb:cc:dd:ee:01
        }
        {
        	ip_address=192.168.64.41
        	hw_address=1,aa:bb:cc:dd:ee:02
        	lease=soon
        }
        """
        let now = Date(timeIntervalSince1970: 4_000_000_000)
        #expect(DHCPLeases.ipFor(mac: "aa:bb:cc:dd:ee:01", in: sample, now: now)
            == "192.168.64.40")
        #expect(DHCPLeases.ipFor(mac: "aa:bb:cc:dd:ee:02", in: sample, now: now)
            == "192.168.64.41")
        #expect(DHCPLeases.parseExpiry("0x6a9b25a0")
            == Date(timeIntervalSince1970: 0x6a9b25a0))
        #expect(DHCPLeases.parseExpiry("garbage") == nil)
    }

    @Test func normalizeMacPadsAndLowercases() {
        #expect(DHCPLeases.normalizeMac("AA:B:1:22:3:F") == "aa:0b:01:22:03:0f")
    }

    @Test func lookupUsesNormalizedMac() {
        let sample = "{\nip_address=10.0.0.2\nhw_address=1,a:b:c:d:e:f\n}"
        let leases = DHCPLeases.parse(sample)
        #expect(leases[DHCPLeases.normalizeMac("0A:0B:0C:0D:0E:0F")] == "10.0.0.2")
    }
}

@Suite struct CloudInitTests {
    @Test func userDataContainsUserAndKey() {
        let text = CloudInit.userData(
            user: "eric", publicKeys: ["ssh-ed25519 AAAA test"], hostname: "dev")
        #expect(text.hasPrefix("#cloud-config"))
        #expect(text.contains("name: eric"))
        #expect(text.contains("ssh-ed25519 AAAA test"))
        #expect(text.contains("hostname: dev"))
        #expect(text.contains("NOPASSWD:ALL"))
    }

    @Test func everyAuthorizedKeyReachesTheUserAndRoot() {
        let store = "ssh-ed25519 AAAA store"
        let host = "ssh-ed25519 AAAA eric@mac"
        let text = CloudInit.userData(
            user: "eric", publicKeys: [store, host], hostname: "dev")
        // Once under the user's block (six spaces) and once at the top level
        // for root (two) — the Mac user's own key included, which is what
        // makes `ssh eric@<ip>` work from their Terminal.
        #expect(text.contains("      - \(store)\n      - \(host)\n"))
        #expect(text.contains("\nssh_authorized_keys:\n  - \(store)\n  - \(host)\n"))
    }

    @Test func withoutAPasswordTheAccountStaysLockedAsBefore() {
        let text = CloudInit.userData(
            user: "eric", publicKeys: ["k"], hostname: "dev")
        #expect(text.contains("lock_passwd: true"))
        #expect(text.contains("    - name: eric\n      password: \"*\"\n      type: hash"))
    }

    @Test func aPasswordUnlocksTheConsoleLoginButNotSsh() {
        let text = CloudInit.userData(
            user: "eric", publicKeys: ["k"], hostname: "dev", password: "Abc23xyz")
        // The account has to be unlocked or the console login prompt can
        // never be satisfied, however right the password is.
        #expect(text.contains("lock_passwd: false"))
        #expect(text.contains("    - name: eric\n      password: \"Abc23xyz\"\n      type: text"))
        // root keeps no password at all, and SSH stays key-only.
        #expect(text.contains("    - name: root\n      password: \"*\"\n      type: hash"))
        #expect(text.contains("ssh_pwauth: false"))
    }

    @Test func generatedPasswordsAreTypeableAndUnrepeated() {
        let first = generateGuestPassword()
        #expect(first.count == 20)
        // Nothing that needs YAML quoting, and none of the glyph pairs that
        // are a coin flip in a console font.
        #expect(first.allSatisfy { $0.isLetter || $0.isNumber })
        #expect(!first.contains(where: { "01lIO".contains($0) }))
        #expect(first != generateGuestPassword())
    }

    @Test func onlyNonRootAccountsTakeAPassword() {
        #expect(guestTakesPassword(user: "eric"))
        #expect(!guestTakesPassword(user: "root"))
        #expect(!guestTakesPassword(user: ""))
    }

    @Test func metaDataCarriesInstanceId() {
        let text = CloudInit.metaData(hostname: "dev")
        #expect(text.contains("instance-id: iid-dev"))
        #expect(text.contains("local-hostname: dev"))
    }

    @Test func withoutACustomDocumentTheSeedIsTheOwnCloudConfigAlone() {
        let text = CloudInit.seedUserData(
            user: "eric", publicKeys: ["k"], hostname: "dev", customUserData: nil)
        #expect(text.hasPrefix("#cloud-config"))
        #expect(!text.contains("multipart"))
        // Whitespace is no document either.
        let blank = CloudInit.seedUserData(
            user: "eric", publicKeys: ["k"], hostname: "dev", customUserData: "  \n")
        #expect(blank == text)
    }

    @Test func aCustomDocumentRidesFirstInAMultipartSeed() {
        let custom = "#cloud-config\npackages:\n  - git\n"
        let text = CloudInit.multipartUserData(
            custom: custom,
            seed: CloudInit.userData(user: "eric", publicKeys: ["k"], hostname: "dev"),
            boundary: "==B==")
        #expect(text.hasPrefix("Content-Type: multipart/mixed; boundary=\"==B==\"\nMIME-Version: 1.0\n\n--==B==\n"))
        // The caller's part comes first and untyped, so cloud-init reads
        // its kind off the first line exactly as it would a bare file.
        let customStart = text.range(of: "Content-Type: text/plain; charset=\"utf-8\"")!
        let ownStart = text.range(of: "Content-Type: text/cloud-config")!
        #expect(customStart.lowerBound < ownStart.lowerBound)
        #expect(text.contains("\n\n#cloud-config\npackages:\n  - git\n--==B==\n"))
        // vmctl's part names how it merges: nothing the caller wrote is
        // replaced, and the lists are appended to theirs.
        #expect(text.contains("Merge-Type: list(append)+dict(no_replace,recurse_array)+str()\n\n#cloud-config\nhostname: dev\n"))
        // Last, and replacing: whatever the caller wrote, SSH stays
        // key-only and root keeps the store's key.
        let pinsStart = text.range(of: "Merge-Type: list()+dict(replace)+str()\n\n#cloud-config\nssh_pwauth: false\ndisable_root: false\n")!
        #expect(ownStart.lowerBound < pinsStart.lowerBound)
        #expect(text.hasSuffix("disable_root: false\n--==B==--\n"))
    }

    @Test func aDocumentWithoutATrailingNewlineStillClosesItsPart() {
        let text = CloudInit.multipartUserData(
            custom: "#!/bin/sh\necho hi", seed: "#cloud-config\nhostname: x", boundary: "==B==")
        #expect(text.contains("echo hi\n--==B==\n"))
        #expect(text.contains("hostname: x\n--==B==\n"))
    }

    @Test func customUserDataIsReadBeforeAnythingIsCreated() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-userdata-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String, _ body: String) throws -> String {
            let url = dir.appendingPathComponent(name)
            try body.write(to: url, atomically: true, encoding: .utf8)
            return url.path
        }
        #expect(try VmctlCLI.readCustomUserData(at: try write("ok.yaml", "#cloud-config\npackages: [git]\n"))
            == "#cloud-config\npackages: [git]\n")
        #expect(try VmctlCLI.readCustomUserData(at: try write("script.sh", "#!/bin/sh\necho hi\n"))
            .hasPrefix("#!/bin/sh"))
        // Leading blank lines are fine; cloud-init strips them too.
        #expect(try VmctlCLI.readCustomUserData(at: try write("lead.yaml", "\n\n#cloud-config\n"))
            .hasSuffix("#cloud-config\n"))
        #expect(throws: VmctlError.self) {
            try VmctlCLI.readCustomUserData(at: dir.appendingPathComponent("missing").path)
        }
        #expect(throws: VmctlError.self) {
            try VmctlCLI.readCustomUserData(at: try write("empty.yaml", "   \n"))
        }
        // The header is the app's check, not vmctl's: a document it did not
        // write is passed through as it is.
        #expect(try VmctlCLI.readCustomUserData(at: try write("plain.txt", "packages: [git]\n"))
            == "packages: [git]\n")
    }

    @Test func userDataRunsTheGettyFixEveryBoot() {
        let text = CloudInit.userData(
            user: "eric", publicKeys: ["ssh-ed25519 AAAA test"], hostname: "dev")
        // bootcmd, not runcmd: the flood starts long before the final stage.
        #expect(text.contains("bootcmd:\n  - |\n"))
        // Indented into the block scalar, or the YAML does not parse.
        #expect(text.contains("\n    vmctl_fix_gettys() {\n"))
        #expect(text.contains("\n    vmctl_fix_gettys\n"))
    }

    /// Runs the guest-side script against a fixture — its own inittab, its
    /// own "/dev", and no init to signal — and returns the inittab after.
    private func runGettyFix(inittab: String, devices: [String]) throws -> String {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("vmctl-getty-\(UUID().uuidString)")
        let devDir = dir.appendingPathComponent("dev")
        try fm.createDirectory(at: devDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        for device in devices {
            fm.createFile(atPath: devDir.appendingPathComponent(device).path, contents: nil)
        }
        let inittabURL = dir.appendingPathComponent("inittab")
        try inittab.write(to: inittabURL, atomically: true, encoding: .utf8)
        let scriptURL = dir.appendingPathComponent("fix.sh")
        try CloudInit.consoleGettyFixScript
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.environment = [
            "WSLMANAGER_INITTAB": inittabURL.path,
            "WSLMANAGER_DEV": devDir.path,
            // Empty on purpose: nothing may HUP the *host's* pid 1.
            "WSLMANAGER_INIT_PID": "",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        return try String(contentsOf: inittabURL, encoding: .utf8)
    }

    @Test func gettyFixDisablesTtysTheMachineLacks() throws {
        let result = try runGettyFix(
            inittab: """
            ::sysinit:/sbin/openrc sysinit
            tty1::respawn:/sbin/getty 38400 tty1
            ttyAMA0::respawn:/sbin/getty -L 0 ttyAMA0 vt100
            ttyS0::respawn:/sbin/getty -L 0 ttyS0 vt100

            """,
            devices: ["tty1", "hvc0"])

        // The two serial gettys VZ cannot back are out...
        #expect(result.contains("\n#ttyAMA0::respawn:"))
        #expect(result.contains("\n#ttyS0::respawn:"))
        // ...the console that does exist keeps its getty, and hvc0 gains one.
        #expect(result.contains("\ntty1::respawn:/sbin/getty 38400 tty1\n"))
        #expect(result.contains("\nhvc0::respawn:/sbin/getty -L 0 hvc0 vt100\n"))
        // Non-getty lines are none of its business.
        #expect(result.contains("::sysinit:/sbin/openrc sysinit"))
    }

    @Test func gettyFixLeavesAnAlreadyGoodInittabAlone() throws {
        // Second boot: nothing to comment out twice, no duplicate hvc0 line.
        let inittab = """
        tty1::respawn:/sbin/getty 38400 tty1
        #ttyAMA0::respawn:/sbin/getty -L 0 ttyAMA0 vt100
        hvc0::respawn:/sbin/getty -L 0 hvc0 vt100

        """
        let result = try runGettyFix(inittab: inittab, devices: ["tty1", "hvc0"])
        #expect(result == inittab)
    }

    @Test func gettyFixAddsNothingToAnInittabNothingReads() throws {
        // A systemd guest can still carry a leftover /etc/inittab. It runs no
        // getty from it, so a busybox line there would only be litter.
        let inittab = """
        # Legacy file, kept by the distro and read by nothing.
        id:5:initdefault:

        """
        let result = try runGettyFix(inittab: inittab, devices: ["hvc0"])
        #expect(result == inittab)
    }

    @Test func gettyFixIgnoresGuestsWithoutAnInittab() throws {
        // Debian/Ubuntu cloud images are systemd: no inittab to repair, and
        // the script must not invent one.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent("vmctl-getty-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let inittabURL = dir.appendingPathComponent("inittab")
        let scriptURL = dir.appendingPathComponent("fix.sh")
        try CloudInit.consoleGettyFixScript
            .write(to: scriptURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [scriptURL.path]
        process.environment = [
            "WSLMANAGER_INITTAB": inittabURL.path,
            "WSLMANAGER_DEV": dir.path,
            "WSLMANAGER_INIT_PID": "",
        ]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(!fm.fileExists(atPath: inittabURL.path))
    }
}

@Suite final class VMStoreTests {
    let tempRoot: URL
    let hostSshDir: URL
    let store: VMStore

    init() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-tests-\(UUID().uuidString)")
        // Never the real ~/.ssh: these tests generate keys into it.
        hostSshDir = tempRoot.appendingPathComponent("home-ssh")
        store = VMStore(root: tempRoot, hostSshDir: hostSshDir)
        try store.ensureExists()
    }

    deinit {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    @Test func hostKeyIsGeneratedWhenTheMacHasNoneAndReusedAfterwards() throws {
        #expect(!FileManager.default.fileExists(atPath: hostSshDir.path))
        let generated = try #require(store.hostSshPublicKey())
        #expect(generated.hasPrefix("ssh-ed25519 "))
        #expect(generated.hasSuffix("wslmanager"))
        // A second ask reuses it rather than rotating the user's identity.
        #expect(store.hostSshPublicKey() == generated)
        let attrs = try FileManager.default
            .attributesOfItem(atPath: hostSshDir.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)
    }

    @Test func anExistingHostKeyIsUsedUntouched() throws {
        try FileManager.default.createDirectory(
            at: hostSshDir, withIntermediateDirectories: true)
        let mine = "ssh-rsa AAAAB3NzaC1yc2EAAAA mine@mac"
        try mine.write(
            to: hostSshDir.appendingPathComponent("id_rsa.pub"),
            atomically: true, encoding: .utf8)

        #expect(store.hostSshPublicKey() == mine)
        // Nothing was generated over it.
        #expect(!FileManager.default.fileExists(
            atPath: hostSshDir.appendingPathComponent("id_ed25519").path))
    }

    @Test func authorizedKeysPairsTheStoreKeyWithTheHostOne() throws {
        let keys = try store.authorizedKeys()
        #expect(keys.count == 2)
        // The store key first: it is the one exec/shell sign in with.
        #expect(keys[0] == (try store.sshPublicKey()))
        #expect(keys[1] == store.hostSshPublicKey())
        #expect(Set(keys).count == keys.count)
    }

    @Test func aGuestWithoutAReadableHostKeyStillGetsTheStoreKey() throws {
        // A file where ~/.ssh should be: the directory cannot be created and
        // ssh-keygen never runs, but VM creation must not fail over it.
        try Data().write(to: hostSshDir)
        #expect(store.hostSshPublicKey() == nil)
        #expect(try store.authorizedKeys() == [try store.sshPublicKey()])
    }

    @Test func passwordSurvivesAConfigRoundTripAndOldConfigsReadAsNone() throws {
        let config = VMConfig(
            name: "pw", os: .linux, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "dev", password: "Abc23xyz", macAddress: "aa:aa:aa:aa:aa:ae")
        try store.saveConfig(config)
        #expect(try store.loadConfig("pw").password == "Abc23xyz")

        // A config.json written before passwords existed has no such key.
        let old = #"""
        {"createdAt":"2026-01-02T03:04:05Z","cpus":1,"diskSizeBytes":1,
         "macAddress":"aa:aa:aa:aa:aa:af","memoryBytes":1,"name":"old",
         "os":"linux","user":"dev"}
        """#
        try FileManager.default.createDirectory(
            at: store.vmDir("old"), withIntermediateDirectories: true)
        try old.write(to: store.configPath("old"), atomically: true, encoding: .utf8)
        #expect(try store.loadConfig("old").password == nil)
    }

    @Test func configRoundTrip() throws {
        let config = VMConfig(
            name: "trip", os: .linux, cpus: 3,
            memoryBytes: 2_147_483_648, diskSizeBytes: 1_073_741_824,
            user: "dev", macAddress: "aa:bb:cc:dd:ee:ff")
        try store.saveConfig(config)
        let loaded = try store.loadConfig("trip")
        #expect(loaded.name == config.name)
        #expect(loaded.os == .linux)
        #expect(loaded.cpus == 3)
        #expect(loaded.memoryBytes == 2_147_483_648)
        #expect(loaded.user == "dev")
        #expect(loaded.macAddress == "aa:bb:cc:dd:ee:ff")
    }

    @Test func missingConfigThrows() {
        #expect(throws: (any Error).self) { try store.loadConfig("nope") }
    }

    @Test func allNamesListsOnlyRealVms() throws {
        try store.saveConfig(VMConfig(
            name: "b", os: .linux, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "u", macAddress: "aa:aa:aa:aa:aa:aa"))
        try store.saveConfig(VMConfig(
            name: "a", os: .linux, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "u", macAddress: "aa:aa:aa:aa:aa:ab"))
        // A stray directory without config.json is not a VM.
        try FileManager.default.createDirectory(
            at: tempRoot.appendingPathComponent("junk"),
            withIntermediateDirectories: true)
        #expect(try store.allNames() == ["a", "b"])
    }

    @Test func createDiskImageIsSparseAndGrows() throws {
        let disk = tempRoot.appendingPathComponent("disk.img")
        try store.createDiskImage(at: disk, sizeBytes: 4096 * 10)
        #expect(store.fileSize(disk) == 4096 * 10)
        // Growing keeps content; shrinking never happens.
        try store.createDiskImage(at: disk, sizeBytes: 4096 * 5)
        #expect(store.fileSize(disk) == 4096 * 10)
        try store.createDiskImage(at: disk, sizeBytes: 4096 * 20)
        #expect(store.fileSize(disk) == 4096 * 20)
    }

    @Test func stalePidReadsAsStopped() throws {
        let name = "stale"
        try store.saveConfig(VMConfig(
            name: name, os: .linux, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: "u", macAddress: "aa:aa:aa:aa:aa:ac"))
        try FileManager.default.createDirectory(
            at: store.runDir(name), withIntermediateDirectories: true)
        // A PID that can't exist.
        try "999999".write(to: store.pidPath(name), atomically: true, encoding: .utf8)
        #expect(!(store.isRunning(name)))
        // And the stale file is cleaned up.
        #expect(!(FileManager.default.fileExists(atPath: store.pidPath(name).path)))
    }

    @Test func listEntriesReportsState() throws {
        try store.saveConfig(VMConfig(
            name: "one", os: .linux, cpus: 2, memoryBytes: 1024, diskSizeBytes: 0,
            user: "dev", macAddress: "aa:aa:aa:aa:aa:ad"))
        let entries = try store.listEntries { _ in "10.0.0.9" }
        #expect(entries.count == 1)
        #expect(entries[0].name == "one")
        #expect(entries[0].state == "stopped")
        // The resolver only runs for running VMs.
        #expect(entries[0].ip == nil)
        #expect(entries[0].user == "dev")
    }
}

@Suite struct SshArgumentTests {
    @Test func aShellSessionCarriesNoRemoteCommand() {
        let args = VmctlCLI.sshArguments(key: "/store/id", user: "eric", ip: "10.0.0.2")
        #expect(args.last == "eric@10.0.0.2")
        #expect(!args.contains("--"))
        // Only the store key is offered: a guest with Alpine's default
        // MaxAuthTries disconnects before the right key gets a turn.
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("-i"))
        #expect(args.contains("/store/id"))
    }

    @Test func aRemoteCommandGoesAfterTheDoubleDash() {
        let args = VmctlCLI.sshArguments(
            key: "/store/id", user: "root", ip: "10.0.0.2", remote: ["echo", "hi"])
        let dash = try! #require(args.firstIndex(of: "--"))
        #expect(args[(dash - 1)] == "root@10.0.0.2")
        #expect(Array(args[(dash + 1)...]) == ["echo", "hi"])
    }

    // bostrot/ai-tasks#70: the AI Workspace dashboards bind the guest's
    // loopback, which the Mac cannot dial; the forward is how it gets there.
    @Test func aForwardJoinsBothLoopbacks() {
        let args = VmctlCLI.forwardArguments(
            key: "/store/id", user: "root", ip: "192.168.64.7",
            localPort: 50123, remotePort: 4096)
        let spec = try! #require(args.firstIndex(of: "-L"))
        // Loopback on the Mac side too: a forward bound to every interface
        // would hand an unauthenticated dashboard to the whole LAN.
        #expect(args[spec + 1] == "127.0.0.1:50123:127.0.0.1:4096")
        #expect(args.contains("ExitOnForwardFailure=yes"))
        #expect(args.contains("IdentitiesOnly=yes"))
        let dash = try! #require(args.firstIndex(of: "--"))
        #expect(args[dash - 1] == "root@192.168.64.7")
    }

    @Test func aForwardEndsWithItsStdin() {
        let args = VmctlCLI.forwardArguments(
            key: "/store/id", user: "root", ip: "10.0.0.2",
            localPort: 18789, remotePort: 18789)
        // `-N` would outlive the app that opened it; a remote reader of stdin
        // ends the session when the app's pipe closes.
        #expect(!args.contains("-N"))
        #expect(args.last == "cat >/dev/null")
    }

    @Test func aForwardPortMustBeATcpPort() throws {
        let given = ArgumentBag(["--port", "4096"], flagNames: [])
        #expect(try VmctlCLI.tcpPort(given, "port", default: nil) == 4096)
        // The local port defaults to the remote one.
        #expect(try VmctlCLI.tcpPort(given, "local-port", default: 4096) == 4096)

        for bad in ["0", "65536", "-1", "http"] {
            let bag = ArgumentBag(["--port", bad], flagNames: [])
            #expect(throws: VmctlError.self) {
                try VmctlCLI.tcpPort(bag, "port", default: nil)
            }
        }
        #expect(throws: VmctlError.self) {
            try VmctlCLI.tcpPort(ArgumentBag([], flagNames: []), "port", default: nil)
        }
    }
}

@Suite struct GuestUserTests {
    @Test func acceptsWhatUseraddWould() {
        #expect(isValidGuestUser("user"))
        #expect(isValidGuestUser("_svc"))
        #expect(isValidGuestUser("eric-2"))
    }

    @Test func refusesAnythingThatWouldHaveToBeEscaped() {
        // The name reaches an ssh target, a --user argument and the
        // .command script Terminal opens; none of these are places to
        // discover a quote.
        #expect(!isValidGuestUser(#"x" ; rm -rf /"#))
        #expect(!isValidGuestUser("has space"))
        #expect(!isValidGuestUser("Eric"))
        #expect(!isValidGuestUser("2cool"))
        #expect(!isValidGuestUser(""))
        #expect(!isValidGuestUser(String(repeating: "a", count: 33)))
    }
}

@Suite struct GuestPasswordTests {
    private func config(os: GuestOS, user: String, password: String? = nil) -> VMConfig {
        VMConfig(
            name: "vm", os: os, cpus: 1, memoryBytes: 1, diskSizeBytes: 1,
            user: user, password: password, macAddress: "aa:aa:aa:aa:aa:aa")
    }

    /// The store is only there to satisfy the signature; nothing is read.
    private let store = VMStore(
        root: URL(fileURLWithPath: "/nonexistent"),
        hostSshDir: URL(fileURLWithPath: "/nonexistent/.ssh"))

    @Test func aLinuxGuestWithoutOneGetsAPasswordExactlyOnce() throws {
        var subject = config(os: .linux, user: "eric")
        #expect(try VmctlCLI.ensureGuestPassword(store, &subject))
        let first = try #require(subject.password)
        #expect(!first.isEmpty)
        // Idempotent: asking again must not rotate a password the user has
        // already been shown and the guest has already applied.
        #expect(!(try VmctlCLI.ensureGuestPassword(store, &subject)))
        #expect(subject.password == first)
    }

    @Test func rootAndMacosGuestsAreLeftAlone() throws {
        var asRoot = config(os: .linux, user: "root")
        #expect(!(try VmctlCLI.ensureGuestPassword(store, &asRoot)))
        #expect(asRoot.password == nil)

        var mac = config(os: .macos, user: "eric")
        #expect(!(try VmctlCLI.ensureGuestPassword(store, &mac)))
        #expect(mac.password == nil)
    }
}

@Suite struct ArgumentBagTests {
    @Test func optionsFlagsAndRemainder() {
        let bag = ArgumentBag(
            ["--name", "vm1", "--gui", "--user", "root", "--", "echo", "hi"],
            flagNames: ["gui"])
        #expect(bag.options["name"] == "vm1")
        #expect(bag.options["user"] == "root")
        #expect(bag.flags.contains("gui"))
        #expect(bag.remainder == ["echo", "hi"])
    }

    @Test func requireThrowsWhenMissing() {
        let bag = ArgumentBag([], flagNames: [])
        #expect(throws: (any Error).self) { try bag.require("name") }
    }

    @Test func intFallsBackToDefault() {
        let bag = ArgumentBag(["--cpus", "8", "--memory", "x"], flagNames: [])
        #expect(bag.int("cpus", default: 2) == 8)
        #expect(bag.int("memory", default: 4) == 4)
        #expect(bag.int("disk-size", default: 32) == 32)
    }
}

// Serialized: the long-socket-path fallback chdirs the process, which is
// safe in the daemon (one bind at startup) and the one-shot CLI, but races
// when parallel tests each bind their own relay.
@Suite(.serialized) final class ConsoleRelayTests {
    let dir: URL
    let relay: ConsoleRelay

    init() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("relay-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        relay = try ConsoleRelay(
            socketPath: dir.appendingPathComponent("console.sock").path,
            logPath: dir.appendingPathComponent("serial.log").path)
        relay.start()
    }

    deinit {
        relay.shutdown()
        try? FileManager.default.removeItem(at: dir)
    }

    private func connectClient() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try UnixSocketAddress.connect(fd, to: relay.socketPath)
        return fd
    }

    private func readSome(_ fd: Int32, timeoutMs: Int32 = 2000) -> [UInt8] {
        var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&p, 1, timeoutMs) > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = read(fd, &buffer, buffer.count)
        return count > 0 ? Array(buffer[0..<count]) : []
    }

    @Test func guestOutputReachesClientAndLog() throws {
        let client = try connectClient()
        defer { close(client) }
        Thread.sleep(forTimeInterval: 0.2) // let accept() land

        let payload = Array("login: ".utf8)
        _ = payload.withUnsafeBytes { write(relay.vmSideFd, $0.baseAddress, payload.count) }

        #expect(readSome(client) == payload)
        // The log tee keeps working for the early-exit diagnostics.
        Thread.sleep(forTimeInterval: 0.2)
        let log = try String(
            contentsOf: dir.appendingPathComponent("serial.log"), encoding: .utf8)
        #expect(log.contains("login: "))
    }

    @Test func clientInputReachesGuest() throws {
        let client = try connectClient()
        defer { close(client) }
        Thread.sleep(forTimeInterval: 0.2)

        let payload = Array("root\n".utf8)
        _ = payload.withUnsafeBytes { write(client, $0.baseAddress, payload.count) }
        #expect(readSome(relay.vmSideFd) == payload)
    }

    @Test func newClientReplacesOldOne() throws {
        let first = try connectClient()
        Thread.sleep(forTimeInterval: 0.2)
        let second = try connectClient()
        defer { close(second) }
        Thread.sleep(forTimeInterval: 0.2)

        let payload = Array("hello".utf8)
        _ = payload.withUnsafeBytes { write(relay.vmSideFd, $0.baseAddress, payload.count) }
        #expect(readSome(second) == payload)
        // The first connection was closed by the relay.
        #expect(readSome(first, timeoutMs: 500).isEmpty)
        close(first)
    }
}
