import CoreVideo
import MetalKit
import UIKit
import simd

enum SBSDisplayMode: Equatable {
    case standard
    case half  // Each view was compressed horizontally by a factor of two.
    case full  // Each half already has the correct eye image aspect ratio.

    case immersive(VRProjection, VREyeLayout, headset: Bool)

    func eyeAspect(packedAspect: CGFloat) -> CGFloat {
        self == .half ? packedAspect : packedAspect / 2
    }
}

enum VRProjection: Int, CaseIterable {
    case flat = 0, vr180, vr360, fisheye180
}

enum VREyeLayout: Int, CaseIterable {
    case mono, sideBySide, halfSideBySide, topBottom
}

private struct VRMovieUniforms {
    var cameraToWorld: simd_float3x3
    var rayAndLens: SIMD4<Float>
    var fitAndDisc: SIMD4<Float>
    var eyeRect: SIMD4<Float>
    var options: SIMD4<UInt32>
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
    // GPU completion and actual drawable presentation are distinct callbacks.
    // The latter may arrive on another queue or after a newer source frame.
    private final class GPUProgress: @unchecked Sendable {
        private let lock = NSLock()
        private var completedID: UInt64 = 0
        private var presentedID: UInt64 = 0
        private var presentationTime: CFTimeInterval = 0
        private var failures = 0
        private var lastError = "none"

        func completed(id: UInt64, command: MTLCommandBuffer) {
            lock.withLock {
                if command.status == .completed { completedID = max(completedID, id) }
                else {
                    failures += 1
                    if let error = command.error as NSError? { lastError = "\(error.domain):\(error.code)" }
                    else { lastError = "status-\(command.status.rawValue)" }
                }
            }
        }

        func presented(id: UInt64, time: CFTimeInterval) {
            lock.withLock {
                if id > presentedID && time > 0 {
                    presentedID = id
                    presentationTime = time
                }
            }
        }

        var lastPresentedID: UInt64 { lock.withLock { presentedID } }

        var summary: String {
            lock.withLock {
                #if targetEnvironment(simulator)
                let presentation = "presentID=NA presentAgeSec=NA presentation=unavailable-on-simulator"
                #else
                let age = presentationTime > 0 ? String(format: "%.2f", max(0, CACurrentMediaTime() - presentationTime)) : "NA"
                let presentation = "presentID=\(presentedID) presentAgeSec=\(age)"
                #endif
                return "completeID=\(completedID) \(presentation) gpuFailures=\(failures) gpuError=\(lastError)"
            }
        }
    }

    var mode: SBSDisplayMode = .standard {
        didSet {
            if oldValue != mode { updateDrawableSize(); requestDraw() }
        }
    }

    var nativeResolution = false {
        didSet { if oldValue != nativeResolution { updateDrawableSize(); requestDraw() } }
    }
    // Used by the embedded XR viewer. The regular viewer keeps its existing 1920/native choice.
    var renderScalePercent: Int? {
        didSet { if oldValue != renderScalePercent { updateDrawableSize(); requestDraw() } }
    }
    var targetFrameRate: Int {
        get { metalView.preferredFramesPerSecond }
        set { metalView.preferredFramesPerSecond = newValue == 30 ? 30 : 60 }
    }
    private var cameraToWorld = matrix_identity_float3x3
    private var shortSideFOV: Float = 80

    func setCamera(yaw: Float, pitch: Float, fieldOfView: Float, head: simd_float3x3 = matrix_identity_float3x3) {
        guard yaw.isFinite, pitch.isFinite, fieldOfView.isFinite else { return }
        let radians = Float.pi / 180
        let turn = simd_quatf(angle: -yaw * radians, axis: SIMD3(0, 1, 0))
        let tilt = simd_quatf(angle: min(89, max(-89, pitch)) * radians, axis: SIMD3(1, 0, 0))
        cameraToWorld = simd_float3x3(turn) * head * simd_float3x3(tilt)
        shortSideFOV = min(110, max(45, fieldOfView))
        requestDraw()
    }

