import AppKit
import Foundation
import Virtualization

/// Runs one VM for its whole lifetime inside this (daemonised) process.
///
/// Virtualization.framework keeps the VM in-process, so `vmctl start` spawns
/// a detached copy of itself running this loop; `vmctl stop` sends that
/// process SIGTERM, which is translated into a graceful guest stop request
/// with a hard stop fallback.
public final class VMRunner: NSObject, VZVirtualMachineDelegate {
    private let store: VMStore
    private let config: VMConfig
    private let gui: Bool
    private var virtualMachine: VZVirtualMachine?
    private var signalSource: DispatchSourceSignal?
    private var showSignalSource: DispatchSourceSignal?
    private var consoleRelay: ConsoleRelay?
    private var window: NSWindow?
    /// Held for the life of the process; released by exit. See `DiskGuard`.
    private var diskLock: DiskLock?
    private var shutdownRequested = false

    /// How long a guest gets to shut down after the ACPI power button before
    /// it is powered off. A Debian guest in the middle of an apt run needs
    /// systemd's own 90 s stop timeout to get through, and powering off a
    /// guest that is still writing is how a journal ends up replaying over a
    /// half-written disk. `vmctl stop` waits longer than this.
    public static let gracefulStopTimeout: TimeInterval = 120

    /// What the daemon log says when the grace period ran out; `vmctl stop`
    /// looks for it to report the stop as forced.
    public static let forcedStopMarker = "Guest did not shut down in time; powering it off."

    public init(store: VMStore, config: VMConfig, gui: Bool) {
        self.store = store
        self.config = config
        self.gui = gui
    }

    public func run() throws -> Never {
        // Before anything else — before the pid file, the console socket or
        // the serial log — or a second daemon for the same VM would clobber
        // the running one's bookkeeping on its way to being refused.
        // See `DiskGuard.swift`.
        guard let lock = try DiskLock.tryAcquire(store.diskLockPath(config.name).path) else {
            throw VmctlError(
                "The disk of \(config.name) is in use by another instance of it; not starting a second one on the same image.")
        }
        diskLock = lock
        let holders = DiskHolders.pids(store.diskPath(config.name).path)
        guard holders.isEmpty else {
            throw VmctlError(
                "The disk of \(config.name) is still open in process \(holders.map(String.init).joined(separator: ", ")) (a previous run still shutting down, or the image attached in Finder); not starting on it.")
        }

        // Linux guests get an attachable serial console; the relay also owns
        // the serial.log tee the diagnostics read.
        if config.os == .linux {
            try? FileManager.default.createDirectory(
                at: store.runDir(config.name), withIntermediateDirectories: true)
            let relay = try ConsoleRelay(
                socketPath: store.consoleSocketPath(config.name).path,
                logPath: store.serialLogPath(config.name).path)
            relay.start()
            consoleRelay = relay
        }
        let vmHandle = consoleRelay.map {
            FileHandle(fileDescriptor: $0.vmSideFd, closeOnDealloc: false)
        }
        let vzConfig = try VMFactory.configuration(
            config, store: store,
            consoleInput: vmHandle, consoleOutput: vmHandle)
        let vm = VZVirtualMachine(configuration: vzConfig)
        vm.delegate = self
        virtualMachine = vm

        try store.writePid(config.name)
        installSignalHandler()

        DispatchQueue.main.async {
            vm.start { result in
                switch result {
                case .success:
                    FileHandle.standardError.write(Data("VM \(self.config.name) started\n".utf8))
                    // A Linux guest mounts its shares itself, from the
                    // config, once its sshd answers. Off the main thread:
                    // this waits for a whole boot.
                    if self.config.os == .linux, let mounts = self.config.mounts {
                        let store = self.store
                        let config = self.config
                        // Only what VMFactory attached: a share whose host
                        // directory is gone has no device for the guest to
                        // mount, and the status says so instead.
                        let present = VMFactory.presentMounts(config)
                        let skipped = mounts.filter { !present.contains($0) }
                        DispatchQueue.global(qos: .utility).async {
                            VmctlCLI.syncGuestMounts(
                                store: store, config: config, mounts: present, skipped: skipped)
                        }
                    }
                case .failure(let error):
                    FileHandle.standardError.write(Data("VM start failed: \(error)\n".utf8))
                    self.store.clearPid(self.config.name)
                    exit(1)
                }
            }
        }

        // One AppKit loop for both modes: headless just starts with no
        // window and the accessory activation policy, and can grow a window
        // later when `vmctl show` sends SIGUSR1.
        let app = NSApplication.shared
        app.setActivationPolicy(gui ? .regular : .accessory)
        if gui {
            showWindow()
        }
        app.run()
        // Not reached; the loop runs until exit().
        exit(0)
    }

