@preconcurrency import AVFoundation
import SwiftUI

/// Playback of a session's mic.caf: play/pause, a scrubbable progress
/// capsule, mono clock. Segment taps in the transcript seek here through
/// `seek(to:)`. One player per visible session screen.
///
/// Player creation, prepareToPlay, and audio-session activation all happen
/// off the main thread — a 15 MB CAF plus setActive() while the
/// transcriber saturates the CPU froze the UI when done synchronously.
@MainActor
final class PlaybackModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isLoading = false
    @Published var position: TimeInterval = 0
    @Published private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// Seek requested before the player finished loading.
    private var pendingSeek: TimeInterval?
    /// We activated the shared session and owe a deactivate on teardown.
    private var activated = false
    /// Some session is recording. A take owns AVAudioSession as
    /// `.playAndRecord`; flipping it to `.playback` would kill the mic, so
    /// playback stands down for the duration. Driven from the view.
    @Published private(set) var blockedByRecording = false

    /// Playback and recording share one AVAudioSession — recording wins.
    func setRecording(_ recording: Bool) {
        blockedByRecording = recording
        if recording { pause() }
    }

    func load(_ url: URL) {
        guard player == nil, !isLoading else { return }
        #if DEBUG
        Self.selfCheck()
        #endif
        isLoading = true
        Task.detached(priority: .userInitiated) {
            let p = try? AVAudioPlayer(contentsOf: url)
            p?.prepareToPlay()
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.player = p
                p?.delegate = self
                self.duration = p?.duration ?? 0
                self.isLoading = false
                if let target = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: target)
                }
            }
        }
    }

    func toggle() {
        guard let player, !blockedByRecording else { return }
        if isPlaying {
            pause()
        } else {
            isPlaying = true // optimistic; corrected below if start fails
            startTicker()
            Task.detached {
                // Session activation can block for seconds under load —
                // never on the main thread.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                let ok = player.play()
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.activated = true
                    if ok {
                        self.observeInterruptions()
                    } else {
                        self.isPlaying = false
                        self.stopTicker()
                    }
                }
            }
        }
    }

    /// Single stop-playing path — interruptions, the pause button, a new
    /// recording, and view teardown all route through here.
    func pause() {
        guard isPlaying else { return }
        player?.pause()
        stopTicker()
        isPlaying = false
    }

    func seek(to seconds: TimeInterval) {
        guard let player else {
            pendingSeek = seconds // honor the tap once loading finishes
            return
        }
        player.currentTime = Self.clamp(seconds, duration: duration)
        position = player.currentTime
        if !isPlaying { toggle() }
    }

    func scrub(fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = Self.clamp(duration * fraction, duration: duration)
        position = player.currentTime
    }

    func teardown() {
        player?.stop()
        stopTicker()
        player = nil
        isPlaying = false
        position = 0
        duration = 0
        pendingSeek = nil
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
        if activated {
            activated = false
            // Hand the session back so the mic (and other apps' audio) can
            // have it — playback holding .playback blocks the next take.
            Task.detached {
                try? AVAudioSession.sharedInstance()
                    .setActive(false, options: .notifyOthersOnDeactivation)
            }
        }
    }

    /// Both ends of the scrubbable range, in one place: never past the last
    /// 100ms (AVAudioPlayer treats currentTime == duration as finished).
    static func clamp(_ seconds: TimeInterval, duration: TimeInterval) -> TimeInterval {
        min(max(0, seconds), max(0, duration - 0.1))
    }

    /// Unplugged headphones / a phone call must stop playback, not leave a
    /// silent bar claiming to play. `.began` is the only case that matters —
    /// quill doesn't auto-resume.
    private func observeInterruptions() {
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { note in
            guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  AVAudioSession.InterruptionType(rawValue: raw) == .began else { return }
            Task { @MainActor [weak self] in self?.pause() }
        }
    }

    private var observer: NSObjectProtocol?

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            position = 0
            stopTicker()
        }
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, let player = self.player else { return }
                self.position = player.currentTime
            }
        }
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    #if DEBUG
    /// One runnable check for the arithmetic in this file: clamp bounds and
    /// the playhead→segment lookup (gaps between segments included).
    static func selfCheck() {
        assert(clamp(-5, duration: 10) == 0)
        assert(clamp(99, duration: 10) == 9.9)
        assert(clamp(4, duration: 10) == 4)
        assert(clamp(3, duration: 0) == 0)  // not-yet-loaded player

        func seg(_ a: Int, _ b: Int) -> Transcript.Segment {
            .init(speaker: "s", start_ms: a, end_ms: b, text: "")
        }
        // 0–1s, silence 1–3s, 3–4s.
        let segs = [seg(0, 1000), seg(3000, 4000)]
        assert(Transcript.segmentIndex(at: 0, in: segs) == 0)
        assert(Transcript.segmentIndex(at: 0.5, in: segs) == 0)
        assert(Transcript.segmentIndex(at: 2, in: segs) == nil)   // in the gap
        assert(Transcript.segmentIndex(at: 3.5, in: segs) == 1)
        assert(Transcript.segmentIndex(at: 9, in: segs) == nil)   // past the end
        assert(Transcript.segmentIndex(at: 1, in: []) == nil)
    }
    #endif
}

