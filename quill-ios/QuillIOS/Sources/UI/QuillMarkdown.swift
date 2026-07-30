import MarkdownUI
import SwiftUI

/// Markdown rendering themed to DESIGN.md: espresso ink prose, mono
/// kicker-style headings, terracotta accents, matte inset code blocks.
/// Used for notes.md — the product's primary artifact deserves real
/// rendering (headings, lists, task boxes), not inline-only Text().
struct QuillMarkdown: View {
    let content: String

    var body: some View {
        Markdown(content)
            .markdownTheme(.quill)
            .markdownTextStyle(\.code) {
                FontFamilyVariant(.monospaced)
                FontSize(.em(0.85))
                ForegroundColor(Theme.accent)
            }
            // MarkdownUI's default image provider FETCHES `![](http://…)` over
            // the network. notes.md is LLM output (and user-editable in Files),
            // so a stray image link would quietly make a request off the phone
            // — breaking the "nothing leaves this device" contract the whole
            // app is sold on. `.asset` resolves bundle resources only, never
            // the network; a link to something we don't ship renders as
            // nothing, which is the right outcome for a local-first note.
            .markdownImageProvider(.asset)
            .markdownInlineImageProvider(.asset)
            .textSelection(.enabled)
    }
}

extension MarkdownUI.Theme {
    /// Reading-first typography (the note is a document, not UI chrome):
    /// bold sentence-case headings, 16pt body with generous leading,
    /// solid→hollow nested bullets. Terracotta stays in the small accents.
    @MainActor static let quill = MarkdownUI.Theme()
        .text {
            FontSize(16)
            ForegroundColor(Theme.ink)
        }
        .paragraph { configuration in
            configuration.label
                .lineSpacing(6)
                .markdownMargin(top: 4, bottom: 12)
        }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(22)
                }
                .markdownMargin(top: 24, bottom: 8)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.bold)
                    FontSize(18)
                }
                .markdownMargin(top: 20, bottom: 6)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle {
                    FontWeight(.semibold)
                    FontSize(16)
                }
                .markdownMargin(top: 16, bottom: 4)
        }
        .listItem { configuration in
            configuration.label
                .lineSpacing(5)
                .markdownMargin(top: 4, bottom: 4)
        }
        // Nesting reads through the marker: solid dot at the top level,
        // hollow circle one level in. Text glyphs (not shapes) so the
        // marker sits on the same baseline as the item's first line —
        // shape markers need manual padding that drifts with font size.
        .bulletedListMarker { configuration in
            Text(configuration.listLevel > 1 ? "◦" : "•")
                .font(.system(size: 16))
                .foregroundStyle(configuration.listLevel > 1 ? Theme.muted : Theme.ink.opacity(0.75))
                .frame(minWidth: 12, alignment: .center)
        }
        .taskListMarker { configuration in
            Image(systemName: configuration.isCompleted ? "checkmark.square.fill" : "square")
                .font(.system(size: 13))
                .foregroundStyle(configuration.isCompleted ? Theme.accent : Theme.muted)
        }
        .codeBlock { configuration in
            configuration.label
                .markdownTextStyle {
                    FontFamilyVariant(.monospaced)
                    FontSize(.em(0.85))
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                        .fill(Theme.inset.opacity(0.6))
                )
                .markdownMargin(top: 6, bottom: 10)
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(Theme.accent.opacity(0.5))
                        .frame(width: 2)
                }
                .markdownMargin(top: 6, bottom: 10)
        }
}
