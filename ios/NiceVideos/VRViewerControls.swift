import SwiftUI
import Combine
import simd
import UIKit

/// Projection belongs to the movie; gesture and output preferences belong to the viewer.
struct VRMoviePreferences: Equatable {
    var projection = VRProjection.vr180
    var eyes = VREyeLayout.sideBySide
    var headset = false
    var fieldOfView: Float = 80

    var mode: SBSDisplayMode { .immersive(projection, eyes, headset: headset) }

    init() {}
    init(key: String, defaults: UserDefaults = .standard) {
        self.init(values: defaults.dictionary(forKey: "vr.movie." + key))
    }

    init(values: [String: Any]?, fallback: Self = Self()) {
        self = fallback
        guard let values else { return }
        if let value = values["projection"] as? Int, let saved = VRProjection(rawValue: value) { projection = saved }
        if let value = values["eyes"] as? Int, let saved = VREyeLayout(rawValue: value) { eyes = saved }
        headset = values["headset"] as? Bool ?? headset
        if let fov = values["fov"] as? Double, fov.isFinite { fieldOfView = Float(min(110, max(45, fov))) }
    }

    var values: [String: Any] {
        ["projection": projection.rawValue, "eyes": eyes.rawValue, "headset": headset, "fov": Double(fieldOfView)]
    }

    func save(key: String, defaults: UserDefaults = .standard) {
        defaults.set(values, forKey: "vr.movie." + key)
    }
}

extension VRProjection {
    var label: String {
        switch self {
        case .vr180: return "180° 全景"
        case .vr360: return "360° 全景"
        case .fisheye180: return "180° 鱼眼"
        case .flat: return "平面影院"
        }
    }
}

extension VREyeLayout {
    var label: String {
        switch self {
        case .mono: return "单画面"
        case .sideBySide: return "左右分屏"
        case .halfSideBySide: return "半宽左右分屏"
        case .topBottom: return "上下分屏"
        }
    }
}

enum VRDoubleTapAction: String, CaseIterable {
    case recenter = "视角回正"
    case playback = "播放／暂停"
    case controls = "显示／隐藏控件"
}

enum VRPinchResponse: String, CaseIterable {
    case fine = "精细"
    case regular = "标准"
    case fast = "快速"
    var exponent: Double {
        switch self {
        case .fine: return 0.55
        case .regular: return 1
        case .fast: return 1.7
        }
    }
}

/// The draw path writes only camera uniforms. It has no access to a player, file or seek state.
@MainActor final class VRGestureCamera: ObservableObject {
    private weak var renderer: SBSMetalView?
    let controlsRequested = PassthroughSubject<Void, Never>()
    private var wakeMode: VRWakeGesture = .off
    private var wakeDetector = VRHandsFreeDetector()
    private lazy var tracker = VRHeadTracker { [weak self] pose in
        self?.receivedHeadPose(pose)
    }

    private func receivedHeadPose(_ pose: simd_float3x3) {
        head = pose
        draw()
        guard lastGyro, wakeMode != .off else { return }
        let forward = -pose.columns.2
        let yaw = atan2(forward.x, -forward.z) * 180 / .pi
        let pitch = asin(min(1, max(-1, forward.y))) * 180 / .pi
        if wakeDetector.update(yaw: yaw, pitch: pitch, at: ProcessInfo.processInfo.systemUptime, mode: wakeMode) {
            controlsRequested.send()
        }
    }
    private var head = matrix_identity_float3x3
    private var yaw: Float = 0
    private var pitch: Float = 0
    private var lastGyro = false
    private(set) var fieldOfView: Float

    init(fieldOfView: Float = 80) { self.fieldOfView = fieldOfView }
    var sensorAvailable: Bool { tracker.isAvailable }

