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
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private(set) var frameCount: AVAudioFramePosition = 0
    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    init(url: URL) { self.url = url }

    /// Вызывать всегда с одной и той же очереди.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
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
            onError?("Ошибка записи \(url.lastPathComponent): \(error.localizedDescription)")
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
                onError?("Не удалось создать конвертер \(inputFormat) → \(target)")
                return false
            }
            converter = conv
        }
        do {
            file = try AVAudioFile(forWriting: url, settings: target.settings)
            targetFormat = target
            return true
        } catch {
            onError?("Не удалось создать файл \(url.lastPathComponent): \(error.localizedDescription)")
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
            onError?("Ошибка конвертации: \(error?.localizedDescription ?? "неизвестно")")
            return nil
        }
        return out.frameLength > 0 ? out : nil
    }
}
