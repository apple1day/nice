import GameController
import SwiftUI

enum VRGamepadCommand {
    case playPause, recenter, toggleControls, backward, forward
}

/// Installs the foreground viewer's controls on connected extended gamepads.
/// Camera changes stay on the same path as touch input.
struct VRGamepadInput: UIViewRepresentable {
    let enabled: Bool
    let onCommand: (VRGamepadCommand) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        context.coordinator.update(enabled: enabled, onCommand: onCommand)
    }

    static func dismantleUIView(_ view: UIView, coordinator: Coordinator) {
        coordinator.stop()
    }

    @MainActor final class Coordinator {
        private var action: ((VRGamepadCommand) -> Void)?
        private var observers: [NSObjectProtocol] = []
        private var pads: [ObjectIdentifier: GCExtendedGamepad] = [:]
        private var generation = 0

        func update(enabled: Bool, onCommand: @escaping (VRGamepadCommand) -> Void) {
            guard enabled else { stop(); return }
            action = onCommand
            guard observers.isEmpty else { return }
            for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in MainActor.assumeIsolated { self?.refresh() }
                })
            }
            refresh()
        }

        private func refresh() {
            guard action != nil else { return }
            let present = GCController.controllers().compactMap(\.extendedGamepad)
            let ids = Set(present.map { ObjectIdentifier($0) })
            for id in Array(pads.keys) where !ids.contains(id) {
                if let pad = pads.removeValue(forKey: id) { clear(pad) }
            }
            for pad in present {
                let id = ObjectIdentifier(pad)
                guard pads[id] == nil else { continue }
                pads[id] = pad
                for (button, command) in bindings(pad) {
                    let generation = self.generation
                    button.pressedChangedHandler = { [weak self] _, _, pressed in
                        guard pressed else { return }
                        DispatchQueue.main.async {
                            guard let self, self.generation == generation, self.pads[id] != nil else { return }
                            self.action?(command)
                        }
                    }
                }
            }
        }

        private func bindings(_ pad: GCExtendedGamepad) -> [(GCControllerButtonInput, VRGamepadCommand)] {
            [(pad.buttonA, .playPause), (pad.buttonX, .recenter), (pad.buttonY, .toggleControls),
             (pad.leftShoulder, .backward), (pad.rightShoulder, .forward)]
        }

        private func clear(_ pad: GCExtendedGamepad) {
            for (button, _) in bindings(pad) { button.pressedChangedHandler = nil }
        }

        func stop() {
            guard action != nil else { return }
            action = nil
            generation &+= 1
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers.removeAll()
            for pad in pads.values { clear(pad) }
            pads.removeAll()
        }
    }
}
