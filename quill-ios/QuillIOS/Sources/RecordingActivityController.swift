@preconcurrency import ActivityKit
import Foundation

/// App-side lifecycle for the Live Activity across both phases:
/// recording (start → level/pause updates → stop) and transcribing
/// (progress updates → end). Throttled — every update redraws the island.
@MainActor
final class RecordingActivityController {
    private typealias State = RecordingActivityAttributes.ContentState

    private var activity: Activity<RecordingActivityAttributes>?
    private var lastUpdate = Date.distantPast
    private var lastPhase: RecordingActivityAttributes.Phase?
    private var anchor = Date()

    /// A card left over from a crash or force-quit keeps ticking forever.
    /// Nothing restores recording state across launches, so any activity
    /// still alive at startup is garbage — clear it before starting ours.
    init() {
        #if DEBUG
        Self.selfCheck()
        #endif
        endAll()
    }

    // MARK: Recording phase

    func start(kind: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        anchor = Date()
        let state = State(
            phase: .recording, startedAt: anchor, isPaused: false,
            pausedAt: nil, level: 0, progress: 0
        )
        // Transcription of an earlier session may still be running and
        // holding the card. Flip that one back to recording instead of
        // requesting a second — two quill cards on the lock screen, and the
        // transcribing one orphaned with no handle to end it.
        guard activity == nil else { return push(state, force: true) }
        activity = try? Activity.request(
            attributes: RecordingActivityAttributes(kind: kind),
            content: content(state)
        )
        lastPhase = activity == nil ? nil : .recording
    }

    /// Called from the 15fps ticker; pushes at most 1 Hz. No elapsed needed —
    /// `anchor` is what the widget's ticking timer renders from.
    func level(_ value: Float) {
        push(State(
            phase: .recording, startedAt: anchor, isPaused: false,
            pausedAt: nil, level: Double(value), progress: 0
        ))
    }

    func pause(elapsed: TimeInterval) {
        // Freeze the clock as a span between two stored dates, so the widget
        // reads exactly `elapsed` however often the system re-renders it.
        let now = Date()
        push(State(
            phase: .recording, startedAt: now.addingTimeInterval(-elapsed),
            isPaused: true, pausedAt: now, level: 0, progress: 0
        ), force: true)
    }

    func resume(elapsed: TimeInterval) {
        anchor = Date().addingTimeInterval(-elapsed)
        push(State(
            phase: .recording, startedAt: anchor, isPaused: false,
            pausedAt: nil, level: 0, progress: 0
        ), force: true)
    }

    /// Recording ended. When audio will be transcribed the card stays up and
    /// flips phase — ending here and re-requesting for transcription flickers,
    /// and would fail outright if the app is backgrounded by then
    /// (`Activity.request` needs the foreground).
    func recordingStopped(willTranscribe: Bool) {
        if willTranscribe {
            transcribing(progress: 0)
        } else {
            stop()
        }
    }

    func stop() {
        activity = nil
        lastPhase = nil
        endAll()
    }

    // MARK: Transcribing phase

    /// Reuse the live activity handed over from recording; otherwise start
    /// one (resume-after-relaunch transcribes with no prior activity).
    func transcribing(progress: Double, kind: String = "quick") {
        let state = State(
            phase: .transcribing, startedAt: Date(), isPaused: false,
            pausedAt: nil, level: 0, progress: progress
        )
        if activity != nil {
            // Never throttle away the phase flip: dropping it leaves the card
            // claiming to record until the next slice checkpoint (minutes).
            push(state, force: lastPhase != .transcribing)
        } else {
            guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
            activity = try? Activity.request(
                attributes: RecordingActivityAttributes(kind: kind),
                content: content(state)
            )
            lastPhase = activity == nil ? nil : .transcribing
            lastUpdate = Date()
        }
    }

    /// Transcription finished (or failed) — take the activity down.
    func endTranscribing() {
        stop()
    }

    // MARK: -

    /// Single update path: one throttle, one staleDate, one phase record.
    private func push(_ state: State, force: Bool = false) {
        guard let activity else { return }
        guard Self.shouldPush(force: force, since: lastUpdate) else { return }
        lastUpdate = Date()
        lastPhase = state.phase
        Task { await activity.update(content(state)) }
    }

    /// Every update redraws the island, so level/progress pushes are capped
    /// at 1 Hz — but a forced push (pause, resume, phase flip) must never be
    /// dropped, or the card keeps showing the previous state for minutes.
    static func shouldPush(force: Bool, since: Date, now: Date = Date()) -> Bool {
        force || now.timeIntervalSince(since) >= 1.0
    }

    #if DEBUG
    static func selfCheck() {
        let t = Date()
        assert(shouldPush(force: false, since: t, now: t + 2))     // throttle open
        assert(!shouldPush(force: false, since: t, now: t + 0.3))  // throttled
        assert(shouldPush(force: true, since: t, now: t + 0.3))    // force wins
        assert(shouldPush(force: false, since: .distantPast, now: t))
    }
    #endif

    /// `staleDate` is the only defense against a force-quit leaving a card
    /// that ticks forever: the system greys it out instead of showing a lie.
    /// ponytail: a >30min pause with no pushes also greys out; push on a
    /// timer while paused if that ever matters.
    private func content(_ state: State) -> ActivityContent<State> {
        .init(state: state, staleDate: Date().addingTimeInterval(30 * 60))
    }

    /// Ends every activity of this type, not just the one we hold — an
    /// orphan from a previous launch is invisible to `activity`.
    private func endAll() {
        for live in Activity<RecordingActivityAttributes>.activities {
            Task { await live.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
