import AVFoundation
import AudioToolbox
import os

/// Loads an audio file from disk as 16 kHz mono Float32 samples for Whisper.
///
/// WhatsApp voice notes are Opus in an Ogg container (.ogg / .opus). CoreAudio
/// ships an Opus decoder but AVFoundation can't parse the Ogg container, so
/// that path parses the container here and hands raw packets to an
/// AudioConverter. Everything else (.m4a, .mp3, .wav, …) goes through
/// AVAudioFile.
enum AudioFileImporter {
    static let supportedExtensions: Set<String> = [
        "ogg", "opus", "oga", "m4a", "mp3", "wav", "aac", "caf", "aiff", "aif", "mp4", "m4b",
    ]

    private static let log = Logger(subsystem: "com.vela.app", category: "import")

    static func load(url: URL) throws -> [Float] {
        let ext = url.pathExtension.lowercased()
        if ["ogg", "opus", "oga"].contains(ext) {
            let data = try Data(contentsOf: url)
            let decoded = try OggOpusDecoder.decode(data)
            return try convert(
                samples: decoded.samples,
                channels: decoded.channels,
                sampleRate: decoded.sampleRate
            )
        }

        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard file.length > 0 else { throw VelaError.audio("\(url.lastPathComponent) contains no audio") }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw VelaError.audio("Could not allocate buffer for \(url.lastPathComponent)")
        }
        try file.read(into: buffer)
        return try convert(buffer: buffer)
    }

    /// Reads a file as 16 kHz mono in bounded pieces, so a 90-minute video is
    /// never held in memory at its native rate all at once (48 kHz stereo
    /// Float32 is ~1.4 GB per hour; one 10-minute piece is ~230 MB).
    ///
    /// Not thread-safe: call `next()` from one task at a time.
    final class ChunkedReader: @unchecked Sendable {
        let durationSeconds: Double
        /// How far into the file the reader has advanced, in seconds.
        private(set) var positionSeconds: Double = 0
        var atEnd: Bool { positionSeconds >= durationSeconds }

        private let chunkSeconds: Double
        private let file: AVAudioFile?
        private var framePosition: AVAudioFramePosition = 0
        /// Ogg-Opus has no seekable AVAudioFile path — decoded once, then sliced.
        private var decoded: [Float] = []
        private var decodedOffset = 0

        init(url: URL, chunkSeconds: Double = 600) throws {
            self.chunkSeconds = chunkSeconds
            if ["ogg", "opus", "oga"].contains(url.pathExtension.lowercased()) {
                decoded = try AudioFileImporter.load(url: url)
                file = nil
                durationSeconds = Double(decoded.count) / AudioRecorder.targetSampleRate
            } else {
                let file = try AVAudioFile(forReading: url)
                let rate = file.processingFormat.sampleRate
                guard rate > 0, file.length > 0 else {
                    throw VelaError.audio("\(url.lastPathComponent) contains no audio")
                }
                self.file = file
                durationSeconds = Double(file.length) / rate
            }
        }

        /// The next piece as 16 kHz mono samples, or nil once the file is
        /// exhausted. The position advances even when a read throws, so a
        /// damaged stretch can be skipped and the rest still transcribed.
        func next() throws -> [Float]? {
            guard let file else {
                guard decodedOffset < decoded.count else { return nil }
                let end = min(decodedOffset + Int(chunkSeconds * AudioRecorder.targetSampleRate), decoded.count)
                defer {
                    decodedOffset = end
                    positionSeconds = Double(end) / AudioRecorder.targetSampleRate
                }
                return Array(decoded[decodedOffset..<end])
            }

            guard framePosition < file.length else { return nil }
            let rate = file.processingFormat.sampleRate
            let frames = AVAudioFrameCount(min(
                AVAudioFramePosition(rate * chunkSeconds),
                file.length - framePosition
            ))
            let start = framePosition
            framePosition += AVAudioFramePosition(frames)
            positionSeconds = Double(framePosition) / rate

            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frames) else {
                throw VelaError.audio("Could not allocate audio buffer")
            }
            file.framePosition = start
            try file.read(into: buffer, frameCount: frames)
            guard buffer.frameLength > 0 else { return [] }
            return try AudioFileImporter.convert(buffer: buffer)
        }
    }

    /// Where to cut `samples` so the cut falls in the quietest 100 ms of the
    /// last `searchSeconds` — between words rather than through one. The audio
    /// after the cut is carried into the next piece, so nothing is lost and no
    /// overlap has to be de-duplicated.
    static func quietSplitIndex(in samples: [Float], searchSeconds: Double = 15) -> Int {
        let rate = Int(AudioRecorder.targetSampleRate)
        let frame = rate / 10
        let window = Int(searchSeconds) * rate
        guard samples.count > window * 2 else { return samples.count }
        var bestStart = samples.count - frame
        var bestEnergy = Float.greatestFiniteMagnitude
        var start = samples.count - window
        while start + frame <= samples.count {
            var energy: Float = 0
            for i in start..<(start + frame) { energy += samples[i] * samples[i] }
            if energy < bestEnergy {
                bestEnergy = energy
                bestStart = start
            }
            start += frame
        }
        return bestStart + frame / 2
    }

    /// Wraps raw interleaved samples in a PCM buffer and converts to 16 kHz mono.
    private static func convert(samples: [Float], channels: Int, sampleRate: Double) throws -> [Float] {
        guard !samples.isEmpty else { throw VelaError.audio("Decoded no audio") }
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: AVAudioChannelCount(channels),
            interleaved: true
        ) else { throw VelaError.audio("Unsupported decoded format") }

        let frames = samples.count / channels
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else {
            throw VelaError.audio("Could not allocate conversion buffer")
        }
        samples.withUnsafeBufferPointer { source in
            buffer.floatChannelData![0].update(from: source.baseAddress!, count: frames * channels)
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return try convert(buffer: buffer)
    }

    /// Converts any PCM buffer (any rate / channel count) to 16 kHz mono Float32.
    private static func convert(buffer: AVAudioPCMBuffer) throws -> [Float] {
        let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: AudioRecorder.targetSampleRate,
            channels: 1,
            interleaved: false
        )!
        guard let converter = AVAudioConverter(from: buffer.format, to: targetFormat) else {
            throw VelaError.audio("Unsupported audio format (\(Int(buffer.format.sampleRate)) Hz, \(buffer.format.channelCount) ch)")
        }

        var served = false
        var output: [Float] = []
        let ratio = AudioRecorder.targetSampleRate / buffer.format.sampleRate
        output.reserveCapacity(Int(Double(buffer.frameLength) * ratio) + 1024)
        let chunkFrames = AVAudioFrameCount(AudioRecorder.targetSampleRate * 30) // 30 s per pull

        while true {
            guard let out = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkFrames) else {
                throw VelaError.audio("Could not allocate conversion buffer")
            }
            var error: NSError?
            let status = converter.convert(to: out, error: &error) { _, outStatus in
                if served {
                    outStatus.pointee = .endOfStream
                    return nil
                }
                served = true
                outStatus.pointee = .haveData
                return buffer
            }
            if let error { throw VelaError.audio("Conversion failed: \(error.localizedDescription)") }
            if out.frameLength > 0, let channel = out.floatChannelData?[0] {
                output.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(out.frameLength)))
            }
            if status == .endOfStream || status == .error || out.frameLength == 0 { break }
        }
        return output
    }
}

