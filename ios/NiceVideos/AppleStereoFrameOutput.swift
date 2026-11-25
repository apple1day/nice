import AVFoundation
import UIKit

// Pull the system decoder's frame for the upcoming display tick. The same
// AVPlayerItem keeps the audio clock and seek position when switching to VR.
final class AppleStereoFrameOutput: NSObject, AVPlayerItemOutputPullDelegate {
    private weak var item: AVPlayerItem?
    private var handler: ((CVPixelBuffer) -> Void)?
    private var onAttach: (() -> Void)?
    private var output: AVPlayerItemVideoOutput?
    private var displayLink: CADisplayLink?
    private var lastDelivery = CACurrentMediaTime()
    private(set) var frameSequence: UInt64 = 0
    var hasVideoFrame: Bool { frameSequence > 0 }

    init(item: AVPlayerItem, onAttach: @escaping () -> Void = {}, handler: @escaping (CVPixelBuffer) -> Void) {
        self.item = item
        self.handler = handler
        self.onAttach = onAttach
        super.init()
        attachOutputIfReady()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func attachOutputIfReady() {
        guard output == nil, let item else { return }
        // At first the presentation size may still be zero. Giving the
        // converter the final dimensions avoids allocating 8K BGRA surfaces.
        let size = item.presentationSize
        guard size.width.isFinite, size.height.isFinite,
              size.width > 0, size.height > 0 else { return }
        let scale = min(1, 2560 / max(size.width, size.height))
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: max(2, Int((size.width * scale).rounded())),
            kCVPixelBufferHeightKey as String: max(1, Int((size.height * scale).rounded())),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        let next = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        // Leave the native layer rendering behind the opaque stereo surface
        // so exiting VR can reveal an up-to-date frame immediately.
        next.setDelegate(self, queue: .main)
        item.add(next)
        output = next
        onAttach?()
        onAttach = nil
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let handler else { return }
        attachOutputIfReady()
        guard let output else { return }
        let hostTime = link.targetTimestamp
        let scheduled = output.itemTime(forHostTime: hostTime)
        let time = scheduled.isNumeric ? scheduled : (item?.currentTime() ?? .invalid)
        if time.isNumeric, (!hasVideoFrame || output.hasNewPixelBuffer(forItemTime: time)),
           let frame = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) {
            lastDelivery = hostTime
            frameSequence &+= 1
            handler(frame)
        } else if hasVideoFrame, hostTime - lastDelivery > 0.5 {
            link.isPaused = true
            output.requestNotificationOfMediaDataChange(withAdvanceInterval: 0.05)
        }
    }

    func outputMediaDataWillChange(_ sender: AVPlayerItemOutput) { refresh() }
    func outputSequenceWasFlushed(_ output: AVPlayerItemOutput) { refresh() }

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
            item?.remove(output)
        }
        output = nil
        item = nil
    }
}
