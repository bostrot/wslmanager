import Foundation

/// Resolves a guest's IP from the host DHCP lease table.
///
/// VMs on VZNATNetworkDeviceAttachment get their address from macOS's
/// InternetSharing DHCP server, which records leases in
/// `/var/db/dhcpd_leases` as pseudo-plist `{ name=…\n ip_address=…\n
/// hw_address=1,aa:bb:… }` blocks. Matching by MAC address is the same
/// technique Lima and Tart use.
public enum DHCPLeases {
    public static let leasesPath = "/var/db/dhcpd_leases"

    /// Parse the lease file contents and return `hw_address` → `ip_address`.
    /// MAC octets are normalised (lowercase, zero-padded) because the file
    /// drops leading zeros while VZMACAddress prints them.
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        var currentIp: String?
        var currentMac: String?

        func flush() {
            if let ip = currentIp, let mac = currentMac {
                result[mac] = ip
            }
            currentIp = nil
            currentMac = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                flush()
            } else if line.hasPrefix("ip_address=") {
                currentIp = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                // Format: hw_address=1,aa:bb:cc:d:ee:ff
                let value = String(line.dropFirst("hw_address=".count))
                let parts = value.split(separator: ",", maxSplits: 1)
                if parts.count == 2 {
                    currentMac = normalizeMac(String(parts[1]))
                }
            }
        }
        flush()
        return result
    }

    public static func normalizeMac(_ mac: String) -> String {
        mac.lowercased()
            .split(separator: ":")
            .map { $0.count == 1 ? "0\($0)" : String($0) }
            .joined(separator: ":")
    }

    /// One lease block, with the identifier octets normalized.
    struct Entry {
        let hw: String
        let ip: String
        let name: String
        /// When bootpd will stop honouring the lease (`lease=0x…`, host
        /// epoch seconds). Nil when the block carries no `lease=` line.
        let expiry: Date?

        /// A lease past its expiry belongs to a guest that stopped renewing:
        /// it dropped the address (or the whole network) and the IP is dead.
        /// bootpd keeps the block on file anyway, so without this check
        /// `list` kept advertising an address nothing answered on and every
        /// `exec` dialled it until ssh gave up.
        func isCurrent(at now: Date) -> Bool {
            guard let expiry else { return true }
            return expiry > now
        }
    }

    /// All lease blocks as (normalized hw/identifier octets, ip) pairs.
    /// Unlike [parse] this keeps identifiers that are not plain MACs —
    /// clients following RFC 4361 (Alpine's dhcpcd, some systemd setups)
    /// send a DUID-based client-id, which macOS records in hw_address as a
    /// long octet string whose *last six octets are the interface MAC*.
    static func entries(_ text: String) -> [Entry] {
        var result: [Entry] = []
        var currentIp: String?
        var currentHw: String?
        var currentName: String?
        var currentExpiry: Date?

        func flush() {
            if let ip = currentIp, let hw = currentHw {
                result.append(Entry(
                    hw: hw, ip: ip, name: currentName ?? "", expiry: currentExpiry))
            }
            currentIp = nil
            currentHw = nil
            currentName = nil
            currentExpiry = nil
        }

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line == "{" {
                flush()
            } else if line.hasPrefix("name=") {
                currentName = String(line.dropFirst("name=".count))
            } else if line.hasPrefix("ip_address=") {
                currentIp = String(line.dropFirst("ip_address=".count))
            } else if line.hasPrefix("hw_address=") {
                let value = String(line.dropFirst("hw_address=".count))
                let parts = value.split(separator: ",", maxSplits: 1)
                if parts.count == 2 {
                    currentHw = normalizeMac(String(parts[1]))
                }
            } else if line.hasPrefix("lease=") {
                currentExpiry = parseExpiry(String(line.dropFirst("lease=".count)))
            }
        }
        flush()
        return result
    }

    /// `lease=0x6a9b25a0`: hex seconds since the epoch. Unparseable text
    /// counts as "no expiry" rather than "expired" so a format change in a
    /// future macOS degrades to the old behaviour, not to every VM losing
    /// its address.
    static func parseExpiry(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("0x") { text = String(text.dropFirst(2)) }
        guard let seconds = UInt64(text, radix: 16) else { return nil }
        return Date(timeIntervalSince1970: TimeInterval(seconds))
    }

    /// IP for a guest within [text], most reliable signal first:
    /// 1. a lease whose hw_address is exactly [mac];
    /// 2. one whose identifier ends in the MAC (RFC 4361, dhcpcd-style);
    /// 3. one whose name equals [hostname] — systemd-networkd sends a
    ///    machine-id-derived DUID that contains no MAC at all, so for those
    ///    guests the hostname (which the cloud-init seed pins to the VM
    ///    name) is the only recoverable key.
    ///
    /// Within a level the lease that runs longest wins, which is the one
    /// granted or renewed last. File order says nothing reliable: bootpd
    /// prepends new blocks and rewrites renewed ones in place.
    ///
    /// The hostname level only considers DUID-style identifiers. A lease
    /// keyed by a plain six-octet MAC that is not ours belongs to another
    /// interface — typically an earlier VM of the same name that was deleted
    /// and recreated with a fresh MAC — and its address is somebody else's
    /// or nobody's. Matching it by name is how a new VM was reported at its
    /// predecessor's IP while nothing answered there.
    ///
    /// Expired leases (see [Entry.isCurrent]) are skipped at every level:
    /// they name an address the guest no longer holds. A current lease is
    /// still no proof the guest is up — see `VmctlCLI.liveIp`.
    public static func ipFor(
        mac: String, hostname: String? = nil, in text: String, now: Date = Date()
    ) -> String? {
        let target = normalizeMac(mac)
        var exact: Entry?
        var suffix: Entry?
        var named: Entry?
        func newer(_ candidate: Entry, than current: Entry?) -> Bool {
            guard let current else { return true }
            return (candidate.expiry ?? .distantPast) > (current.expiry ?? .distantPast)
        }
        for entry in entries(text) where entry.isCurrent(at: now) {
            if entry.hw == target {
                if newer(entry, than: exact) { exact = entry }
            } else if entry.hw.hasSuffix(":" + target) {
                if newer(entry, than: suffix) { suffix = entry }
            } else if let hostname, !hostname.isEmpty, entry.name == hostname,
                      !isPlainMac(entry.hw) {
                if newer(entry, than: named) { named = entry }
            }
        }
        return (exact ?? suffix ?? named)?.ip
    }

    /// Six octets: an Ethernet address, as opposed to a DUID client id.
    static func isPlainMac(_ hw: String) -> Bool {
        hw.split(separator: ":").count == 6
    }

    /// Compatibility shim over [ipFor].
    public static func ipForMac(_ mac: String, in text: String) -> String? {
        ipFor(mac: mac, in: text)
    }

    /// IP for the guest, or nil while it has no lease yet.
    public static func ipFor(mac: String, hostname: String? = nil) -> String? {
        guard let text = try? String(contentsOfFile: leasesPath, encoding: .utf8) else {
            return nil
        }
        return ipFor(mac: mac, hostname: hostname, in: text)
    }

    /// IP for [mac], or nil while the guest has no lease yet.
    public static func ipForMac(_ mac: String) -> String? {
        ipFor(mac: mac)
    }
}

/// Whether a guest actually answers at an address.
///
/// A DHCP lease outlives the network stack that took it — bootpd keeps it
/// current for the whole lease time (an hour on the default
/// InternetSharing setup) whether or not the guest is still there, so a
/// guest whose kernel fell over kept being reported at its address and
/// every `exec` and restart dialled it until ssh gave up.
public enum GuestReachability {
    /// True when [ip]:[port] accepts a TCP connection or actively refuses
    /// one within [timeout]. A refusal (RST) proves a live network stack just
    /// as well as an accept does, so a guest with no sshd yet still counts.
    public static func answers(
        _ ip: String, port: UInt16 = 22, timeout: TimeInterval = 1.0
    ) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, ip, &addr.sin_addr) == 1 else { return false }

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        if errno == ECONNREFUSED { return true }
        guard errno == EINPROGRESS else { return false }

        var watched = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&watched, 1, Int32(timeout * 1000)) > 0 else { return false }
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else {
            return false
        }
        return error == 0 || error == ECONNREFUSED
    }
}
