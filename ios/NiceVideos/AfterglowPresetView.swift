import SwiftUI
import CoreMotion

enum AfterglowPreset {
    private static let profileKey = "vr.afterglow.profile"
    static let gyroKey = "vr.afterglow.gyro"
    static let renderScaleKey = "vr.afterglow.renderScalePercent"
    static let frameRateKey = "vr.afterglow.targetFrameRate"

    static func load(defaults: UserDefaults = .standard) -> VRMoviePreferences {
        var initial = VRMoviePreferences()
        initial.projection = .vr360
        initial.headset = true
        return VRMoviePreferences(values: defaults.dictionary(forKey: profileKey), fallback: initial)
    }

    static func save(_ profile: VRMoviePreferences, defaults: UserDefaults = .standard) {
        defaults.set(profile.values, forKey: profileKey)
    }
}

struct AfterglowPresetView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile = AfterglowPreset.load()
    @AppStorage(AfterglowPreset.gyroKey) private var followHead = true
    @State private var sensorAvailable = CMMotionManager().isDeviceMotionAvailable

    var body: some View {
        NavigationStack {
            Form {
                Section("打开影片时使用") {
                    VRProjectionFields(profile: $profile)
                }
                Section("观看设置") {
                    if profile.projection != .flat {
                        Toggle("陀螺仪跟随", isOn: $followHead).disabled(!sensorAvailable)
                        LabeledContent("初始视场角", value: "\(Int(profile.fieldOfView))°")
                        Slider(value: $profile.fieldOfView, in: 45...110, step: 1)
                            .accessibilityLabel("初始视场角")
                            .accessibilityValue("\(Int(profile.fieldOfView)) 度")
                    }
                    AfterglowRenderFields()
                }
            }
            .onChange(of: profile) { _, value in AfterglowPreset.save(value) }
            .navigationTitle("Afterglow XR 播放预设")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }.accessibilityIdentifier("afterglowSettingsDone")
                }
            }
        }
    }
}

struct AfterglowRenderFields: View {
    @AppStorage(AfterglowPreset.renderScaleKey) private var renderScale = 75
    @AppStorage(AfterglowPreset.frameRateKey) private var frameRate = 30

    var body: some View {
        Picker("渲染比例", selection: $renderScale) {
            Text("50%").tag(50)
            Text("75%").tag(75)
            Text("100%").tag(100)
        }
        .accessibilityIdentifier("afterglowRenderScale")
        Picker("显示帧率", selection: $frameRate) {
            Text("30 fps").tag(30)
            Text("60 fps").tag(60)
        }
        .accessibilityIdentifier("afterglowFrameRate")
    }
}
