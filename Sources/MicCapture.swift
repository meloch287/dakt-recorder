import Foundation
import AVFoundation

/// Запись микрофона (твой голос) через AVAudioEngine.
final class MicCapture {
    private let engine = AVAudioEngine()
    private let queue = DispatchQueue(label: "recorder.mic")
    private let writer: PCMWriter
    private var tapped = false

    private(set) var startHostSeconds: Double?

    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    var frameCount: AVAudioFramePosition { writer.frameCount }
    var fileURL: URL { writer.url }

    init(url: URL) {
        writer = PCMWriter(url: url)
        writer.onError = { [weak self] in self?.onError?($0) }
        writer.onLevel = { [weak self] in self?.onLevel?($0) }
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.message("Микрофон недоступен. Проверьте входное устройство в системных настройках звука.")
        }

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, let copy = buffer.deepCopy() else { return }
            let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            self.queue.async {
                if self.startHostSeconds == nil { self.startHostSeconds = hostSeconds }
                self.writer.write(copy)
            }
        }
        tapped = true
        engine.prepare()
        try engine.start()
    }

    func stop() {
        if tapped {
            engine.inputNode.removeTap(onBus: 0)
            tapped = false
        }
        if engine.isRunning { engine.stop() }
        queue.sync { writer.close() }
    }
}
