import SwiftUI
import UIKit

@MainActor protocol PlaybackScrubObserver: AnyObject {
    func draftChanged(_ seconds: Double?)
    func editingChanged(_ editing: Bool)
    func commit(_ seconds: Double)
}

// The parent stores this reference without observing draft changes. Cancelling
// is synchronous: the native tracking token is invalid before a button seeks,
// switches clips or changes layout, without waiting for a SwiftUI update.
@MainActor final class PlaybackScrubController {
    private var session = PlaybackScrubSession()
    private weak var slider: PlaybackTrackingSlider?
    private weak var observer: PlaybackScrubObserver?
    private var notificationRevision: UInt = 0

    func bind(_ view: PlaybackTrackingSlider, observer: PlaybackScrubObserver) {
        if slider !== view {
            cancel(deferred: true)
            slider = view
            view.scrubController = self
            self.observer = observer
            publish(editingChanged: true, deferred: true)
        } else {
            self.observer = observer
        }
    }

    func detach(_ view: PlaybackTrackingSlider) {
        guard slider === view else { return }
        cancel(deferred: true)
        view.scrubController = nil
        slider = nil
    }

    func cancel() { cancel(deferred: false) }

    private func cancel(deferred: Bool) {
        let wasEditing = session.cancel()
        // Invalidate first. The control may synchronously emit more tracking events
        // while it cancels; none of them may commit the old draft.
        slider?.cancelTracking(with: nil)
        if wasEditing { publish(editingChanged: true, deferred: deferred) }
    }

    func isEditing(in view: PlaybackTrackingSlider) -> Bool {
        slider === view && session.isEditing
    }

    fileprivate func begin(in view: PlaybackTrackingSlider, seconds: Double) -> UUID? {
        guard slider === view, let token = session.begin(at: seconds) else { return nil }
        publish(editingChanged: true)
        return token
    }

    fileprivate func update(in view: PlaybackTrackingSlider, token: UUID, seconds: Double) {
        guard slider === view, session.update(seconds, token: token) else { return }
        publish(editingChanged: false)
    }

    fileprivate func finish(in view: PlaybackTrackingSlider, token: UUID, seconds: Double) {
        guard slider === view, session.update(seconds, token: token),
              let target = session.finish(token: token) else { return }
        publish(editingChanged: true)
        observer?.commit(target)
    }

    fileprivate func cancelled(in view: PlaybackTrackingSlider, token: UUID?, deferred: Bool) {
        guard slider === view, let token, session.token == token else { return }
        session.cancel()
        publish(editingChanged: true, deferred: deferred)
    }

    fileprivate func adjustAccessibility(in view: PlaybackTrackingSlider, seconds: Double) {
        guard slider === view, seconds.isFinite else { return }
        cancel()
        // An accessibility adjustment is a complete operation, with no touch-up
        // to wait for. Retain the control's Adjustable accessibility behavior.
        publish(editingChanged: true)
        observer?.commit(seconds)
    }

    private func publish(editingChanged: Bool, deferred: Bool = false) {
        notificationRevision &+= 1
        let revision = notificationRevision
        let draft = session.draftSeconds
        let editing = session.isEditing
        let deliver = { [weak self] in
            guard let self, self.notificationRevision == revision else { return }
            self.observer?.draftChanged(draft)
            if editingChanged { self.observer?.editingChanged(editing) }
        }
        // Model updates / removal can happen inside SwiftUI's render pass.
        // Invalidate the session now, but defer State writes. A subsequent drag
        // advances the revision and rejects this old cancellation notification.
        if deferred { DispatchQueue.main.async { deliver() } }
        else { deliver() }
    }
}

// Own the whole 44pt touch surface and its coordinate mapping. A UISlider's
// internal thumb/gesture tracking must not decide whether our scrub session
// starts or finishes. UIControl supplies cancellation without a parent gesture.
final class PlaybackTrackingSlider: UIControl {
    fileprivate weak var scrubController: PlaybackScrubController?
    private var trackingToken: UUID?
    private var deferCancellationNotifications = false
    private let trackLayer = CALayer()
    private let progressLayer = CALayer()
    private let thumbLayer = CALayer()
    private var storedValue: Float = 0
    private let thumbDiameter: CGFloat = 20

