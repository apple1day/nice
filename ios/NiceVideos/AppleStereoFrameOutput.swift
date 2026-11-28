import AVFoundation
import UIKit

// The same item supplies both audio and the frame for the upcoming display tick.
final class AppleStereoFrameOutput: NSObject, AVPlayerItemOutputPullDelegate {
    private weak var item: AVPlayerItem?
    private var handler: ((CVPixelBuffer, Double?, Bool) -> Void)?
    private var onAttach: (() -> Void)?
    private let preferBiPlanar: () -> Bool
    private let trackSize: () -> CGSize?
    private let recovery: Bool
    private let afterglowFormat: AfterglowMovieOutput.Format?
    private var afterglowOutput: AfterglowMovieOutput?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var cadenceObserver: NSObjectProtocol?
    private var lastDelivery = CACurrentMediaTime()
    private var continuousPull = false
    private var pausedByUser = false
    private var newestDisplayTime: CMTime = .invalid
    private(set) var frameSequence: UInt64 = 0
    private(set) var hasVideoFrame = false
    private(set) var requestDescription = "awaiting presentation size"
    private(set) var ticks: UInt64 = 0
    var isParked: Bool { displayLink?.isPaused == true }

    init(item: AVPlayerItem, recovery: Bool, preferBiPlanar: @escaping () -> Bool,
         trackSize: @escaping () -> CGSize?, afterglowFormat: AfterglowMovieOutput.Format? = nil,
         onAttach: @escaping () -> Void = {}, handler: @escaping (CVPixelBuffer, Double?, Bool) -> Void) {
        self.item = item
        self.preferBiPlanar = preferBiPlanar
        self.trackSize = trackSize
        self.afterglowFormat = afterglowFormat
        self.recovery = recovery
        self.handler = handler
        self.onAttach = onAttach
        super.init()
        attachOutputIfReady()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        displayLink = link
        if afterglowFormat != nil {
            applyAfterglowCadence()
            cadenceObserver = NotificationCenter.default.addObserver(
                forName: UserDefaults.didChangeNotification, object: UserDefaults.standard, queue: .main
            ) { [weak self] _ in self?.applyAfterglowCadence() }
        }
        link.add(to: .main, forMode: .common)
    }

    private func applyAfterglowCadence() {
        let rate: Float = UserDefaults.standard.integer(forKey: AfterglowPreset.frameRateKey) == 60 ? 60 : 30
        displayLink?.preferredFrameRateRange = CAFrameRateRange(minimum: rate, maximum: rate, preferred: rate)
    }

    private func attachOutputIfReady() {
        guard output == nil, let item else { return }
        if let format = afterglowFormat {
            let next = AfterglowMovieOutput(item: item, format: format)
            afterglowOutput = next
            attach(next.output, description: format.description)
            return
        }
        // Some local HEVC items keep presentationSize at zero until an
        // output is attached. The selected track already has its dimensions.
        let presented = item.presentationSize
        let metadata = trackSize()
        let size = presented.width > 0 && presented.height > 0 ? presented : (metadata ?? .zero)
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let longest = max(size.width, size.height)
        // Wait for color metadata before negotiating an 8K conversion.
        // An early BGRA request costs bandwidth for the entire session.
        let large = longest > 4096
        guard !large || metadata != nil else { return }
        let limit: CGFloat = large ? (recovery ? 1280 : 1920) : (recovery ? 1920 : 2560)
        let scale = min(1, limit / longest)
        let biPlanar = (recovery || large) && preferBiPlanar()
        let format = biPlanar ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA
        var width = max(2, Int((size.width * scale).rounded()))
        var height = max(1, Int((size.height * scale).rounded()))
        if biPlanar {
            width -= width % 2
            height = max(2, height - height % 2)
        }
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let next = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        // For large tracks the visible Metal projection is the sole video
        // destination. Smaller movies keep a warm layer for the return to 2D.
        next.suppressesPlayerRendering = large
        item.add(next)
        attach(next, description: "\(biPlanar ? "420v" : "BGRA") \(width)x\(height)")
    }

    private func attach(_ next: AVPlayerItemVideoOutput, description: String) {
        next.setDelegate(self, queue: .main)
        output = next
        requestDescription = description
        onAttach?()
        onAttach = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let handler else { return }
        ticks &+= 1
        attachOutputIfReady()
        guard let output else { return }
        let hostTime = link.targetTimestamp
        if let (frame, displayTime) = frame(for: hostTime, output: output) {
            lastDelivery = hostTime
            let firstInSequence = !hasVideoFrame
            hasVideoFrame = true
            // If the converter repeatedly returns the same PTS, the decoder
            // has not advanced even though a new buffer object was acquired.
            if !displayTime.isNumeric || !newestDisplayTime.isNumeric || displayTime > newestDisplayTime {
                frameSequence &+= 1
                if displayTime.isNumeric { newestDisplayTime = displayTime }
            }
            handler(frame, displayTime.isNumeric ? displayTime.seconds : nil, firstInSequence)
        } else if (hasVideoFrame || pausedByUser) && !continuousPull && hostTime - lastDelivery > 0.5 {
            // Park only when playback is quiescent. A delayed frame while the
            // audio clock runs must not put the consumer to sleep.
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.05)
            link.isPaused = true
        }
    }

    private func frame(for hostTime: CFTimeInterval, output: AVPlayerItemVideoOutput) -> (CVPixelBuffer, CMTime)? {
        if let afterglowOutput { return afterglowOutput.frame(at: hostTime, allowFirst: !hasVideoFrame) }
        let scheduled = output.itemTime(forHostTime: hostTime)
        let time = scheduled.isNumeric ? scheduled : (item?.currentTime() ?? .invalid)
        var displayTime = CMTime.invalid
        guard time.isNumeric, !hasVideoFrame || output.hasNewPixelBuffer(forItemTime: time),
              let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: &displayTime) else { return nil }
        return (frame, displayTime)
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) {
        guard sender === output else { return }
        refresh()
    }

    func outputSequenceWasFlushed(_ sender: AVPlayerItemOutput) {
        guard sender === output else { return }
        refreshAfterSeek()
    }

    func refreshAfterSeek() {
        // The last buffer belongs to the previous timeline. Permit a first pull
        // again even if a paused AV output doesn't advertise a new picture.
        if afterglowOutput != nil { hasVideoFrame = false }
        newestDisplayTime = .invalid
        refresh()
    }

    func setContinuousPull(_ enabled: Bool, paused: Bool) {
        let resume = pausedByUser && !paused
        pausedByUser = afterglowOutput != nil && paused
        guard enabled != continuousPull || resume else { return }
        continuousPull = enabled
        if enabled || resume { refresh() }
    }

    func refresh() {
        lastDelivery = CACurrentMediaTime()
        displayLink?.isPaused = false
    }

    func stop() {
        if let cadenceObserver { NotificationCenter.default.removeObserver(cadenceObserver) }
        cadenceObserver = nil
        displayLink?.invalidate()
        displayLink = nil
        handler = nil
        onAttach = nil
        if let output {
            output.setDelegate(nil, queue: nil)
            if let item, item.outputs.contains(where: { $0 === output }) { item.remove(output) }
        }
        output = nil
        afterglowOutput = nil
        item = nil
    }
}
