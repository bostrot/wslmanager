import Foundation

/// Where a long-running create is, reported on stderr one line per step:
///
///     progress {"fraction":0.42,"phase":"download","received":6,"total":14}
///
/// A macOS guest takes tens of minutes — a restore image of several GB to
/// fetch and then a full installer run — and until this existed the app had
/// nothing to show for any of it but "Creating instance"
/// (bostrot/ai-tasks#100). The line is JSON so the app can drive a progress
/// bar from it, and prefixed so the same stream can still carry plain
/// diagnostics: anything that is not a progress line is the helper talking
/// about a failure.
public enum InstallProgress {
    /// What marks a line as a progress report rather than a diagnostic.
    public static let linePrefix = "progress "

    /// The steps a create reports, in the order they happen.
    public enum Phase: String {
        /// Asking Apple which restore image this Mac supports.
        case lookup
        /// Fetching that image (several GB).
        case download
        /// Writing the platform blobs and the guest's disk.
        case prepare
        /// The installer itself.
        case install
    }

    /// One report, terminated by a newline. [fraction] is rounded to whole
    /// percent: the installer's observer fires far more often than that, and
    /// a line per notification would be thousands of them.
    public static func line(
        phase: Phase,
        fraction: Double? = nil,
        received: UInt64? = nil,
        total: UInt64? = nil
    ) -> String {
        var payload: [String: Any] = ["phase": phase.rawValue]
        if let fraction {
            payload["fraction"] = Double(percent(of: fraction)) / 100.0
        }
        if let received { payload["received"] = received }
        if let total, total > 0 { payload["total"] = total }
        guard
            let data = try? JSONSerialization.data(
                withJSONObject: payload, options: [.sortedKeys]),
            let json = String(data: data, encoding: .utf8)
        else {
            return "\(linePrefix){\"phase\":\"\(phase.rawValue)\"}\n"
        }
        return "\(linePrefix)\(json)\n"
    }

    /// Whole percent, clamped: `Progress` reports a fraction slightly past 1
    /// on the last notification of some tasks, and -1 while a download's
    /// total is still unknown.
    static func percent(of fraction: Double) -> Int {
        Int((min(max(fraction, 0), 1) * 100).rounded())
    }

    /// How much a download without a known total has to grow before it is
    /// worth another line. A server that sends no `Content-Length` leaves
    /// the fraction at -1 for the whole transfer, so percent alone would
    /// report the download once and then say nothing for the rest of an
    /// hour — the very silence this protocol exists to end.
    static let byteStep: UInt64 = 64 * 1024 * 1024
}

/// Writes [InstallProgress] lines, skipping the ones that would say what the
/// last one already said.
///
/// The installer's `fractionCompleted` observer fires continuously; a
/// consumer only ever sees whole percent, so a step that has not moved a
/// percent is not worth a line. A phase that reports neither a percent nor
/// bytes is reported once; one that only counts bytes gets a line per
/// [InstallProgress.byteStep].
///
/// Locked because the reports come from whichever queue the observed
/// `Progress` happens to notify on, and a torn line on stderr is a line the
/// app cannot parse.
public final class InstallProgressReporter {
    private let sink: (String) -> Void
    private let lock = NSLock()
    private var lastKey: String?

    public init(sink: @escaping (String) -> Void = InstallProgressReporter.standardError) {
        self.sink = sink
    }

    /// The default destination: the app reads this process's stderr.
    public static func standardError(_ line: String) {
        FileHandle.standardError.write(Data(line.utf8))
    }

    public func report(
        _ phase: InstallProgress.Phase,
        fraction: Double? = nil,
        received: UInt64? = nil,
        total: UInt64? = nil
    ) {
        let step = received.map { $0 / InstallProgress.byteStep } ?? 0
        let key =
            "\(phase.rawValue)|\(fraction.map(InstallProgress.percent(of:)) ?? -1)|\(step)"
        lock.lock()
        defer { lock.unlock() }
        guard key != lastKey else { return }
        lastKey = key
        sink(
            InstallProgress.line(
                phase: phase, fraction: fraction, received: received, total: total))
    }
}
