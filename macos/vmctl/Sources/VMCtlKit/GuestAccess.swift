import Foundation

/// Puts the app's public keys — the store's own and the Mac user's — into a
/// guest that cloud-init never provisioned (a VM installed by hand from an
/// ISO, or an imported disk without cloud-init), so `exec`/`shell` and a
/// plain `ssh` from the user's Terminal work by key from then on.
///
/// The guest's login password is used exactly once, for that one SSH
/// session, and travels only through channels other users on the Mac cannot
/// read: an environment variable into ssh's askpass helper on the host, and
/// stdin into the guest (for `sudo -S`/`su`). It never appears in argv, in a
/// file, or in the store.
public enum GuestAccess {
    /// The variable `vmctl authorize` reads the guest password from.
    public static let passwordEnvVar = "VMCTL_GUEST_PASSWORD"

    /// Marker lines the installer script prints so the host can tell which
    /// accounts got the key without scraping shell errors.
    static let userOk = "VMCTL_USER_OK"
    static let userFail = "VMCTL_USER_FAIL"
    static let rootOk = "VMCTL_ROOT_OK"
    static let rootFail = "VMCTL_ROOT_FAIL"

    /// What the guest reported back.
    public struct Report: Equatable {
        public let userInstalled: Bool
        public let rootInstalled: Bool
    }

    /// The remote side of the session, handed to ssh as ONE argument and
    /// wrapped in `sh -c` so it runs the same under bash, ash or fish login
    /// shells. Line one of stdin is the password; the rest is the installer
    /// script, which is *sourced* so `PW` stays a plain shell variable (not
    /// exported, not in the environment of anything the script spawns).
    public static let remoteCommand = "sh -c '" +
        "IFS= read -r PW && T=$(mktemp) && cat >\"$T\" && . \"$T\"; " +
        "rc=$?; rm -f \"$T\"; exit $rc'"

    /// POSIX-sh installer, run in the guest as the login user. It adds the
    /// keys to that user's authorized_keys, then re-runs itself as root
    /// (`--as-root`) through whichever of sudo/doas/su the guest offers.
    /// The keys go in base64 so no quoting reaches the guest shell.
    ///
    /// The loop splits on newlines through `IFS` rather than piping into
    /// `while read`: a pipeline's body runs in a subshell whose exit status
    /// is all `install_key` would have to report on, and this function's
    /// return value is what decides `VMCTL_USER_OK`.
    ///
    /// Relies on the wrapper's `PW` and `T` (its own path) being in scope,
    /// which sourcing guarantees.
    public static func installerScript(publicKeys: [String]) -> String {
        let encoded = Data(publicKeys.joined(separator: "\n").utf8).base64EncodedString()
        return """
        KEYS=$(printf %s \(encoded) | base64 -d)
        install_key() {
          d="$1/.ssh"; f="$d/authorized_keys"
          mkdir -p "$d" && chmod 700 "$d" && touch "$f" && chmod 600 "$f" || return 1
          oldifs=$IFS
          IFS='
        '
          for k in $KEYS; do
            [ -n "$k" ] || continue
            grep -qxF "$k" "$f" 2>/dev/null || printf '%s\\n' "$k" >>"$f" || {
              IFS=$oldifs; return 1
            }
          done
          IFS=$oldifs
          return 0
        }
        if [ "$1" = "--as-root" ]; then
          eval H=~root
          install_key "${H:-/root}"
          exit $?
        fi
        if install_key "$HOME"; then echo \(userOk); else echo \(userFail); fi
        if [ "$(id -u)" = 0 ]; then echo \(rootOk); exit 0; fi
        as_root() {
          if command -v sudo >/dev/null 2>&1; then
            sudo -n sh "$T" --as-root 2>/dev/null && return 0
            printf '%s\\n' "$PW" | sudo -S -p '' sh "$T" --as-root 2>/dev/null && return 0
          fi
          if command -v doas >/dev/null 2>&1; then
            doas -n sh "$T" --as-root 2>/dev/null && return 0
          fi
          printf '%s\\n' "$PW" | su root -c "sh $T --as-root" >/dev/null 2>&1 && return 0
          return 1
        }
        if as_root; then echo \(rootOk); else echo \(rootFail); fi

        """
    }

    /// Reads the marker lines out of whatever the session printed.
    public static func parseReport(_ output: String) -> Report {
        let lines = Set(output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) })
        return Report(
            userInstalled: lines.contains(userOk),
            rootInstalled: lines.contains(rootOk))
    }

    /// ssh options for the one password-authenticated session: the store key
    /// is deliberately not offered (it is the thing being installed), and one
    /// prompt is all the askpass helper answers.
    static let sshOptions = [
        "-o", "PubkeyAuthentication=no",
        "-o", "PreferredAuthentications=keyboard-interactive,password",
        "-o", "NumberOfPasswordPrompts=1",
        "-o", "StrictHostKeyChecking=no",
        "-o", "UserKnownHostsFile=/dev/null",
        "-o", "ConnectTimeout=10",
        "-o", "LogLevel=ERROR",
    ]

    /// The askpass helper ssh calls for the password: it echoes the
    /// environment variable, so nothing secret is ever written to disk.
    static let askpassScript = "#!/bin/sh\nprintf '%s\\n' \"$\(passwordEnvVar)\"\n"

    /// Writes (or refreshes) the askpass helper at [path] with owner-only
    /// permissions.
    public static func writeAskpassHelper(at path: URL) throws {
        try askpassScript.write(to: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: path.path)
    }

    /// Runs the whole exchange against `user@ip` and returns what the guest
    /// reported. Throws when ssh itself fails (wrong password, no sshd,
    /// password login disabled) with ssh's own words.
    public static func install(
        publicKeys: [String], user: String, ip: String, password: String, askpassPath: URL
    ) throws -> Report {
        try writeAskpassHelper(at: askpassPath)

        let ssh = Process()
        ssh.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        ssh.arguments = sshOptions + ["\(user)@\(ip)", "--", remoteCommand]
        var env = ProcessInfo.processInfo.environment
        env["SSH_ASKPASS"] = askpassPath.path
        // OpenSSH ≥ 8.4: use the helper even though a terminal may exist.
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env[passwordEnvVar] = password
        ssh.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        ssh.standardInput = stdin
        ssh.standardOutput = stdout
        ssh.standardError = stderr
        try ssh.run()

        let payload = password + "\n" + installerScript(publicKeys: publicKeys)
        stdin.fileHandleForWriting.write(Data(payload.utf8))
        try? stdin.fileHandleForWriting.close()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        ssh.waitUntilExit()

        let output = String(data: outData, encoding: .utf8) ?? ""
        let errors = (String(data: errData, encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard ssh.terminationStatus != 255 else {
            let reason = errors.isEmpty ? "ssh exited with 255" : errors
            throw VmctlError("Could not sign in as \(user)@\(ip): \(reason)")
        }
        let report = parseReport(output)
        guard report.userInstalled else {
            let reason = errors.isEmpty ? output.trimmingCharacters(in: .whitespacesAndNewlines) : errors
            throw VmctlError(
                "Signed in as \(user), but could not write ~/.ssh/authorized_keys"
                    + (reason.isEmpty ? "." : ": \(reason)"))
        }
        return report
    }
}
