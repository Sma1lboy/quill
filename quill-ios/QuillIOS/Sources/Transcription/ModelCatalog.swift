import Foundation

/// The whisper variants quill offers, with the tradeoff each represents.
/// Selection persists in UserDefaults ("quill.model"); the downloaded
/// weights live under Documents/huggingface/ and can be deleted per-model.
enum ModelCatalog {
    struct Model: Identifiable, Equatable {
        let id: String        // WhisperKit variant name
        let label: String
        /// Total download, bytes. One source — the display string is derived,
        /// so a size shown to the user can't drift from the one we check
        /// free space against.
        let bytes: Int64
        let description: String

        /// "1.5 GB" — decimal units, matching how iOS reports storage.
        var size: String {
            ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        }
    }

    // Byte counts measured from the HuggingFace API file list for
    // argmaxinc/whisperkit-coreml on 2026-07-30 (sum of every file in the
    // variant folder — WhisperKit downloads all of them). Cross-checked
    // against the copy on disk: `small` matched to the byte.
    // Exact, not approximate. Re-measure if the repo republishes weights.
    static let models: [Model] = [
        Model(
            id: "openai_whisper-base",
            label: "base",
            bytes: 146_719_453,
            description: "fastest · fine for clear speech in quiet rooms, weakest on Chinese and accents"
        ),
        Model(
            id: "openai_whisper-small",
            label: "small",
            bytes: 486_487_465,
            description: "fast · good speed/accuracy balance when storage is tight"
        ),
        Model(
            id: "openai_whisper-large-v3_turbo",
            label: "large-v3 turbo",
            bytes: 3_195_115_988,
            description: "default · most accurate (won the on-device bake-off), faster than real time"
        ),
    ]

    // large-v3 turbo won the 2026-07-29 on-device bake-off (benchmark.md):
    // best zh accuracy + punctuation, and speed is a non-goal for a
    // background queue.
    /// Single source of truth for the default — ModelPicker's @AppStorage
    /// must use this same literal or the settings radio marks one model while
    /// the queue downloads another.
    static let defaultID = "openai_whisper-large-v3_turbo"

    static var selectedID: String {
        UserDefaults.standard.string(forKey: "quill.model") ?? defaultID
    }

    static var selected: Model {
        // Fall back to the default, not a positional index: models[1] was
        // "small" while the default is turbo, so an unknown stored ID
        // silently reported the wrong model.
        models.first { $0.id == selectedID }
            ?? models.first { $0.id == defaultID }
            ?? models[0]
    }

    /// WhisperKit's download root (HubApi downloadBase default).
    static var modelsRoot: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/argmaxinc/whisperkit-coreml", isDirectory: true)
    }

    static func folder(for id: String) -> URL {
        modelsRoot.appendingPathComponent(id, isDirectory: true)
    }

    static func isDownloaded(_ id: String) -> Bool {
        // Folder existence isn't enough — a partial download leaves an
        // incomplete folder. The compiled audio encoder is the largest
        // artifact; require it plus config.
        let f = folder(for: id)
        let fm = FileManager.default
        return fm.fileExists(atPath: f.appendingPathComponent("AudioEncoder.mlmodelc").path)
            && fm.fileExists(atPath: f.appendingPathComponent("config.json").path)
    }

    static func downloadedBytes(_ id: String) -> Int64 {
        let fm = FileManager.default
        guard let files = fm.enumerator(at: folder(for: id), includingPropertiesForKeys: [.fileSizeKey])
        else { return 0 }
        var bytes: Int64 = 0
        for case let url as URL in files {
            bytes += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return bytes
    }

    /// Delete a downloaded model's weights (re-downloads on next use).
    static func delete(_ id: String) {
        try? FileManager.default.removeItem(at: folder(for: id))
    }

    // MARK: - Storage

    /// `ByteCountFormatter` in quill's voice: it renders 0 as "Zero KB",
    /// which is both capitalized and not how anyone says it. Units stay
    /// uppercase — "GB" is a unit, not prose.
    static func bytesLabel(_ bytes: Int64) -> String {
        bytes <= 0 ? "0 MB" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// Free space iOS will actually give us, in bytes. `ImportantUsage`
    /// counts purgeable space (caches the system can evict), so it's the
    /// honest number for "can this download land" — the plain free-space key
    /// under-reports and would refuse downloads that would have worked.
    static func freeBytes() -> Int64 {
        #if DEBUG
        selfCheck()  // reached from both the picker and the download path
        #endif
        return (try? modelsRoot.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage)
            // Documents dir always resolves; treat an unreadable volume as
            // "don't block the user" rather than inventing a refusal.
            ?? .max
    }

    /// Why a download can't start, in quill's voice — or nil when it can.
    /// Both figures, so the number isn't a mystery.
    static func downloadBlocker(for model: Model, free: Int64 = freeBytes()) -> String? {
        // Already on disk — nothing to download, so nothing to refuse.
        guard !isDownloaded(model.id) else { return nil }
        return shortfall(need: model.bytes, free: free)
    }

    /// The comparison itself, with no filesystem in it — so the self-check
    /// means the same thing on a device that already has the weights.
    static func shortfall(need: Int64, free: Int64) -> String? {
        guard free < required(need) else { return nil }
        return "needs \(bytesLabel(need)) · \(bytesLabel(max(0, free))) free"
            + " — clear space or pick a smaller model"
    }

    /// Download size plus 15%. CoreML unpacks and recompiles the weights, and
    /// a volume that exactly fits fails partway; 15% covers the working set
    /// on turbo (~480 MB) without refusing an otherwise-fine base download.
    /// ponytail: flat percentage, not a per-model measured working set.
    static func required(_ bytes: Int64) -> Int64 { bytes + bytes / 100 * 15 }

    #if DEBUG
    /// Both directions of the comparison: a false refusal strands a user who
    /// had room, and a missing one lets a 3 GB download die at 90%.
    static func selfCheck() {
        let turbo = models.last!
        assert(turbo.bytes == 3_195_115_988)          // measured, not guessed
        assert(required(1_000_000_000) == 1_150_000_000)

        // Free space is compared against size+15%, not size.
        let n = turbo.bytes
        assert(shortfall(need: n, free: 10_000_000_000) == nil)
        assert(shortfall(need: n, free: n) != nil)              // exact fit fails
        assert(shortfall(need: n, free: 0) != nil)
        assert(shortfall(need: n, free: required(n)) == nil)
        // Unreadable volume must not manufacture a refusal.
        assert(shortfall(need: n, free: .max) == nil)
        // Both figures present, quill's voice: no exclamation, no
        // capitalized prose. Units stay uppercase ("GB" is a unit).
        let msg = shortfall(need: n, free: 0)!
        assert(msg.contains("needs 3.2 GB") && msg.contains("0 MB free"))
        assert(!msg.contains("!") && !msg.contains("Zero"))
        assert(bytesLabel(0) == "0 MB")
    }
    #endif
}
