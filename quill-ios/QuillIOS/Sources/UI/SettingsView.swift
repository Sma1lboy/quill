import SwiftUI

/// Settings — kobe grammar: mono key/value facts, terracotta accents,
/// matte paper. Persisted in UserDefaults.
struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    /// CSV of allowed language codes; empty = auto-detect anything.
    /// Multi-select: mixed-language speakers pick their set (e.g. zh+en),
    /// detection is then restricted to it.
    @AppStorage("quill.languages") private var languagesCSV = ""
    let root: URL

    private static let languages: [(code: String, label: String)] = [
        ("zh-Hans", "简体中文"),
        ("zh-Hant", "繁體中文"),
        ("en", "English"),
        ("es", "Español"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
    ]

    private var selected: Set<String> {
        Set(languagesCSV.split(separator: ",").map(String.init))
    }

    private func toggle(_ code: String) {
        var set = selected
        if set.contains(code) {
            set.remove(code)
        } else {
            // Hans and Hant are mutually exclusive scripts of one whisper
            // language — picking one drops the other.
            if code == "zh-Hans" { set.remove("zh-Hant") }
            if code == "zh-Hant" { set.remove("zh-Hans") }
            set.insert(code)
        }
        languagesCSV = set.sorted().joined(separator: ",")
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    BrandBlock()

                    section("languages") {
                        FlowLayoutChips(
                            options: Self.languages,
                            isSelected: { selected.contains($0) },
                            toggle: toggle
                        )
                        Text(hint)
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 2)
                    }

                    section("model") {
                        ModelPicker()
                    }

                    section("notes model") {
                        NotesModelSection()
                    }

                    section("notes prompt") {
                        EnhancePromptEditor()
                    }

                    section("storage") {
                        factLine("recordings", recordingsSize)
                        factLine("location", "Files → quill → Recordings")
                        Text("every session is a folder you own — audio, transcript, images, notes")
                            .font(Theme.mono(10))
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }

                    if DevSettings.isDevBuild {
                        DevSection(root: root)
                    }

                    FooterSignature()
                }
                .padding(20)
            }
            .background(Theme.paper.ignoresSafeArea())
            .navigationTitle("settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("done") { dismiss() }
                        .font(Theme.mono(13, .medium))
                        .foregroundStyle(Theme.accent)
                }
            }
        }
        .tint(Theme.accent)
        .task {
            #if DEBUG
            Theme.selfCheck()
            #endif
        }
    }

    /// The instructions the on-device LLM gets when structuring notes.
    /// Editable; empty = built-in default.
    private struct EnhancePromptEditor: View {
        @AppStorage("quill.enhancePrompt") private var custom = ""
        @FocusState private var focused: Bool

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                TextEditor(text: Binding(
                    get: { custom.isEmpty ? FoundationModelsEnhance.defaultPrompt : custom },
                    set: { custom = $0 == FoundationModelsEnhance.defaultPrompt ? "" : $0 }
                ))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 96, maxHeight: 160)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.inset.opacity(0.5))
                )
                .focused($focused)
                // A multiline TextEditor has no return-key dismiss, so without
                // this the keyboard can only be closed by dragging the sheet,
                // which also loses the edit position.
                //
                // Deliberately NOT labelled "done": the sheet's own done
                // (which closes settings) sits at the top of the same screen,
                // and two buttons reading "done" with different consequences
                // is worse than the keyboard being hard to dismiss.
                .toolbar {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("hide keyboard") { focused = false }
                            .font(Theme.mono(13, .medium))
                            .foregroundStyle(Theme.accent)
                    }
                }

                HStack {
                    Text(custom.isEmpty ? "default prompt" : "custom prompt")
                        .font(Theme.mono(9))
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    if !custom.isEmpty {
                        Button("reset to default") { custom = "" }
                            .font(Theme.mono(10, .medium))
                            .foregroundStyle(Theme.accent)
                            .buttonStyle(.plain)
                    }
                }
                Text("applies to the next recording · re-run per session from its screen")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    /// Who we are — bracket-chip identity card at the top of settings.
    private struct BrandBlock: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                BracketChip(size: 22)
                Text("local-first voice notes")
                    .font(Theme.mono(12))
                    .foregroundStyle(Theme.muted)
                Text("record → transcribe → structured notes, all on this phone. no account, no cloud, no subscription — your recordings are folders in Files.")
                    .font(Theme.face(13))
                    .foregroundStyle(Theme.ink.opacity(0.85))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Theme.accentSoft)
            )
            // Wordmark + tagline + pitch is one identity card, not three stops.
            .accessibilityElement(children: .combine)
        }
    }

    /// Quiet colophon at the bottom — version, engines, maker.
    private struct FooterSignature: View {
        var body: some View {
            VStack(alignment: .leading, spacing: 3) {
                Text("quill \(AppVersion.current) (\(AppVersion.build))")
                    .font(Theme.mono(10, .medium))
                    .foregroundStyle(Theme.muted)
                Text("whisperkit + apple foundation models · on-device")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
                Text("made by jackson · sibling of [ kobe ]")
                    .font(Theme.mono(9))
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .multilineTextAlignment(.center)
            .accessibilityElement(children: .combine)
            .padding(.top, 6)
            .padding(.bottom, 12)
        }
    }

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Theme.kicker(title)
            VStack(alignment: .leading, spacing: 4) { content() }
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
    }

    private func factLine(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(key)
                .font(Theme.mono(11))
                .foregroundStyle(Theme.muted)
                // Scales with the glyphs: "recordings" clipped in an 84pt
                // column as soon as the user asked for larger text.
                .frame(width: Theme.scaled(84), alignment: .leading)
            Text(value)
                .font(Theme.mono(11, .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 1)
        // "location, Files → quill → Recordings" as one stop, not two.
        .accessibilityElement(children: .combine)
    }

    private var hint: String {
        let langOnly = selected.filter { !$0.hasPrefix("zh-") }
        let zhCount = selected.contains("zh-Hans") || selected.contains("zh-Hant") ? 1 : 0
        switch langOnly.count + zhCount {
        case 0: return "none selected — detects any language per recording"
        case 1: return "every transcript uses this language"
        default: return "detection picks the best match from your set per recording"
        }
    }

    private var recordingsSize: String {
        let fm = FileManager.default
        var bytes: Int64 = 0
        if let files = fm.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in files {
                bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            }
        }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Multi-selectable mono chips, wrapping — terracotta fill when active.
private struct FlowLayoutChips: View {
    let options: [(code: String, label: String)]
    let isSelected: (String) -> Bool
    let toggle: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(options, id: \.code) { option in
                let active = isSelected(option.code)
                Button {
                    toggle(option.code)
                } label: {
                    Text(option.label)
                        .font(Theme.mono(11, .medium))
                        .foregroundStyle(active ? Theme.paper : Theme.ink)
                        .lineLimit(1)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(active ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.inset))
                        )
                        // ~21pt tall visually; the chips are a dense wrapping
                        // grid where growing the visual size would break the
                        // layout, so the hit area grows instead.
                        .contentShape(Capsule(style: .continuous).inset(by: -11))
                }
                .buttonStyle(PressableButtonStyle())
                // Selected-vs-not was terracotta fill and nothing else —
                // invisible to VoiceOver and to a colorblind user.
                .accessibilityAddTraits(active ? [.isButton, .isSelected] : .isButton)
            }
        }
    }
}

/// Minimal wrapping layout for the chips row.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