    private let metalView = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    private let errorLabel = UILabel()
    private var textureCache: CVMetalTextureCache?
    private var pipeline: MTLRenderPipelineState?
    private var immersivePipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var indexBuffer: MTLBuffer?
    private var vertexBuffer: MTLBuffer?
    private var geometry: SBSMovieGeometry?
    private var frameToDraw: MetalMovieFrame?
    private var frameOrigin: PlaybackFrameOrigin?
    private let gpuProgress = GPUProgress()
    private(set) var receivedFrameID: UInt64 = 0
    private(set) var acceptedFrameID: UInt64 = 0
    private var submittedFrameID: UInt64 = 0
    var presentedFrameID: UInt64 { gpuProgress.lastPresentedID }
    private var receivedWidth = 0, receivedHeight = 0
    private var pixelFormat: OSType = 0
    private var rejected = 0, cpuUploads = 0, noDrawable = 0, gpuBusy = 0
    private var lastMapError = "none"
    private var lastCacheResult: CVReturn = kCVReturnSuccess
    private var retries = 0
    private var delayedRetry: DispatchWorkItem?

    // Sample only when logging or copying diagnostics, never per display tick.
    var frameDiagnostics: String {
        let size = metalView.drawableSize
        let bytes = [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pixelFormat >> $0) }
        let fourCC = bytes.allSatisfy { (32..<127).contains($0) } ? String(decoding: bytes, as: UTF8.self) : "unknown"
        return "metal recvID=\(receivedFrameID) acceptID=\(acceptedFrameID) submitID=\(submittedFrameID) " +
            gpuProgress.summary + " input=\(receivedWidth)x\(receivedHeight):\(fourCC) target=\(Int(size.width))x\(Int(size.height))" +
            " drawFPS=\(targetFrameRate) visible=\(canPresent) paused=\(metalView.isPaused) rejected=\(rejected) cpuUpload=\(cpuUploads)" +
            " noDrawable=\(noDrawable) gpuBusy=\(gpuBusy) textureCV=\(lastCacheResult) mapError=\(lastMapError)"
    }

    var isReadyForDisplay: Bool {
        metalView.device != nil && queue != nil && pipeline != nil && immersivePipeline != nil && indexBuffer != nil
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
        metalView.autoResizeDrawable = false
        metalView.preferredFramesPerSecond = 60
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
        descriptor.fragmentFunction = library?.makeFunction(name: "vrMovieFragment")
        immersivePipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        let indices = SBSMovieGeometry.indices
        indexBuffer = device.makeBuffer(bytes: indices, length: indices.count * MemoryLayout<UInt16>.stride, options: [])
        if queue == nil || pipeline == nil || immersivePipeline == nil || indexBuffer == nil {
            errorLabel.text = "无法初始化视频显示，请重新打开视频。"
        }
    }

    func clear() {
        frameToDraw = nil
        frameOrigin = nil
        requestDraw()
    }

    func display(_ pixelBuffer: CVPixelBuffer, origin: PlaybackFrameOrigin? = nil) {
        receivedFrameID &+= 1
        receivedWidth = CVPixelBufferGetWidth(pixelBuffer)
        receivedHeight = CVPixelBufferGetHeight(pixelBuffer)
        pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard let device = metalView.device, isReadyForDisplay else {
            rejected += 1
            lastMapError = "renderer-unavailable"
            return
        }
        do {
            let frame = try MetalMovieFrame(id: receivedFrameID, buffer: pixelBuffer, device: device, cache: textureCache)
            frameToDraw = frame
            frameOrigin = origin
            acceptedFrameID = frame.id
            lastCacheResult = frame.cacheResult
            if frame.copiedToGPU { cpuUploads += 1 }
            errorLabel.text = nil
            requestDraw()
        } catch {
            rejected += 1
            lastMapError = (error as? MetalMovieFrame.MappingError)?.reason ?? "unknown"
            errorLabel.text = "无法显示当前视频帧，可在 VR 设置中查看播放诊断。"
        }
    }

    private var canPresent: Bool {
        guard let window, !isHidden, !window.isHidden, bounds.width > 0, bounds.height > 0 else { return false }
        if let scene = window.windowScene { return scene.activationState == .foregroundActive }
        return UIApplication.shared.applicationState == .active
    }

    @objc private func presentationDidBecomeAvailable(_ note: Notification) { requestDraw() }

    @objc private func applicationWillResignActive(_ note: Notification) { metalView.isPaused = true }

    private func requestDraw() {
        delayedRetry?.cancel()
        delayedRetry = nil
        retries = 0
        needsDraw = true
        missedDrawables = 0
        if canPresent && isReadyForDisplay { metalView.isPaused = false }
    }

    private func missedDisplayTick() {
        // When a paused video loses its window or the GPU stays unavailable,
        // do not spin forever. A new frame, layout, or reactivation wakes it.
        missedDrawables += 1
        if missedDrawables >= 12 {
            metalView.isPaused = true
            scheduleRetry()
        }
    }

    private func scheduleRetry() {
        guard canPresent, delayedRetry == nil, retries < 3 else { return }
        retries += 1
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.delayedRetry = nil
            guard self.needsDraw, self.canPresent else { return }
            self.missedDrawables = 0
            self.metalView.isPaused = false
        }
        delayedRetry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateDrawableSize()
    }

    private func updateDrawableSize() {
        let scale = window?.screen.scale ?? traitCollection.displayScale
        let width = bounds.width * scale, height = bounds.height * scale
        guard width > 0, height > 0 else { return }
        var factor: CGFloat = 1
        if case .immersive = mode {
            if let renderScalePercent { factor = CGFloat(min(100, max(50, renderScalePercent))) / 100 }
            else if !nativeResolution { factor = min(1, 1920 / max(width, height)) }
        }
        let size = CGSize(width: max(1, (width * factor).rounded()), height: max(1, (height * factor).rounded()))
        if metalView.drawableSize != size { metalView.drawableSize = size }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { metalView.isPaused = true }
        else { updateDrawableSize(); requestDraw() }
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
            gpuBusy += 1
            missedDisplayTick()
            return
        }
        guard let command = queue?.makeCommandBuffer(), let pass = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable else {
            noDrawable += 1
            gpuSlots.signal()
            missedDisplayTick()
            return
        }
        let id = frameToDraw?.id ?? 0
        guard encodeMovie(pass: pass, command: command) else {
            gpuSlots.signal()
            missedDisplayTick()
            return
        }
        submittedFrameID = max(submittedFrameID, id)
        command.addCompletedHandler { [weak self, gpuSlots, gpuProgress] command in
            gpuSlots.signal()
            gpuProgress.completed(id: id, command: command)
            if command.status == .error {
                DispatchQueue.main.async {
                    guard let self, self.frameToDraw?.id == id else { return }
                    self.needsDraw = true
                    self.metalView.isPaused = true
                    self.scheduleRetry()
                }
            }
        }
        #if !targetEnvironment(simulator)
        drawable.addPresentedHandler { [gpuProgress] shown in
            gpuProgress.presented(id: id, time: shown.presentedTime)
        }
        #endif
        command.present(drawable)
        needsDraw = false
        command.commit()
    }

    // Taken only when the user copies diagnostics. Never read the drawable:
    // it stays framebuffer-only. Re-render the *same* accepted frame, camera
    // and shader to a tiny target at the current viewport's aspect ratio.
    func captureBrightness(current: PlaybackFrameOrigin?) async -> String {
        guard let frame = frameToDraw else { return "pixelProbe=no-accepted-frame" }
        let source = frameOrigin.map { "\($0.route) probeLoadID=\($0.loadID)" } ?? "unknown"
        let matches = frameOrigin == nil || current == nil ? "unknown" : (frameOrigin == current ? "yes" : "no")
        let header = "pixelProbe frameID=\(frame.id) probeRoute=\(source) matchesCurrentInput=\(matches) luma8=min/mean/max"
        let input = FrameProbeLayout(mode: mode, projected: false)
        let viewport = FrameProbeLayout(mode: mode, projected: true)
        let size = metalView.drawableSize
        let render = makeProbeRender(size: size)
        let buffer = frame.pixelBuffer
        let sourceBrightness = Task.detached(priority: .utility) { input.input(buffer) }
        var projected = "unavailable"
        if let (command, texture) = render {
            projected = await withCheckedContinuation { continuation in
                command.addCompletedHandler { completed in
                    let result = completed.status == .completed ? viewport.projection(texture) : "unavailable(gpu)"
                    continuation.resume(returning: result)
                }
                command.commit()
            }
        }
        let inputResult = await sourceBrightness.value
        return header + " inputLuma={\(inputResult)} offscreenViewportLuma={\(projected)}"
    }

    private func makeProbeRender(size: CGSize) -> (MTLCommandBuffer, MTLTexture)? {
        guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0,
              let device = metalView.device, let command = queue?.makeCommandBuffer() else { return nil }
        let scale = min(1, 64 / max(size.width, size.height))
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm,
            width: max(2, Int((size.width * scale).rounded())),
            height: max(2, Int((size.height * scale).rounded())), mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard encodeMovie(pass: pass, command: command) else { return nil }
        return (command, texture)
    }

    // The view and offscreen render tests use the same render pass.
    @discardableResult func encodeMovie(pass: MTLRenderPassDescriptor, command: MTLCommandBuffer) -> Bool {
        guard let target = pass.colorAttachments[0].texture,
              let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return false }
        defer { encoder.endEncoding() }
        guard let frame = frameToDraw else { return true } // Deliberate black clear.
        guard let pipeline else { return false }
        encoder.setRenderPipelineState(pipeline)
        frame.bind(to: encoder)
        let width = Double(target.width), height = Double(target.height)
        if case let .immersive(projection, layout, headset) = mode {
            guard let immersivePipeline else { return false }
            encoder.setRenderPipelineState(immersivePipeline)
            encodeImmersive(frame: frame, encoder: encoder, width: target.width, height: target.height,
                            projection: projection, layout: layout, headset: headset)
        } else if mode == .standard {
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
            guard let vertexBuffer, let indexBuffer else { return false }
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
        return true
    }

    private func encodeImmersive(frame: MetalMovieFrame, encoder: MTLRenderCommandEncoder, width: Int, height: Int,
                                 projection: VRProjection, layout: VREyeLayout, headset: Bool) {
        let textureWidth = frame.texture.width, textureHeight = frame.texture.height
        let splitX = layout == .sideBySide || layout == .halfSideBySide
        let splitY = layout == .topBottom
        let tileWidth = splitX ? max(1, textureWidth / 2) : textureWidth
        let tileHeight = splitY ? max(1, textureHeight / 2) : textureHeight
        let widthRatio = Float(tileWidth) / Float(textureWidth)
        let heightRatio = Float(tileHeight) / Float(textureHeight)
        let sourceAspect = Float(frame.packedAspect) * widthRatio / heightRatio * (layout == .halfSideBySide ? 2 : 1)
        let views = headset ? 2 : 1
        encoder.setVertexBytes(Self.flatQuad, length: MemoryLayout<SBSMovieVertex>.stride * 4, index: 0)
        for eye in 0..<views {
            let first = eye * width / views
            let columns = (eye + 1) * width / views - first
            guard columns > 0 else { continue }
            let size = SIMD2(Float(columns), Float(height))
            let relativeSize = size / min(size.x, size.y)
            let rays = relativeSize * tan(shortSideFOV * .pi / 360)
            let lens = headset ? relativeSize * tan(Float.pi * 40 / 180) : .zero
            let screenAspect = size.x / size.y
            let x = eye == 1 && splitX ? 1 - widthRatio : 0
            let y = eye == 1 && splitY ? 1 - heightRatio : 0
            var uniforms = VRMovieUniforms(
                cameraToWorld: cameraToWorld,
                rayAndLens: SIMD4(rays.x, rays.y, lens.x, lens.y),
                fitAndDisc: SIMD4(min(1, sourceAspect / screenAspect), min(1, screenAspect / sourceAspect),
                                  min(1, 1 / sourceAspect), min(1, sourceAspect)),
                eyeRect: SIMD4(x, y, x + widthRatio, y + heightRatio),
                options: SIMD4(UInt32(projection.rawValue), 0, 0, 0)
            )
            encoder.setViewport(MTLViewport(originX: Double(first), originY: 0, width: Double(columns),
                                            height: Double(height), znear: 0, zfar: 1))
            encoder.setFragmentBytes(&uniforms, length: MemoryLayout<VRMovieUniforms>.stride, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
    }

    private func setTextureRegion(rightHalf: Bool, widthFraction: Float, encoder: MTLRenderCommandEncoder) {
        var region = SIMD2<Float>(rightHalf ? 1 : 0, widthFraction)
        encoder.setFragmentBytes(&region, length: MemoryLayout<SIMD2<Float>>.stride, index: 0)
    }
}
