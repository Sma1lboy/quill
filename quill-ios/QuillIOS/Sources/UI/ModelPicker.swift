import SwiftUI

/// Whisper model chooser: one card per variant with its tradeoff, download
/// state, and a per-model delete. Switching takes effect on the next
/// transcription (the queue reloads the pipe lazily).
struct ModelPicker: View {
    // Default must match ModelCatalog.selectedID's — on a fresh install
    // nothing has written the key, so a different literal here marked the
    // wrong radio while the queue downloaded and used the other model.
    @AppStorage("quill.model") private var selectedID = ModelCatalog.defaultID
    @State private var refresh = 0
    @State private var pendingDelete: ModelCatalog.Model?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ModelCatalog.models) { model in
                let active = selectedID == model.id
                let downloaded = ModelCatalog.isDownloaded(model.id)
                let blocker = ModelCatalog.downloadBlocker(for: model)

                Button {
                    selectedID = model.id
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 8) {
                            Circle()
                                .strokeBorder(active ? Theme.accent : Theme.line, lineWidth: active ? 5 : 1.5)
                                .frame(width: 14, height: 14)
                            Text(model.label)
                                .font(Theme.mono(12, .semibold))
                                .foregroundStyle(Theme.ink)
                            Text(model.size)
                                .font(Theme.mono(10))
                                .foregroundStyle(Theme.muted)
                            Spacer(minLength: 0)
                            if downloaded {
                                Text("ON DISK")
                                    .font(Theme.mono(8, .semibold))
                                    .tracking(1)
                                    .foregroundStyle(Theme.accent)
                            }
                        }
                        Text(model.description)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.muted.opacity(0.8))
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.leading, 22)
                        // Say it here rather than letting the download die at
                        // 90% and surface as "transcription failed".
                        if let blocker {
                            Text(blocker)
                                .font(Theme.mono(9))
                                .foregroundStyle(Theme.error)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.leading, 22)
                        }
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .fill(active ? Theme.accentSoft : Theme.inset.opacity(0.5))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                            .strokeBorder(active ? Theme.accent.opacity(0.4) : Color.clear, lineWidth: 1)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
                }
                .buttonStyle(PressableButtonStyle())
                .contextMenu {
                    if downloaded {
                        Button(role: .destructive) {
                            // Deleting the model in use means the next
                            // recording silently re-downloads it, possibly on
                            // cellular. Confirm that one; an inactive model
                            // costs nothing to drop, so it stays one tap.
                            if active {
                                pendingDelete = model
                            } else {
                                ModelCatalog.delete(model.id)
                                refresh += 1
                            }
                        } label: {
                            Label("Delete download (\(model.size))", systemImage: "trash")
                        }
                    }
                }
            }
            Text("hold a model to delete its download · switch applies to the next recording")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.muted.opacity(0.6))
        }
        // Same grammar as the session delete dialog: lowercase, states the
        // consequence, cancel declared explicitly (the implicit one follows
        // the system language, not quill's voice).
        .confirmationDialog(
            "delete the model in use?",
            isPresented: Binding(
                get: { pendingDelete != nil },
                set: { if !$0 { pendingDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            if let model = pendingDelete {
                Button("delete \(model.size)", role: .destructive) {
                    ModelCatalog.delete(model.id)
                    pendingDelete = nil
                    refresh += 1
                }
            }
            Button("cancel", role: .cancel) { pendingDelete = nil }
        } message: {
            if let model = pendingDelete {
                Text("the next recording re-downloads \(model.size)")
            }
        }
        .id(refresh)
    }
}
