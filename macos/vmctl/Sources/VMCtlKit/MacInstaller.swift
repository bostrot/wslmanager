#if arch(arm64)
import Foundation
import Virtualization

/// Creates a macOS guest: platform hardware blobs from a restore image, then
/// a full VZMacOSInstaller run. Apple Silicon only, and deliberately
/// synchronous — installation takes many minutes and progress goes to
/// stderr, which the app streams.
public enum MacInstaller {
    public static func createAndInstall(
        store: VMStore,
        config: inout VMConfig,
        restoreImagePath: String?,
        diskSizeBytes: UInt64,
        progress: InstallProgressReporter = InstallProgressReporter()
    ) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: store.vmDir(config.name), withIntermediateDirectories: true)

        let imageURL: URL
        if let restoreImagePath, !restoreImagePath.isEmpty {
            guard fm.fileExists(atPath: restoreImagePath) else {
                throw VmctlError("Restore image not found: \(restoreImagePath)")
            }
            imageURL = URL(fileURLWithPath: restoreImagePath)
        } else {
            imageURL = try downloadLatestRestoreImage(store: store, progress: progress)
        }

        progress.report(.prepare)
        let restoreImage = try loadRestoreImage(imageURL)
        guard let requirements = restoreImage.mostFeaturefulSupportedConfiguration else {
            throw VmctlError("This restore image is not supported on this Mac.")
        }
        guard requirements.hardwareModel.isSupported else {
            throw VmctlError("The restore image's hardware model is not supported here.")
        }

        // Persist the platform identity so the VM can be reconstructed on
        // every later start.
        try requirements.hardwareModel.dataRepresentation
            .write(to: store.hardwareModelPath(config.name))
        try VZMacMachineIdentifier().dataRepresentation
            .write(to: store.machineIdentifierPath(config.name))
        _ = try VZMacAuxiliaryStorage(
            creatingStorageAt: store.auxStoragePath(config.name),
            hardwareModel: requirements.hardwareModel,
            options: [])

        config.cpus = max(config.cpus, requirements.minimumSupportedCPUCount)
        config.memoryBytes = max(config.memoryBytes, requirements.minimumSupportedMemorySize)
        try store.createDiskImage(at: store.diskPath(config.name), sizeBytes: diskSizeBytes)
        try store.saveConfig(config)

        let vzConfig = try VMFactory.macosConfiguration(config, store: store)
        let vm = VZVirtualMachine(configuration: vzConfig)

        progress.report(.install, fraction: 0)
        var installError: Error?
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: imageURL)
            let observation = installer.progress.observe(\.fractionCompleted) { installProgress, _ in
                progress.report(.install, fraction: installProgress.fractionCompleted)
            }
            installer.install { result in
                _ = observation
                if case .failure(let error) = result {
                    installError = error
                }
                done.signal()
            }
        }
        // Pump the main run loop while waiting: the installer needs it.
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.25))
        }
        if let installError {
            throw VmctlError("macOS installation failed: \(installError)")
        }
    }

    static func loadRestoreImage(_ url: URL) throws -> VZMacOSRestoreImage {
        var loaded: Result<VZMacOSRestoreImage, Error>?
        let done = DispatchSemaphore(value: 0)
        VZMacOSRestoreImage.load(from: url) { result in
            loaded = result
            done.signal()
        }
        while done.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        switch loaded {
        case .success(let image):
            return image
        case .failure(let error):
            throw VmctlError("Could not read restore image: \(error)")
        case nil:
            throw VmctlError("Could not read restore image.")
        }
    }

    /// Download the newest supported ipsw into the store (cached across VMs).
    static func downloadLatestRestoreImage(
        store: VMStore, progress: InstallProgressReporter = InstallProgressReporter()
    ) throws -> URL {
        try store.ensureExists()
        let target = store.root.appendingPathComponent("RestoreImage.ipsw")
        if FileManager.default.fileExists(atPath: target.path) {
            return target
        }

        progress.report(.lookup)
        var latest: Result<VZMacOSRestoreImage, Error>?
        let fetched = DispatchSemaphore(value: 0)
        VZMacOSRestoreImage.fetchLatestSupported { result in
            latest = result
            fetched.signal()
        }
        while fetched.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        }
        guard case .success(let image) = latest else {
            throw VmctlError("Could not determine the latest macOS restore image.")
        }

        // Not a progress line: the app keeps the plain ones as the detail a
        // failed create is reported with, and which image it was downloading
        // is the first thing worth knowing about a download that failed.
        FileHandle.standardError.write(
            Data("downloading restore image from \(image.url)\n".utf8))
        progress.report(.download, fraction: 0)
        var downloadResult: Result<URL, Error>?
        let downloaded = DispatchSemaphore(value: 0)
        let task = URLSession.shared.downloadTask(with: image.url) { location, _, error in
            if let location {
                downloadResult = .success(location)
            } else {
                downloadResult = .failure(error ?? VmctlError("download failed"))
            }
            downloaded.signal()
        }
        // Several GB over whatever line the Mac is on: without this the app
        // sat on one unchanging message for the better part of an hour.
        let observation = task.progress.observe(\.fractionCompleted) { [weak task] _, _ in
            guard let task else { return }
            // The byte counts come from the task, not from its `Progress`:
            // a download task's progress counts in units of its own (100 of
            // them), so completedUnitCount as "bytes" reads 5 of 100 on a
            // 14 GB image. A response without a Content-Length leaves the
            // expected count at -1, and reporting that as a percent would
            // pin the app's bar at 0% for an hour, so such a download
            // counts bytes only.
            let received = task.countOfBytesReceived
            let expected = task.countOfBytesExpectedToReceive
            progress.report(
                .download,
                fraction: expected > 0 ? Double(received) / Double(expected) : nil,
                received: UInt64(max(received, 0)),
                total: UInt64(max(expected, 0)))
        }
        task.resume()
        while downloaded.wait(timeout: .now()) == .timedOut {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.5))
        }
        observation.invalidate()
        switch downloadResult {
        case .success(let location):
            try FileManager.default.moveItem(at: location, to: target)
            return target
        case .failure(let error):
            throw VmctlError("Restore image download failed: \(error)")
        case nil:
            throw VmctlError("Restore image download failed.")
        }
    }
}
#endif
