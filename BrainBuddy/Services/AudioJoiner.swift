import AVFoundation
import Foundation

/// Joins the pieces of an interrupted recording into one file to play back.
///
/// Decoded and re-encoded rather than stitched at the container level: the
/// pieces are short AAC files written by separate recorders, and decoding them
/// through `PCMReader` copes with any of them differing in format.
enum AudioJoiner {
    /// Mono AAC at 44.1 kHz: speech-quality, small enough that a long note
    /// still syncs to iCloud quickly. An hour lands around 28 MB. Shared with
    /// the recorder, so a joined file is the same kind of file as its pieces.
    static var fileSettings: [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100.0,
            AVNumberOfChannelsKey: 1,
            AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]
    }

    static func join(_ pieces: [URL]) async throws -> URL {
        let sampleRate = 44_100.0
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("voice-\(UUID().uuidString).m4a")
        let reader = try PCMReader(files: pieces, sampleRate: sampleRate)
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false
        ) else { throw RecordingTranscriber.Failure.unreadable("no audio format") }

        do {
            let file = try AVAudioFile(
                forWriting: output,
                settings: fileSettings,
                commonFormat: .pcmFormatFloat32,
                interleaved: false
            )
            while !reader.isFinished {
                let samples = try reader.read(frames: Int(sampleRate) * 10)
                guard !samples.isEmpty,
                      let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
                      let channel = buffer.floatChannelData?[0] else { continue }
                samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
                buffer.frameLength = AVAudioFrameCount(samples.count)
                try file.write(from: buffer)
            }
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
        return output
    }

    /// Length in seconds, read from the file.
    static func duration(of url: URL) -> TimeInterval {
        guard let file = try? AVAudioFile(forReading: url) else { return 0 }
        return Double(file.length) / file.fileFormat.sampleRate
    }
}
