import CoreMotion
import simd
import UIKit

/// Camera pose relative to the screen orientation at the last recenter.
@MainActor
final class VRHeadTracker: NSObject {
    private let motion = CMMotionManager()
    private let onPose: (simd_float3x3) -> Void
    private var inverseCenter: simd_float3x3?
    private var requested = false
    private var foreground = false
    private var generation = 0

    var isAvailable: Bool { motion.isDeviceMotionAvailable }
    var interfaceOrientation: UIInterfaceOrientation = .portrait {
        didSet {
            if oldValue != interfaceOrientation { recenter() }
        }
    }

    init(onPose: @escaping (simd_float3x3) -> Void) {
        self.onPose = onPose
        super.init()
        foreground = UIApplication.shared.applicationState == .active
        NotificationCenter.default.addObserver(self, selector: #selector(resignedActive),
                                               name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(becameActive),
                                               name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    deinit { motion.stopDeviceMotionUpdates() }

    func setEnabled(_ enabled: Bool) {
        guard requested != enabled else { return }
        requested = enabled
        updateMotion()
    }

    func recenter() {
        inverseCenter = nil
        onPose(matrix_identity_float3x3)
    }

    @objc private func resignedActive() {
        foreground = false
        updateMotion()
    }

    @objc private func becameActive() {
        foreground = true
        updateMotion()
    }

    private func updateMotion() {
        let shouldRun = requested && foreground && isAvailable
        guard shouldRun != motion.isDeviceMotionActive else { return }
        generation += 1
        recenter()
        guard shouldRun else { motion.stopDeviceMotionUpdates(); return }
        let subscription = generation
        motion.deviceMotionUpdateInterval = 1.0 / 60
        motion.startDeviceMotionUpdates(using: .xArbitraryZVertical, to: .main) { [weak self] sample, _ in
            // This delivery queue is the main OperationQueue. Ignore any callbacks
            // already enqueued before this subscription was stopped or replaced.
            MainActor.assumeIsolated {
                guard let self, self.generation == subscription, let sample else { return }
                self.receive(sample.attitude.quaternion)
            }
        }
    }

    private func receive(_ q: CMQuaternion) {
        let values = SIMD4(Float(q.x), Float(q.y), Float(q.z), Float(q.w))
        let length = simd_length_squared(values)
        guard length.isFinite, length > 0.00001 else { return }
        let current = Self.screenToReference(
            deviceToReference: simd_float3x3(simd_quatf(vector: values / sqrt(length))),
            orientation: interfaceOrientation
        )
        if inverseCenter == nil { inverseCenter = current.transpose }
        if let inverseCenter { onPose(inverseCenter * current) }
    }

    static func screenToReference(deviceToReference: simd_float3x3,
                                  orientation: UIInterfaceOrientation) -> simd_float3x3 {
        let angle: Float
        switch orientation {
        case .landscapeLeft: angle = .pi / 2
        case .landscapeRight: angle = -.pi / 2
        case .portraitUpsideDown: angle = .pi
        default: return deviceToReference
        }
        let screenToDevice = simd_float3x3(simd_quatf(angle: angle, axis: SIMD3(0, 0, 1)))
        return deviceToReference * screenToDevice
    }
}
