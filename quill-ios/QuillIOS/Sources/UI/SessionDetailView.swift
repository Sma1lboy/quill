import PhotosUI
import SwiftUI

/// One session/note. Content reads top-down (facts → images → transcript);
/// the record controls dock at the bottom where the thumb lives — same
/// grammar as the home screen. Notes can attach images (stored in the
/// session folder's images/, feeding the future LLM enhance pass).
struct SessionDetailView: View {
    @ObservedObject var state: AppState
    let id: String
    /// Segment index to open the transcript on (set when arriving from search).
    var scrollToSegment: Int?
    @State private var transcript: Transcript?
    @State private var notes: String?
    @State private var images: [URL] = []
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var enhancing = false
    @State private var enhanceError: String?
    @State private var showTranscript = false
    @State private var renaming = false
    @State private var draftTitle = ""
    @State private var confirmDelete = false
    @State private var zipping = false
    @State private var share: SharePayload?
    /// Rename/share failure — `enhanceError` only renders when notes are
    /// absent, so these need their own line.
    @State private var actionError: String?
    @StateObject private var playback = PlaybackModel()
    @Environment(\.dismiss) private var dismiss

    private var session: SessionSummary? {
        state.sessions.first { $0.id == id }
    }
    private var isActive: Bool { state.recordingID == id }
    /// Share the note when it exists (the product), else the transcript.
    private var shareItem: URL {
        let notes = dir.appendingPathComponent("notes.md")
        return FileManager.default.fileExists(atPath: notes.path)
            ? notes
            : dir.appendingPathComponent("transcript.md")
    }
    private var dir: URL { state.root.appendingPathComponent(id, isDirectory: true) }
    /// This session is the one the pipeline is currently transcribing.
    private var isQueued: Bool {
        if case .transcribing(let s, _, _) = state.pipeline, s == id { return true }
        return false
    }
    /// Slice progress for this session while transcribing, 0…1.
    private var queueProgress: Double? {
        if case .transcribing(let s, _, let p) = state.pipeline, s == id, p > 0 { return p }
        return nil
    }
    /// Segment the playhead is inside, or nil when stopped.
    private var playingSegment: Int? {
        guard playback.isPlaying, let transcript else { return nil }
        return Transcript.segmentIndex(at: playback.position, in: transcript.segments)
    }