    var minimumValue: Float = 0 {
        didSet { setValue(storedValue, animated: false) }
    }
    var maximumValue: Float = 1 {
        didSet { setValue(storedValue, animated: false) }
    }
    var value: Float {
        get { storedValue }
        set { setValue(newValue, animated: false) }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 44)
    }

    private var trackRect: CGRect {
        CGRect(x: thumbDiameter / 2, y: bounds.midY - 2,
               width: max(0, bounds.width - thumbDiameter), height: 4)
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = false
        trackLayer.backgroundColor = UIColor.white.withAlphaComponent(0.35).cgColor
        progressLayer.backgroundColor = UIColor.white.cgColor
        thumbLayer.backgroundColor = UIColor.white.cgColor
        thumbLayer.shadowColor = UIColor.black.cgColor
        thumbLayer.shadowOpacity = 0.25
        thumbLayer.shadowRadius = 2
        thumbLayer.shadowOffset = CGSize(width: 0, height: 1)
        layer.addSublayer(trackLayer)
        layer.addSublayer(progressLayer)
        layer.addSublayer(thumbLayer)
        isAccessibilityElement = true
        accessibilityTraits.insert(.adjustable)
        accessibilityLabel = "播放进度"
        accessibilityHint = "向上或向下轻扫，前进或后退15秒。"
        accessibilityIdentifier = "playbackProgressSlider"
        addTarget(self, action: #selector(valueDidChange), for: .valueChanged)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let track = trackRect
        let range = Double(maximumValue) - Double(minimumValue)
        let fraction = range.isFinite && range > 0
            ? min(1, max(0, (Double(value) - Double(minimumValue)) / range)) : 0
        let thumbX = track.minX + track.width * CGFloat(fraction)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = track
        trackLayer.cornerRadius = track.height / 2
        progressLayer.frame = CGRect(x: track.minX, y: track.minY,
                                    width: max(0, thumbX - track.minX), height: track.height)
        progressLayer.cornerRadius = track.height / 2
        thumbLayer.frame = CGRect(x: thumbX - thumbDiameter / 2,
                                 y: bounds.midY - thumbDiameter / 2,
                                 width: thumbDiameter, height: thumbDiameter)
        thumbLayer.cornerRadius = thumbDiameter / 2
        CATransaction.commit()
    }

    func setValue(_ value: Float, animated: Bool) {
        guard value.isFinite, minimumValue.isFinite, maximumValue.isFinite,
              maximumValue >= minimumValue else { return }
        storedValue = min(maximumValue, max(minimumValue, value))
        // Playback and finger updates must be immediate, without implicit layer
        // animations or a valueChanged event for a programmatic update.
        setNeedsLayout()
    }

    override var isEnabled: Bool {
        didSet {
            alpha = isEnabled ? 1 : 0.4
            if isEnabled {
                accessibilityTraits.remove(.notEnabled)
            } else {
                accessibilityTraits.insert(.notEnabled)
                cancelTracking(with: nil)
            }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        beginScrubbing(at: touch.location(in: self))
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        continueScrubbing(at: touch.location(in: self))
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        guard let touch else {
            cancelTracking(with: event)
            return
        }
        finishScrubbing(at: touch.location(in: self))
        super.endTracking(touch, with: event)
    }

    override func cancelTracking(with event: UIEvent?) {
        let token = trackingToken
        trackingToken = nil
        scrubController?.cancelled(in: self, token: token,
                                   deferred: deferCancellationNotifications)
        super.cancelTracking(with: event)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            performModelUpdate { cancelTracking(with: nil) }
        }
    }

    override func accessibilityIncrement() {
        adjustAccessibleProgress(by: 15)
    }

    override func accessibilityDecrement() {
        adjustAccessibleProgress(by: -15)
    }

    private func adjustAccessibleProgress(by seconds: Double) {
        guard isEnabled else { return }
        scrubController?.cancel()
        let lower = Double(minimumValue), upper = Double(maximumValue)
        let previous = Double(value)
        guard lower.isFinite, upper.isFinite, previous.isFinite, upper > lower else { return }
        let target = Float(min(upper, max(lower, previous + seconds)))
        // Do not rely on superclass accessibility hooks to change the value.
        // Own the adjustment explicitly, with the same 15-second steps as the
        // transport buttons, even before accessibility services are activated.
        guard target != value else { refreshAccessibilityValue(); return }
        setValue(target, animated: false)
        refreshAccessibilityValue()
        // setValue does not send valueChanged. Commit once here; a late control
        // event has no tracking token and cannot repeat this seek.
        scrubController?.adjustAccessibility(in: self, seconds: Double(value))
    }

    // UIKit touch callbacks and coordinate unit tests share these operations.
    // XCUITest separately verifies real press/drag/release through the player.
    @discardableResult
    func beginScrubbing(at point: CGPoint? = nil) -> Bool {
        guard isEnabled, trackingToken == nil, trackRect.width > 0, bounds.height > 0,
              minimumValue.isFinite, maximumValue.isFinite, maximumValue > minimumValue else { return false }
        if let point {
            guard bounds.contains(point), let target = value(at: point) else { return false }
            setValue(target, animated: false)
        }
        trackingToken = scrubController?.begin(in: self, seconds: Double(value))
        return trackingToken != nil
    }

    @discardableResult
    func continueScrubbing(at point: CGPoint) -> Bool {
        guard trackingToken != nil else { return false }
        guard isEnabled, let target = value(at: point) else {
            cancelTracking(with: nil)
            return false
        }
        setValue(target, animated: false)
        sendActions(for: .valueChanged)
        return true
    }

    func finishScrubbing(at point: CGPoint? = nil) {
        guard let token = trackingToken else { return }
        if let point, !continueScrubbing(at: point) {
            cancelTracking(with: nil)
            return
        }
        trackingToken = nil
        scrubController?.finish(in: self, token: token, seconds: Double(value))
        refreshAccessibilityValue()
    }

    private func value(at point: CGPoint) -> Float? {
        guard point.x.isFinite, point.y.isFinite, trackRect.width > 0,
              minimumValue.isFinite, maximumValue.isFinite, maximumValue > minimumValue else { return nil }
        let fraction = min(1, max(0, (point.x - trackRect.minX) / trackRect.width))
        return Float(Double(minimumValue)
            + Double(fraction) * (Double(maximumValue) - Double(minimumValue)))
    }

    @objc private func valueDidChange() {
        refreshAccessibilityValue()
        // A value event after cancellation is not a new drag. VoiceOver commits
        // explicitly above, so neither path can seek twice or revive an old token.
        guard let token = trackingToken else { return }
        scrubController?.update(in: self, token: token, seconds: Double(value))
    }

    func performModelUpdate(_ update: () -> Void) {
        let previous = deferCancellationNotifications
        deferCancellationNotifications = true
        update()
        deferCancellationNotifications = previous
    }

    fileprivate func refreshAccessibilityValue() {
        accessibilityValue = PlaybackPosition.label(Double(value)) + " / "
            + PlaybackPosition.label(Double(maximumValue))
    }
}

