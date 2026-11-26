import CoreVideo
import Darwin
import Foundation
import OSLog

protocol PlaybackDiagnosticReporting: AnyObject {
    @MainActor func playbackDiagnosticReport() -> String?
}

/// A bounded trace for one movie. Only app-generated labels and numerical media
/// properties enter this report. File names, URLs and localized errors can contain
/// private provider paths, so they are deliberately absent from the interface.
final class PlaybackDiagnostics {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "NiceVideos", category: "NiceVR")
    private static let capacity = 36
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let log: (String) -> Void
    private let start: TimeInterval
    private let session = String(UUID().uuidString.prefix(8))
    private let header: String
    private var history: [String] = []
    private var lastSample: TimeInterval?
    private var phase = PlaybackPhase.idle
    private var clock: Double = 0
    private var duration: Double = 0
    private var ready = false
    private var track = "unknown"
    private var route: MovieOutput?
    private var mode: SBSDisplayMode?
    private var apple = ""
    private var vlc = ""
    private var copies: UInt64 = 0
    private var width = 0
    private var height = 0
    private var format: OSType = 0
    private var lastCopy: TimeInterval?
    private var lastPTS: Double?

    init(bytes: UInt64?, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         log: ((String) -> Void)? = nil) {
        self.now = now
        self.start = now()
        self.log = log ?? { line in Self.logger.notice("[NiceVR] \(line, privacy: .public)") }
        var system = utsname()
        uname(&system)
        let hardware = withUnsafeBytes(of: &system.machine) { buffer in
            String(decoding: buffer.prefix(while: { $0 != 0 }), as: UTF8.self)
        }
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "?"
        let build = info["CFBundleVersion"] as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let size = bytes.map { String($0) } ?? "unknown"
        header = "session=\(session) app=\(version)(\(build)) device=\(hardware) iOS=\(os.majorVersion).\(os.minorVersion).\(os.patchVersion) fileBytes=\(size)"
        self.log(header)
    }

    func setRoute(_ route: MovieOutput, mode: SBSDisplayMode) {
        lock.withLock {
            guard route != self.route || mode != self.mode else { return }
            if route != self.route {
                copies = 0; width = 0; height = 0; format = 0
                lastCopy = nil; lastPTS = nil; apple = ""; vlc = ""
            }
            self.route = route
            self.mode = mode
            lastSample = nil
            record("output \(route) mode=\(mode)", at: now())
        }
    }

    // Called once per buffer obtained from AVPlayerItemVideoOutput / forwarded by VLC.
    // No logger, texture creation, SwiftUI update, or pixel access on the frame path.
    func decodedFrame(_ buffer: CVPixelBuffer, pts: Double?) {
        lock.withLock {
            copies &+= 1
            width = CVPixelBufferGetWidth(buffer)
            height = CVPixelBufferGetHeight(buffer)
            format = CVPixelBufferGetPixelFormatType(buffer)
            lastCopy = now()
            lastPTS = pts.flatMap { $0.isFinite ? $0 : nil }
        }
    }

    func appleStatus(_ value: String) { lock.withLock { apple = value } }
    func vlcStatus(_ value: String) { lock.withLock { vlc = value } }
    func event(_ message: String) { lock.withLock { record(message, at: now()) } }

    func observe(_ snapshot: PlaybackSnapshot, renderer: () -> String) {
        lock.withLock {
            let t = now()
            let phaseChanged = phase != snapshot.phase
            phase = snapshot.phase
            clock = snapshot.seconds
            duration = snapshot.duration
            ready = snapshot.hasVideo
            if let details = snapshot.videoDetails { track = details }
            // State transitions can arrive in bursts during a seek. Sample those at
            // most once a second, except failures, which precede decoder fallback.
            let interval: Double = phaseChanged ? 1 : 5
            if let lastSample, t - lastSample < interval, !(phaseChanged && phase == .failed) { return }
            lastSample = t
            record(sample(at: t, renderer: renderer()), at: t)
        }
    }

    func report(renderer: () -> String) -> String {
        lock.withLock {
            let t = now()
            let current = line("capture " + sample(at: t, renderer: renderer()), at: t)
            log("session=\(session) \(current)")
            return (["NiceVideos playback diagnostics", header] + history + [current]).joined(separator: "\n")
        }
    }

    private func sample(at time: TimeInterval, renderer: String) -> String {
        let age = lastCopy.map { Self.number(time - $0) } ?? "-"
        let pts = lastPTS.map(Self.number) ?? "-"
        let routeLabel = route.map { String(describing: $0) } ?? "pending"
        let modeLabel = mode.map { String(describing: $0) } ?? "pending"
        var values = ["phase=\(phase)", "media=\(Self.number(clock))/\(Self.number(duration))",
                      "route=\(routeLabel)", "mode=\(modeLabel)", "videoReady=\(ready ? 1 : 0)",
                      "track={\(track)}", "copied=\(copies)", "copyAge=\(age)s", "framePTS=\(pts)",
                      "buffer=\(width)x\(height)", "fourcc=\(Self.fourCC(format))",
                      "thermal=\(ProcessInfo.processInfo.thermalState.rawValue)"]
        if !apple.isEmpty { values.append(apple) }
        if !vlc.isEmpty { values.append(vlc) }
        values.append(renderer)
        return values.joined(separator: " ")
    }

    private static func fourCC(_ code: OSType) -> String {
        guard code != 0 else { return "-" }
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: code >> $0) }
        guard bytes.allSatisfy({ (32...126).contains($0) }) else { return String(code, radix: 16) }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func number(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), value) : "-"
    }

    private func line(_ text: String, at t: TimeInterval) -> String { "+\(Self.number(t - start))s \(text)" }

    private func record(_ value: String, at time: TimeInterval) {
        let value = line(value, at: time)
        if history.count == Self.capacity { history.removeFirst() }
        history.append(value)
        log("session=\(session) \(value)")
    }
}
