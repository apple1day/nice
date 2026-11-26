import CoreVideo
import Metal

// Keep the Core Video wrappers and decoder surface alive until a command
// that samples them completes. An MTLTexture does not retain its CVMetalTexture.
struct MetalMovieFrame {
    private struct Plane {
        let mapping: CVMetalTexture?
        let texture: MTLTexture
        let cacheResult: CVReturn
    }

    // Layout shared with MovieColor in SBSMovie.metal.
    private struct MovieColor {
        var levels = SIMD4<Float>.zero // luma black, chroma center, luma/chroma scale
        var coefficients = SIMD4<Float>.zero // R:Cr, G:Cb, G:Cr, B:Cb
    }

    let id: UInt64
    let pixelBuffer: CVPixelBuffer
    let packedAspect: CGFloat
    private let lumaOrColor: Plane
    private let chroma: Plane?
    private let conversion: MovieColor
    var texture: MTLTexture { lumaOrColor.texture }
    var copiedToGPU: Bool { lumaOrColor.mapping == nil || (chroma != nil && chroma?.mapping == nil) }
    var cacheResult: CVReturn {
        lumaOrColor.cacheResult == kCVReturnSuccess ? (chroma?.cacheResult ?? kCVReturnSuccess) : lumaOrColor.cacheResult
    }

    struct MappingError: Error { let reason: String }

    init(id: UInt64, buffer: CVPixelBuffer, device: MTLDevice, cache: CVMetalTextureCache?) throws {
        self.id = id
        pixelBuffer = buffer
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer)
        // Maximum 2D texture dimension on iPhones supported by this target.
        guard width >= 2, height > 0, max(width, height) <= 16384 else {
            throw MappingError(reason: "texture-dimensions")
        }
        let displaySize = CVImageBufferGetDisplaySize(buffer)
        packedAspect = displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height : CGFloat(width) / CGFloat(height)
        switch format {
        case kCVPixelFormatType_32BGRA:
            conversion = MovieColor()
            lumaOrColor = try Self.plane(buffer, index: 0, format: .bgra8Unorm, device: device, cache: cache)
            chroma = nil
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange:
            guard CVPixelBufferGetPlaneCount(buffer) == 2 else { throw MappingError(reason: "nv12-plane-count") }
            let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferYCbCrMatrixKey, nil) as? String
            let kr: Float, kb: Float
            if attachment == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String || (attachment == nil && height <= 576) {
                (kr, kb) = (0.299, 0.114)
            } else if attachment == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String {
                (kr, kb) = (0.2627, 0.0593)
            } else { (kr, kb) = (0.2126, 0.0722) }
            let kg = 1 - kr - kb
            let full = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            conversion = MovieColor(
                levels: SIMD4(full ? 0 : 16.0 / 255, 128.0 / 255, full ? 1 : 255.0 / 219, full ? 1 : 255.0 / 224),
                coefficients: SIMD4(2 * (1 - kr), -2 * kb * (1 - kb) / kg, -2 * kr * (1 - kr) / kg, 2 * (1 - kb))
            )
            lumaOrColor = try Self.plane(buffer, index: 0, format: .r8Unorm, device: device, cache: cache)
            chroma = try Self.plane(buffer, index: 1, format: .rg8Unorm, device: device, cache: cache)
        default:
            throw MappingError(reason: "unsupported-pixel-format")
        }
    }

    func bind(to encoder: MTLRenderCommandEncoder) {
        encoder.setFragmentTexture(lumaOrColor.texture, index: 0)
        // Also bind for BGRA so both functions validate on every Metal device.
        encoder.setFragmentTexture(chroma?.texture ?? lumaOrColor.texture, index: 1)
        var constants = conversion
        encoder.setFragmentBytes(&constants, length: MemoryLayout<MovieColor>.stride, index: 1)
    }

    private static func plane(_ buffer: CVPixelBuffer, index: Int, format: MTLPixelFormat,
                              device: MTLDevice, cache: CVMetalTextureCache?) throws -> Plane {
        let planar = CVPixelBufferIsPlanar(buffer)
        let width = planar ? CVPixelBufferGetWidthOfPlane(buffer, index) : CVPixelBufferGetWidth(buffer)
        let height = planar ? CVPixelBufferGetHeightOfPlane(buffer, index) : CVPixelBufferGetHeight(buffer)
        guard width > 0, height > 0 else { throw MappingError(reason: "empty-plane-\(index)") }
        var mapped: CVMetalTexture?
        var result: CVReturn = kCVReturnInvalidArgument
        if let cache {
            result = CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, nil, format, width, height, index, &mapped)
            if result == kCVReturnSuccess, let mapped, let texture = CVMetalTextureGetTexture(mapped) {
                return Plane(mapping: mapped, texture: texture, cacheResult: result)
            }
        }

        // VLC and some providers supply CPU-backed pixel buffers. Preserve each
        // plane's actual row pitch. Never reinterpret bi-planar data as BGRA.
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MappingError(reason: "allocate-plane-\(index)-cv\(result)")
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            throw MappingError(reason: "lock-plane-\(index)-cv\(result)")
        }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let address = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, index) : CVPixelBufferGetBaseAddress(buffer)
        let pitch = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, index) : CVPixelBufferGetBytesPerRow(buffer)
        guard let address else { throw MappingError(reason: "address-plane-\(index)-cv\(result)") }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0, withBytes: address, bytesPerRow: pitch)
        return Plane(mapping: nil, texture: texture, cacheResult: result)
    }
}
