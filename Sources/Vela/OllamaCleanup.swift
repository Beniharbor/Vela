import Foundation
import os

/// F2: optional transcript cleanup/formatting via a local Ollama server, with the
/// prompt chosen by the active DictationStyle (Structured/Clean — Flow never calls this).
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

    /// Rewrites the transcript per the selected style's prompt. Throws if Ollama is
    /// unavailable — callers should fall back to the raw transcript.
    static func clean(_ transcript: String, style: DictationStyle, glossaryTerms: [String]) async throws -> String {
        guard var system = style.systemPrompt else { return transcript }
        try await ensureServerRunning()
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
