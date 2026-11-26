import XCTest
@testable import NiceVideos

final class VRHandsFreeDetectorTests: XCTestCase {
    private struct Motion {
        var detector = VRHandsFreeDetector()
        var mode: VRWakeGesture
        var time: Double = 0
        var yaw: Float = 0
        var pitch: Float = 0
        var events = 0

        mutating func move(yaw endYaw: Float, pitch endPitch: Float, duration: Double) {
            let frames = max(1, Int((duration * 60).rounded()))
            let fromYaw = yaw, fromPitch = pitch
            for frame in 1...frames {
                let t = Float(frame) / Float(frames)
                yaw = fromYaw + (endYaw - fromYaw) * t
                pitch = fromPitch + (endPitch - fromPitch) * t
                time += duration / Double(frames)
                if detector.update(yaw: yaw, pitch: pitch, at: time, mode: mode) { events += 1 }
            }
        }

        mutating func nod() {
            let rest = pitch
            move(yaw: yaw, pitch: rest - 20, duration: 0.2)
            move(yaw: yaw, pitch: rest, duration: 0.2)
        }
        mutating func hold(_ duration: Double) { move(yaw: yaw, pitch: pitch, duration: duration) }
    }

    func testDoubleNodMustCompleteWithinWindowAndReturnToRest() {
        var motion = Motion(mode: .nod)
        motion.hold(0.1)
        motion.nod()
        XCTAssertEqual(motion.events, 0)
        motion.hold(2)
        motion.nod()
        XCTAssertEqual(motion.events, 0, "The first nod expired")
        motion.hold(0.15)
        motion.nod()
        XCTAssertEqual(motion.events, 1)
        motion.hold(2)
        XCTAssertEqual(motion.events, 1)
        motion.move(yaw: 0, pitch: -24, duration: 2.0)
        motion.move(yaw: 0, pitch: 0, duration: 2.0)
        XCTAssertEqual(motion.events, 1, "Slow looking around is not a nod")
    }

    func testCornerRequiresDwellAndOnlyRearmsAfterLookingAway() {
        var motion = Motion(mode: .corner)
        motion.hold(0.05)
        motion.move(yaw: -36, pitch: 25, duration: 0.3)
        motion.hold(0.5)
        XCTAssertEqual(motion.events, 0)
        motion.hold(0.55)
        XCTAssertEqual(motion.events, 1)
        motion.hold(3)
        XCTAssertEqual(motion.events, 1)
        motion.move(yaw: 0, pitch: 0, duration: 0.4)
        motion.move(yaw: 40, pitch: 25, duration: 0.35)
        motion.hold(1.1)
        XCTAssertEqual(motion.events, 2)
        motion.move(yaw: 120, pitch: 35, duration: 0.4)
        motion.hold(2)
        XCTAssertEqual(motion.events, 2)
    }

    func testSwitchingOffOrRecenteringCannotFinishAPartialGesture() {
        var motion = Motion(mode: .both)
        motion.hold(0.1)
        motion.nod()
        motion.detector.reset()
        motion.hold(0.1)
        motion.nod()
        XCTAssertEqual(motion.events, 0)
        motion.mode = .off
        motion.nod()
        motion.move(yaw: 42, pitch: 22, duration: 0.2)
        motion.hold(2)
        XCTAssertEqual(motion.events, 0)
        motion.mode = .corner
        motion.hold(0.5)
        motion.time += 2
        motion.hold(0.5)
        XCTAssertEqual(motion.events, 0, "Missing sensor samples must restart dwell")
        motion.hold(0.6)
        XCTAssertEqual(motion.events, 1)
    }
}
