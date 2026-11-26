// Adapted from Afterglow, app/Afterglow/Media/VideoPlayer.swift.
// Upstream revision fac3236d61b3196846c63fc4bcc4188da4691142. Apache-2.0.
// NiceVideos changes: bounded pixel buffers, SDR two-plane support and presentation
// timestamps. NiceVideos' shared Metal texture cache retains the decoder surface
// through GPU completion and samples each eye from the same packed picture.
import AVFoundation
import CoreVideo

/// Afterglow uses the ordinary movie output for a packed SBS movie. The tagged
/// AVPlayerVideoOutput in its spatial-video branch is for two-layer MV-HEVC.
final class AfterglowMovieOutput {
    struct Format {
        let size: CGSize
        let biPlanar: Bool

        init?(source: CGSize, sdr: Bool, recovery: Bool) {
            let longest = max(source.width, source.height)
            guard source.width.isFinite, source.height.isFinite, source.width >= 2,
                  source.height >= 2, longest <= CGFloat(Int32.max) else { return nil }
            let scale = min(1, (recovery ? 1280 : 1920) / longest)
            // Even dimensions keep 4:2:0 planes aligned and preserve the packed eye layout.
            size = CGSize(width: max(2, (source.width * scale / 2).rounded() * 2),
                          height: max(2, (source.height * scale / 2).rounded() * 2))
            biPlanar = sdr
        }

        var description: String { "Afterglow packed \(biPlanar ? "420v" : "BGRA") \(Int(size.width))x\(Int(size.height))" }
    }

    let output: AVPlayerItemVideoOutput

    init(item: AVPlayerItem, format: Format) {
        let attributes: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: format.biPlanar
                ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange : kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(format.size.width),
            kCVPixelBufferHeightKey as String: Int(format.size.height),
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]
        ]
        output = AVPlayerItemVideoOutput(pixelBufferAttributes: attributes)
        item.add(output)
    }

    /// Pull only the latest picture for this display time, as in VideoPlayer.frame(at:).
    /// The optional first-frame pull also supports a paused seek to the start.
    func frame(at hostTime: CFTimeInterval, allowFirst: Bool) -> (CVPixelBuffer, CMTime)? {
        let itemTime = output.itemTime(forHostTime: hostTime)
        guard itemTime.isNumeric, allowFirst || output.hasNewPixelBuffer(forItemTime: itemTime) else { return nil }
        var pts = CMTime.invalid
        guard let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: &pts) else { return nil }
        return (buffer, pts)
    }
}