    /// Present the VM's display, creating the window on first use — also the
    /// re-open path after the user closed it.
    private func showWindow() {
        guard let vm = virtualMachine else { return }
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        if window == nil {
            let view = VZVirtualMachineView()
            view.capturesSystemKeys = true
            view.virtualMachine = vm

            let created = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 1280, height: 800),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false)
            created.title = config.name
            created.contentView = view
            // The window outlives its on-screen appearances; AppKit must not
            // free it on close.
            created.isReleasedWhenClosed = false
            created.center()

            // Closing the window is "close the screen", not "pull the plug":
            // the VM keeps running and the screen can be summoned again.
            NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: created, queue: nil
            ) { _ in
                app.setActivationPolicy(.accessory)
            }
            window = created
        }

        window?.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
    }

    private func installSignalHandler() {
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { [weak self] in
            self?.requestShutdown()
        }
        source.resume()
        signalSource = source

        // SIGUSR1 = "show your screen" (`vmctl show`).
        signal(SIGUSR1, SIG_IGN)
        let show = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        show.setEventHandler { [weak self] in
            self?.showWindow()
        }
        show.resume()
        showSignalSource = show
    }

    private func requestShutdown() {
        guard let vm = virtualMachine else { exit(0) }
        // A second SIGTERM (a retried stop) must not restart the clock.
        guard !shutdownRequested else { return }
        shutdownRequested = true
        // Ask the guest first (ACPI power button); force after a grace period.
        guard vm.canRequestStop else {
            log("Guest cannot take a shutdown request in state \(vm.state.rawValue); powering it off.")
            forceStop()
            return
        }
        do {
            try vm.requestStop()
            log("Shutdown requested; waiting up to \(Int(Self.gracefulStopTimeout))s for the guest.")
        } catch {
            log("Shutdown request failed (\(error)); powering the guest off.")
            forceStop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.gracefulStopTimeout) { [weak self] in
            guard let self, let vm = self.virtualMachine, vm.state == .running else { return }
            self.log(Self.forcedStopMarker)
            self.forceStop()
        }
    }

    private func forceStop() {
        guard let vm = virtualMachine, vm.canStop else {
            cleanUpAndExit(0)
        }
        vm.stop { [weak self] _ in
            self?.cleanUpAndExit(0)
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("\(message)\n".utf8))
    }

    private func cleanUpAndExit(_ code: Int32) -> Never {
        consoleRelay?.shutdown()
        // Drop the framework's VM object, then give its XPC service a moment
        // to close the image before the lock goes: the lock is what the next
        // start trusts. Bounded — whatever is left is the next start's
        // `lsof` check to wait out.
        virtualMachine?.delegate = nil
        virtualMachine = nil
        _ = store.waitForDiskReleaseByOthers(config.name, timeout: 5)
        store.clearPid(config.name)
        diskLock?.release()
        exit(code)
    }

    // MARK: VZVirtualMachineDelegate

    public func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        cleanUpAndExit(0)
    }

    public func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        FileHandle.standardError.write(Data("VM stopped with error: \(error)\n".utf8))
        cleanUpAndExit(1)
    }
}
