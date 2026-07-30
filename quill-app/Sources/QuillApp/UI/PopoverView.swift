import SwiftUI

// quill popover in kobe's design language: matte porcelain paper (solid, not
// system glass), espresso ink, terracotta accent, mono kickers, and the
// `[ quill ]` bracket-chip grammar from kobe's hotkey UI. Motion stays
// apple-design: critically damped springs, press feedback on pointer-down,
// Reduce Motion degrades to fades.

struct PopoverView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Header(state: state)
            RecordHero(state: state)

            if state.pipeline != .idle {
                PipelineBanner(status: state.pipeline)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            SessionList(sessions: state.sessions)
            FooterBar(state: state)
        }
        .frame(width: 292)
        .background(Theme.paper)
        .animation(reducedSpring, value: state.isRecording)
        .animation(reducedSpring, value: state.pipeline)
    }
}

var reducedSpring: Animation {
    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        ? .easeOut(duration: 0.15)
        : .spring(response: 0.35, dampingFraction: 1.0)
}

// MARK: - Header — [ quill ] wordmark + live state

private struct Header: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // Bracket chip: terracotta brackets, ink word — kobe's `[Tab]`
            // hotkey grammar. Reads as the thing you press.
            Text("[").foregroundStyle(Theme.accent)
            Text(" quill ").foregroundStyle(Theme.ink)
            Text("]").foregroundStyle(Theme.accent)

            Spacer()

            if state.isRecording {
                HStack(spacing: 5) {
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 6, height: 6)
                    Text("REC")
                        .font(Theme.mono(10, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.accent)
                }
                .transition(.opacity)
            } else {
                Theme.kicker("local · on-device")
            }
        }
        .font(Theme.mono(13, .bold))
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

// MARK: - Record hero

private struct RecordHero: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Button(action: { state.toggleRecording() }) {
                HStack(spacing: 10) {
                    ZStack {
                        RoundedRectangle(cornerRadius: state.isRecording ? 2.5 : 6, style: .continuous)
                            .fill(state.isRecording ? Theme.paper : Theme.accent)
                            .frame(
                                width: state.isRecording ? 11 : 12,
                                height: state.isRecording ? 11 : 12
                            )
                    }
                    .frame(width: 16, height: 16)

                    if state.isRecording {
                        Text(AppState.format(state.elapsed))
                            .font(Theme.mono(15, .semibold))
                            .monospacedDigit()
                            .contentTransition(.numericText())
                            .animation(.default, value: Int(state.elapsed))
                            .foregroundStyle(Theme.paper)

                        Spacer(minLength: 8)

                        Waveform(level: state.micLevel, tint: Theme.paper)
                            .frame(width: 56, height: 18)

                        Text("STOP")
                            .font(Theme.mono(10, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.paper.opacity(0.85))
                    } else {
                        Text("start recording")
                            .font(Theme.mono(12.5, .medium))
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .fixedSize()

                        Spacer(minLength: 8)

                        Text("mic+sys")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.muted)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(state.isRecording ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.surface))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .strokeBorder(state.isRecording ? Color.clear : Theme.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(state.isRecording ? "Stop recording" : "Start recording")
            .padding(.horizontal, 14)
            .padding(.bottom, 12)

            if let error = state.lastError {
                Text(error)
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.error)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
        }
    }
}

/// Five thin bars breathing with the mic level, desynced weights.
private struct Waveform: View {
    let level: Float
    let tint: Color
    private static let weights: [CGFloat] = [0.5, 0.9, 1.0, 0.7, 0.45]

    var body: some View {
        HStack(alignment: .center, spacing: 2.5) {
            ForEach(0..<Self.weights.count, id: \.self) { i in
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.9))
                    .frame(width: 2.5, height: 3 + CGFloat(min(1, sqrt(level))) * 15 * Self.weights[i])
                    .animation(.linear(duration: 1.0 / 15.0), value: level)
            }
        }
        .accessibilityHidden(true)
    }
}

private struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.spring(response: 0.25, dampingFraction: 1.0), value: configuration.isPressed)
    }
}

// MARK: - Pipeline banner

private struct PipelineBanner: View {
    let status: AppState.PipelineStatus

