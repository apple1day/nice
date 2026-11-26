import CoreVideo
import Metal

// Only aggregate brightness leaves the renderer. Each named region samples the
// centers of a 7 x 5 grid. It may miss small highlights and cannot prove motion.
enum FrameProbeLayout {
    case full, sideBySide, topBottom

    init(mode: SBSDisplayMode, projected: Bool) {
        switch mode {
        case .standard: self = .full
        case .half, .full: self = .sideBySide
        case let .immersive(_, eyes, headset):
            if projected { self = headset ? .sideBySide : .full }
            else {
                switch eyes {
                case .mono: self = .full
                case .sideBySide, .halfSideBySide: self = .sideBySide
                case .topBottom: self = .topBottom
                }
            }
        }
    }

    func summary(width: Int, height: Int, sample: (Int, Int) -> Int) -> String {
        func region(_ name: String, x: Int, y: Int, width: Int, height: Int) -> String {
            guard width > 0, height > 0 else { return "\(name):empty" }
            var total = 0, low = 255, high = 0
            for row in 0..<5 {
                for column in 0..<7 {
                    let value = sample(x + (2 * column + 1) * width / 14, y + (2 * row + 1) * height / 10)
                    low = min(low, value)
                    high = max(high, value)
                    total += value
                }
            }
            return "\(name):\(low)/\((total + 17) / 35)/\(high)"
        }
        switch self {
        case .full:
            return region("full", x: 0, y: 0, width: width, height: height)
        case .sideBySide:
            let half = width / 2
            return region("L", x: 0, y: 0, width: half, height: height) + "," +
                region("R", x: width - half, y: 0, width: half, height: height)
        case .topBottom:
            let half = height / 2
            return region("L", x: 0, y: 0, width: width, height: half) + "," +
                region("R", x: 0, y: height - half, width: width, height: half)
        }
    }

    private func bgra(_ pixel: UnsafePointer<UInt8>) -> Int {
        // Approximate BT.709 luma, scaled to 0...255; skip alpha.
        (19 * Int(pixel[0]) + 183 * Int(pixel[1]) + 54 * Int(pixel[2]) + 128) >> 8
    }

    func input(_ buffer: CVPixelBuffer) -> String {
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return "unavailable(lock)" }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_32BGRA, let start = CVPixelBufferGetBaseAddress(buffer) {
            let base = start.assumingMemoryBound(to: UInt8.self), pitch = CVPixelBufferGetBytesPerRow(buffer)
            return summary(width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer)) { x, y in
                bgra(base + y * pitch + x * 4)
            }
        }
        let videoRange = format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        guard videoRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
              CVPixelBufferGetPlaneCount(buffer) == 2, let start = CVPixelBufferGetBaseAddressOfPlane(buffer, 0)
        else { return "unavailable(format)" }
        let base = start.assumingMemoryBound(to: UInt8.self), pitch = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        return summary(width: CVPixelBufferGetWidthOfPlane(buffer, 0), height: CVPixelBufferGetHeightOfPlane(buffer, 0)) { x, y in
            let yValue = Int(base[y * pitch + x])
            return videoRange ? min(255, max(0, (yValue - 16) * 255 / 219)) : yValue
        }
    }

    func projection(_ texture: MTLTexture) -> String {
        // The source is exclusively the tiny diagnostic render target.
        guard texture.width <= 64, texture.height <= 64 else { return "unavailable(dimensions)" }
        let pitch = texture.width * 4
        var bytes = [UInt8](repeating: 0, count: pitch * texture.height)
        return bytes.withUnsafeMutableBufferPointer { storage in
            guard let base = storage.baseAddress else { return "unavailable(storage)" }
            texture.getBytes(base, bytesPerRow: pitch, from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
            return summary(width: texture.width, height: texture.height) { x, y in bgra(base + y * pitch + x * 4) }
        }
    }
}

struct PlaybackFrameOrigin: Equatable {
    let route: MovieOutput
    let loadID: UInt64
}
