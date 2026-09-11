import Foundation

// Pure interaction state, independent of VLC and the wall clock. Pass monotonic
// systemUptime from the UI; tests advance time without sleeping or playing media.
struct PlaybackControlsState {
    static let defaultHideDelay: TimeInterval = 4
    let hideDelay: TimeInterval
    private(set) var isVisible = true
    private(set) var isFullscreen = false
    private(set) var isPlaying = false
    private(set) var isScrubbing = false
    private(set) var isNavigating = false
    private(set) var isSceneActive = true
    private(set) var voiceOverEnabled = false
    private(set) var isPresentingAlert = false
    private(set) var hideDeadline: TimeInterval?

    init(hideDelay: TimeInterval = Self.defaultHideDelay) {
        self.hideDelay = hideDelay.isFinite && hideDelay > 0 && hideDelay <= 60
            ? hideDelay : Self.defaultHideDelay
    }

    private var canHide: Bool {
        isPlaying && isSceneActive && !isScrubbing && !isNavigating && !voiceOverEnabled && !isPresentingAlert
    }

    mutating func interacted(at now: TimeInterval) {
        isVisible = true
        hideDeadline = canHide && now.isFinite ? now + hideDelay : nil
    }

    mutating func surfaceTapped(at now: TimeInterval) {
        if isVisible && canHide {
            isVisible = false
            hideDeadline = nil
        } else {
            interacted(at: now)
        }
    }

    mutating func setPlaying(_ value: Bool, at now: TimeInterval) {
        // VLC emits time updates while playing; these must NOT reset the timer.
        guard value != isPlaying else { return }
        isPlaying = value
        interacted(at: now)
    }

    mutating func setScrubbing(_ value: Bool, at now: TimeInterval) {
        isScrubbing = value
        interacted(at: now)
    }

    mutating func setNavigating(_ value: Bool, at now: TimeInterval) {
        isNavigating = value
        interacted(at: now)
    }

    mutating func toggleFullscreen(at now: TimeInterval) {
        isFullscreen.toggle()
        interacted(at: now)
    }

    mutating func setSceneActive(_ value: Bool, at now: TimeInterval) {
        isSceneActive = value
        if !value { isScrubbing = false; isNavigating = false }
        interacted(at: now)
    }

    mutating func setVoiceOverEnabled(_ value: Bool, at now: TimeInterval) {
        voiceOverEnabled = value
        interacted(at: now)
    }

    mutating func setPresentingAlert(_ value: Bool, at now: TimeInterval) {
        isPresentingAlert = value
        interacted(at: now)
    }

    mutating func hideIfDue(at now: TimeInterval, deadline: TimeInterval) {
        // Even an already-resumed cancelled task cannot hide newly shown controls.
        guard canHide, isVisible, hideDeadline == deadline, now >= deadline else { return }
        isVisible = false
        hideDeadline = nil
    }

    mutating func stop() {
        hideDeadline = nil
        isPlaying = false
        isSceneActive = false
        isScrubbing = false
        isNavigating = false
    }
}