    func connect(to renderer: SBSMetalView?, followHead: Bool, wake: VRWakeGesture = .off) {
        if wake != wakeMode || self.renderer !== renderer {
            wakeMode = wake
            wakeDetector.reset()
        }
        if self.renderer !== renderer {
            self.renderer = renderer
            draw()
        }
        let enabled = renderer != nil && followHead
        if enabled != lastGyro {
            lastGyro = enabled
            wakeDetector.reset()
            tracker.setEnabled(enabled)
            head = matrix_identity_float3x3
            draw()
        }
    }

    func updateOrientation(_ orientation: UIInterfaceOrientation?) {
        if let orientation, orientation != .unknown, tracker.interfaceOrientation != orientation {
            wakeDetector.reset()
            tracker.interfaceOrientation = orientation
        }
    }

    func recenter() {
        yaw = 0
        pitch = 0
        head = matrix_identity_float3x3
        wakeDetector.reset()
        tracker.recenter()
        draw()
    }

    func setFOV(_ fov: Float) {
        guard fov.isFinite else { return }
        fieldOfView = min(110, max(45, fov))
        draw()
    }

    func pan(by delta: CGPoint, in size: CGSize, headset: Bool) {
        let eyeWidth = headset ? size.width / 2 : size.width
        let shortSide = Double(min(eyeWidth, size.height))
        guard shortSide > 0 else { return }
        let scale = 2 * tan(Double(fieldOfView) * .pi / 360) / shortSide
        yaw = (yaw - Float(atan(Double(delta.x) * scale) * 180 / .pi)).truncatingRemainder(dividingBy: 360)
        pitch = min(89, max(-89, pitch + Float(atan(Double(delta.y) * scale) * 180 / .pi)))
        draw()
    }

    func zoom(from initial: Float, scale: CGFloat, response: VRPinchResponse) {
        guard scale > 0 && scale.isFinite else { return }
        let extent = tan(Double(initial) * .pi / 360) / pow(Double(scale), response.exponent)
        setFOV(Float(atan(extent) * 360 / .pi))
    }

    private func draw() {
        renderer?.setCamera(yaw: yaw, pitch: pitch, fieldOfView: fieldOfView, head: head)
    }
}

@MainActor struct VRPanoramaSurface: UIViewRepresentable {
    let camera: VRGestureCamera
    let panorama: Bool
    let headset: Bool
    let response: VRPinchResponse
    let onTap: () -> Void
    let onDoubleTap: () -> Void
    let onZoomEnd: (Float) -> Void

    @MainActor final class Coordinator: NSObject {
        var owner: VRPanoramaSurface
        var initialFOV: Float = 80
        init(_ owner: VRPanoramaSurface) { self.owner = owner }

