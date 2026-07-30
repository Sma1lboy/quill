import SwiftUI

/// Notes-model status + the local fallback toggle. Shows live diagnosis of
/// Apple Intelligence (the "why isn't it working" answer in-app) and the
/// opt-in Qwen download for the llama.cpp fallback.
struct NotesModelSection: View {
    @AppStorage("quill.llamaFallback") private var llamaEnabled = false
    @State private var downloading = false
    @State private var progress: Double = 0
    @State private var downloadError: String?
    @State private var refresh = 0
    /// Held so switching the fallback off aborts an in-flight download —
    /// otherwise the ~1 GB keeps arriving after the user opted out, with the
    /// progress UI already hidden.
    @State private var downloadTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 1 · Apple Intelligence — primary, zero-download.
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("apple intelligence")
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if FoundationModelsEnhance().isAvailable {
                        Text("READY")
                            .font(Theme.mono(8, .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.accent)
                    } else {
                        Text("UNAVAILABLE")
                            .font(Theme.mono(8, .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.error)
                    }
                }
                if let reason = FoundationModelsEnhance.unavailableReason {
                    Text(reason)
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("system on-device model · used first")
                        .font(Theme.mono(10))
                        .foregroundStyle(Theme.muted.opacity(0.7))
                }
            }

            Divider().overlay(Theme.line)

            // 2 · Qwen fallback — opt-in download.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("qwen 2.5 1.5b · fallback")
                        .font(Theme.mono(12, .semibold))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    if LlamaEnhance.isDownloaded {
                        Text("ON DISK")
                            .font(Theme.mono(8, .semibold))
                            .tracking(1)
                            .foregroundStyle(Theme.accent)
                    }
                    Toggle("", isOn: $llamaEnabled)
                        .labelsHidden()
                        .tint(Theme.accent)
                        .scaleEffect(0.8)
                }
                Text("runs when apple intelligence can't · ~1 GB download · fully offline")
                    .font(Theme.mono(10))
                    .foregroundStyle(Theme.muted.opacity(0.7))
                    .fixedSize(horizontal: false, vertical: true)

                if llamaEnabled && !LlamaEnhance.isDownloaded {
                    if downloading {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                BrailleSpinner(size: 10)
                                Text("downloading qwen · \(Int(progress * 100))%")
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.muted)
                                Spacer(minLength: 0)
                                Button("cancel") { downloadTask?.cancel() }
                                    .font(Theme.mono(10, .medium))
                                    .foregroundStyle(Theme.accent)
                                    .buttonStyle(.plain)
                            }
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.line)
                                    Capsule()
                                        .fill(Theme.accent)
                                        .frame(width: max(3, geo.size.width * progress))
                                }
                            }
                            .frame(height: 3)
                        }
                    } else if let blocker = LlamaEnhance.downloadBlocker {
                        // Say it before the tap, same rule and voice as the
                        // whisper picker — not after a gigabyte has failed.
                        Text(blocker)
                            .font(Theme.mono(9))
                            .foregroundStyle(Theme.error)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Button {
                            startDownload()
                        } label: {
                            Text("download model")
                                .font(Theme.mono(11, .medium))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(Capsule(style: .continuous).fill(Theme.accentSoft))
                        }
                        .buttonStyle(PressableButtonStyle())
                    }
                }

                if let downloadError {
                    Text(downloadError)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.error)
                }
            }
        }
        .id(refresh)
        .onChange(of: llamaEnabled) { _, enabled in
            if !enabled { downloadTask?.cancel() }
        }
        .contextMenu {
            if LlamaEnhance.isDownloaded {
                Button(role: .destructive) {
                    LlamaEnhance.deleteModel()
                    refresh += 1
                } label: {
                    Label("Delete qwen download (~1 GB)", systemImage: "trash")
                }
            }
        }
    }

    private func startDownload() {
        guard downloadTask == nil else { return } // no double-tap into two 1 GB pulls
        downloading = true
        downloadError = nil
        progress = 0
        downloadTask = Task {
            do {
                try await LlamaEnhance.download { p in
                    Task { @MainActor in progress = p }
                }
            } catch is CancellationError {
                // User's own choice — no error to report.
            } catch let error as URLError where error.code == .cancelled {
                // URLSession reports our cancel as NSURLErrorCancelled.
            } catch {
                downloadError = "download failed: \(error.localizedDescription)"
            }
            downloading = false
            downloadTask = nil
            refresh += 1
        }
    }
}