// MARK: - Ogg-Opus

/// Sentinel returned by the input callback when all packets are consumed.
/// File-scope because a C function pointer cannot capture type context.
private let oggOpusNoMorePackets: OSStatus = OSStatus(bitPattern: 0x76656C61) // 'vela'

/// Minimal Ogg container parser + CoreAudio Opus decode, sufficient for
/// WhatsApp voice notes and other single-stream Ogg-Opus files.
enum OggOpusDecoder {
    struct Decoded {
        /// Interleaved Float32 at 48 kHz (Opus always decodes at 48 kHz).
        let samples: [Float]
        let channels: Int
        let sampleRate: Double
    }

    static func decode(_ data: Data) throws -> Decoded {
        let stream = try parseOgg(data)
        guard stream.packets.count >= 2 else {
            throw VelaError.audio("Not a valid Ogg-Opus file")
        }

        // Packet 1: OpusHead — channel count and pre-skip (encoder priming samples
        // that must be dropped from the decoded output).
        let head = stream.packets[0]
        guard head.count >= 19, head.prefix(8).elementsEqual("OpusHead".utf8) else {
            throw VelaError.audio("Not an Opus file (missing OpusHead)")
        }
        let channels = Int(head[9])
        let preSkip = Int(head[10]) | (Int(head[11]) << 8)
        guard channels == 1 || channels == 2 else {
            throw VelaError.audio("Unsupported Opus channel layout (\(channels) channels)")
        }

        // Packet 2 is OpusTags (metadata); audio packets follow.
        let audioPackets = Array(stream.packets.dropFirst(2))
        guard !audioPackets.isEmpty else { throw VelaError.audio("No audio in file") }

        var samples = try decodePackets(audioPackets, channels: channels)

        // Trim priming samples, and trailing encoder padding when the final
        // granule position (total valid samples incl. pre-skip) is known.
        let skipSamples = preSkip * channels
        if samples.count > skipSamples {
            samples.removeFirst(skipSamples)
        }
        if stream.finalGranule > UInt64(preSkip) {
            let valid = Int(stream.finalGranule) - preSkip
            if samples.count > valid * channels {
                samples.removeLast(samples.count - valid * channels)
            }
        }
        return Decoded(samples: samples, channels: channels, sampleRate: 48_000)
    }

