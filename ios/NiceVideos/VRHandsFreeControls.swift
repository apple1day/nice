import Foundation
import SwiftUI

enum VRWakeGesture: String, CaseIterable {
    case off, nod, corner, both

    var label: String {
        switch self {
        case .off: return "关闭"
        case .nod: return "连续点头两次"
        case .corner: return "看向上角并停留"
        case .both: return "点头或看向上角"
        }
    }

    var instruction: String? {
        switch self {
        case .off: return nil
        case .nod: return "向下轻点头并抬回，连续两次可显示播放控件。"
        case .corner: return "相对回正方向，转向左上或右上并停稳约一秒，可显示播放控件。"
        case .both: return "连续点头两次，或转向左上、右上并停稳约一秒，可显示播放控件。"
        }
    }
}

struct VRHandsFreeSettingRow: View {
    @Binding var selection: VRWakeGesture

    var body: some View {
        VStack(alignment: .leading) {
            Picker("头部唤出控制栏", selection: $selection) {
                ForEach(VRWakeGesture.allCases, id: \.self) { gesture in
                    Text(gesture.label).tag(gesture)
                }
            }
            .accessibilityIdentifier("vrHeadWakeGesture")
            if let instruction = selection.instruction {
                Text(instruction).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

/// Monotonic, screen-relative head angles. Positive pitch looks up. A wake
/// event can only reveal the toolbar; the caller owns playback actions.
struct VRHandsFreeDetector {
    private struct Pose {
        let yaw: Float
        let pitch: Float
        let time: TimeInterval
    }
    private struct Nod {
        let origin: Pose
        var dipped = false
    }
    private var mode: VRWakeGesture = .off
    private var previous: Pose?
    private var nod: Nod?
    private var firstNodEnd: TimeInterval?
    private var cornerAnchor: Pose?
    private var cornerLatched = false
    private var lastWake: TimeInterval?

    mutating func reset() { self = Self() }

    mutating func update(yaw: Float, pitch: Float, at time: TimeInterval, mode next: VRWakeGesture) -> Bool {
        guard next != .off, yaw.isFinite, pitch.isFinite, time.isFinite else {
            reset()
            return false
        }
        let sample = Pose(yaw: yaw, pitch: pitch, time: time)
        // Recenter, a resumed motion subscription, or stale sensor readings
        // must not complete a gesture begun in another coordinate system.
        guard mode == next, let last = previous, time > last.time, time - last.time <= 0.35 else {
            reset()
            mode = next
            previous = sample
            return false
        }
        previous = sample
        let fromCorner = (mode == .corner || mode == .both) && checkCorner(sample)
        let fromNods = (mode == .nod || mode == .both) && checkNods(sample, after: last)
        guard fromCorner || fromNods else { return false }
        guard lastWake.map({ time - $0 > 1.25 }) ?? true else { return false }
        lastWake = time
        firstNodEnd = nil
        nod = nil
        return true
    }

    private static func yawDistance(_ a: Float, _ b: Float) -> Float {
        abs((a - b + 540).truncatingRemainder(dividingBy: 360) - 180)
    }

    private mutating func checkCorner(_ pose: Pose) -> Bool {
        let horizontal = abs(pose.yaw)
        if cornerLatched {
            if horizontal < 21 || pose.pitch < 10 || horizontal > 75 || pose.pitch > 60 {
                cornerLatched = false
            }
            return false
        }
        // Bounding the upper corners keeps a look over the shoulder or
        // straight up from activating controls.
        guard (28...68).contains(horizontal), (16...52).contains(pose.pitch) else {
            cornerAnchor = nil
            return false
        }
        guard let anchor = cornerAnchor,
              Self.yawDistance(pose.yaw, anchor.yaw) <= 5,
              abs(pose.pitch - anchor.pitch) <= 5 else {
            cornerAnchor = pose
            return false
        }
        guard pose.time - anchor.time >= 0.9 else { return false }
        cornerAnchor = nil
        cornerLatched = true
        return true
    }

    private mutating func checkNods(_ pose: Pose, after previous: Pose) -> Bool {
        if let first = firstNodEnd, pose.time - first > 1.3 { firstNodEnd = nil }
        if nod == nil {
            let speed = Double(pose.pitch - previous.pitch) / (pose.time - previous.time)
            guard speed < -28 else { return false }
            nod = Nod(origin: previous)
        }
        guard var stroke = nod else { return false }
        let elapsed = pose.time - stroke.origin.time
        let depth = stroke.origin.pitch - pose.pitch
        guard elapsed <= 0.95, depth < 42,
              Self.yawDistance(pose.yaw, stroke.origin.yaw) < 16 else {
            nod = nil
            return false
        }
        if depth >= 14 { stroke.dipped = true }
        nod = stroke
        if !stroke.dipped && (depth < 0 || elapsed > 0.45) {
            nod = nil
            return false
        }
        guard stroke.dipped, depth <= 5, elapsed >= 0.16 else { return false }
        nod = nil
        if firstNodEnd != nil {
            firstNodEnd = nil
            return true
        }
        firstNodEnd = pose.time
        return false
    }
}
