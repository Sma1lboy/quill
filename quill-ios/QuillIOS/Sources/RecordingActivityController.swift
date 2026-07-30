@preconcurrency import ActivityKit
import Foundation

/// App-side lifecycle for the Live Activity across both phases:
/// recording (start → level/pause updates → stop) and transcribing
/// (progress updates → end). Throttled — every update redraws the island.
@MainActor
final class RecordingActivityController {
    private var activity: Activity<RecordingActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var anchor = Date()

    // MARK: Recording phase

    func start(kind: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        anchor = Date()
        let attributes = RecordingActivityAttributes(kind: kind)
        let state = RecordingActivityAttributes.ContentState(
            phase: .recording, startedAt: anchor, isPaused: false, level: 0, progress: 0
        )
        activity = try? Activity.request(
            attributes: attributes,
            content: .init(state: state, staleDate: nil)
        )
    }

    /// Called from the 15fps ticker; pushes at most 1 Hz.
    func level(_ value: Float, elapsed: TimeInterval) {
        guard let activity, Date().timeIntervalSince(lastUpdate) >= 1.0 else { return }
        lastUpdate = Date()
        let state = RecordingActivityAttributes.ContentState(
            phase: .recording, startedAt: anchor, isPaused: false,
            level: Double(value), progress: 0
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func pause(elapsed: TimeInterval) {
        guard let activity else { return }
        let state = RecordingActivityAttributes.ContentState(
            phase: .recording,
            startedAt: Date().addingTimeInterval(-elapsed),
            isPaused: true, level: 0, progress: 0
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func resume(elapsed: TimeInterval) {
        guard let activity else { return }
        anchor = Date().addingTimeInterval(-elapsed)
        let state = RecordingActivityAttributes.ContentState(
            phase: .recording, startedAt: anchor, isPaused: false, level: 0, progress: 0
        )
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    func stop() {
        guard let activity else { return }
        self.activity = nil
        Task { await activity.end(nil, dismissalPolicy: .immediate) }
    }

    // MARK: Transcribing phase

    /// Reuse the live activity if recording just ended into transcription;
    /// otherwise start one (e.g. resume-after-relaunch transcribes with no
    /// prior recording activity).
    func transcribing(progress: Double, kind: String = "quick") {
        let state = RecordingActivityAttributes.ContentState(
            phase: .transcribing, startedAt: Date(), isPaused: false,
            level: 0, progress: progress
        )
        if let activity {
            // Throttle progress redraws to 1 Hz too.
            guard Date().timeIntervalSince(lastUpdate) >= 1.0 else { return }
            lastUpdate = Date()
            Task { await activity.update(.init(state: state, staleDate: nil)) }
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: RecordingActivityAttributes(kind: kind),
                content: .init(state: state, staleDate: nil)
            )
        }
    }

    /// Transcription finished (or failed) — take the activity down.
    func endTranscribing() {
        stop()
    }
}
