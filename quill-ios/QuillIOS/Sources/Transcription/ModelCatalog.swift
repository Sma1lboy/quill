import Foundation

/// The whisper variants quill offers, with the tradeoff each represents.
/// Selection persists in UserDefaults ("quill.model"); the downloaded
/// weights live under Documents/huggingface/ and can be deleted per-model.
enum ModelCatalog {
    struct Model: Identifiable, Equatable {
        let id: String        // WhisperKit variant name
        let label: String
        let size: String
        let description: String
    }

    static let models: [Model] = [
        Model(
            id: "openai_whisper-base",
            label: "base",
            size: "~150 MB",
            description: "fastest · fine for clear speech in quiet rooms, weakest on Chinese and accents"
        ),
        Model(
            id: "openai_whisper-small",
            label: "small",
            size: "~600 MB",
            description: "fast · good speed/accuracy balance when storage is tight"
        ),
        Model(
            id: "openai_whisper-large-v3_turbo",
            label: "large-v3 turbo",
            size: "~1.6 GB",
            description: "default · most accurate (won the on-device bake-off), ~3s per 8s of audio"
        ),
    ]

    // large-v3 turbo won the 2026-07-29 on-device bake-off (benchmark.md):
    // best zh accuracy + punctuation, and speed is a non-goal for a
    // background queue.
    static var selectedID: String {
        UserDefaults.standard.string(forKey: "quill.model") ?? "openai_whisper-large-v3_turbo"
    }

    static var selected: Model {
        models.first { $0.id == selectedID } ?? models[1]
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
}