    var body: some View {
        // quill is a note-taker: notes.md is the product. The pipeline
        // stages (audio, transcript) are kept and inspectable, but read as
        // intermediates — notes first, then images, then a collapsed
        // transcript, playback and facts tucked at the bottom.
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // 1 · The note (or the path to one).
                if let notes {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Theme.kicker("notes")
                            Spacer()
                            Button {
                                rerunEnhance()
                            } label: {
                                if enhancing {
                                    BrailleSpinner(size: 11)
                                } else {
                                    Text("re-run")
                                        .font(Theme.mono(10, .medium))
                                        .foregroundStyle(Theme.accent)
                                }
                            }
                            .buttonStyle(.plain)
                            .disabled(enhancing)
                        }
                        QuillMarkdown(content: notes)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                } else if transcript != nil {
                    // Notes are an automatic pipeline stage, not a call to
                    // action — while they're pending this is just a quiet
                    // status line. Failures land in the facts block below.
                    HStack(spacing: 8) {
                        if enhancing {
                            BrailleSpinner(size: 11)
                        }
                        Text(enhancing ? "structuring notes…" : "notes pending")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                }

                if !images.isEmpty {
                    ImageStrip(urls: images)
                        .padding(.top, 16)
                }

                // 2 · Intermediates, collapsed by default.
                if let transcript {
                    DisclosureGroup(isExpanded: $showTranscript) {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            ForEach(transcript.segments.indices, id: \.self) { i in
                                let seg = transcript.segments[i]
                                // One wash, two reasons: the search hit stays
                                // marked after the jump, and the segment being
                                // played marks itself as the playhead moves.
                                let marked = i == scrollToSegment || i == playingSegment
                                VStack(alignment: .leading, spacing: 2) {
                                    // Timestamp doubles as a seek button.
                                    Button {
                                        playback.seek(to: TimeInterval(seg.start_ms) / 1000)
                                    } label: {
                                        Text("[\(Transcript.clock(seg.start_ms))] \(seg.speaker)")
                                            .font(Theme.mono(10, .semibold))
                                            .foregroundStyle(Theme.accent.opacity(0.8))
                                    }
                                    .buttonStyle(.plain)
                                    Text(seg.text)
                                        .font(.system(size: 14))
                                        .foregroundStyle(Theme.ink.opacity(marked ? 1 : 0.85))
                                        .lineSpacing(3)
                                        .textSelection(.enabled)
                                }
                                .padding(.horizontal, marked ? 8 : 0)
                                .padding(.vertical, marked ? 6 : 0)
                                .background(
                                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                                        .fill(marked ? Theme.accentSoft : .clear)
                                )
                                .id(i)
                            }
                        }
                        .animation(Theme.spring, value: playingSegment)
                        .padding(.top, 12)
                    } label: {
                        HStack(spacing: 6) {
                            Theme.kicker("transcript")
                            Text("\(transcript.segments.count) segments")
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.muted.opacity(0.6))
                        }
                    }
                    .tint(Theme.muted)
                    .padding(.horizontal, 20)
                    .padding(.top, 22)
                }

                // 3 · Source audio + session facts, last.
                if !isActive, FileManager.default.fileExists(
                    atPath: dir.appendingPathComponent("mic.caf").path
                ) {
                    PlaybackBar(model: playback)
                        .padding(.horizontal, 20)
                        .padding(.top, 22)
                        .onAppear { playback.load(dir.appendingPathComponent("mic.caf")) }
                }

                factsBlock
                    .padding(.horizontal, 20)
                    .padding(.top, 12)

                Color.clear.frame(height: 24)
            }
        }
        .background(Theme.paper.ignoresSafeArea())
        .navigationTitle(session?.title ?? id)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // Matched pair: same size, same weight, same 30pt frame, so the
            // two glyphs sit on one optical line. Attach is the one action
            // frequent enough to stay out of the menu.
            ToolbarItemGroup(placement: .primaryAction) {
                PhotosPicker(
                    selection: $pickerItems,
                    maxSelectionCount: 8,
                    matching: .images
                ) {
                    Image(systemName: "photo")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(Theme.accent)
                        .frame(width: 30, height: 30)
                }

                Menu {
                    Button("rename") {
                        draftTitle = session?.contentTitle ?? ""
                        renaming = true
                    }

                    if FileManager.default.fileExists(
                        atPath: dir.appendingPathComponent("transcript.md").path
                    ) {
                        // The note (or transcript) as one file — the common share.
                        ShareLink("share note", item: shareItem)
                    }
                    // The whole folder: audio, transcript, notes, images.
                    Button("share folder") { shareFolder() }
                        .disabled(zipping)

                    Divider()

                    Button("delete", role: .destructive) { confirmDelete = true }
                        .disabled(state.isBusy(id: id))
                } label: {
                    if zipping {
                        BrailleSpinner(size: 12).frame(width: 30, height: 30)
                    } else {
                        Image(systemName: "ellipsis.circle")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 30, height: 30)
                    }
                }
                .accessibilityLabel("Session actions")
            }
        }
        // Rename: a plain alert text field. The title lands in meta.json, so
        // the home list and search rows pick it up on the next scan.
        .alert("rename session", isPresented: $renaming) {
            TextField("title", text: $draftTitle)
            Button("cancel", role: .cancel) {}
            Button("save") { state.renameSession(id: id, to: draftTitle) }
        } message: {
            Text("empty falls back to the timestamp")
        }
        .confirmationDialog(
            "delete this session?",
            isPresented: $confirmDelete,
            titleVisibility: .visible
        ) {
            Button("delete", role: .destructive) {
                state.deleteSession(id: id)
                dismiss()
            }
            // Declared rather than left to SwiftUI's implicit one: the rename
            // alert already says "cancel" in quill's voice, and the automatic
            // button follows the system language instead.
            Button("cancel", role: .cancel) {}
        } message: {
            Text("the folder moves to .trash — recoverable from Files for 7 days")
        }
        .sheet(item: $share) { payload in
            ActivityView(url: payload.url)
        }
        // Record / pause / resume / stop docked at the bottom — only while
        // this session can still record: live now, or a note with no audio
        // yet. A finished session hides the dock entirely (re-recording
        // would clobber mic.caf; multi-take is a future feature).
        .safeAreaInset(edge: .bottom) {
            if isActive || session?.stage == .empty {
                NoteControls(state: state, id: id, isActive: isActive)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
                    .padding(.bottom, 6)
                    .background(
                        LinearGradient(
                            colors: [Theme.paper.opacity(0), Theme.paper, Theme.paper],
                            startPoint: .top, endPoint: .bottom
                        )
                        .ignoresSafeArea(edges: .bottom)
                    )
            }
        }
        .task(id: state.pipeline) { reload() }
        .task {
            #if DEBUG
            SessionActions.selfCheck()
            #endif
        }
        .onAppear { reload() }
        .onDisappear { playback.teardown() }
        // Recording (this session or another) owns AVAudioSession as
        // .playAndRecord; playback flipping it to .playback would kill the
        // mic mid-take, so playback stands down while any take is live.
        .onChange(of: state.isRecording, initial: true) { _, recording in
            playback.setRecording(recording)
        }
        .onChange(of: pickerItems) { _, items in
            guard !items.isEmpty else { return }
            Task { await importImages(items) }
        }
        // Arrived from search: open the transcript and ride down to the hit.
        // ponytail: one frame of settle time instead of an onAppear handshake
        // per row — the disclosure has to lay out before the id resolves.
        .task {
            guard let target = scrollToSegment else { return }
            showTranscript = true
            try? await Task.sleep(for: .milliseconds(120))
            withAnimation(Theme.spring) { proxy.scrollTo(target, anchor: .center) }
        }
        }
    }

    /// Re-run the LLM structure pass with the current prompt; overwrites
    /// notes.md (transcript is untouched, so this is always safe).
    private func rerunEnhance() {
        guard !enhancing else { return }
        let enhancer = FoundationModelsEnhance()
        guard enhancer.isAvailable else {
            enhanceError = FoundationModelsEnhance.unavailableReason
            return
        }
        enhancing = true
        enhanceError = nil
        let sessionDir = dir
        Task {
            do {
                try? FileManager.default.removeItem(
                    at: sessionDir.appendingPathComponent("notes.md")
                )
                try await enhancer.enhance(session: sessionDir)
            } catch {
                enhanceError = "notes failed: \(error.localizedDescription)"
            }
            enhancing = false
            reload()
        }
    }

    /// Zip the session folder off the main actor, then hand it to the share
    /// sheet. Failures land in the facts block next to the notes error.
    private func shareFolder() {
        guard !zipping else { return }
        zipping = true
        let sessionDir = dir
        Task {
            let result = await Task.detached { try SessionActions.zip(sessionDir) }.result
            zipping = false
            switch result {
            case .success(let url): share = SharePayload(url: url)
            case .failure(let error): actionError = "share failed: \(error.localizedDescription)"
            }
        }
    }

    private func reload() {
        transcript = Transcript.read(from: dir)
        notes = try? String(
            contentsOf: dir.appendingPathComponent("notes.md"), encoding: .utf8
        )
        images = SessionImages.list(in: dir)
    }

    private func importImages(_ items: [PhotosPickerItem]) async {
        for item in items {
            if let data = try? await item.loadTransferable(type: Data.self) {
                SessionImages.save(data, in: dir)
            }
        }
        pickerItems = []
        reload()
    }

    private var factsBlock: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let reason = actionError {
                Text(reason)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let session {
                factLine("kind", session.kind)
                if let d = session.duration {
                    factLine("duration", AppState.format(TimeInterval(d)))
                }
            }
            if !images.isEmpty {
                factLine("images", "\(images.count)")
            }
            if let t = transcript {
                factLine("engine", t.engine)
                factLine("segments", "\(t.segments.count)")
                if notes == nil {
                    // Notes stage status — retry lives here, small, with
                    // the reason when the automatic pass failed.
                    HStack(spacing: 8) {
                        Text("notes")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                            .frame(width: 72, alignment: .leading)
                        if enhancing {
                            BrailleSpinner(size: 10)
                        } else {
                            Button {
                                rerunEnhance()
                            } label: {
                                Text("retry")
                                    .font(Theme.mono(11, .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    if let reason = enhanceError {
                        Text(reason)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if isActive {
                factLine("status", state.isPaused ? "paused" : "recording")
            } else if session?.stage == .recorded {
                // Spinner lives in the value column so the key column stays
                // aligned with the other fact lines.
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("status")
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.muted)
                        .frame(width: 72, alignment: .leading)
                    HStack(spacing: 6) {
                        if isQueued { BrailleSpinner(size: 10) }
                        Text(statusText)
                            .font(Theme.mono(11, .medium))
                            .foregroundStyle(gaveUp ? Theme.error : Theme.ink)
                        // Without this the row says "awaiting transcription"
                        // forever: past the auto-retry cap nothing re-queues
                        // it, and `retryTranscription` had no caller at all.
                        if gaveUp {
                            Button {
                                state.retryTranscription(id: id)
                            } label: {
                                Text("retry")
                                    .font(Theme.mono(11, .medium))
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            } else if session?.stage == .empty {
                factLine("status", "no audio yet")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 1)
        )
    }

    /// Transcription hit the auto-retry cap: nothing will pick this up again
    /// without the retry button.
    private var gaveUp: Bool {
        !isQueued && Transcriber.failedAttempts(in: dir) >= Transcriber.maxAutoAttempts
    }

    private var statusText: String {
        if isQueued {
            if let p = queueProgress { return "transcribing… \(Int(p * 100))%" }
            return "transcribing…"
        }
        // "awaiting" would be a lie once the queue has given up on it.
        return gaveUp ? "transcription failed" : "awaiting transcription"
    }

    private func factLine(_ key: String, _ value: String) -> some View {
        HStack(spacing: 8) {
            Text(key)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 72, alignment: .leading)
            Text(value)
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.ink)
        }
    }
}

/// Horizontal thumbnails of the session's attached images.
private struct ImageStrip: View {
    let urls: [URL]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(urls, id: \.self) { url in
                    if let image = UIImage(contentsOfFile: url.path) {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                                    .strokeBorder(Theme.line, lineWidth: 1)
                            )
                    }
                }
            }
            .padding(.horizontal, 20)
        }
    }
}

/// Session-folder image store: images/img-<n>.jpg next to mic.caf and
/// transcript.json — everything a future enhance pass needs in one place.
enum SessionImages {
    static func list(in dir: URL) -> [URL] {
        let folder = dir.appendingPathComponent("images", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil
        )) ?? []
        return urls
            .filter { ["jpg", "jpeg", "png", "heic"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    static func save(_ data: Data, in dir: URL) {
        let folder = dir.appendingPathComponent("images", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let n = list(in: dir).count + 1
        let url = folder.appendingPathComponent(String(format: "img-%03d.jpg", n))
        // Re-encode to JPEG so HEIC/PNG picks normalize to one format.
        if let image = UIImage(data: data),
           let jpeg = image.jpegData(compressionQuality: 0.85) {
            try? jpeg.write(to: url)
        } else {
            try? data.write(to: url)
        }
    }
}

/// Record / pause / resume / stop bar inside a note — bottom-docked.
private struct NoteControls: View {
    @ObservedObject var state: AppState
    let id: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 10) {
            if !isActive {
                Button {
                    state.startNoteRecording(id: id)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Theme.accent)
                            .frame(width: 12, height: 12)
                        Text("record")
                            .font(Theme.mono(14, .medium))
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: 0)
                        Text("mic")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.muted)
                    }
                    .padding(.horizontal, 18)
                    .frame(height: 60)
                    .frame(maxWidth: .infinity)
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
                .disabled(state.isRecording) // busy with another session
                .opacity(state.isRecording ? 0.45 : 1)
            } else {
                HStack(spacing: 12) {
                    Text(AppState.format(state.elapsed))
                        .font(Theme.mono(17, .semibold))
                        .monospacedDigit()
                        .foregroundStyle(Theme.paper)

                    if state.isPaused {
                        Text("PAUSED")
                            .font(Theme.mono(10, .semibold))
                            .tracking(1.2)
                            .foregroundStyle(Theme.paper.opacity(0.75))
                    } else {
                        Waveform(level: state.micLevel, tint: Theme.paper, maxHeight: 18)
                            .frame(width: 52, height: 22)
                    }

                    Spacer(minLength: 6)

                    Button(action: {
                        state.isPaused ? state.resumeRecording() : state.pauseRecording()
                    }) {
                        Image(systemName: state.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.paper)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Color.white.opacity(0.18)))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel(state.isPaused ? "Resume" : "Pause")

                    Button(action: { state.stopRecording() }) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background(Circle().fill(Theme.paper))
                    }
                    .buttonStyle(PressableButtonStyle())
                    .accessibilityLabel("Stop")
                }
                .padding(.horizontal, 18)
                .frame(height: 60)
                .frame(maxWidth: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(Theme.accent)
                        .shadow(color: Theme.accent.opacity(0.35), radius: 14, y: 4)
                )
            }
        }
        .animation(Theme.spring, value: isActive)
        .animation(Theme.spring, value: state.isPaused)
    }
}