    // MARK: Ogg container

    private struct OggStream {
        var packets: [Data] = []
        /// Granule position of the last page = total 48 kHz samples incl. pre-skip.
        var finalGranule: UInt64 = 0
    }

    private static func parseOgg(_ data: Data) throws -> OggStream {
        // Data slices keep original indices; rebase to 0 for arithmetic below.
        let bytes = [UInt8](data)
        guard bytes.count > 27, bytes[0...3].elementsEqual("OggS".utf8) else {
            throw VelaError.audio("Not an Ogg file")
        }

        var stream = OggStream()
        var packet = Data()
        var offset = 0

        while offset + 27 <= bytes.count {
            guard bytes[offset..<(offset + 4)].elementsEqual("OggS".utf8) else {
                throw VelaError.audio("Corrupt Ogg page at byte \(offset)")
            }
            var granule: UInt64 = 0
            for i in 0..<8 {
                granule |= UInt64(bytes[offset + 6 + i]) << (8 * i)
            }
            let segmentCount = Int(bytes[offset + 26])
            let tableStart = offset + 27
            guard tableStart + segmentCount <= bytes.count else { break }

            var body = tableStart + segmentCount
            for i in 0..<segmentCount {
                let lacing = Int(bytes[tableStart + i])
                guard body + lacing <= bytes.count else {
                    throw VelaError.audio("Truncated Ogg file")
                }
                packet.append(contentsOf: bytes[body..<(body + lacing)])
                body += lacing
                // A lacing value < 255 terminates the packet; 255 means it
                // continues in the next segment (possibly on the next page).
                if lacing < 255 {
                    stream.packets.append(packet)
                    packet = Data()
                }
            }
            // -1 granule (all bits set) marks a page with no completed packet.
            if granule != UInt64.max {
                stream.finalGranule = granule
            }
            offset = body
        }
        return stream
    }

    // MARK: Opus packets → PCM via CoreAudio

    /// Feeds one Opus packet per converter callback. Packet bytes live in one
    /// manually-allocated contiguous buffer so the pointers handed to the
    /// converter stay valid for the whole decode.
    private final class PacketFeeder {
        let buffer: UnsafeMutablePointer<UInt8>
        let ranges: [(offset: Int, size: Int)]
        let description: UnsafeMutablePointer<AudioStreamPacketDescription>
        var index = 0

