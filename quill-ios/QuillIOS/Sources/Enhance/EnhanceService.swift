import Foundation

/// Future LLM structure pass. A session folder is the full input contract:
///
///     <session>/
///       mic.caf          — audio (kept forever; transcript never replaces it)
///       transcript.json  — timed segments (canonical)
///       transcript.md    — readable render
///       images/img-*.jpg — user-attached photos (whiteboards, slides…)
///       notes.md         — OUTPUT of this pass
///
/// An implementation reads transcript + images, produces structured notes
/// (summary / key points / decisions / actions, image content woven in),
/// and writes notes.md atomically. Candidates: Apple FoundationModels
/// (iOS 26, on-device, has vision), Claude API (remote, opt-in — breaks the
/// "nothing leaves the phone" default so it must be explicit), or handoff
/// to the macOS sibling's `claude -p` pipeline via synced folders.
///
/// ponytail: protocol + no-op today; wire a real backend when one is chosen.
protocol EnhanceService: Sendable {
    /// Whether this backend can run right now (model downloaded, opted in…).
    var isAvailable: Bool { get }
    /// Read the session folder, write notes.md. Throwing leaves the folder
    /// untouched — enhance is always re-runnable.
    func enhance(session dir: URL) async throws
}

/// Placeholder until a backend lands; keeps call sites compilable.
struct NoopEnhance: EnhanceService {
    var isAvailable: Bool { false }
    func enhance(session dir: URL) async throws {}
}
