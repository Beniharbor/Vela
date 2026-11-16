import AppKit
import CoreAudio
import os

/// Pauses whatever is playing (music, a video) while a dictation is in
/// progress and resumes it when the pipeline finishes — so the mic doesn't
/// record the music and Bluetooth headphones aren't juggling both at once.
///
/// Only ever resumes what it paused itself: if nothing was playing when the
/// recording started, nothing is touched at the end.
///
/// Detection is CoreAudio's public per-process "is running output" flag.
/// Spotify and Music are then driven by AppleScript, which can confirm the
/// player really is playing before pausing. Anything else (a browser tab,
/// a video player) gets MediaRemote's explicit pause / play commands — never
/// the play/pause *toggle*, which would start music that wasn't playing.
@MainActor
final class MediaPauser {
    static let shared = MediaPauser()

    private enum Owned: Sendable {
        case scripted(bundleID: String)
        case mediaRemote
    }

    private var owned: Owned?
    /// Bumped on every start/end so a slow pause that lands after the take is
    /// already over undoes itself instead of leaving the music stopped.
    private var generation = 0
    private nonisolated static let log = Logger(subsystem: "com.vela.app", category: "media")

    func recordingStarted() {
        guard AppSettings.pauseMediaWhileDictating, owned == nil else { return }
        generation += 1
        let token = generation
        // Off the main actor: never delays the first captured audio.
        Task.detached(priority: .userInitiated) {
            guard let paused = Self.pauseIfPlaying() else { return }
            let stale = await MainActor.run { () -> Bool in
                if self.generation == token {
                    self.owned = paused
                    return false
                }
                return true
            }
            if stale { Self.resume(paused) }
        }
    }

    func pipelineFinished() {
        generation += 1
        guard let paused = owned else { return }
        owned = nil
        Task.detached(priority: .userInitiated) { Self.resume(paused) }
    }

    // MARK: Pause / resume

    private nonisolated static let scriptable: Set<String> = ["com.spotify.client", "com.apple.Music"]

    /// Apps that hold an output stream for a call, not for media — sending them
    /// (or the now-playing app behind them) a pause would be wrong.
    private nonisolated static let ignoredBundleIDs: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.apple.FaceTime",
        "com.hnc.Discord", "com.tinyspeck.slackmacgap", "net.whatsapp.WhatsApp",
        "com.FluidApp.app", "systemsoundserverd",
    ]
    /// Apple processes are system sounds / daemons unless listed here.
    private nonisolated static let appleMediaBundleIDs: Set<String> = [
        "com.apple.WebKit.GPU", "com.apple.Safari", "com.apple.Music", "com.apple.TV",
        "com.apple.podcasts", "com.apple.QuickTimePlayerX",
    ]

    private nonisolated static func pauseIfPlaying() -> Owned? {
        let playing = bundleIDsRunningOutput()
        guard !playing.isEmpty else { return nil }

        var scriptFailed = false
        for bundleID in playing where scriptable.contains(bundleID) {
            let script = """
            tell application id "\(bundleID)"
                if player state is playing then
                    pause
                    return "paused"
                end if
            end tell
            return "idle"
            """
            switch runAppleScript(script) {
            case "paused":
                log.info("Paused \(bundleID, privacy: .public) for dictation")
                return .scripted(bundleID: bundleID)
            case "idle":
                continue // output stream open but not actually playing
            default:
                scriptFailed = true // Automation not granted — try MediaRemote
            }
        }

        let others = playing.filter { !scriptable.contains($0) }
        guard !others.isEmpty || scriptFailed else { return nil }
        guard sendMediaRemote(command: 1) else { return nil } // 1 = pause
        log.info("Sent pause to the now-playing app")
        return .mediaRemote
    }

    private nonisolated static func resume(_ owned: Owned) {
        switch owned {
        case .scripted(let bundleID):
            _ = runAppleScript("tell application id \"\(bundleID)\" to play")
        case .mediaRemote:
            _ = sendMediaRemote(command: 0) // 0 = play
        }
        log.info("Resumed media after dictation")
    }

    // MARK: MediaRemote (explicit pause / play, no toggle)

    private typealias SendCommand = @convention(c) (UInt32, CFDictionary?) -> Bool

    private nonisolated static let mediaRemoteSend: SendCommand? = {
        guard let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW),
              let symbol = dlsym(handle, "MRMediaRemoteSendCommand")
        else { return nil }
        return unsafeBitCast(symbol, to: SendCommand.self)
    }()

    private nonisolated static func sendMediaRemote(command: UInt32) -> Bool {
        guard let send = mediaRemoteSend else { return false }
        return send(command, nil)
    }

    // MARK: AppleScript

    /// Runs via osascript so it can happen off the main thread. Returns the
    /// trimmed result, or nil on any failure (app gone, Automation denied).
    private nonisolated static func runAppleScript(_ source: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", source]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: CoreAudio

    /// Bundle IDs of other apps currently running an audio output stream.
    private nonisolated static func bundleIDsRunningOutput() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [String] = []
        for process in processes {
            guard uint32(process, kAudioProcessPropertyIsRunningOutput) == 1 else { continue }
            if let pid = uint32(process, kAudioProcessPropertyPID), pid_t(bitPattern: pid) == ownPID { continue }
            guard let bundleID = bundleID(of: process), !bundleID.isEmpty else { continue }
            if ignoredBundleIDs.contains(bundleID) { continue }
            if bundleID.hasPrefix("com.apple."), !appleMediaBundleIDs.contains(bundleID) { continue }
            // Helper processes ("com.spotify.client.helper") count as their app.
            let base = scriptable.first { bundleID.hasPrefix($0) } ?? bundleID
            if !result.contains(base) { result.append(base) }
        }
        return result
    }

    private nonisolated static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private nonisolated static func bundleID(of object: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }
}

/// Short audible cues so a dictation can be started and stopped without
/// looking at the screen.
enum SoundCue {
    case start, stop

    @MainActor
    func play() {
        guard AppSettings.soundCues else { return }
        let name = self == .start ? "Tink" : "Pop"
        guard let sound = NSSound(named: name) else { return }
        sound.volume = 0.35
        sound.play()
    }
}
