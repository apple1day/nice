import AVFoundation
import UIKit

// The same item supplies both audio and the frame for the upcoming display tick.
final class AppleStereoFrameOutput: NSObject, AVPlayerItemOutputPullDelegate {
    private weak var item: AVPlayerItem?
    private var handler: ((CVPixelBuffer, Double?) -> Void)?
    private var onAttach: (() -> Void)?
    private let preferBiPlanar: () -> Bool
    private let recovery: Bool
    private let afterglowFormat: AfterglowMovieOutput.Format?
    private var afterglowOutput: AfterglowMovieOutput?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var lastDelivery = CACurrentMediaTime()
    private var continuousPull = false
    private var newestDisplayTime: CMTime = .invalid
    private(set) var frameSequence: UInt64 = 0
    private(set) var hasVideoFrame = false
    private(set) var requestDescription = "awaiting presentation size"
    private(set) var ticks: UInt64 = 0
    var isParked: Bool { displayLink?.isPaused == true }

    init(item: AVPlayerItem, recovery: Bool, preferBiPlanar: @escaping () -> Bool,
         afterglowFormat: AfterglowMovieOutput.Format? = nil,
         onAttach: @escaping () -> Void = {}, handler: @escaping (CVPixelBuffer, Double?) -> Void) {
        self.item = item
        self.preferBiPlanar = preferBiPlanar
        self.afterglowFormat = afterglowFormat
        self.recovery = recovery
        self.handler = handler
        self.onAttach = onAttach
        super.init()
        attachOutputIfReady()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if afterglowFormat?.highRate8K == true {
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 30, preferred: 30)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func attachOutputIfReady() {
        guard output == nil, let item else { return }
        if let format = afterglowFormat {
            let next = AfterglowMovieOutput(item: item, format: format)
            afterglowOutput = next
            attach(next.output, description: format.description)
            return
        }
        let size = item.presentationSize
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else { return }
        let longest = max(size.width, size.height)
        let scale = min(1, (recovery ? 1920 : 2560) / longest)
        let biPlanar = (recovery || longest > 4096) && preferBiPlanar()
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
            hasVideoFrame = true
            // If the converter repeatedly returns the same PTS, the decoder
            // has not advanced even though a new buffer object was acquired.
            if !displayTime.isNumeric || !newestDisplayTime.isNumeric || displayTime > newestDisplayTime {
                frameSequence &+= 1
                if displayTime.isNumeric { newestDisplayTime = displayTime }
            }
            handler(frame, displayTime.isNumeric ? displayTime.seconds : nil)
        } else if hasVideoFrame && !continuousPull && hostTime - lastDelivery > 0.5 {
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
        newestDisplayTime = .invalid
        refresh()
    }

    func setContinuousPull(_ enabled: Bool) {
        guard enabled != continuousPull else { return }
        continuousPull = enabled
        if enabled { refresh() }
    }

    func refresh() {
        lastDelivery = CACurrentMediaTime()
        displayLink?.isPaused = false
    }

    func stop() {
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