        @objc func singleTap() { owner.onTap() }
        @objc func doubleTap() { owner.onDoubleTap() }
        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard owner.panorama, let view = gesture.view else { return }
            if gesture.state == .changed || gesture.state == .ended {
                let delta = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                owner.camera.pan(by: delta, in: view.bounds.size, headset: owner.headset)
            }
        }
        @objc func pinch(_ gesture: UIPinchGestureRecognizer) {
            guard owner.panorama else { return }
            switch gesture.state {
            case .began: initialFOV = owner.camera.fieldOfView
            case .changed: owner.camera.zoom(from: initialFOV, scale: gesture.scale, response: owner.response)
            case .ended:
                owner.camera.zoom(from: initialFOV, scale: gesture.scale, response: owner.response)
                owner.onZoomEnd(owner.camera.fieldOfView)
            case .cancelled, .failed: owner.camera.setFOV(initialFOV)
            default: break
            }
        }
    }

    final class TouchView: UIView {
        weak var camera: VRGestureCamera?
        override func layoutSubviews() {
            super.layoutSubviews()
            camera?.updateOrientation(window?.windowScene?.interfaceOrientation)
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            camera?.updateOrientation(window?.windowScene?.interfaceOrientation)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> TouchView {
        let view = TouchView()
        view.camera = camera
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isMultipleTouchEnabled = true
        let coordinator = context.coordinator
        let tap = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.singleTap))
        let double = UITapGestureRecognizer(target: coordinator, action: #selector(Coordinator.doubleTap))
        double.numberOfTapsRequired = 2
        tap.require(toFail: double)
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        let pinch = UIPinchGestureRecognizer(target: coordinator, action: #selector(Coordinator.pinch(_:)))
        for gesture in [tap, double, pan, pinch] as [UIGestureRecognizer] { view.addGestureRecognizer(gesture) }
        return view
    }
    func updateUIView(_ view: TouchView, context: Context) { context.coordinator.owner = self }
}

@MainActor struct VRViewerSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var profile: VRMoviePreferences
    @Binding var followHead: Bool
    @Binding var nativeResolution: Bool
    @Binding var doubleTap: VRDoubleTapAction
    @Binding var pinchResponse: VRPinchResponse
    @Binding var wakeGesture: VRWakeGesture
    let sensorAvailable: Bool
    let decoder: String
    let details: String?
    @State private var didCopyDiagnostics = false
    let decoderAction: String?
    let onCopyDiagnostics: () async -> Bool
    let onDecoderChange: () -> Void
    let usesAfterglowPreset: Bool
    let onOpenAfterglow: () -> Void
    let onExit: () -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button {
                        Task { didCopyDiagnostics = await onCopyDiagnostics() }
                    } label: {
                        Label(didCopyDiagnostics ? "已复制播放诊断" : "复制播放诊断", systemImage: "doc.on.doc")
                    }
                    .accessibilityIdentifier("copyPlaybackDiagnostics")
                }
                Section("当前影片") { VRProjectionFields(profile: $profile) }
                if profile.projection != .flat {
                    Section("环顾") {
                        Toggle("陀螺仪跟随", isOn: $followHead).disabled(!sensorAvailable)
                        if profile.headset && followHead && sensorAvailable {
                            VRHandsFreeSettingRow(selection: $wakeGesture)
                        }
                        if !sensorAvailable { Text("当前设备可用手指拖动环顾。").font(.footnote) }
                        Picker("双指缩放幅度", selection: $pinchResponse) {
                            ForEach(VRPinchResponse.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                    }
                }
                Section("观看偏好") {
                    Picker("画面双击", selection: $doubleTap) {
                        ForEach(VRDoubleTapAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    if usesAfterglowPreset {
                        AfterglowRenderFields()
                    } else {
                        Picker("VR 渲染清晰度", selection: $nativeResolution) {
                            Text("流畅（最长边 1920）").tag(false)
                            Text("屏幕原生").tag(true)
                        }
                    }
                }
                Section("片源信息") {
                    LabeledContent("当前解码", value: decoder)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("当前解码")
                        .accessibilityValue(decoder)
                        .accessibilityIdentifier("vrCurrentDecoder")
                    if let details { Text(details).font(.footnote) }
                    if let decoderAction { Button(decoderAction) { onDecoderChange(); dismiss() } }
                    if !usesAfterglowPreset {
                        Button("用 Afterglow XR 播放") { onOpenAfterglow(); dismiss() }
                    }
                }
                Button("退出全景 VR") { onExit(); dismiss() }
                    .accessibilityIdentifier("exitPanoramaVR")
            }
            .navigationTitle("VR 设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct VRProjectionFields: View {
    @Binding var profile: VRMoviePreferences
    var body: some View {
        Picker("投影", selection: $profile.projection) {
            ForEach(VRProjection.allCases, id: \.self) { Text($0.label).tag($0) }
        }.accessibilityIdentifier("vrProjectionPicker")
        Picker("片源排布", selection: $profile.eyes) {
            ForEach(VREyeLayout.allCases, id: \.self) { Text($0.label).tag($0) }
        }.accessibilityIdentifier("vrEyeLayoutPicker")
        Toggle("双眼眼镜", isOn: $profile.headset)
            .accessibilityIdentifier("vrHeadsetToggle")
    }
}