    var body: some View {
        HStack(spacing: 7) {
            if isWorking {
                ProgressView()
                    .controlSize(.mini)
                    .tint(Theme.accent)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(Theme.error)
            }
            Text(label)
                .font(Theme.mono(10.5))
                .foregroundStyle(Theme.muted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
        .background(Theme.inset)
    }

    private var isWorking: Bool {
        switch status {
        case .transcribing, .structuring: return true
        default: return false
        }
    }

    private var label: String {
        switch status {
        case .idle: return ""
        case .transcribing(let s, let q):
            return q > 0 ? "transcribing \(s) · \(q) queued" : "transcribing \(s)"
        case .structuring(let s, _): return "writing notes · \(s)"
        case .failed(let s): return "transcription failed · \(s)"
        }
    }
}

// MARK: - Session list

private struct SessionList: View {
    let sessions: [SessionSummary]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)

            HStack {
                Theme.kicker("recent")
                Spacer()
                if !sessions.isEmpty {
                    Text(String(format: "%02d", sessions.count))
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 11)
            .padding(.bottom, 4)

            if sessions.isEmpty {
                VStack(spacing: 6) {
                    Text("~/Recordings is empty")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                    Text("sessions land here as folders you own")
                        .font(Theme.mono(9.5))
                        .foregroundStyle(Theme.muted.opacity(0.6))
                }
                .frame(maxWidth: .infinity, minHeight: 84)
                .padding(.bottom, 6)
            } else {
                ScrollView {
                    LazyVStack(spacing: 1) {
                        ForEach(sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                    .padding(.horizontal, 7)
                    .padding(.bottom, 7)
                }
                .frame(height: min(CGFloat(sessions.count) * 37 + 7, 158))
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary
    @State private var hovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 8) {
                // Stage as a fixed-width mono tag — terminal column, not an icon.
                Text(stageTag)
                    .font(Theme.mono(9, .semibold))
                    .tracking(0.5)
                    .foregroundStyle(session.stage == .structured ? Theme.accent : Theme.muted.opacity(0.75))
                    .frame(width: 34, alignment: .leading)

                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)

                Spacer(minLength: 8)

                if let d = session.duration {
                    Text(AppState.format(TimeInterval(d)))
                        .font(Theme.mono(10.5))
                        .monospacedDigit()
                        .foregroundStyle(hovering ? Theme.ink : Theme.muted)
                }
            }
            .padding(.horizontal, 8)
            .frame(height: 32)
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(hovering ? Theme.accentSoft : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .help(helpText)
    }

    private func open() {
        let fm = FileManager.default
        let notes = session.dir.appendingPathComponent("notes.md")
        let transcript = session.dir.appendingPathComponent("transcript.md")
        if fm.fileExists(atPath: notes.path) {
            NSWorkspace.shared.open(notes)
        } else if fm.fileExists(atPath: transcript.path) {
            NSWorkspace.shared.open(transcript)
        } else {
            NSWorkspace.shared.open(session.dir)
        }
    }

    private var stageTag: String {
        switch session.stage {
        case .recorded: return "AUD"
        case .transcribed: return "TXT"
        case .structured: return "NOTE"
        }
    }

    private var helpText: String {
        switch session.stage {
        case .recorded: return "Audio only — opens the folder"
        case .transcribed: return "Opens transcript.md"
        case .structured: return "Opens notes.md"
        }
    }

    private var title: String {
        guard let started = session.started else { return session.id }
        let time = started.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(started) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(started) { return "Yesterday \(time)" }
        let day = started.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
        return "\(day) · \(time)"
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Theme.line).frame(height: 1)
            HStack(spacing: 2) {
                FooterButton(label: "~/Recordings") { state.openRecordingsFolder() }
                Spacer()
                FooterButton(label: "quit") { state.quit() }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
        }
        .background(Theme.inset.opacity(0.5))
    }
}

private struct FooterButton: View {
    let label: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(Theme.mono(10.5, .medium))
                .foregroundStyle(hovering ? Theme.accent : Theme.muted)
                .padding(.horizontal, 7)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(hovering ? Theme.accentSoft : Color.clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }
}
