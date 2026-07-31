import Foundation
import os

/// F2: optional transcript cleanup/formatting via a local Ollama server, with the
/// prompt chosen by the active DictationMode (modes with an empty prompt never call this).
/// On-demand lifecycle: starts `ollama serve` only when needed; `keep_alive: 0`
/// unloads the LLM from RAM immediately after each request (G3).
struct OllamaCleanup {
    private static let baseURL = URL(string: "http://127.0.0.1:11434")!
    private static let log = Logger(subsystem: "com.vela.app", category: "cleanup")

    /// Candidate install locations (Homebrew ARM, Homebrew Intel, official .pkg).
    private static let ollamaPaths = [
        "/opt/homebrew/bin/ollama",
        "/usr/local/bin/ollama",
        "/Applications/Ollama.app/Contents/Resources/ollama",
    ]

    static var isInstalled: Bool {
        installedBinary != nil
    }

    private static var installedBinary: String? {
        ollamaPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Loads the LLM into RAM while the user is still speaking so the cleanup pass
    /// starts hot (a promptless generate is Ollama's "load only" call). keep_alive
    /// briefly outlives the dictation; the real request's keep_alive: 0 evicts it
    /// right after, so G3 still holds.
    static func prewarm() async {
        guard isInstalled else { return }
        do {
            try await ensureServerRunning()
            let body: [String: Any] = [
                "model": AppSettings.ollamaModel,
                "keep_alive": 300,
            ]
            var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.timeoutInterval = 120
            _ = try await URLSession.shared.data(for: request)
            log.info("Ollama prewarmed \(AppSettings.ollamaModel, privacy: .public)")
        } catch {
            log.info("Ollama prewarm skipped: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Shared rule appended to EVERY mode's prompt (built-in and custom): the mic
    /// also catches speech not meant for dictation — asides to people in the room,
    /// self-corrections about who is being addressed — which must never reach the
    /// output. Lives here rather than in each mode so user-created modes get it too.
    private static let offTargetRule = """

    The microphone may also capture speech NOT meant for dictation: asides to \
    other people or pets in the room, answering a phone, laughter, or the speaker \
    remarking on the dictation itself ("no no, I'm talking to the computer", \
    "wait, that wasn't for you", "hahaha"). OMIT all such off-target speech from \
    the output — keep only what the speaker intended to dictate, and stitch the \
    remaining dictation back together seamlessly. If the speaker retracts words \
    ("scratch that", "ignore what I just said", "no no, not that"), drop the \
    retracted words AND the retraction phrase itself.
    """

    /// Rewrites the transcript per the selected mode's prompt. Throws if Ollama is
    /// unavailable — callers should fall back to the raw transcript.
    /// `language` is Whisper's detected ISO code — stated explicitly because small
    /// models drift into translating when the generic "same language" rule is soft.
    static func clean(_ transcript: String, mode: DictationMode, glossaryTerms: [String], language: String? = nil) async throws -> String {
        guard var system = mode.resolvedPrompt else { return transcript }
        try await ensureServerRunning()
        system += offTargetRule
        if let name = languageName(language) {
            system += "\nThe transcript is in \(name). Your output MUST be entirely in \(name)."
        }
        if !glossaryTerms.isEmpty {
            system += "\nUser glossary (canonical spellings — map near-misses to these): "
                + glossaryTerms.joined(separator: ", ")
        }

        let body: [String: Any] = [
            "model": AppSettings.ollamaModel,
            "system": system,
            "prompt": transcript,
            "stream": false,
            "keep_alive": 0, // G3: evict the model from RAM immediately after responding
            "options": ["temperature": 0.1],
        ]

        var request = URLRequest(url: baseURL.appendingPathComponent("api/generate"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 120

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw VelaError.cleanup("Ollama returned an error (is \(AppSettings.ollamaModel) pulled?)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let cleaned = json["response"] as? String
        else {
            throw VelaError.cleanup("Unexpected Ollama response")
        }
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func languageName(_ code: String?) -> String? {
        guard let code, code.count == 2 else { return nil }
        return Locale(identifier: "en").localizedString(forLanguageCode: code)
    }

    // MARK: - Server lifecycle

    private static func serverIsUp() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("api/version"))
        request.timeoutInterval = 2
        return (try? await URLSession.shared.data(for: request)) != nil
    }

    private static func ensureServerRunning() async throws {
        if await serverIsUp() { return }
        guard let binary = installedBinary else {
            throw VelaError.cleanup("Ollama is not installed (brew install ollama)")
        }
        log.info("Starting ollama serve on demand")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["serve"]
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["OLLAMA_KEEP_ALIVE": "0"], uniquingKeysWith: { _, new in new }
        )
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()

        // Wait up to ~5 s for the server to come up.
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(500))
            if await serverIsUp() { return }
        }
        throw VelaError.cleanup("Ollama server did not start in time")
    }
}
