import Foundation
import Network
import os

/// Loopback-only HTTP API so local agents (OpenBot, scripts, MCP servers) can
/// hand Vela a video link and get its transcript back — they can't watch a
/// reel or a YouTube video, but they can read what was said in it.
///
///   GET  /health                      → {"ok": true, "model": "..."}
///   POST /transcribe  {"url": "..."}  → {"text", "language", "title", "durationSeconds", "source"}
///        optional: "path" (local audio/video file instead of url),
///                  "language" ("auto" default, or "en", "es", …)
///
/// Bound to 127.0.0.1 only, so nothing off this Mac can reach it. Requests that
/// carry an Origin header (i.e. from a web page in a browser) are refused, so a
/// website can't make Vela download things behind your back.
final class LocalAPIServer: @unchecked Sendable {
    static let shared = LocalAPIServer()
    static let port: UInt16 = 47821

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.vela.api")
    private let log = Logger(subsystem: "com.vela.app", category: "api")
    /// One video at a time: each job holds a full Whisper pass in memory.
    private let gate = SerialGate()

    private static let maxHeaderBytes = 32 * 1024
    private static let maxBodyBytes = 1024 * 1024

    func start() {
        queue.async { [self] in
            guard listener == nil else { return }
            do {
                let params = NWParameters.tcp
                params.allowLocalEndpointReuse = true
                params.requiredLocalEndpoint = .hostPort(
                    host: .ipv4(.loopback),
                    port: NWEndpoint.Port(rawValue: Self.port)!
                )
                let listener = try NWListener(using: params)
                listener.newConnectionHandler = { [weak self] connection in
                    self?.accept(connection)
                }
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        self?.log.info("Local API listening on 127.0.0.1:\(Self.port)")
                    case .failed(let error):
                        self?.log.error("Local API failed: \(error.localizedDescription, privacy: .public)")
                        self?.listener = nil
                    default: break
                    }
                }
                listener.start(queue: queue)
                self.listener = listener
            } catch {
                log.error("Local API could not start: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    // MARK: Connection / minimal HTTP/1.1

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let request = HTTPRequest.parse(buffer) {
                if request.body.count >= request.contentLength {
                    Task { await self.respond(to: request, on: connection) }
                    return
                }
                if request.contentLength > Self.maxBodyBytes {
                    self.send(.init(status: 413, json: ["error": "Request body too large"]), on: connection)
                    return
                }
            } else if buffer.count > Self.maxHeaderBytes {
                self.send(.init(status: 431, json: ["error": "Headers too large"]), on: connection)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
            } else {
                self.receive(on: connection, buffer: buffer)
            }
        }
    }

    private func respond(to request: HTTPRequest, on connection: NWConnection) async {
        let response: HTTPResponse
        if request.headers["origin"] != nil {
            response = .init(status: 403, json: ["error": "Browser requests are not allowed"])
        } else {
            switch (request.method, request.path) {
            case ("GET", "/health"):
                response = .init(status: 200, json: ["ok": true, "model": AppSettings.whisperModel])
            case ("POST", "/transcribe"):
                response = await transcribe(request.body.prefix(request.contentLength))
            default:
                response = .init(status: 404, json: ["error": "Use GET /health or POST /transcribe"])
            }
        }
        send(response, on: connection)
    }

