import Foundation

/// Builds a NoCloud cloud-init seed ISO so a fresh Linux guest (cloud image
/// or installer supporting cloud-init) comes up with a known user, the app's
/// SSH keys for both that user and root, a console password for that user and
/// passwordless sudo — which is what makes `vmctl exec`/`shell` possible
/// without any manual guest setup, and what makes the guest's own login
/// prompt answerable by the person who created it.
public enum CloudInit {
    /// [publicKeys] are all authorized for both [user] and root — the store's
    /// key, which `exec`/`shell` use, plus the Mac user's own so a plain
    /// `ssh user@ip` works from their Terminal.
    ///
    /// [password] is what [user] types at the VM's screen or serial console.
    /// Without one the account has no password at all and the login prompt on
    /// the console can never be satisfied, which is what made a guest with a
    /// custom user look locked out of itself (bostrot/ai-tasks#60). SSH stays
    /// key-only either way (`ssh_pwauth: false`), so the password buys a
    /// console login and nothing reachable over the network.
    public static func userData(
        user: String, publicKeys: [String], hostname: String, password: String? = nil
    ) -> String {
        // /bin/sh, not bash: Alpine has no bash and a user with a missing
        // shell cannot exec anything over SSH. Without a password the chpasswd
        // block writes `*` hashes: `lock_passwd` leaves `!` in /etc/shadow,
        // and Alpine's sshd refuses "locked" accounts even for public-key
        // auth — `*` means "no password" without counting as locked. root
        // keeps that treatment even when the user gets a password: the seeded
        // user has passwordless sudo, so an unlocked root would only add a
        // console login nobody asked for.
        let keyList = publicKeys.map { "  - \($0)" }.joined(separator: "\n")
        let userKeyList = publicKeys.map { "      - \($0)" }.joined(separator: "\n")
        // Interpolated text keeps its own indentation — the literal's baseline
        // strip only applies to the literal's lines — so the continuation
        // carries the six spaces the YAML needs, spelled out.
        let userSecret = password.map { "password: \"\($0)\"\n      type: text" }
            ?? "password: \"*\"\n      type: hash"
        return """
        #cloud-config
        hostname: \(hostname)
        users:
          - name: \(user)
            groups: [sudo, wheel]
            sudo: ALL=(ALL) NOPASSWD:ALL
            shell: /bin/sh
            lock_passwd: \(password == nil)
            ssh_authorized_keys:
        \(userKeyList)
        disable_root: false
        ssh_authorized_keys:
        \(keyList)
        ssh_pwauth: false
        chpasswd:
          expire: false
          users:
            - name: root
              password: "*"
              type: hash
            - name: \(user)
              \(userSecret)
        package_update: false
        bootcmd:
          - |
        \(indented(consoleGettyFixScript, by: 4))
          - |
        \(indented(consoleKernelArgScript, by: 4))

        """
    }

    /// Puts the kernel's console — and with it fsck, systemd's boot status
    /// and the emergency shell — on the virtio console from the next boot on.
    ///
    /// The daemon logs everything the guest writes to hvc0 (`serial.log`),
    /// but cloud images name the consoles of the machines they were built
    /// for: Debian's says `console=tty0 console=ttyS0`, others `ttyAMA0`,
    /// none of which exist here. So a guest whose root filesystem failed its
    /// check dropped into emergency mode on a console nobody had, and the log
    /// held nothing but GRUB's screen setup. Appended last, `console=hvc0`
    /// also becomes /dev/console, which is where the emergency shell opens.
    ///
    /// GRUB guests (Debian, Ubuntu) get a `grub.d` snippet and an
    /// `update-grub`; BLS guests (Fedora and friends) get `grubby`. Anything
    /// else — Alpine's extlinux, a hand-installed guest — is left alone.
    /// Runs on every boot and does nothing once the running kernel already
    /// has the argument or the snippet is in place; the first boot of a new
    /// VM is the one boot it cannot cover.
    ///
    /// The overrides let the tests run it against a fixture.
    public static let consoleKernelArgScript = """
    vmctl_console_on_hvc0() {
      devdir=${WSLMANAGER_DEV:-/dev}
      cmdline=${WSLMANAGER_CMDLINE:-/proc/cmdline}
      grubd=${WSLMANAGER_GRUB_D:-/etc/default/grub.d}
      [ -e "$devdir/hvc0" ] || return 0
      grep -q 'console=hvc0' "$cmdline" 2>/dev/null && return 0
      if command -v grubby >/dev/null 2>&1; then
        grubby --update-kernel=ALL --args=console=hvc0 >/dev/null 2>&1
        return 0
      fi
      command -v update-grub >/dev/null 2>&1 || return 0
      conf="$grubd/99-wslmanager-console.cfg"
      [ -f "$conf" ] && return 0
      mkdir -p "$grubd" || return 0
      printf '%s\n' \
        '# WSL Manager: boot messages and the emergency shell on hvc0' \
        'GRUB_CMDLINE_LINUX_DEFAULT="${GRUB_CMDLINE_LINUX_DEFAULT} console=hvc0"' \
        > "$conf" || return 0
      update-grub >/dev/null 2>&1 || rm -f "$conf"
      return 0
    }
    vmctl_console_on_hvc0
    """

