import Speech
import AVFoundation
import os

/// Live, on-device keyword spot for the "watermelon" voice stop-word. Whisper
/// only transcribes after recording ends, so stopping by voice needs a second,
/// low-latency recognizer running alongside the raw capture just to catch this
/// one word — on-device only (requiresOnDeviceRecognition), nothing leaves the Mac.
final class WatchwordListener {
    static let word = "watermelon"

    /// Built per take and dropped on stop(). A live SFSpeechRecognizer is a
    /// standing speech session as far as the system is concerned; idle Vela
    /// should hold no voice-input state at all, so other apps' audio is never
    /// competing with a recognizer that isn't being used.
    private var recognizer: SFSpeechRecognizer?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var fired = false
    private let log = Logger(subsystem: "com.vela.app", category: "watchword")

    /// Fired once per take, hopped to the main actor, the moment "watermelon" is heard.
    var onDetected: (() -> Void)?

    static func requestAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Call once recording has actually started (mirrors AudioRecorder.start()).
    func start() {
        fired = false
        let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        self.recognizer = recognizer
        guard let recognizer, recognizer.isAvailable else {
            self.recognizer = nil
            log.info("Speech recognizer unavailable — watermelon stop-word disabled for this take")
            return
        }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        self.request = request
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            if let error {
                self?.log.error("Watchword recognition error: \(error.localizedDescription, privacy: .public)")
            }
            guard let result else { return }
            let heard = result.bestTranscription.formattedString.lowercased()
            guard heard.contains(Self.word) else { return }
            Task { @MainActor [weak self] in
                guard let self, !self.fired else { return }
                self.fired = true
                self.onDetected?()
            }
        }
    }

    /// Feed a raw mic buffer — called on the audio thread, same as AudioRecorder.append.
    func append(_ buffer: AVAudioPCMBuffer) {
        request?.append(buffer)
    }

    func stop() {
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        recognizer = nil
    }
}
