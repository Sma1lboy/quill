import SwiftUI

/// Remote notes: the opt-in that lets transcript text leave the phone.
///
/// The section leads with what crosses the network and what doesn't, because
/// quill's whole pitch is that nothing does. Burying that under a toggle
/// would be the kind of quiet downgrade the app exists not to do.
struct RemoteNotesSection: View {
    @AppStorage("quill.remoteEnhance") private var enabled = false
    @AppStorage("quill.remoteShape") private var shapeRaw = RemoteShape.anthropic.rawValue
    @AppStorage("quill.remoteModel") private var model = ""
    @AppStorage("quill.remoteBaseURL") private var baseURL = ""
    @State private var draftKey = ""
    @State private var storedKey = RemoteCredential.key
    @State private var editingKey = false
    /// Model IDs the endpoint reported, [] until probed (or when it has no
    /// catalog — plenty of proxies serve completions and not /v1/models).
    @State private var known: [String] = []
    @State private var probing = false
    @State private var testing = false
    @State private var testResult: String?

    private var shape: RemoteShape {
        RemoteShape(rawValue: shapeRaw) ?? .anthropic
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("remote notes")
                    .font(Theme.mono(12, .semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if enabled, storedKey != nil {
                    Text("ON")
                        .font(Theme.mono(8, .semibold))
                        .tracking(1)
                        .foregroundStyle(Theme.accent)
                }
                Toggle("remote notes", isOn: $enabled)
                    .labelsHidden()
                    .tint(Theme.accent)
                    .scaleEffect(0.8)
            }

            // The boundary, stated before the controls rather than after.
            Text("your audio stays on this phone, always — transcription never leaves. with this on, the transcript text is sent to the model below to write notes.")
                .font(Theme.mono(10))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if enabled {
                Divider().overlay(Theme.line)
                shapePicker
                keyRow
                modelRow
                field("endpoint", $baseURL, placeholder: shape.defaultBaseURL)
                Text(shape.compatibilityHint)
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                statusRow
            }
        }
        .onAppear { storedKey = RemoteCredential.key }
        // Endpoint or protocol changed — the old catalog describes a
        // different server, so drop it and re-probe rather than suggesting
        // models this endpoint has never heard of.
        .onChange(of: baseURL) { _, _ in known = []; testResult = nil }
        .onChange(of: shapeRaw) { _, _ in known = []; testResult = nil }
    }

    // MARK: - Rows

    private var shapePicker: some View {
        HStack(spacing: 8) {
            Text("api")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 64, alignment: .leading)
            ForEach(RemoteShape.allCases, id: \.self) { option in
                let on = option == shape
                Button {
                    shapeRaw = option.rawValue
                } label: {
                    Text(option.label)
                        .font(Theme.mono(11, on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.accent : Theme.muted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(on ? Theme.accentSoft : Color.clear)
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .strokeBorder(on ? Color.clear : Theme.line, lineWidth: 1)
                        )
                }
                .buttonStyle(PressableButtonStyle())
            }
            Spacer(minLength: 0)
        }
    }

    /// Masked once stored; the field only appears when setting a new one, so
    /// a shoulder-surfer sees nothing.
    private var keyRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("api key")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 64, alignment: .leading)
                if let storedKey, !editingKey {
                    Text(RemoteCredential.masked(storedKey))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button("replace") { editingKey = true }
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                    Button("remove") {
                        RemoteCredential.clear()
                        self.storedKey = nil
                        known = []
                        testResult = nil
                    }
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.error)
                    .buttonStyle(.plain)
                } else {
                    SecureField("sk-…", text: $draftKey)
                        .font(Theme.mono(11))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .onSubmit(commitKey)
                    Button("save", action: commitKey)
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                        .disabled(draftKey.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Text("stored in the keychain, this device only · never written into a session folder")
                .font(Theme.mono(9))
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Free text — whatever the user types is what gets sent. The catalog
    /// below is a suggestion, never a gate: a proxy that serves a model it
    /// doesn't advertise must still work.
    private var modelRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("model")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 64, alignment: .leading)
                TextField(shape.defaultModel, text: $model)
                    .font(Theme.mono(11))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .foregroundStyle(Theme.ink)
                if probing {
                    BrailleSpinner(size: 10)
                } else if storedKey != nil {
                    // Cached an hour per endpoint, so this is one request the
                    // first time and free afterwards.
                    Button(known.isEmpty ? "list" : "refresh") { probe(force: !known.isEmpty) }
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }

            let suggestions = RemoteModels.matches(model, in: known)
            if !suggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(suggestions, id: \.self) { id in
                            Button { model = id } label: {
                                Text(id)
                                    .font(Theme.mono(10))
                                    .foregroundStyle(Theme.ink)
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule(style: .continuous).fill(Theme.inset)
                                    )
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                }
                .frame(height: 26)
            }
        }
    }

    private var statusRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if let reason = RemoteEnhance.unavailableReason {
                    Text(reason)
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.error)
                } else if testing {
                    BrailleSpinner(size: 10)
                    Text("testing…")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.muted)
                } else {
                    Text("used first · falls back to the on-device models if it fails")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if storedKey != nil, !testing {
                    // One tiny completion. Finding a wrong key here beats
                    // finding it after a 40-minute recording.
                    Button("test") { test() }
                        .font(Theme.mono(10, .medium))
                        .foregroundStyle(Theme.accent)
                        .buttonStyle(.plain)
                }
            }
            if let testResult {
                Text(testResult)
                    .font(Theme.mono(9))
                    .foregroundStyle(testResult.hasPrefix("ok") ? Theme.accent : Theme.error)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Blank means "use the shape's default", so the placeholder shows what
    /// that is rather than pre-filling a value the user would have to delete.
    private func field(
        _ label: String, _ text: Binding<String>, placeholder: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                .frame(width: 64, alignment: .leading)
            TextField(placeholder, text: text)
                .font(Theme.mono(11))
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
                .foregroundStyle(Theme.ink)
        }
    }

    // MARK: - Actions

    private func commitKey() {
        RemoteCredential.save(draftKey)
        storedKey = RemoteCredential.key
        draftKey = ""
        editingKey = false
        testResult = nil
    }

    private func probe(force: Bool) {
        guard let key = storedKey, !probing else { return }
        probing = true
        let base = baseURL.isEmpty ? shape.defaultBaseURL : baseURL
        let currentShape = shape
        Task {
            known = await RemoteModels.list(
                base: base, shape: currentShape, key: key, force: force
            )
            probing = false
            if known.isEmpty {
                testResult = "this endpoint doesn't list models — type the name yourself"
            }
        }
    }

    private func test() {
        guard let key = storedKey, !testing else { return }
        testing = true
        testResult = nil
        Task {
            testResult = await RemoteEnhance.verify(key: key).map { $0 }
                ?? "ok · \(RemoteEnhance.model) responded"
            testing = false
        }
    }
}
