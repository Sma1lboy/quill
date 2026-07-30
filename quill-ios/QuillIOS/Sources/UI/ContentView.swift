import SwiftUI

// quill-ios main screen — DESIGN.md grammar on a phone canvas:
// bracket-chip header, full-width record bar (56pt), stage-tagged session
// list, matte paper everywhere.

struct ContentView: View {
    @ObservedObject var state: AppState
    @State private var path = NavigationPath()
    @State private var showSettings = false
    @State private var showSearch = false
    @StateObject private var updates = UpdateChecker()

    var body: some View {
        NavigationStack(path: $path) {
            // Content fills the screen; the record bar docks at the bottom
            // where the thumb lives.
            VStack(spacing: 0) {
                Header(
                    state: state,
                    onSearch: { showSearch = true },
                    onSettings: { showSettings = true }
                )

                if let manifest = updates.available {
                    UpdateBanner(manifest: manifest)
                        .padding(.horizontal, 20)
                        .padding(.top, 4)
                }

                if state.pipeline != .idle {
                    PipelineBanner(status: state.pipeline)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = state.lastError {
                    Text(error)
                        .font(Theme.mono(12))
                        .foregroundStyle(Theme.error)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                }

                SessionList(state: state)
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 10) {
                    RecordBar(state: state)
                    if !state.isRecording {
                        NewNoteButton {
                            if let id = state.createNote() {
                                path.append(id)
                            }
                        }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 6)
                .background(
                    // Paper fades in under the dock so list rows scroll
                    // beneath it without a hard edge.
                    LinearGradient(
                        colors: [Theme.paper.opacity(0), Theme.paper, Theme.paper],
                        startPoint: .top, endPoint: .bottom
                    )
                    .ignoresSafeArea(edges: .bottom)
                )
            }
            .background(Theme.paper.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(root: state.root)
        }
        .sheet(isPresented: $showSearch) {
            SearchView(state: state)
        }
        .task { updates.check() }
        .animation(Theme.spring, value: state.isRecording)
        .animation(Theme.spring, value: state.pipeline)
        .tint(Theme.accent)
    }
}

// MARK: - Header

private struct Header: View {
    @ObservedObject var state: AppState
    let onSearch: () -> Void
    let onSettings: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            BracketChip(size: 19)
            Spacer()
            if state.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Theme.accent).frame(width: 7, height: 7)
                    Text("REC")
                        .font(Theme.mono(11, .semibold))
                        .tracking(1.2)
                        .foregroundStyle(Theme.accent)
                }
                .transition(.opacity)
            } else {
                Theme.kicker("local · 100 languages")
            }

            // The icon pair sits in its own group — their 32pt frames are the
            // separation, so no extra spacing eats the kicker on a small phone.
            HStack(spacing: 0) {
                Button(action: onSearch) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Search")

                Button(action: onSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 32, height: 32)
                        .contentShape(Circle())
                }
                .buttonStyle(PressableButtonStyle())
                .accessibilityLabel("Settings")
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 14)
    }
}

// MARK: - Record bar

private struct RecordBar: View {
    @ObservedObject var state: AppState

    var body: some View {
        Group {
            if state.isRecording {
                recordingBar
            } else {
                idleButton
            }
        }
    }

    /// Idle: the whole bar is one obvious button.
    private var idleButton: some View {
        Button(action: { state.toggleRecording() }) {
            HStack(spacing: 12) {
                Circle()
                    .fill(Theme.accent)
                    .frame(width: 14, height: 14)
                Text("quick take")
                    .font(Theme.mono(16, .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 10)
                Text("mic")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 20)
            .frame(height: 60)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.surface)
                    .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Theme.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("Start recording")
    }

    /// Recording: a status surface (not tappable) with two explicit round
    /// controls on the right. Timer is static mono — it ticks crisply, no
    /// per-second animation to fight the appear transition.
    private var recordingBar: some View {
        HStack(spacing: 12) {
            Text(AppState.format(state.elapsed))
                .font(Theme.mono(19, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.paper)

            if state.isPaused {
                Text("PAUSED")
                    .font(Theme.mono(10, .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Theme.paper.opacity(0.75))
            } else {
                Waveform(level: state.micLevel, tint: Theme.paper, maxHeight: 22)
                    .frame(width: 56, height: 26)
            }

            Spacer(minLength: 8)

            Button {
                state.isPaused ? state.resumeRecording() : state.pauseRecording()
            } label: {
                Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Color.white.opacity(0.18)))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel(state.isPaused ? "Resume" : "Pause")

            Button(action: { state.stopRecording() }) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 42, height: 42)
                    .background(Circle().fill(Theme.paper))
            }
            .buttonStyle(PressableButtonStyle())
            .accessibilityLabel("Stop recording")
        }
        .padding(.horizontal, 14)
        .frame(height: 60)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Theme.accent)
                .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 4)
        )
    }
}

