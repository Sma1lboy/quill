import ActivityKit
import Foundation

/// Live Activity contract shared between the app (starts/updates/ends) and
/// the widget extension (renders). One activity covers both live phases:
/// recording (dot + waveform + ticking timer) and transcribing (spinner +
/// percentage).
struct RecordingActivityAttributes: ActivityAttributes {
    public enum Phase: String, Codable, Hashable {
        case recording
        case transcribing
    }

    public struct ContentState: Codable, Hashable {
        var phase: Phase
        /// Recording: wall-clock anchor so the timer renders via
        /// Text(timerInterval:) without per-second pushes.
        var startedAt: Date
        var isPaused: Bool
        /// Recording: 0…1 coarse mic level (~1 Hz) for the waveform.
        var level: Double
        /// Transcribing: 0…1 slice progress; drives the percentage.
        var progress: Double
    }

    /// "quick" or "note" — the session kind being worked on.
    var kind: String
}
