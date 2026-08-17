import Foundation
import AVFoundation

enum RecorderError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let text): return text }
    }
}

struct MixSource {
    let url: URL
    /// Сдвиг начала дорожки относительно самой ранней дорожки, в секундах.
    let startOffset: Double
    let gain: Float
}

/// Складывает дорожки в один стерео-файл, выравнивая их по времени старта.
enum Mixdown {
    static func mix(sources: [MixSource], to output: URL) throws {
        struct Track {
            let file: AVAudioFile
            let offset: AVAudioFramePosition
            let length: AVAudioFramePosition
            let channels: Int
            let gain: Float
        }

        var tracks: [Track] = []
        for source in sources {
            let file = try AVAudioFile(forReading: source.url)
            guard file.length > 0 else { continue }
            tracks.append(Track(
                file: file,
                offset: AVAudioFramePosition((source.startOffset * Canonical.sampleRate).rounded()),
                length: file.length,
                channels: Int(file.processingFormat.channelCount),
                gain: source.gain
            ))
        }
        guard !tracks.isEmpty else {
            throw RecorderError.message("Обе дорожки пустые — звук не записался.")
        }

        let total = tracks.map { $0.offset + $0.length }.max() ?? 0
        let mixFormat = Canonical.format(channels: 2)
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Canonical.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]
        let out = try AVAudioFile(forWriting: output, settings: settings)

        let chunk: AVAudioFrameCount = 16_384
        guard let mixBuffer = AVAudioPCMBuffer(pcmFormat: mixFormat, frameCapacity: chunk),
              let mixChannels = mixBuffer.floatChannelData else {
            throw RecorderError.message("Не удалось выделить буфер для микширования.")
        }

        var position: AVAudioFramePosition = 0
        while position < total {
            let frames = AVAudioFrameCount(min(AVAudioFramePosition(chunk), total - position))
            mixBuffer.frameLength = frames
            for ch in 0..<2 {
                memset(mixChannels[ch], 0, Int(frames) * MemoryLayout<Float>.size)
            }

            for track in tracks {
                let dstStart = max(0, track.offset - position)
                let readStart = max(0, position - track.offset)
                if readStart >= track.length { continue }
                let count = min(AVAudioFramePosition(frames) - dstStart, track.length - readStart)
                if count <= 0 { continue }

                guard let tmp = AVAudioPCMBuffer(pcmFormat: track.file.processingFormat,
                                                 frameCapacity: AVAudioFrameCount(count)) else { continue }
                track.file.framePosition = readStart
                try track.file.read(into: tmp, frameCount: AVAudioFrameCount(count))
                guard let src = tmp.floatChannelData, tmp.frameLength > 0 else { continue }
                let read = Int(tmp.frameLength)

                for ch in 0..<2 {
                    let srcChannel = src[min(ch, track.channels - 1)]
                    let dstChannel = mixChannels[ch] + Int(dstStart)
                    for i in 0..<read {
                        dstChannel[i] += srcChannel[i] * track.gain
                    }
                }
            }

            // Мягкое ограничение, чтобы сумма двух дорожек не клиппировала.
            for ch in 0..<2 {
                let p = mixChannels[ch]
                for i in 0..<Int(frames) {
                    p[i] = max(-1, min(1, p[i]))
                }
            }

            try out.write(from: mixBuffer)
            position += AVAudioFramePosition(frames)
        }
    }
}
