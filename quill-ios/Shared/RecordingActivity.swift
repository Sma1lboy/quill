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
        /// When paused, the instant capture stopped. Both ends of the frozen
        /// elapsed span must be stored dates: the system re-renders a Live
        /// Activity whenever it likes, and a `Date()` read at render time
        /// made the paused clock keep climbing.
        var pausedAt: Date?
        /// Recording: 0…1 coarse mic level (~1 Hz) for the waveform.
        var level: Double
        /// Transcribing: 0…1 slice progress; drives the percentage.
        var progress: Double

        /// The paused clock, formatted the way the *running* clock formats
        /// itself. `Text(timerInterval:)` rolls into `h:mm:ss` past an hour,
        /// so a fixed `.minuteSecond` pattern here made pausing a 90-minute
        /// interview relabel it "90:00" — which reads as ninety seconds.
        var pausedClock: String {
            let elapsed = max(0, (pausedAt ?? startedAt).timeIntervalSince(startedAt))
            return Duration.seconds(elapsed).formatted(.time(
                pattern: elapsed >= 3600 ? .hourMinuteSecond : .minuteSecond
            ))
        }
    }

    /// "quick" or "note" — the session kind being worked on.
    var kind: String

    #if DEBUG
    /// The pause clock, both sides of the hour boundary — the running timer
    /// switches format there and the frozen one has to agree, or pausing
    /// silently changes what the number means.
    static func selfCheckPausedClock() {
        func clock(_ elapsed: TimeInterval) -> String {
            let start = Date()
            return ContentState(
                phase: .recording, startedAt: start, isPaused: true,
                pausedAt: start.addingTimeInterval(elapsed), level: 0, progress: 0
            ).pausedClock
        }
        assert(clock(7) == "0:07")
        assert(clock(754) == "12:34")
        assert(clock(3599) == "59:59")       // last second before rollover
        assert(clock(3600) == "1:00:00")     // was "60:00" — reads as a minute
        assert(clock(5400) == "1:30:00")     // was "90:00"
        assert(clock(44_625) == "12:23:45")  // was "743:45"
        // A pause with no recorded instant must read zero, never a negative
        // span or a clock that keeps climbing.
        let start = Date()
        assert(ContentState(
            phase: .recording, startedAt: start, isPaused: true,
            pausedAt: nil, level: 0, progress: 0
        ).pausedClock == "0:00")
        assert(ContentState(
            phase: .recording, startedAt: start, isPaused: true,
            pausedAt: start.addingTimeInterval(-30), level: 0, progress: 0
        ).pausedClock == "0:00", "a clock skew must not render a negative span")
    }
    #endif
}