    private func send(_ response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    // MARK: Transcription

    private struct TranscribeRequest: Decodable {
        let url: String?
        let path: String?
        let language: String?
    }

    private func transcribe(_ body: Data) async -> HTTPResponse {
        guard let request = try? JSONDecoder().decode(TranscribeRequest.self, from: body) else {
            return .init(status: 400, json: ["error": #"Body must be JSON like {"url": "https://…"}"#])
        }

        await gate.acquire()
        defer { Task { await gate.release() } }

        let workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-api-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        do {
            let file: URL
            var title: String?
            let source: String
            if let link = request.url?.trimmingCharacters(in: .whitespacesAndNewlines), !link.isEmpty {
                guard let parsed = URL(string: link), ["http", "https"].contains(parsed.scheme?.lowercased() ?? "") else {
                    return .init(status: 400, json: ["error": "url must be an http(s) link"])
                }
                try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
                log.info("API: downloading \(link, privacy: .public)")
                (file, title) = try await VideoDownloader.downloadAudio(from: link, into: workDir)
                source = link
            } else if let path = request.path, !path.isEmpty {
                file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
                guard FileManager.default.fileExists(atPath: file.path) else {
                    return .init(status: 404, json: ["error": "No file at \(file.path)"])
                }
                source = file.path
            } else {
                return .init(status: 400, json: ["error": "Provide \"url\" or \"path\""])
            }

            let samples = try await Task.detached(priority: .userInitiated) {
                try AudioFileImporter.load(url: file)
            }.value
            let duration = Double(samples.count) / AudioRecorder.targetSampleRate
            guard duration > 0.3 else { throw VelaError.audio("No audio track found") }

            log.info("API: transcribing \(Int(duration))s of audio")
            // Auto-detect by default: reels are often Spanish or mixed. No
            // glossary prompt — on long audio it blanks out whole windows.
            let stt = try await Transcriber.shared.transcribe(
                samples: samples,
                glossaryTerms: [],
                languageOverride: request.language ?? "auto"
            ) { _, _ in }
            let text = TranscriptFilter.clean(stt.text)

            var json: [String: Any] = [
                "text": text,
                "language": stt.language,
                "durationSeconds": (duration * 10).rounded() / 10,
                "source": source,
            ]
            if let title { json["title"] = title }
            if text.isEmpty { json["note"] = "No speech detected (music-only or silent video?)" }
            return .init(status: 200, json: json)
        } catch {
            log.error("API: \(error.localizedDescription, privacy: .public)")
            return .init(status: 500, json: ["error": error.localizedDescription])
        }
    }
}

// MARK: - yt-dlp

enum VideoDownloader {
    private static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin",
                                      NSHomeDirectory() + "/.local/bin"]

    /// Downloads just the audio of a YouTube / Instagram / TikTok / … link.
    static func downloadAudio(from link: String, into dir: URL) async throws -> (URL, String?) {
        guard let ytdlp = searchPaths.map({ $0 + "/yt-dlp" }).first(where: FileManager.default.isExecutableFile) else {
            throw VelaError.audio("yt-dlp is not installed (brew install yt-dlp ffmpeg)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = [
            "--no-playlist", "--no-progress", "--no-warnings",
            "-f", "bestaudio/best",
            "-x", "--audio-format", "m4a",
            "-o", dir.appendingPathComponent("audio.%(ext)s").path,
            "--no-simulate",
            "--print", "before_dl:TITLE:%(title)s",
            "--print", "after_move:FILE:%(filepath)s",
            "--", link,
        ]
        // GUI apps don't inherit the shell PATH; yt-dlp needs to find ffmpeg.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        // Files, not pipes: a chatty yt-dlp can't deadlock on a full pipe buffer.
        let outURL = dir.appendingPathComponent("stdout.txt")
        let errURL = dir.appendingPathComponent("stderr.txt")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        process.standardOutput = try FileHandle(forWritingTo: outURL)
        process.standardError = try FileHandle(forWritingTo: errURL)

        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(throwing: error); return }
            // Hard stop for stuck downloads.
            DispatchQueue.global().asyncAfter(deadline: .now() + 600) {
                if process.isRunning { process.terminate() }
            }
        }

        let stdout = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
        guard status == 0 else {
            let stderr = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
            let reason = stderr.split(separator: "\n").last(where: { $0.contains("ERROR") }) ?? Substring(stderr.suffix(400))
            throw VelaError.audio("Download failed: \(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
        }

        let lines = stdout.split(separator: "\n").map(String.init)
        let title = lines.first { $0.hasPrefix("TITLE:") }.map { String($0.dropFirst(6)) }
        if let path = lines.last(where: { $0.hasPrefix("FILE:") }).map({ String($0.dropFirst(5)) }),
           FileManager.default.fileExists(atPath: path) {
            return (URL(fileURLWithPath: path), title)
        }
        // Fallback: whatever audio.* landed in the folder.
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        guard let file = files.first(where: { $0.lastPathComponent.hasPrefix("audio.") }) else {
            throw VelaError.audio("Download produced no audio file")
        }
        return (file, title)
    }
}

// MARK: - Helpers

private actor SerialGate {
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !busy { busy = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let contentLength: Int
    let body: Data

    /// nil until the full header block has arrived.
    static func parse(_ data: Data) -> HTTPRequest? {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return nil }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let path = String(parts[1].split(separator: "?").first ?? "")
        return HTTPRequest(
            method: String(parts[0]).uppercased(),
            path: path,
            headers: headers,
            contentLength: Int(headers["content-length"] ?? "") ?? 0,
            body: Data(data[end.upperBound...])
        )
    }
}

private struct HTTPResponse {
    let status: Int
    let json: [String: Any]

    func serialized() -> Data {
        let body = (try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])) ?? Data("{}".utf8)
        let reason = [200: "OK", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                      413: "Payload Too Large", 431: "Request Header Fields Too Large",
                      500: "Internal Server Error"][status] ?? "Status"
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json; charset=utf-8\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(body)
        return out
    }
}