        init(packets: [Data]) {
            let total = packets.reduce(0) { $0 + $1.count }
            let storage = UnsafeMutablePointer<UInt8>.allocate(capacity: max(total, 1))
            var ranges: [(Int, Int)] = []
            ranges.reserveCapacity(packets.count)
            var offset = 0
            for packet in packets {
                ranges.append((offset, packet.count))
                packet.withUnsafeBytes { raw in
                    guard let base = raw.baseAddress else { return }
                    (storage + offset).update(from: base.assumingMemoryBound(to: UInt8.self), count: packet.count)
                }
                offset += packet.count
            }
            buffer = storage
            self.ranges = ranges
            description = .allocate(capacity: 1)
            description.initialize(to: AudioStreamPacketDescription())
        }

        deinit {
            buffer.deallocate()
            description.deallocate()
        }
    }


    private static func decodePackets(_ packets: [Data], channels: Int) throws -> [Float] {
        var inDesc = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatOpus,
            mFormatFlags: 0,
            mBytesPerPacket: 0,
            // 0 = variable, decoder reads each packet's frame count from its TOC.
            // Never declare a fixed value: WhatsApp packs 120 ms per packet
            // (6 × 20 ms SILK frames) and Apple's converter rejects any fixed
            // framesPerPacket above 2880 — and rejects the data as 'bada' when
            // packets exceed the declared size.
            mFramesPerPacket: 0,
            mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 0,
            mReserved: 0
        )
        var outDesc = AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: UInt32(4 * channels),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(4 * channels),
            mChannelsPerFrame: UInt32(channels),
            mBitsPerChannel: 32,
            mReserved: 0
        )

        var converterRef: AudioConverterRef?
        let createStatus = AudioConverterNew(&inDesc, &outDesc, &converterRef)
        guard createStatus == noErr, let converter = converterRef else {
            throw VelaError.audio("Opus decoder unavailable (error \(createStatus))")
        }
        defer { AudioConverterDispose(converter) }

        let feeder = PacketFeeder(packets: packets)
        let feederRef = Unmanaged.passUnretained(feeder).toOpaque()

        let inputProc: AudioConverterComplexInputDataProc = { _, ioNumberDataPackets, ioData, outPacketDescription, inUserData in
            let feeder = Unmanaged<PacketFeeder>.fromOpaque(inUserData!).takeUnretainedValue()
            guard feeder.index < feeder.ranges.count else {
                ioNumberDataPackets.pointee = 0
                return oggOpusNoMorePackets
            }
            let (offset, size) = feeder.ranges[feeder.index]
            feeder.index += 1

            ioData.pointee.mNumberBuffers = 1
            ioData.pointee.mBuffers.mData = UnsafeMutableRawPointer(feeder.buffer + offset)
            ioData.pointee.mBuffers.mDataByteSize = UInt32(size)
            ioData.pointee.mBuffers.mNumberChannels = 0

            feeder.description.pointee = AudioStreamPacketDescription(
                mStartOffset: 0,
                mVariableFramesInPacket: 0,
                mDataByteSize: UInt32(size)
            )
            outPacketDescription?.pointee = feeder.description
            ioNumberDataPackets.pointee = 1
            return noErr
        }

        var output: [Float] = []
        // Rough capacity: 20 ms per packet is the common case.
        output.reserveCapacity(packets.count * 960 * channels)
        let chunkFrames = 48_000 // 1 s of output per pull
        var chunk = [Float](repeating: 0, count: chunkFrames * channels)

        while true {
            var ioPackets = UInt32(chunkFrames)
            let produced: UInt32 = try chunk.withUnsafeMutableBufferPointer { out in
                var list = AudioBufferList(
                    mNumberBuffers: 1,
                    mBuffers: AudioBuffer(
                        mNumberChannels: UInt32(channels),
                        mDataByteSize: UInt32(out.count * 4),
                        mData: UnsafeMutableRawPointer(out.baseAddress)
                    )
                )
                let status = AudioConverterFillComplexBuffer(converter, inputProc, feederRef, &ioPackets, &list, nil)
                guard status == noErr || status == oggOpusNoMorePackets else {
                    throw VelaError.audio("Opus decode failed (error \(status))")
                }
                return ioPackets
            }
            if produced > 0 {
                output.append(contentsOf: chunk[0..<(Int(produced) * channels)])
            }
            if produced < UInt32(chunkFrames) { break } // drained
        }
        return output
    }
}
