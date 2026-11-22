import Foundation
import Testing

@testable import VMCtlKit

@Suite("install progress")
struct InstallProgressTests {
    @Test("a report is one prefixed JSON line")
    func lineShape() throws {
        let line = InstallProgress.line(
            phase: .download, fraction: 0.4242, received: 6, total: 14)
        #expect(line.hasSuffix("\n"))
        #expect(line.hasPrefix(InstallProgress.linePrefix))

        let json = line.dropFirst(InstallProgress.linePrefix.count)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["phase"] as? String == "download")
        // Rounded to whole percent: the raw fraction would be a new line
        // on every notification.
        #expect(decoded["fraction"] as? Double == 0.42)
        #expect(decoded["received"] as? UInt64 == 6)
        #expect(decoded["total"] as? UInt64 == 14)
    }

    @Test("a phase without a fraction carries only its name")
    func phaseOnly() throws {
        let line = InstallProgress.line(phase: .prepare)
        let json = line.dropFirst(InstallProgress.linePrefix.count)
        let decoded = try #require(
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(decoded["phase"] as? String == "prepare")
        #expect(decoded["fraction"] == nil)
        #expect(decoded["total"] == nil)
    }

    /// A download whose total is still unknown reports -1 units, and the
    /// last notification of a task can read slightly over 1.
    @Test("out-of-range fractions clamp instead of escaping the bar")
    func clamping() {
        #expect(InstallProgress.percent(of: -1) == 0)
        #expect(InstallProgress.percent(of: 1.2) == 100)
    }

    @Test("only a whole-percent change is worth a line")
    func throttling() {
        var lines: [String] = []
        let reporter = InstallProgressReporter { lines.append($0) }
        reporter.report(.install, fraction: 0.4201)
        reporter.report(.install, fraction: 0.4202)
        reporter.report(.install, fraction: 0.4249)
        #expect(lines.count == 1)
        reporter.report(.install, fraction: 0.43)
        #expect(lines.count == 2)
    }

    /// Apple's CDN sends a length, but a proxy or a mirror need not: then
    /// `Progress` stays at -1 units for the whole transfer and percent
    /// alone would report the download once and go quiet for an hour.
    @Test("a download with no percent still reports as it grows")
    func bytesWithoutAPercent() {
        var lines: [String] = []
        let reporter = InstallProgressReporter { lines.append($0) }
        reporter.report(.download, received: 1)
        reporter.report(.download, received: InstallProgress.byteStep - 1)
        #expect(lines.count == 1)
        reporter.report(.download, received: InstallProgress.byteStep)
        #expect(lines.count == 2)
        #expect(lines[1].contains("\"received\":\(InstallProgress.byteStep)"))
        #expect(!lines[1].contains("fraction"))
    }

    @Test("a fractionless phase is reported once, and a later phase again")
    func fractionlessPhases() {
        var lines: [String] = []
        let reporter = InstallProgressReporter { lines.append($0) }
        reporter.report(.lookup)
        reporter.report(.lookup)
        reporter.report(.prepare)
        #expect(lines.count == 2)
        #expect(lines[0].contains("\"phase\":\"lookup\""))
        #expect(lines[1].contains("\"phase\":\"prepare\""))
    }
}
