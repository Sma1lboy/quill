import Foundation
@preconcurrency import LlamaSwift

/// Local-LLM notes fallback: Qwen2.5-1.5B-Instruct (Q4 GGUF, ~1 GB) driven
/// through the raw llama.cpp C API (LlamaSwift re-export). Used when
/// FoundationModels can't run (Apple Intelligence off, model assets
/// missing). Fully offline after a one-time download.
///
/// Memory: created per call, freed on scope exit; the transcriber releases
/// whisper before the enhance stage so the two never co-reside.
struct LlamaEnhance: EnhanceService {
    static let downloadURL = URL(string:
        "https://huggingface.co/Qwen/Qwen2.5-1.5B-Instruct-GGUF/resolve/main/qwen2.5-1.5b-instruct-q4_k_m.gguf"
    )!

    static var modelURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("llm/qwen2.5-1.5b-instruct-q4_k_m.gguf")
    }

    /// The model is opt-in via settings (1 GB download).
    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "quill.llamaFallback")
    }

    /// Existence isn't enough: a build before the size guard (or a file
    /// restored half-written) leaves a truncated GGUF that reports "ON DISK"
    /// and then fails to load forever, with no way to retry from the UI.
    /// Size is the cheap proxy for complete.
    static var isDownloaded: Bool {
        let size = (try? modelURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return Int64(size) >= minModelBytes
    }

    static func deleteModel() {
        try? FileManager.default.removeItem(at: modelURL.deletingLastPathComponent())
    }

    /// Floor for "this is really the Qwen Q4 GGUF" — the real file is ~1.1 GB,
    /// so anything under 900 MB is a truncated body or an error page.
    /// ponytail: size check, not a SHA — a hash means shipping a digest we
    /// have nowhere to pin. Upgrade if HF starts serving partial 200s.
    static let minModelBytes: Int64 = 900_000_000

    /// Download size, for the pre-flight space check. Exact, from the
    /// HuggingFace API file listing (and the `x-linked-size` header) for
    /// qwen2.5-1.5b-instruct-q4_k_m.gguf on 2026-07-30.
    static let downloadBytes: Int64 = 1_117_320_736

    /// Why the download can't start, or nil when it can. Same helpers the
    /// whisper picker uses, so both downloads refuse on the same rule and in
    /// the same voice.
    static var downloadBlocker: String? {
        #if DEBUG
        selfCheck()
        #endif
        guard !isDownloaded else { return nil }
        return ModelCatalog.shortfall(need: downloadBytes, free: ModelCatalog.freeBytes())
    }

    #if DEBUG
    /// The completeness guard, both directions: too low a floor accepts a
    /// truncated GGUF as "ON DISK" (loads fail forever, no retry path), too
    /// high a one rejects the real file.
    static func selfCheck() {
        assert(minModelBytes < downloadBytes, "the real model must pass its own floor")
        assert(minModelBytes > downloadBytes / 2, "floor too low to catch a half-finished body")
        // An HTML error page served as 200 is kilobytes, not gigabytes.
        assert(Int64(4_096) < minModelBytes)
        // Space check runs against size+15%, so an exact fit must refuse.
        assert(ModelCatalog.shortfall(need: downloadBytes, free: downloadBytes) != nil)
        assert(ModelCatalog.shortfall(need: downloadBytes, free: 10_000_000_000) == nil)
    }
    #endif

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // Refuse before spending a gigabyte of the user's bandwidth on a
        // download that can't land.
        if let blocker = downloadBlocker {
            throw NSError(domain: "quill", code: 4, userInfo: [NSLocalizedDescriptionKey: blocker])
        }

        let (tmp, response) = try await DownloadTask.run(downloadURL, onProgress: progress)
        // The delegate hands back a file we own; drop it on any failure path
        // so a rejected download can't leave a gigabyte parked in tmp.
        defer { try? FileManager.default.removeItem(at: tmp) }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(domain: "quill", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "model download failed (\((response as? HTTPURLResponse)?.statusCode ?? -1))",
            ])
        }
        // A truncated body still arrives as a valid 200 download. Committing
        // it would leave `isDownloaded == true` over a corrupt file, and the
        // only symptom is "model load failed" forever with no way to retry.
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
        guard size >= minModelBytes else {
            throw NSError(domain: "quill", code: 5, userInfo: [
                NSLocalizedDescriptionKey:
                    "download incomplete (\(ModelCatalog.bytesLabel(size))) — try again",
            ])
        }
        _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: tmp)
    }

    /// `URLSession.download(from:)` (the async one) never invokes the
    /// session's `didWriteData` delegate callback — verified: 0 callbacks for
    /// a full 8 MB body, whether the delegate is attached at session or task
    /// level. Only the classic `downloadTask` + delegate pair reports
    /// progress, so the continuation bridge is what makes the progress bar
    /// real. Also gives us cancellation for free.
    private final class DownloadTask: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let onProgress: @Sendable (Double) -> Void
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var settled = false

        private init(onProgress: @escaping @Sendable (Double) -> Void) {
            self.onProgress = onProgress
        }

        static func run(
            _ url: URL, onProgress: @escaping @Sendable (Double) -> Void
        ) async throws -> (URL, URLResponse?) {
            let delegate = DownloadTask(onProgress: onProgress)
            let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }
            let task = session.downloadTask(with: url)
            let file = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { k in
                    delegate.attach(k)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
            return (file, task.response)
        }

        private func attach(_ k: CheckedContinuation<URL, Error>) {
            lock.lock(); defer { lock.unlock() }
            // Cancelled before the task started — resume here or we hang.
            if settled { k.resume(throwing: CancellationError()) } else { continuation = k }
        }

        /// Resume exactly once: `didFinishDownloadingTo` and
        /// `didCompleteWithError` both fire on a successful download.
        private func finish(_ result: Result<URL, Error>) {
            lock.lock()
            guard !settled else { lock.unlock(); return }
            settled = true
            let k = continuation
            continuation = nil
            lock.unlock()
            guard let k else { return }
            switch result {
            case .success(let url): k.resume(returning: url)
            case .failure(let error): k.resume(throwing: error)
            }
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didFinishDownloadingTo location: URL
        ) {
            // URLSession deletes `location` the moment this returns, so move
            // it out before resuming the caller.
            let kept = FileManager.default.temporaryDirectory
                .appendingPathComponent("quill-model-\(UUID().uuidString)")
            do {
                try FileManager.default.moveItem(at: location, to: kept)
                finish(.success(kept))
            } catch {
                finish(.failure(error))
            }
        }

        func urlSession(
            _ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?
        ) {
            if let error { finish(.failure(error)) }
        }
    }

    var isAvailable: Bool { Self.isEnabled && Self.isDownloaded }

    func enhance(session dir: URL) async throws {
        let transcriptURL = dir.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.isEmpty else { return }
        let clipped = String(transcript.prefix(8_000))

        let notes = try await Self.generate(
            system: FoundationModelsEnhance.prompt
                + (await FoundationModelsEnhance.imageContext(dir)),
            user: clipped,
            maxTokens: 800
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        try Data((notes + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)

        // Same title prompt as the FoundationModels path, so the two backends
        // can't drift; saveTitle scrubs the output either way.
        if let title = try? await Self.generate(
            system: FoundationModelsEnhance.titlePrompt,
            user: String(notes.prefix(2_000)),
            maxTokens: 24
        ) {
            FoundationModelsEnhance.saveTitle(title, in: dir)
        }
    }

    // MARK: - llama.cpp plumbing

    /// One-shot generation over the Qwen chat template, greedy-ish sampling.
    /// Blocking C calls run off the main actor (detached).
    static func generate(system: String, user: String, maxTokens: Int32) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try generateSync(system: system, user: user, maxTokens: maxTokens)
        }.value
    }

    private static func generateSync(system: String, user: String, maxTokens: Int32) throws -> String {
        llama_backend_init()
        defer { llama_backend_free() }

        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 99 // Metal
        guard let model = llama_model_load_from_file(modelURL.path, mparams) else {
            throw err("model load failed")
        }
        defer { llama_model_free(model) }
        guard let vocab = llama_model_get_vocab(model) else { throw err("no vocab") }

        // Qwen2.5 ChatML template.
        let prompt = """
        <|im_start|>system
        \(system)<|im_end|>
        <|im_start|>user
        \(user)<|im_end|>
        <|im_start|>assistant

        """

        // Tokenize (two-pass: size then fill).
        let utf8Count = Int32(prompt.utf8.count)
        let needed = -llama_tokenize(vocab, prompt, utf8Count, nil, 0, true, true)
        var tokens = [llama_token](repeating: 0, count: Int(needed))
        let count = llama_tokenize(vocab, prompt, utf8Count, &tokens, needed, true, true)
        guard count > 0 else { throw err("tokenize failed") }
        tokens.removeLast(tokens.count - Int(count))

        var cparams = llama_context_default_params()
        cparams.n_ctx = UInt32(min(8192, Int(count) + Int(maxTokens) + 16))
        cparams.n_batch = 512
        guard let ctx = llama_init_from_model(model, cparams) else {
            throw err("context init failed")
        }
        defer { llama_free(ctx) }

        // Feed the prompt in batches.
        var pos: Int32 = 0
        var i = 0
        while i < tokens.count {
            let n = min(512, tokens.count - i)
            var batch = llama_batch_get_one(&tokens[i], Int32(n))
            guard llama_decode(ctx, batch) == 0 else { throw err("decode failed at \(pos)") }
            pos += Int32(n)
            i += n
        }

        // Sampler chain: light temperature + dist (greedy collapses Qwen
        // into repetition on long structured output).
        let sctx = llama_sampler_chain_init(llama_sampler_chain_default_params())
        defer { llama_sampler_free(sctx) }
        llama_sampler_chain_add(sctx, llama_sampler_init_temp(0.3))
        llama_sampler_chain_add(sctx, llama_sampler_init_dist(42))

        var out = ""
        var cur = llama_sampler_sample(sctx, ctx, -1)
        var generated: Int32 = 0
        var piece = [CChar](repeating: 0, count: 256)

        while generated < maxTokens, !llama_vocab_is_eog(vocab, cur) {
            let len = llama_token_to_piece(vocab, cur, &piece, 256, 0, true)
            if len > 0 {
                out += piece.withUnsafeBufferPointer { buf in
                    String(decoding: buf.prefix(Int(len)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                }
            }
            var tok = cur
            var batch = llama_batch_get_one(&tok, 1)
            guard llama_decode(ctx, batch) == 0 else { break }
            cur = llama_sampler_sample(sctx, ctx, -1)
            generated += 1
        }
        return out
    }

    private static func err(_ message: String) -> NSError {
        NSError(domain: "quill.llama", code: 3, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