extension Transcript {
    /// Index of the segment containing `position` (seconds), or nil when the
    /// playhead sits in a gap or past the last segment.
    /// ponytail: linear scan — a 1h transcript is ~1k segments and this runs
    /// 5×/s; binary search if segment counts ever get absurd.
    static func segmentIndex(at position: TimeInterval, in segments: [Segment]) -> Int? {
        let ms = Int(position * 1000)
        return segments.firstIndex { ms >= $0.start_ms && ms < $0.end_ms }
    }
}

/// The bar: round play button, scrubbable progress, elapsed/total clocks.
struct PlaybackBar: View {
    @ObservedObject var model: PlaybackModel

    /// "1:23 of 4:56" spoken as words — the mono clocks read as
    /// "one colon two three" digit by digit otherwise.
    private var spokenPosition: String {
        func words(_ t: TimeInterval) -> String {
            Duration.seconds(Int(t)).formatted(
                .units(allowed: [.hours, .minutes, .seconds], width: .wide)
            )
        }
        return "\(words(model.position)) of \(words(model.duration))"
    }

    var body: some View {
        HStack(spacing: 12) {
            Button(action: { model.toggle() }) {
                Group {
                    if model.isLoading {
                        BrailleSpinner(size: 12, tint: Theme.paper)
                    } else {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.paper)
                    }
                }
                .frame(width: 34, height: 34)
                .background(Circle().fill(Theme.accent))
                // 34pt visual, 44pt hit area — the design keeps its small
                // round button, the thumb gets Apple's minimum.
                .contentShape(Circle().inset(by: -5))
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(model.isLoading || model.blockedByRecording)
            .opacity(model.blockedByRecording ? 0.45 : 1)
            .accessibilityLabel(model.isPlaying ? "Pause playback" : "Play recording")
            // Greyed-out-because-recording is conveyed only by 45% opacity;
            // VoiceOver otherwise just says "dimmed" with no reason.
            .accessibilityHint(model.blockedByRecording ? "Unavailable while recording" : "")

            Text(AppState.format(model.position))
                .font(Theme.mono(11, .medium))
                .monospacedDigit()
                .contentTransition(.numericText())
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .accessibilityHidden(true) // spoken as the scrubber's value

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule()
                        .fill(Theme.accent)
                        .frame(width: max(
                            4,
                            geo.size.width * (model.duration > 0 ? model.position / model.duration : 0)
                        ))
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
                // 1:1 scrub — position tracks the finger the whole way.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { model.scrub(fraction: $0.location.x / geo.size.width) }
                )
            }
            .frame(height: 24)
            // A drag-only capsule is invisible to VoiceOver: no trait, no
            // value, and swipe-to-adjust does nothing. The adjustable trait
            // makes it a real scrubber — swipe up/down seeks in 5% steps.
            .accessibilityElement()
            .accessibilityLabel("Playback position")
            .accessibilityValue(spokenPosition)
            .accessibilityAdjustableAction { direction in
                guard model.duration > 0 else { return }
                let step = model.duration * 0.05
                switch direction {
                case .increment: model.scrub(fraction: (model.position + step) / model.duration)
                case .decrement: model.scrub(fraction: (model.position - step) / model.duration)
                @unknown default: break
                }
            }

            Text(AppState.format(model.duration))
                .font(Theme.mono(11))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
                .accessibilityHidden(true) // spoken as the scrubber's value
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 52)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }
}
