import CoreVideo
import MetalKit
import UIKit

enum SBSDisplayMode: Equatable {
    case standard
    case half  // Each view was compressed horizontally by a factor of two.
    case full  // Each half already has the correct eye image aspect ratio.

    func eyeAspect(packedAspect: CGFloat) -> CGFloat {
        self == .half ? packedAspect : packedAspect / 2
    }
}

struct SBSMovieVertex {
    var position: SIMD2<Float>
    var movieUV: SIMD2<Float>
}

// The same mesh is drawn in both viewports. Only the sampled half of the
// video texture changes. All geometry work happens on a mode or size change.
struct SBSMovieGeometry: Equatable {
    static let subdivisions = 32
    let eyeViewportSize: CGSize
    let eyeAspect: CGFloat

    var vertices: [SBSMovieVertex] {
        let width = Float(eyeViewportSize.width), height = Float(eyeViewportSize.height)
        let aspect = Float(eyeAspect)
        guard width > 0, height > 0, aspect.isFinite, aspect > 0 else { return [] }
        let movieHeight = min(height, width / aspect)
        let movieWidth = movieHeight * aspect
        // A centered generic viewer, using the v1 half-FOV (40 degrees).
        // Both axes need the *same* pixel-to-tan-angle scale for circular lenses.
        let tanPerPixel = 2 * tan(Float.pi * 40 / 180) / min(width, height)
        var mesh: [SBSMovieVertex] = []
        let n = Self.subdivisions
        mesh.reserveCapacity((n + 1) * (n + 1))
        for row in 0...n {
            let v = Float(row) / Float(n)
            for column in 0...n {
                let u = Float(column) / Float(n)
                let point = NICECardboardScreenPoint(
                    (u - 0.5) * movieWidth * tanPerPixel,
                    (0.5 - v) * movieHeight * tanPerPixel
                )
                mesh.append(SBSMovieVertex(
                    position: SIMD2(point.x * 2 / (tanPerPixel * width),
                                    point.y * 2 / (tanPerPixel * height)),
                    movieUV: SIMD2(u, v)
                ))
            }
        }
        return mesh
    }

    static let indices: [UInt16] = {
        let n = subdivisions, stride = n + 1
        var indices: [UInt16] = []
        indices.reserveCapacity(6 * n * n)
        for row in 0..<n {
            for column in 0..<n {
                let top = UInt16(row * stride + column)
                let bottom = top + UInt16(stride)
                indices.append(contentsOf: [top, bottom, top + 1, top + 1, bottom, bottom + 1])
            }
        }
        return indices
    }()
}

@MainActor
final class SBSMetalView: UIView, MTKViewDelegate {
    private struct Frame {
        let pixelBuffer: CVPixelBuffer
        let imageTexture: CVMetalTexture?
        let texture: MTLTexture
        let packedAspect: CGFloat
    }

    var mode: SBSDisplayMode = .standard {
        didSet { if oldValue != mode { metalView.setNeedsDisplay() } }
    }

    private let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    private let errorLabel = UILabel()
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var indexBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    private var geometry: SBSMovieGeometry?
    private var frameToDraw: Frame?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        addSubview(metalView)
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = true
        metalView.delegate = self

        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        errorLabel.frame = bounds
        addSubview(errorLabel)
        configureMetal()
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func configureMetal() {
        guard let device = metalView.device else {
            errorLabel.text = "当前设备无法启用 VR 图形显示。"
            return
        }
        queue = device.makeCommandQueue()
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
        let library = device.makeDefaultLibrary()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library?.makeFunction(name: "sbsMovieVertex")
        descriptor.fragmentFunction = library?.makeFunction(name: "sbsMovieFragment")
        descriptor.colorAttachments[0].pixelFormat = metalView.colorPixelFormat
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        let indices = SBSMovieGeometry.indices
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: [])
        if queue == nil || pipeline == nil || indexBuffer == nil {
            errorLabel.text = "无法初始化 VR 画面，请退出 VR 模式。"
        }
    }

    func clear() {
        frameToDraw = nil
        metalView.setNeedsDisplay()
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        guard let device = metalView.device, pipeline != nil, queue != nil, indexBuffer != nil else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 2, height > 0, CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            errorLabel.text = "VR 模式无法显示该视频帧。"
            clear()
            return
        }
        var cvTexture: CVMetalTexture?
        if let textureCache {
            CVMetalTextureCacheCreateTextureFromImage(nil, textureCache, pixelBuffer, nil,
                                                     .bgra8Unorm, width, height, 0, &cvTexture)
        }
        // VLC can also supply CPU-backed rows. Use their real pitch and copy
        // before relinquishing the lock when the zero-copy mapping is unavailable.
        let texture = cvTexture.flatMap { CVMetalTextureGetTexture($0) }
            ?? upload(pixelBuffer, width: width, height: height, device: device)
        guard let texture else {
            errorLabel.text = "无法上传 VR 视频帧，请退出 VR 模式。"
            clear()
            return
        }
        let displaySize = CVImageBufferGetDisplaySize(pixelBuffer)
        let aspect = displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height : CGFloat(width) / CGFloat(height)
        frameToDraw = Frame(pixelBuffer: pixelBuffer, imageTexture: cvTexture,
                            texture: texture, packedAspect: aspect)
        errorLabel.text = nil
        metalView.setNeedsDisplay()
    }

    private func upload(_ buffer: CVPixelBuffer, width: Int, height: Int, device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width,
                                                                 height: height, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let address = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                        withBytes: address, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer))
        return texture
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        view.setNeedsDisplay()
    }

    func draw(in view: MTKView) {
        guard let command = queue?.makeCommandBuffer(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else { return }
        encodeMovie(pass: pass, command: command)
        command.present(drawable)
        command.commit()
    }

    // The view and offscreen render tests use the same render pass.
    func encodeMovie(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) {
        guard let device = metalView.device, let target = pass.colorAttachments[0].texture,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        if let frame = frameToDraw, mode != .standard, let pipeline, let indexBuffer {
            let width = Double(target.width) / 2, height = Double(target.height)
            let nextGeometry = SBSMovieGeometry(eyeViewportSize: CGSize(width: width, height: height),
                                               eyeAspect: mode.eyeAspect(packedAspect: frame.packedAspect))
            if geometry != nextGeometry || vertexBuffer == nil {
                let vertices = nextGeometry.vertices
                vertexBuffer = vertices.isEmpty ? nil : device.makeBuffer(
                    bytes: vertices, length: vertices.count * MemoryLayout<SBSMovieVertex>.stride, options: []
                )
                geometry = nextGeometry
            }
            if let vertexBuffer {
                encoder.setRenderPipelineState(pipeline)
                encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
                encoder.setFragmentTexture(frame.texture, index: 0)
                for eye in 0..<2 {
                    encoder.setViewport(MTLViewport(originX: Double(eye) * width, originY: 0, width: width,
                                                    height: height, znear: 0, zfar: 1))
                    var start = Float(eye) * 0.5
                    encoder.setFragmentBytes(&start, length: MemoryLayout<Float>.stride, index: 0)
                    encoder.drawIndexedPrimitives(type: .triangle, indexCount: SBSMovieGeometry.indices.count,
                                                  indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0)
                }
                // The GPU may still be reading this IOSurface after the next video
                // frame arrives. Keep both the CVMetalTexture and source buffer alive.
                command.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
            }
        }
        encoder.endEncoding()
    }
}
