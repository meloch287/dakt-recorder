import Foundation
import AVFoundation

/// Запись микрофона через AVAudioEngine: выбранное устройство, фильтр низких
/// частот и шумодав по желанию.
final class MicCapture {
    struct Options {
        var deviceUID: String = ""
        var highPassFilter: Bool = false
        var noiseGate: Bool = false
        var compressed: Bool = false
    }

    private let engine = AVAudioEngine()
    private let equalizer = AVAudioUnitEQ(numberOfBands: 1)
    private let queue = DispatchQueue(label: "recorder.mic")
    private let writer: PCMWriter
    private let options: Options
    private var tapNode: AVAudioNode?

    /// Читается из аудиопотока, пишется из главного: запись/чтение Bool атомарны,
    /// а точность момента паузы до буфера здесь не важна.
    var isPaused = false

    private(set) var startHostSeconds: Double?

    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    var frameCount: AVAudioFramePosition { writer.frameCount }
    var fileURL: URL { writer.url }

    init(url: URL, options: Options) {
        self.options = options
        writer = PCMWriter(url: url, compressed: options.compressed)
        writer.onError = { [weak self] in self?.onError?($0) }
        writer.onLevel = { [weak self] in self?.onLevel?($0) }
    }

    func start() throws {
        try AudioDevices.apply(uid: options.deviceUID, to: engine)

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw RecorderError.message("Микрофон недоступен. Проверьте входное устройство в системных настройках звука.")
        }

        let node: AVAudioNode
        if options.highPassFilter {
            let band = equalizer.bands[0]
            band.filterType = .highPass
            band.frequency = 90
            band.bypass = false
            engine.attach(equalizer)
            engine.connect(input, to: equalizer, format: format)
            // Графу нужен потребитель на выходе; громкость микшера ноль,
            // поэтому свой же голос в колонки не попадает и эха нет.
            engine.connect(equalizer, to: engine.mainMixerNode, format: format)
            engine.mainMixerNode.outputVolume = 0
            node = equalizer
        } else {
            node = input
        }

        node.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, when in
            guard let self, !self.isPaused, let copy = buffer.deepCopy() else { return }
            if self.options.noiseGate {
                copy.applyNoiseGate(threshold: 0.02)
            }
            let hostSeconds = AVAudioTime.seconds(forHostTime: when.hostTime)
            self.queue.async {
                if self.startHostSeconds == nil { self.startHostSeconds = hostSeconds }
                self.writer.write(copy)
            }
        }
        tapNode = node

        engine.prepare()
        try engine.start()
    }

    func stop() {
        tapNode?.removeTap(onBus: 0)
        tapNode = nil
        if engine.isRunning { engine.stop() }
        queue.sync { writer.close() }
    }
}
