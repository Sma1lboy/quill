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
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Timer?
    /// Seek requested before the player finished loading.
    private var pendingSeek: TimeInterval?

    func load(_ url: URL) {
        guard player == nil, !isLoading else { return }
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
        guard let player else { return }
        if isPlaying {
            player.pause()
            stopTicker()
            isPlaying = false
        } else {
            isPlaying = true // optimistic; corrected below if start fails
            startTicker()
            Task.detached {
                // Session activation can block for seconds under load —
                // never on the main thread.
                try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio)
                try? AVAudioSession.sharedInstance().setActive(true)
                let ok = player.play()
                if !ok {
                    await MainActor.run { [weak self] in
                        self?.isPlaying = false
                        self?.stopTicker()
                    }
                }
            }
        }
    }

    func seek(to seconds: TimeInterval) {
        guard let player else {
            pendingSeek = seconds // honor the tap once loading finishes
            return
        }
        player.currentTime = min(max(0, seconds), max(0, duration - 0.1))
        position = player.currentTime
        if !isPlaying { toggle() }
    }

    func scrub(fraction: Double) {
        guard let player, duration > 0 else { return }
        player.currentTime = duration * min(max(0, fraction), 1)
        position = player.currentTime
    }

    func teardown() {
        player?.stop()
        stopTicker()
        player = nil
        isPlaying = false
        position = 0
    }

    private func startTicker() {
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

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            isPlaying = false
            position = 0
            stopTicker()
        }
    }
}

/// The bar: round play button, scrubbable progress, elapsed/total clocks.
struct PlaybackBar: View {
    @ObservedObject var model: PlaybackModel

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
            }
            .buttonStyle(PressableButtonStyle())
            .disabled(model.isLoading)
            .accessibilityLabel(model.isPlaying ? "Pause playback" : "Play recording")

            Text(AppState.format(model.position))
                .font(Theme.mono(11, .medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)

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

            Text(AppState.format(model.duration))
                .font(Theme.mono(11))
                .monospacedDigit()
                .foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
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
