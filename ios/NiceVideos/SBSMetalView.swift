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
        didSet { if oldValue != mode { requestDraw() } }
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
    var isReadyForDisplay: Bool {
        metalView.device != nil && queue != nil && pipeline != nil && indexBuffer != nil
    }

    private var needsDraw = false
    private var missedDrawables = 0
    // Leave room in the decoder's bounded pool for its scratch, incoming and
    // newest pending frame. Never wait for the GPU on the UI thread.
    private let gpuSlots = DispatchSemaphore(value: 2)
    private static let flatQuad = [
        SBSMovieVertex(position: SIMD2(-1, 1), movieUV: SIMD2(0, 0)),
        SBSMovieVertex(position: SIMD2(-1, -1), movieUV: SIMD2(0, 1)),
        SBSMovieVertex(position: SIMD2(1, 1), movieUV: SIMD2(1, 0)),
        SBSMovieVertex(position: SIMD2(1, -1), movieUV: SIMD2(1, 1))
    ]

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        isUserInteractionEnabled = false
        addSubview(metalView)
        metalView.frame = bounds
        metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        metalView.clearColor = MTLClearColorMake(0, 0, 0, 1)
        metalView.isPaused = true
        metalView.enableSetNeedsDisplay = false
        metalView.delegate = self

        errorLabel.textColor = .white
        errorLabel.textAlignment = .center
        errorLabel.numberOfLines = 2
        errorLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        errorLabel.frame = bounds
        addSubview(errorLabel)
        configureMetal()
        for event in [UIApplication.didBecomeActiveNotification, UIScene.didActivateNotification, UIWindow.didBecomeVisibleNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(presentationDidBecomeAvailable(_:)),
                                                   name: event, object: nil)
        }
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive(_:)),
                                               name: UIApplication.willResignActiveNotification, object: nil)
    }

    required init?(coder: NSCoder) { fatalError("Use init(frame:)") }

    private func configureMetal() {
        guard let device = metalView.device else {
            errorLabel.text = "当前设备无法启用视频画面。"
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
            errorLabel.text = "无法初始化视频显示，请重新打开视频。"
        }
    }

    func clear() {
        frameToDraw = nil
        requestDraw()
    }

    func display(_ pixelBuffer: CVPixelBuffer) {
        guard let device = metalView.device, pipeline != nil, queue != nil, indexBuffer != nil else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer), height = CVPixelBufferGetHeight(pixelBuffer)
        guard width >= 2, height > 0, CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            errorLabel.text = "无法显示该视频帧。"
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
            errorLabel.text = "无法显示视频帧，请重新打开视频。"
            clear()
            return
        }
        let displaySize = CVImageBufferGetDisplaySize(pixelBuffer)
        let aspect = displaySize.width > 0 && displaySize.height > 0
            ? displaySize.width / displaySize.height : CGFloat(width) / CGFloat(height)
        frameToDraw = Frame(pixelBuffer: pixelBuffer, imageTexture: cvTexture,
                            texture: texture, packedAspect: aspect)
        errorLabel.text = nil
        requestDraw()
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

    private var canPresent: Bool {
        guard let window, !isHidden, !window.isHidden, bounds.width > 0, bounds.height > 0 else { return false }
        if let scene = window.windowScene { return scene.activationState == .foregroundActive }
        return UIApplication.shared.applicationState == .active
    }

    @objc private func presentationDidBecomeAvailable(_ note: Notification) { requestDraw() }

    @objc private func applicationWillResignActive(_ note: Notification) { metalView.isPaused = true }

    private func requestDraw() {
        needsDraw = true
        missedDrawables = 0
        if canPresent && isReadyForDisplay { metalView.isPaused = false }
    }

    private func missedDisplayTick() {
        // When a paused video loses its window or the GPU stays unavailable,
        // do not spin forever. A new frame, layout, or reactivation wakes it.
        missedDrawables += 1
        if missedDrawables >= 12 { metalView.isPaused = true }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { metalView.isPaused = true }
        else { requestDraw() }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        if size.width > 0 && size.height > 0 { requestDraw() }
    }

    func draw(in view: MTKView) {
        // In particular, Files dismissal, rotation and returning from the
        // background can deliver frames before a drawable is available. Keep
        // the newest one dirty and retry at the next display tick, even paused.
        guard needsDraw, canPresent else {
            view.isPaused = true
            return
        }
        guard gpuSlots.wait(timeout: .now()) == .success else {
            missedDisplayTick()
            return
        }
        guard let command = queue?.makeCommandBuffer(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            gpuSlots.signal()
            missedDisplayTick()
            return
        }
        encodeMovie(pass: pass, command: command)
        command.addCompletedHandler { [gpuSlots] _ in gpuSlots.signal() }
        command.present(drawable)
        needsDraw = false
        command.commit()
    }

    // The view and offscreen render tests use the same render pass.
    func encodeMovie(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) {
        guard let target = pass.colorAttachments[0].texture,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        defer { encoder.endEncoding() }
        guard let frame = frameToDraw, let pipeline else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(frame.texture, index: 0)
        let width = Double(target.width), height = Double(target.height)
        if mode == .standard {
            // Fit the complete, unwarped picture, including non-square source pixels.
            let fitHeight = min(height, width / Double(frame.packedAspect))
            let fitWidth = fitHeight * Double(frame.packedAspect)
            encoder.setViewport(MTLViewport(originX: (width - fitWidth) / 2, originY: (height - fitHeight) / 2,
                                            width: fitWidth, height: fitHeight, znear: 0, zfar: 1))
            encoder.setVertexBytes(Self.flatQuad, length: MemoryLayout<SBSMovieVertex>.stride * 4, index: 0)
            setTextureRegion(rightHalf: false, widthFraction: 1, encoder: encoder)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        } else {
            let eyeWidth = width / 2
            let nextGeometry = SBSMovieGeometry(eyeViewportSize: CGSize(width: eyeWidth, height: height),
                                                eyeAspect: mode.eyeAspect(packedAspect: frame.packedAspect))
            if geometry != nextGeometry || vertexBuffer == nil {
                let vertices = nextGeometry.vertices
                vertexBuffer = vertices.isEmpty ? nil : metalView.device?.makeBuffer(
                    bytes: vertices, length: vertices.count * MemoryLayout<SBSMovieVertex>.stride, options: []
                )
                geometry = nextGeometry
            }
            guard let vertexBuffer, let indexBuffer else { return }
            encoder.setVertexBuffer(vertexBuffer, offset: 0, index: 0)
            for eye in 0..<2 {
                encoder.setViewport(MTLViewport(originX: Double(eye) * eyeWidth, originY: 0, width: eyeWidth,
                                                height: height, znear: 0, zfar: 1))
                setTextureRegion(rightHalf: eye == 1, widthFraction: 0.5, encoder: encoder)
                encoder.drawIndexedPrimitives(type: .triangle, indexCount: SBSMovieGeometry.indices.count,
                                              indexType: .uint16, indexBuffer: indexBuffer, indexBufferOffset: 0)
            }
        }
        // GPU sampling can outlive this callback, including across output changes.
        command.addCompletedHandler { _ in withExtendedLifetime(frame) {} }
    }

    private func setTextureRegion(rightHalf: Bool, widthFraction: Float, encoder: MTLRenderCommandEncoder) {
        var region = SIMD2<Float>(rightHalf ? 1 : 0, widthFraction)
        encoder.setFragmentBytes(&region, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    }
}