/// `+ note` — creates a note folder and opens it; recording starts inside.
private struct NewNoteButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text("+ note")
                .font(Theme.mono(13, .medium))
                .foregroundStyle(Theme.accent)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 16)
                .frame(height: 60)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.surface)
                        .shadow(color: Color.black.opacity(0.10), radius: 10, y: 4)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Theme.line, lineWidth: 1)
                )
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(PressableButtonStyle())
        .accessibilityLabel("New note")
    }
}

// MARK: - Pipeline banner

private struct PipelineBanner: View {
    let status: AppState.PipelineStatus

    var body: some View {
        VStack(spacing: 7) {
            HStack(spacing: 8) {
                switch status {
                case .transcribing, .downloadingModel:
                    BrailleSpinner(size: 12)
                default:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.error)
                }
                Text(label)
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let p = fraction {
                    Text("\(Int(p * 100))%")
                        .font(Theme.mono(11, .medium))
                        .monospacedDigit()
                        .foregroundStyle(Theme.accent)
                }
            }

            // Determinate bar for downloads and slice-checkpointed transcription.
            if let p = fraction {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule()
                            .fill(Theme.accent)
                            .frame(width: max(4, geo.size.width * p))
                            .animation(Theme.spring, value: p)
                    }
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.inset)
        )
        .padding(.horizontal, 20)
        .padding(.top, 10)
    }

    private var fraction: Double? {
        switch status {
        case .downloadingModel(let p): return p
        case .transcribing(_, _, let p) where p > 0: return p
        default: return nil
        }
    }

    private var label: String {
        switch status {
        case .idle: return ""
        case .downloadingModel:
            return "downloading whisper model · once"
        case .transcribing(let s, let q, _):
            return q > 0 ? "transcribing \(s) · \(q) queued" : "transcribing \(s)"
        case .failed(let s): return "transcription failed · \(s)"
        }
    }
}

// MARK: - Session list

private struct SessionList: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Theme.kicker("recent")
                Spacer()
                if !state.sessions.isEmpty {
                    Text(String(format: "%02d", state.sessions.count))
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 22)
            .padding(.bottom, 8)

            if state.sessions.isEmpty {
                VStack(spacing: 8) {
                    Text("no recordings yet")
                        .font(Theme.mono(13))
                        .foregroundStyle(Theme.muted)
                    Text("sessions land in Files → quill as folders you own")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted.opacity(0.6))
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 48)
                Spacer()
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(state.sessions) { session in
                            SwipeToDeleteRow(
                                // No swiping a session out from under the
                                // recorder or the transcription queue.
                                disabled: state.isBusy(id: session.id),
                                onDelete: { state.deleteSession(id: session.id) }
                            ) {
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 24)
                }
                .navigationDestination(for: String.self) { id in
                    SessionDetailView(state: state, id: id)
                }
            }
        }
    }
}

private struct SessionRow: View {
    let session: SessionSummary

    var body: some View {
        HStack(spacing: 12) {
            // The tag encodes maturity: NOTE (final, accent) > TXT > AUD.
            Text(stageTag)
                .font(Theme.mono(10, .semibold))
                .tracking(0.5)
                .foregroundStyle(session.stage == .noted ? Theme.accent : Theme.muted.opacity(0.75))
                .frame(width: 36, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                Text(session.title)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                if session.contentTitle != nil {
                    Text(session.timeTitle)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                }
            }

            Spacer(minLength: 8)

            if let d = session.duration {
                Text(AppState.format(TimeInterval(d)))
                    .font(Theme.mono(12))
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Theme.muted.opacity(0.5))
        }
        .padding(.horizontal, 10)
        .frame(height: 46)
        .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var stageTag: String {
        switch session.stage {
        case .empty: return "—"
        case .recorded: return "AUD"
        case .transcribed: return "TXT"
        case .noted: return "NOTE"
        }
    }
}
