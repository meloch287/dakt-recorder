import Foundation
import AVFoundation

/// Единый формат, в котором мы храним обе дорожки: 48 кГц, float32, non-interleaved.
enum Canonical {
    static let sampleRate: Double = 48_000

    static func format(channels: AVAudioChannelCount) -> AVAudioFormat {
        AVAudioFormat(standardFormatWithSampleRate: sampleRate,
                      channels: max(1, min(2, channels)))!
    }
}

extension AVAudioPCMBuffer {
    /// Буфер из тапа AVAudioEngine живёт только внутри колбэка — копируем.
    func deepCopy() -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameLength) else { return nil }
        copy.frameLength = frameLength
        let src = UnsafeMutableAudioBufferListPointer(mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let s = src[i].mData, let d = dst[i].mData else { continue }
            let bytes = Int(min(src[i].mDataByteSize, dst[i].mDataByteSize))
            memcpy(d, s, bytes)
            dst[i].mDataByteSize = UInt32(bytes)
        }
        return copy
    }

    var peakLevel: Float {
        guard let data = floatChannelData, frameLength > 0 else { return 0 }
        var peak: Float = 0
        for ch in 0..<Int(format.channelCount) {
            let p = data[ch]
            for i in 0..<Int(frameLength) {
                let v = abs(p[i])
                if v > peak { peak = v }
            }
        }
        return min(1, peak)
    }
}

/// Пишет входящие PCM-буферы в .caf, приводя их к каноническому формату.
final class PCMWriter {
    let url: URL
    private let compressed: Bool
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var stopped = false
    private var reported = false
    private(set) var frameCount: AVAudioFramePosition = 0
    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(url: URL, compressed: Bool = false) {
        self.url = url
        self.compressed = compressed
    }

    /// Вызывать всегда с одной и той же очереди.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard !stopped, buffer.frameLength > 0 else { return }
        if file == nil, !prepare(for: buffer.format) { return }
        guard let file, let targetFormat else { return }

        var out = buffer
        if let converter {
            guard let converted = convert(buffer, with: converter, to: targetFormat) else { return }
            out = converted
        }
        do {
            try file.write(from: out)
            frameCount += AVAudioFramePosition(out.frameLength)
            onLevel?(out.peakLevel)
        } catch {
            report("Ошибка записи \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    func close() {
        file = nil
        converter = nil
    }

    private func prepare(for inputFormat: AVAudioFormat) -> Bool {
        let target = Canonical.format(channels: inputFormat.channelCount)
        let matches = inputFormat.sampleRate == target.sampleRate
            && inputFormat.channelCount == target.channelCount
            && inputFormat.commonFormat == .pcmFormatFloat32
            && !inputFormat.isInterleaved
        if !matches {
            guard let conv = AVAudioConverter(from: inputFormat, to: target) else {
                report("Не удалось создать конвертер \(inputFormat) → \(target)", fatal: true)
                return false
            }
            // Многоканальный вход без явной карты каналов конвертер не принимает:
            // берём первые один-два канала.
            if inputFormat.channelCount > target.channelCount {
                conv.channelMap = (0..<Int(target.channelCount)).map { NSNumber(value: $0) }
            }
            converter = conv
        }
        do {
            file = try AVAudioFile(forWriting: url, settings: fileSettings(for: target))
            targetFormat = target
            return true
        } catch {
            report("Не удалось создать файл \(url.lastPathComponent): \(error.localizedDescription)", fatal: true)
            return false
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer,
                         with converter: AVAudioConverter,
                         to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var error: NSError?
        var fed = false
        let status = converter.convert(to: out, error: &error) { _, outStatus in
            if fed {
                outStatus.pointee = .noDataNow
                return nil
            }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error {
            report("Ошибка конвертации: \(error?.localizedDescription ?? "неизвестно")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }

    /// Сырые дорожки можно писать сжатыми: разница на диске примерно в десять раз.
    private func fileSettings(for format: AVAudioFormat) -> [String: Any] {
        guard compressed else { return format.settings }
        return [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: Int(format.channelCount),
            AVEncoderBitRateKey: 128_000
        ]
    }

    /// Об ошибке сообщаем один раз, иначе интерфейс завалит одним и тем же текстом
    /// на каждом аудиобуфере. Ошибки подготовки фатальны: писать дальше некуда.
    private func report(_ text: String, fatal: Bool = false) {
        if fatal { stopped = true }
        guard !reported else { return }
        reported = true
        onError?(text)
    }
}

extension AVAudioPCMBuffer {
    /// Простой шумодав: тихий буфер целиком превращается в тишину, чтобы дыхание
    /// и гул комнаты не подмешивались в паузах. Длину не меняем — иначе поедет
    /// синхронизация дорожек.
    func applyNoiseGate(threshold: Float) {
        guard peakLevel < threshold, let data = floatChannelData else { return }
        for ch in 0..<Int(format.channelCount) {
            memset(data[ch], 0, Int(frameLength) * MemoryLayout<Float>.size)
        }
    }
}
