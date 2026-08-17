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
    /// Возвращает путь к записанному файлу: m4a, либо wav, если AAC-кодировщик недоступен.
    @discardableResult
    static func mix(sources: [MixSource], to output: URL, normalize: Bool = false) throws -> URL {
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
            var gain = source.gain
            if normalize {
                gain *= levelingGain(for: file)
                file.framePosition = 0
            }
            tracks.append(Track(
                file: file,
                offset: AVAudioFramePosition((source.startOffset * Canonical.sampleRate).rounded()),
                length: file.length,
                channels: Int(file.processingFormat.channelCount),
                gain: gain
            ))
        }
        guard !tracks.isEmpty else {
            throw RecorderError.message("Обе дорожки пустые — звук не записался.")
        }

        let total = tracks.map { $0.offset + $0.length }.max() ?? 0
        let mixFormat = Canonical.format(channels: 2)
        let aacSettings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: Canonical.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 160_000
        ]

        var outputURL = output
        var out: AVAudioFile
        do {
            out = try AVAudioFile(forWriting: output, settings: aacSettings)
        } catch {
            // Кодировщик AAC недоступен — не теряем сведение, пишем WAV рядом.
            outputURL = output.deletingPathExtension().appendingPathExtension("wav")
            out = try AVAudioFile(forWriting: outputURL, settings: mixFormat.settings)
        }

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

            for ch in 0..<2 {
                let p = mixChannels[ch]
                for i in 0..<Int(frames) {
                    p[i] = softLimit(p[i])
                }
            }

            try out.write(from: mixBuffer)
            position += AVAudioFramePosition(frames)
        }
        return outputURL
    }

    /// Ниже порога сигнал не трогаем, выше — плавно поджимаем к единице,
    /// чтобы одновременная речь не превращалась в треск от обрезанных пиков.
    private static let limitThreshold: Float = 0.8

    private static func softLimit(_ x: Float) -> Float {
        let magnitude = abs(x)
        guard magnitude > limitThreshold else { return x }
        let headroom = 1 - limitThreshold
        let shaped = limitThreshold + headroom * tanh((magnitude - limitThreshold) / headroom)
        return x < 0 ? -shaped : shaped
    }
}

extension Mixdown {
    /// Целевая средняя громкость дорожки: примерно −20 dBFS.
    private static var targetRMS: Float { 0.1 }

    /// Считает средний уровень дорожки и возвращает поправку, чтобы тихий
    /// собеседник и громкий микрофон звучали одинаково. Поправка ограничена,
    /// иначе тишина в дорожке вытянется в шум.
    static func levelingGain(for file: AVAudioFile) -> Float {
        let chunk: AVAudioFrameCount = 32_768
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: chunk) else { return 1 }
        let channels = Int(file.processingFormat.channelCount)

        var sum: Double = 0
        var counted: Double = 0
        file.framePosition = 0
        while file.framePosition < file.length {
            do {
                try file.read(into: buffer, frameCount: chunk)
            } catch {
                break
            }
            guard buffer.frameLength > 0, let data = buffer.floatChannelData else { break }
            for ch in 0..<channels {
                let pointer = data[ch]
                for i in 0..<Int(buffer.frameLength) {
                    let value = pointer[i]
                    // Тишину в расчёт не берём, иначе паузы занижают средний уровень.
                    if abs(value) > 0.005 {
                        sum += Double(value * value)
                        counted += 1
                    }
                }
            }
        }
        file.framePosition = 0
        guard counted > 0 else { return 1 }

        let rms = Float((sum / counted).squareRoot())
        guard rms > 0 else { return 1 }
        return min(4, max(0.25, targetRMS / rms))
    }
}