@MainActor struct PlaybackSlider: UIViewRepresentable {
    let seconds: Double
    let duration: Double
    let isEnabled: Bool
    let controller: PlaybackScrubController
    let onDraftChanged: (Double?) -> Void
    let onEditingChanged: (Bool) -> Void
    let onCommit: (Double) -> Void

    final class Coordinator: PlaybackScrubObserver {
        var parent: PlaybackSlider
        init(_ parent: PlaybackSlider) { self.parent = parent }
        func draftChanged(_ seconds: Double?) { parent.onDraftChanged(seconds) }
        func editingChanged(_ editing: Bool) { parent.onEditingChanged(editing) }
        func commit(_ seconds: Double) {
            if parent.isEnabled { parent.onCommit(seconds) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> PlaybackTrackingSlider {
        let slider = PlaybackTrackingSlider(frame: .zero)
        controller.bind(slider, observer: context.coordinator)
        return slider
    }

    func updateUIView(_ slider: PlaybackTrackingSlider, context: Context) {
        context.coordinator.parent = self
        controller.bind(slider, observer: context.coordinator)
        slider.performModelUpdate {
            let upper = duration.isFinite ? max(1, duration) : 1
            let maximum = Float(min(upper, Double(Float.greatestFiniteMagnitude)))
            if slider.maximumValue != maximum { slider.maximumValue = maximum }
            if slider.isEnabled != isEnabled { slider.isEnabled = isEnabled }
            if !controller.isEditing(in: slider) {
                let value = seconds.isFinite ? min(max(0, seconds), upper) : 0
                slider.setValue(Float(min(value, Double(slider.maximumValue))), animated: false)
            }
            slider.refreshAccessibilityValue()
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: PlaybackTrackingSlider,
                      context: Context) -> CGSize? {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 300
        return CGSize(width: max(44, width), height: 44)
    }

    static func dismantleUIView(_ slider: PlaybackTrackingSlider, coordinator: Coordinator) {
        coordinator.parent.controller.detach(slider)
    }
}