    /// Busybox init restarts a getty for every `respawn` line in
    /// /etc/inittab whether or not the tty behind it exists. Alpine's cloud
    /// images are built for QEMU's `virt` machine and ship a getty on the
    /// PL011 UART, ttyAMA0; Virtualization.framework has no such UART, so
    /// that getty dies the instant it starts and init respawns it forever,
    /// burying the login prompt on the graphical console under an endless
    /// "can't open /dev/ttyAMA0: No such file or directory".
    ///
    /// Comment those entries out, and put a getty on the virtio console the
    /// VZ serial port does expose so `vmctl console` reaches a login prompt
    /// too. `kill -HUP 1` makes busybox init re-read the file, which stops
    /// the flood without a reboot.
    ///
    /// Nothing is appended to an inittab that has no live getty line: a
    /// systemd guest can still carry a vestigial /etc/inittab, and a busybox
    /// entry in it would be dead weight nobody reads.
    ///
    /// Wrapped in a function rather than written straight down, because
    /// cloud-init splices every `bootcmd` entry into one generated script:
    /// a bare `exit` here would swallow whatever entry came next.
    ///
    /// The three environment overrides are what let the tests run this
    /// against a fixture instead of the host's own /etc and init.
    public static let consoleGettyFixScript = """
    vmctl_fix_gettys() {
      inittab=${WSLMANAGER_INITTAB:-/etc/inittab}
      devdir=${WSLMANAGER_DEV:-/dev}
      initpid=${WSLMANAGER_INIT_PID-1}
      [ -f "$inittab" ] || return 0
      tmp="$inittab.vmctl.$$"
      : > "$tmp" || return 0
      changed=0
      gettys=0
      while IFS= read -r line || [ -n "$line" ]; do
        case $line in
          '#'*) ;;
          *:respawn:*getty*)
            gettys=1
            tty=${line%%:*}
            if [ -n "$tty" ] && [ ! -e "$devdir/$tty" ]; then
              line="#$line"
              changed=1
            fi
            ;;
        esac
        printf '%s\\n' "$line" >> "$tmp"
      done < "$inittab"
      if [ "$gettys" = 1 ] && [ -e "$devdir/hvc0" ] \\
        && ! grep -q '^hvc0:' "$inittab"; then
        printf '%s\\n' 'hvc0::respawn:/sbin/getty -L 0 hvc0 vt100' >> "$tmp"
        changed=1
      fi
      if [ "$changed" = 1 ]; then
        cat "$tmp" > "$inittab"
        [ -n "$initpid" ] && kill -HUP "$initpid" 2>/dev/null
      fi
      rm -f "$tmp"
      return 0
    }
    vmctl_fix_gettys
    """

