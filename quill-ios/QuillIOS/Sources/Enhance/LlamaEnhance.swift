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

    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelURL.path)
    }

    static func deleteModel() {
        try? FileManager.default.removeItem(at: modelURL.deletingLastPathComponent())
    }

    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let dir = modelURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let delegate = DownloadProgressDelegate(onProgress: progress)
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let (tmp, response) = try await session.download(from: downloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "quill", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "model download failed (\((response as? HTTPURLResponse)?.statusCode ?? -1))",
            ])
        }
        _ = try FileManager.default.replaceItemAt(modelURL, withItemAt: tmp)
    }

    private final class DownloadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        let onProgress: @Sendable (Double) -> Void
        init(onProgress: @escaping @Sendable (Double) -> Void) { self.onProgress = onProgress }

        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64, totalBytesExpectedToSend: Int64
        ) {}

        func urlSession(
            _ session: URLSession, downloadTask: URLSessionDownloadTask,
            didWriteData bytesWritten: Int64,
            totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
        ) {
            guard totalBytesExpectedToWrite > 0 else { return }
            onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        }
    }

    var isAvailable: Bool { Self.isEnabled && Self.isDownloaded }

    func enhance(session dir: URL) async throws {
        let transcriptURL = dir.appendingPathComponent("transcript.md")
        guard let transcript = try? String(contentsOf: transcriptURL, encoding: .utf8),
              !transcript.isEmpty else { return }
        let clipped = String(transcript.prefix(8_000))

        let notes = try await Self.generate(
            system: FoundationModelsEnhance.prompt,
            user: clipped,
            maxTokens: 800
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !notes.isEmpty else { return }

        try Data((notes + "\n").utf8)
            .write(to: dir.appendingPathComponent("notes.md"), options: .atomic)

        if let title = try? await Self.generate(
            system: "You give one short title for a note. 3-6 words, lowercase unless a proper noun, no quotes, no period. Output only the title.",
            user: String(notes.prefix(2_000)),
            maxTokens: 24
        ).trimmingCharacters(in: .whitespacesAndNewlines),
            !title.isEmpty, title.count <= 60 {
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
