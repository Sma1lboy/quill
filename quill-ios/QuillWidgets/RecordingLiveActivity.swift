import ActivityKit
import SwiftUI
import WidgetKit

// quill's Live Activity — minimal: no wordmark, the terracotta glyph is the
// brand. Two phases share one activity:
//   recording    ● + waveform + ticking mono timer
//   transcribing ✳ pixel-spinner + mono percentage
// One background for the whole card via activityBackgroundTint (painting a
// second layer inside makes the system chrome show as bands).

private enum W {
    static let paperDark = Color(red: 0.078, green: 0.078, blue: 0.075)
    static let inkDark = Color(red: 0.918, green: 0.906, blue: 0.875)
    static let accent = Color(red: 0.800, green: 0.471, blue: 0.361)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct RecordingLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            HStack(spacing: 14) {
                PhaseGlyph(state: context.state, size: 13)
                if context.state.phase == .recording {
                    MiniWaveform(level: context.state.level, paused: context.state.isPaused, tint: W.accent)
                        .frame(width: 56, height: 20)
                    Spacer()
                    ElapsedTimer(state: context.state, size: 22, tint: W.inkDark)
                } else {
                    Text("transcribing")
                        .font(W.mono(13))
                        .foregroundStyle(W.inkDark.opacity(0.8))
                    Spacer()
                    if context.state.progress > 0 {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(W.mono(22, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(W.inkDark)
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .activityBackgroundTint(W.paperDark)
            .activitySystemActionForegroundColor(W.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PhaseGlyph(state: context.state, size: 12)
                        .padding(.leading, 4)
                        .padding(.top, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Group {
                        if context.state.phase == .recording {
                            ElapsedTimer(state: context.state, size: 18, tint: W.inkDark)
                        } else if context.state.progress > 0 {
                            Text("\(Int(context.state.progress * 100))%")
                                .font(W.mono(18, .semibold))
                                .monospacedDigit()
                                .foregroundStyle(W.inkDark)
                        }
                    }
                    .padding(.trailing, 4)
                    .padding(.top, 2)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if context.state.phase == .recording {
                        MiniWaveform(level: context.state.level, paused: context.state.isPaused, tint: W.accent)
                            .frame(height: 20)
                            .frame(maxWidth: .infinity)
                    } else {
                        ProgressCapsule(progress: context.state.progress)
                            .frame(height: 4)
                            .padding(.horizontal, 8)
                    }
                }
            } compactLeading: {
                PhaseGlyph(state: context.state, size: 10)
            } compactTrailing: {
                Group {
                    if context.state.phase == .recording {
                        ElapsedTimer(state: context.state, size: 12, tint: W.accent)
                    } else if context.state.progress > 0 {
                        Text("\(Int(context.state.progress * 100))%")
                            .font(W.mono(12, .semibold))
                            .monospacedDigit()
                            .foregroundStyle(W.accent)
                    }
                }
                .frame(maxWidth: 44)
            } minimal: {
                PhaseGlyph(state: context.state, size: 10)
            }
            .keylineTint(W.accent)
        }
    }
}

/// Recording: solid dot (hollow when paused). Transcribing: a real spinner
/// — the indeterminate ProgressView is one of the few things the system
/// animates inside a Live Activity, so it spins without pushes.
private struct PhaseGlyph: View {
    let state: RecordingActivityAttributes.ContentState
    var size: CGFloat

    var body: some View {
        if state.phase == .recording {
            Circle()
                .fill(state.isPaused ? Color.clear : W.accent)
                .overlay(Circle().strokeBorder(W.accent, lineWidth: state.isPaused ? 2 : 0))
                .frame(width: size, height: size)
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(W.accent)
                .scaleEffect(size / 18)
                .frame(width: size + 4, height: size + 4)
        }
    }
}

private struct ElapsedTimer: View {
    let state: RecordingActivityAttributes.ContentState
    var size: CGFloat
    var tint: Color

    var body: some View {
        Group {
            if state.isPaused {
                Text(Duration.seconds(Date().timeIntervalSince(state.startedAt))
                    .formatted(.time(pattern: .minuteSecond)))
            } else {
                Text(timerInterval: state.startedAt...Date(timeIntervalSinceNow: 3600 * 12),
                     countsDown: false)
            }
        }
        .font(W.mono(size, .semibold))
        .monospacedDigit()
        .foregroundStyle(tint)
        .multilineTextAlignment(.trailing)
    }
}

private struct ProgressCapsule: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(W.inkDark.opacity(0.2))
                Capsule()
                    .fill(W.accent)
                    .frame(width: max(4, geo.size.width * progress))
            }
        }
    }
}

private struct MiniWaveform: View {
    let level: Double
    let paused: Bool
    let tint: Color
    private static let weights: [CGFloat] = [0.5, 0.9, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<Self.weights.count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(tint.opacity(paused ? 0.35 : 0.9))
                    .frame(
                        width: 3,
                        height: 3 + (paused ? 0 : CGFloat(min(1, level.squareRoot())) * 14 * Self.weights[i])
                    )
            }
        }
    }
}