    /// Pads every line so a multi-line script can sit inside a YAML block
    /// scalar. Empty lines stay empty: trailing blanks would be preserved
    /// verbatim in the block.
    static func indented(_ text: String, by spaces: Int) -> String {
        let pad = String(repeating: " ", count: spaces)
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.isEmpty ? "" : pad + $0 }
            .joined(separator: "\n")
    }

    /// Without this, images that leave all networking to cloud-init (Debian
    /// genericcloud) boot with the NIC down: no DHCP lease, no SSH, and the
    /// VM looks dead.
    ///
    /// Explicit device names, not a `match` glob: cloud-init's ENI renderer
    /// (Alpine) resolves a glob at write time and can produce a config that
    /// names no real interface — replacing the image's working default with
    /// nothing. The VZ virtio NIC is `enp0s1` under systemd naming and
    /// `eth0` everywhere else; the entry for whichever name is absent is
    /// inert. `dhcp-identifier: mac` because macOS bootpd never answers the
    /// DUID client-id systemd-networkd sends by default.
    public static func networkConfig() -> String {
        """
        version: 2
        ethernets:
          eth0:
            dhcp4: true
            dhcp-identifier: mac
          enp0s1:
            dhcp4: true
            dhcp-identifier: mac

        """
    }

    public static func metaData(hostname: String, instanceId: String? = nil) -> String {
        """
        instance-id: \(instanceId ?? "iid-\(hostname)")
        local-hostname: \(hostname)
        """
    }

    /// How vmctl's own cloud-config folds into a document the caller wrote.
    ///
    /// cloud-init merges the cloud-config parts of a multipart user-data in
    /// order, and the part being merged *in* names the rules. `no_replace`
    /// keeps every scalar the caller set (their `hostname`, their
    /// `package_update`, their `ssh_pwauth`); `recurse_array` with
    /// `list(append)` adds vmctl's `users`, `ssh_authorized_keys`, `chpasswd`
    /// entries and `bootcmd` to theirs instead of replacing them. So the
    /// account and key `exec`/`shell` depend on always land, and nothing the
    /// caller wrote is overruled.
    public static let seedMergeType = "list(append)+dict(no_replace,recurse_array)+str()"

    /// The two scalars no caller's document may override, applied last with
    /// `dict(replace)` so they win whatever came before: SSH stays key-only
    /// (the console password vmctl writes must not become a network
    /// credential — bostrot/ai-tasks#60), and root keeps the store's key,
    /// which `exec` and the rootfs export depend on.
    public static let pinnedUserData = """
    #cloud-config
    ssh_pwauth: false
    disable_root: false

    """
    public static let pinnedMergeType = "list()+dict(replace)+str()"

    /// The caller's document first, vmctl's second and the pins last, as one
    /// `multipart/mixed` message — the form cloud-init defines for "more
    /// than one user-data".
    ///
    /// The caller's part is typed `text/plain` on purpose: cloud-init decides
    /// what such a part is from its first line (`#cloud-config`, `#!`,
    /// `#include`, …), which is exactly the detection it applies to a bare
    /// user-data file, so a script and a cloud-config both keep working
    /// without vmctl having to know the difference. vmctl's part is typed
    /// outright and carries the merge rules in its header, which is where
    /// cloud-init reads them from without the YAML having to change.
    public static func multipartUserData(
        custom: String, seed: String, boundary: String = "==vmctl-\(UUID().uuidString)=="
    ) -> String {
        func terminated(_ text: String) -> String {
            text.hasSuffix("\n") ? text : text + "\n"
        }
        return """
        Content-Type: multipart/mixed; boundary="\(boundary)"
        MIME-Version: 1.0

        --\(boundary)
        Content-Type: text/plain; charset="utf-8"
        Content-Transfer-Encoding: 8bit
        Content-Disposition: attachment; filename="user-data.custom"

        \(terminated(custom))--\(boundary)
        Content-Type: text/cloud-config; charset="utf-8"
        Content-Transfer-Encoding: 8bit
        Content-Disposition: attachment; filename="user-data.vmctl"
        Merge-Type: \(seedMergeType)

        \(terminated(seed))--\(boundary)
        Content-Type: text/cloud-config; charset="utf-8"
        Content-Transfer-Encoding: 8bit
        Content-Disposition: attachment; filename="user-data.vmctl-pins"
        Merge-Type: \(pinnedMergeType)

        \(pinnedUserData)--\(boundary)--

        """
    }

    /// The seed's `user-data` file: vmctl's own document, or — when the
    /// caller supplied one — both, as a multipart message.
    public static func seedUserData(
        user: String, publicKeys: [String], hostname: String, password: String? = nil,
        customUserData: String? = nil
    ) -> String {
        let own = userData(
            user: user, publicKeys: publicKeys, hostname: hostname, password: password)
        guard let custom = customUserData,
              !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else { return own }
        return multipartUserData(custom: custom, seed: own)
    }

    /// Write the seed directory and pack it as an ISO9660 image named
    /// `cidata` via hdiutil.
    ///
    /// [customUserData] is a document the caller wrote (`create --user-data`);
    /// it goes into the seed alongside vmctl's own, see [multipartUserData].
    public static func writeSeedIso(
        to isoURL: URL,
        user: String,
        publicKeys: [String],
        hostname: String,
        password: String? = nil,
        instanceId: String? = nil,
        customUserData: String? = nil
    ) throws {
        let fm = FileManager.default
        let seedDir = isoURL.deletingLastPathComponent().appendingPathComponent("seed.tmp")
        try? fm.removeItem(at: seedDir)
        try fm.createDirectory(at: seedDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: seedDir) }

        try seedUserData(
            user: user, publicKeys: publicKeys, hostname: hostname, password: password,
            customUserData: customUserData)
            .write(to: seedDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData(hostname: hostname, instanceId: instanceId)
            .write(to: seedDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)
        try networkConfig()
            .write(to: seedDir.appendingPathComponent("network-config"), atomically: true, encoding: .utf8)

        try? fm.removeItem(at: isoURL)
        // hdiutil appends .iso itself when missing, so hand it the final name.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = [
            "makehybrid", "-iso", "-joliet",
            "-default-volume-name", "cidata",
            "-o", isoURL.path,
            seedDir.path,
        ]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? ""
            throw VmctlError("hdiutil failed to build the cloud-init seed: \(message)")
        }
    }
}
