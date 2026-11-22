import Foundation
import Testing
@testable import VMCtlKit

@Suite struct GuestAccessTests {
    let key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIExampleKeyBytes wslmanager-vmctl"
    let hostKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHostKeyBytes eric@mac"

    @Test func installerCarriesTheKeyBase64OnlyAndInstallsForBothAccounts() {
        let script = GuestAccess.installerScript(publicKeys: [key])
        let encoded = Data(key.utf8).base64EncodedString()
        // The key only ever reaches the guest shell base64-encoded, so no
        // character in it needs quoting.
        #expect(script.contains("printf %s \(encoded) | base64 -d"))
        #expect(!script.contains(key))
        // Login user first, then root via each escalation the guest may have.
        #expect(script.contains("install_key \"$HOME\""))
        #expect(script.contains("--as-root"))
        #expect(script.contains("sudo -n sh \"$T\" --as-root"))
        #expect(script.contains("sudo -S -p ''"))
        #expect(script.contains("doas -n"))
        #expect(script.contains("su root -c"))
        // The password is fed to sudo/su on stdin, never as an argument.
        #expect(script.contains("printf '%s\\n' \"$PW\" |"))
        #expect(!script.contains("sudo -S -p '' \"$PW\""))
        // Idempotent: a second run must not duplicate the line.
        #expect(script.contains("grep -qxF \"$k\""))
    }

    @Test func installerCarriesEveryKeyAndSplitsOnNewlinesOnly() {
        let script = GuestAccess.installerScript(publicKeys: [key, hostKey])
        // Both keys travel as one base64 blob, newline-separated.
        let encoded = Data([key, hostKey].joined(separator: "\n").utf8)
            .base64EncodedString()
        #expect(script.contains("printf %s \(encoded) | base64 -d"))
        #expect(!script.contains(hostKey))
        // A key contains spaces, so the loop must not word-split on them:
        // IFS is a bare newline for the duration and restored afterwards.
        #expect(script.contains("oldifs=$IFS\n  IFS='\n'\n"))
        #expect(script.contains("for k in $KEYS; do"))
        // No pipeline around the loop — its body must be able to fail the
        // enclosing function, which a subshell could not.
        #expect(!script.contains("| while"))
    }

    @Test func remoteCommandIsOneShWrapperThatSourcesStdin() {
        // Wrapped in sh -c so the login shell (bash, ash, fish) does not
        // matter, and single-quoted throughout so ssh's re-parse is inert.
        #expect(GuestAccess.remoteCommand.hasPrefix("sh -c '"))
        #expect(GuestAccess.remoteCommand.hasSuffix("'"))
        #expect(GuestAccess.remoteCommand.contains("IFS= read -r PW"))
        #expect(GuestAccess.remoteCommand.contains(". \"$T\""))
        #expect(GuestAccess.remoteCommand.contains("rm -f \"$T\""))
    }

    @Test func reportReadsMarkerLines() {
        let both = GuestAccess.parseReport("noise\nVMCTL_USER_OK\nVMCTL_ROOT_OK\n")
        #expect(both == GuestAccess.Report(userInstalled: true, rootInstalled: true))

        let userOnly = GuestAccess.parseReport("VMCTL_USER_OK\nsudo: a password is required\nVMCTL_ROOT_FAIL")
        #expect(userOnly == GuestAccess.Report(userInstalled: true, rootInstalled: false))

        let nothing = GuestAccess.parseReport("Permission denied")
        #expect(nothing == GuestAccess.Report(userInstalled: false, rootInstalled: false))

        // A marker that is merely a substring of some other line is not one.
        let lookalike = GuestAccess.parseReport("echo VMCTL_ROOT_OK failed")
        #expect(!lookalike.rootInstalled)
    }

    @Test func askpassHelperEchoesTheEnvVarAndIsOwnerOnly() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vmctl-askpass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("askpass.sh")

        try GuestAccess.writeAskpassHelper(at: path)

        let contents = try String(contentsOf: path, encoding: .utf8)
        #expect(contents.hasPrefix("#!/bin/sh\n"))
        #expect(contents.contains("$\(GuestAccess.passwordEnvVar)"))
        let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
        #expect((attrs[.posixPermissions] as? Int) == 0o700)

        // Run it the way ssh would: the password comes out of the
        // environment, so the file itself never holds it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [path.path]
        process.environment = [GuestAccess.passwordEnvVar: "s3cret pass"]
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        process.waitUntilExit()
        let printed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
        #expect(printed == "s3cret pass\n")
        #expect(!contents.contains("s3cret"))
    }

    @Test func installerScriptIsValidPosixSh() throws {
        // `sh -n` parses without running: catches a quoting slip in the
        // Swift string before it reaches a guest.
        let dir = FileManager.default.temporaryDirectory
        let path = dir.appendingPathComponent("vmctl-installer-\(UUID().uuidString).sh")
        try GuestAccess.installerScript(publicKeys: [key, hostKey]).write(to: path, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: path) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-n", path.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
