import Foundation
import llama
import os

/// The built-in language model: llama.cpp running a small instruct model that
/// Vela downloads itself. Powers the LLM dictation styles and voice rewrite
/// with nothing else installed (Ollama remains a fallback when present).
///
/// RAM discipline (G3): the model is loaded on demand — warmed while the user
/// is still speaking — and dropped shortly after the last request.
final class LocalLLM: @unchecked Sendable {
    static let shared = LocalLLM()

    static let modelName = "Qwen2.5 3B Instruct"
    static let fileName = "qwen2.5-3b-instruct-q4_k_m.gguf"
    static let downloadURL = URL(
        string: "https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-GGUF/resolve/main/qwen2.5-3b-instruct-q4_k_m.gguf"
    )!
    static let expectedBytes: Int64 = 2_104_932_768

    static var modelFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Vela/Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent(fileName)
    }

    /// True once the whole file is on disk (a partial download doesn't count).
    static var isDownloaded: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: modelFile.path)
        return (attributes?[.size] as? NSNumber)?.int64Value == expectedBytes
    }

    enum Failure: LocalizedError {
        case notDownloaded, loadFailed, promptTooLong, decodeFailed

        var errorDescription: String? {
            switch self {
            case .notDownloaded: return "The built-in AI model isn't downloaded yet (Settings → Style)"
            case .loadFailed: return "The built-in AI model could not be loaded"
            case .promptTooLong: return "That text is too long for the built-in AI model"
            case .decodeFailed: return "The built-in AI model failed while generating"
            }
        }
    }

    /// All llama.cpp calls happen here, one at a time.
    private let queue = DispatchQueue(label: "com.vela.llm", qos: .userInitiated)
    private var model: OpaquePointer?
    /// Kept between requests so the fixed start of the prompt (mode rules and
    /// worked examples) is evaluated once, not on every dictation.
    private var context: OpaquePointer?
    /// Exactly the tokens the context currently holds.
    private var contextTokens: [llama_token] = []
    private var unloadWork: DispatchWorkItem?
    private let log = Logger(subsystem: "com.vela.app", category: "llm")
    private static let contextLimit = 8192
    private static let batchSize = 2048
    private static let idleSeconds = 20.0

    private init() {
        llama_log_set({ _, _, _ in }, nil) // llama.cpp is chatty on stderr
        llama_backend_init()
        // llama.cpp asserts at process exit if a model is still holding Metal
        // resources — release it before the app quits.
        NotificationCenter.default.addObserver(
            forName: Notification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil
        ) { [weak self] _ in self?.unloadNow() }
    }

    /// Frees the model immediately (blocks until any running request ends).
    func unloadNow() {
        queue.sync {
            unloadWork?.cancel()
            freeModel()
        }
    }

    private func freeModel() {
        if let context { llama_free(context) }
        context = nil
        contextTokens = []
        if let model { llama_model_free(model) }
        model = nil
    }

    /// Loads the model so the first request doesn't pay for it.
    func prewarm() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = try? self.loadIfNeeded()
                self.scheduleUnload()
                continuation.resume()
            }
        }
    }

    /// `examples` are worked input → output pairs replayed as earlier turns of
    /// the conversation; a small model follows those far more reliably than
    /// the same examples described in the system prompt.
    func generate(system: String, examples: [(input: String, output: String)] = [], prompt: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let text = try self.run(system: system, examples: examples, prompt: prompt)
                    continuation.resume(returning: text)
                } catch {
                    continuation.resume(throwing: error)
                }
                self.scheduleUnload()
            }
        }
    }

    // MARK: Queue-confined

    private func loadIfNeeded() throws -> OpaquePointer {
        unloadWork?.cancel()
        if let model { return model }
        guard Self.isDownloaded else { throw Failure.notDownloaded }
        let start = Date()
        var params = llama_model_default_params()
        params.n_gpu_layers = -1 // everything on the GPU (Metal)
        guard let loaded = llama_model_load_from_file(Self.modelFile.path, params) else {
            throw Failure.loadFailed
        }
        model = loaded
        log.info("Built-in LLM loaded in \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        return loaded
    }

    private func scheduleUnload() {
        unloadWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.model != nil else { return }
            self.freeModel()
            self.log.info("Built-in LLM unloaded (idle)")
        }
        unloadWork = work
        queue.asyncAfter(deadline: .now() + Self.idleSeconds, execute: work)
    }

    private func run(system: String, examples: [(input: String, output: String)], prompt: String) throws -> String {
        let model = try loadIfNeeded()
        guard let vocab = llama_model_get_vocab(model) else { throw Failure.loadFailed }

        var turns = [("system", system)]
        for example in examples {
            turns.append(("user", example.input))
            turns.append(("assistant", example.output))
        }
        turns.append(("user", prompt))
        let formatted = try Self.chatPrompt(model: model, turns: turns)
        var tokens = try Self.tokenize(vocab, formatted)
        // Room for an answer about as long as the input, plus headroom.
        let maxNew = min(2048, max(256, tokens.count))
        guard tokens.count + maxNew <= Self.contextLimit else { throw Failure.promptTooLong }

        if context == nil {
            var contextParams = llama_context_default_params()
            contextParams.n_ctx = UInt32(Self.contextLimit)
            contextParams.n_batch = UInt32(Self.batchSize)
            context = llama_init_from_model(model, contextParams)
            contextTokens = []
        }
        guard let context else { throw Failure.loadFailed }

        guard let sampler = llama_sampler_chain_init(llama_sampler_chain_default_params()) else {
            throw Failure.loadFailed
        }
        defer { llama_sampler_free(sampler) }
        llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40))
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9, 1))
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.1))
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(LLAMA_DEFAULT_SEED))

        // Reuse whatever start of this prompt the context already holds.
        var shared = 0
        while shared < contextTokens.count, shared < tokens.count, contextTokens[shared] == tokens[shared] {
            shared += 1
        }
        if shared == tokens.count { shared -= 1 } // always evaluate at least one token
        let memory = llama_get_memory(context)
        if !llama_memory_seq_rm(memory, 0, Int32(shared), -1) {
            llama_memory_clear(memory, true)
            shared = 0
        }
        contextTokens = Array(tokens.prefix(shared))

        let start = Date()
        var position = shared
        while position < tokens.count {
            let count = min(Self.batchSize, tokens.count - position)
            let status = tokens.withUnsafeMutableBufferPointer {
                llama_decode(context, llama_batch_get_one($0.baseAddress! + position, Int32(count)))
            }
            guard status == 0 else {
                contextTokens = []
                llama_memory_clear(memory, true)
                throw Failure.decodeFailed
            }
            position += count
        }
        contextTokens = tokens

        var output = Data()
        var generated = 0
        var piece = [CChar](repeating: 0, count: 256)
        while generated < maxNew {
            var token = llama_sampler_sample(sampler, context, -1)
            if llama_vocab_is_eog(vocab, token) { break }
            let length = llama_token_to_piece(vocab, token, &piece, Int32(piece.count), 0, false)
            if length > 0 {
                piece.withUnsafeBufferPointer { buffer in
                    buffer.baseAddress!.withMemoryRebound(to: UInt8.self, capacity: Int(length)) {
                        output.append($0, count: Int(length))
                    }
                }
            }
            generated += 1
            guard llama_decode(context, llama_batch_get_one(&token, 1)) == 0 else {
                contextTokens = []
                llama_memory_clear(memory, true)
                throw Failure.decodeFailed
            }
            contextTokens.append(token)
        }
        log.info("Built-in LLM: \(tokens.count) in (\(shared) cached), \(generated) out, \(Date().timeIntervalSince(start), format: .fixed(precision: 2))s")
        return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Wraps system + user text in the model's own chat template.
    private static func chatPrompt(model: OpaquePointer, turns: [(String, String)]) throws -> String {
        let template = llama_model_chat_template(model, nil)
        let strings = turns.flatMap { [strdup($0.0), strdup($0.1)] }
        defer { strings.forEach { free($0) } }
        let messages = (0..<turns.count).map {
            llama_chat_message(role: strings[$0 * 2], content: strings[$0 * 2 + 1])
        }
        let bytes = turns.reduce(0) { $0 + $1.1.utf8.count + 64 }
        var buffer = [CChar](repeating: 0, count: bytes + 1024)
        var written = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
        if written > Int32(buffer.count) {
            buffer = [CChar](repeating: 0, count: Int(written) + 1)
            written = llama_chat_apply_template(template, messages, messages.count, true, &buffer, Int32(buffer.count))
        }
        guard written > 0 else { throw Failure.loadFailed }
        return String(decoding: buffer.prefix(Int(written)).map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func tokenize(_ vocab: OpaquePointer, _ text: String) throws -> [llama_token] {
        let length = Int32(text.utf8.count)
        var tokens = [llama_token](repeating: 0, count: Int(length) + 16)
        let count = llama_tokenize(vocab, text, length, &tokens, Int32(tokens.count), true, true)
        guard count > 0 else { throw Failure.promptTooLong }
        return Array(tokens.prefix(Int(count)))
    }
}

/// Downloads the built-in model with progress, for the Settings row.
@MainActor
final class LocalLLMDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = LocalLLMDownloader()

    @Published private(set) var isDownloaded = LocalLLM.isDownloaded
    /// 0–1 while a download is running; nil otherwise.
    @Published private(set) var progress: Double?
    @Published private(set) var error: String?

    private var task: URLSessionDownloadTask?
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)

    func start() {
        guard task == nil, !isDownloaded else { return }
        error = nil
        progress = 0
        let task = session.downloadTask(with: LocalLLM.downloadURL)
        self.task = task
        task.resume()
    }

    func cancel() {
        task?.cancel()
        task = nil
        progress = nil
    }

    func remove() {
        try? FileManager.default.removeItem(at: LocalLLM.modelFile)
        isDownloaded = false
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        let fraction = Double(totalBytesWritten) / Double(LocalLLM.expectedBytes)
        Task { @MainActor in
            if self.task != nil { self.progress = min(1, fraction) }
        }
    }

    nonisolated func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL
    ) {
        // The temp file is deleted when this returns — move it now.
        let destination = LocalLLM.modelFile
        try? FileManager.default.removeItem(at: destination)
        let moved = (try? FileManager.default.moveItem(at: location, to: destination)) != nil
        Task { @MainActor in
            self.task = nil
            self.progress = nil
            self.isDownloaded = LocalLLM.isDownloaded
            if !moved || !self.isDownloaded {
                self.error = "The download was incomplete — try again"
                try? FileManager.default.removeItem(at: destination)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, (error as NSError).code != NSURLErrorCancelled else { return }
        Task { @MainActor in
            self.task = nil
            self.progress = nil
            self.error = error.localizedDescription
        }
    }
}
