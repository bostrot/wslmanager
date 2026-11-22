import Foundation

/// Guest operating system family.
public enum GuestOS: String, Codable {
    case linux
    case macos
}

/// Persistent per-VM configuration, stored as `config.json` in the VM's
/// directory. Everything needed to rebuild the VZVirtualMachineConfiguration
/// on each start lives here.
public struct VMConfig: Codable, Equatable {
    public var name: String
    public var os: GuestOS
    public var cpus: Int
    public var memoryBytes: UInt64
    public var diskSizeBytes: UInt64
    /// Default guest user seeded via cloud-init (linux only).
    public var user: String
    /// Console login password for [user], seeded via cloud-init (linux only).
    /// Nil for macOS guests and for VMs created before passwords existed —
    /// `credentials` fills it in and reseeds when it is asked for one.
    public var password: String?
    /// Stable MAC address so DHCP leases (and therefore the guest IP) survive
    /// restarts.
    public var macAddress: String
    /// Installer ISO attached until the user detaches it (linux only).
    public var isoPath: String?
    /// Host directories shared into the guest. Nil for a VM whose shares were
    /// never configured, so the daemon knows it has no guest to keep in sync;
    /// empty once the user has cleared them (see `Mounts.swift`).
    public var mounts: [VMMount]?
    public var createdAt: Date

    public init(
        name: String,
        os: GuestOS,
        cpus: Int,
        memoryBytes: UInt64,
        diskSizeBytes: UInt64,
        user: String,
        password: String? = nil,
        macAddress: String,
        isoPath: String? = nil,
        mounts: [VMMount]? = nil,
        createdAt: Date = Date()
    ) {
        self.name = name
        self.os = os
        self.cpus = cpus
        self.memoryBytes = memoryBytes
        self.diskSizeBytes = diskSizeBytes
        self.user = user
        self.password = password
        self.macAddress = macAddress
        self.isoPath = isoPath
        self.mounts = mounts
        self.createdAt = createdAt
    }
}

/// A valid VM name is also a safe directory name; refuse anything else
/// instead of escaping it.
public func isValidVmName(_ name: String) -> Bool {
    guard !name.isEmpty, name.count <= 64 else { return false }
    return name.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil
        && !name.hasPrefix(".")
}

/// A random login password for a guest account.
///
/// Alphanumerics only, minus the characters that are guesswork on a VM
/// console in a bitmap font (`0`/`O`, `1`/`l`/`I`): this password is typed by
/// hand at a `login:` prompt far more often than it is pasted, and it also
/// travels through cloud-init YAML, where anything else would need quoting.
/// 20 characters of a 57-symbol alphabet is ~116 bits.
public func generateGuestPassword(length: Int = 20) -> String {
    let alphabet = Array("abcdefghijkmnopqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789")
    var generator = SystemRandomNumberGenerator()
    return String((0..<length).map { _ in alphabet.randomElement(using: &generator)! })
}

/// A valid guest account name, checked the way `useradd` would.
///
/// It is not only cloud-init that reads this: the name reaches an `ssh`
/// target, a `--user` argument and the `.command` script the app opens in
/// Terminal, so anything outside this set is refused at the door rather than
/// escaped three times over.
public func isValidGuestUser(_ user: String) -> Bool {
    guard !user.isEmpty, user.count <= 32 else { return false }
    return user.range(of: "^[a-z_][a-z0-9_-]*$", options: .regularExpression) != nil
}

/// Whether a guest account is one this app may hand a password to. root is
/// left alone: cloud images ship it locked on purpose, the seeded user has
/// passwordless sudo, and an unlocked root would be a console login nobody
/// asked for.
public func guestTakesPassword(user: String) -> Bool {
    let trimmed = user.trimmingCharacters(in: .whitespaces)
    return !trimmed.isEmpty && trimmed != "root"
}
