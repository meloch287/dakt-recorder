import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Захват системного звука (всё, что звучит из колонок/наушников — т.е. голоса в Zoom)
/// через ScreenCaptureKit. Никаких виртуальных аудиодрайверов не требуется.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let audioQueue = DispatchQueue(label: "recorder.system.audio")
    private let videoQueue = DispatchQueue(label: "recorder.system.video")
    private var stream: SCStream?
    private let writer: PCMWriter

    /// Момент первого сэмпла в секундах хост-таймера — нужен для синхронизации дорожек.
    private(set) var startHostSeconds: Double?

    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    var frameCount: AVAudioFramePosition { writer.frameCount }
    var fileURL: URL { writer.url }

    init(url: URL) {
        writer = PCMWriter(url: url)
        super.init()
        writer.onError = { [weak self] in self?.onError?($0) }
        writer.onLevel = { [weak self] in self?.onLevel?($0) }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecorderError.message("Не найден дисплей — системный звук захватить нельзя.")
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = Int(Canonical.sampleRate)
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // Видео нам не нужно, но поток требует валидной конфигурации: минимальный кадр раз в секунду.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.queueDepth = 6

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: videoQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        if let stream {
            try? await stream.stopCapture()
        }
        stream = nil
        audioQueue.sync { writer.close() }
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              var asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              let format = AVAudioFormat(streamDescription: &asbd) else { return }

        if startHostSeconds == nil {
            startHostSeconds = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
        }

        try? sampleBuffer.withAudioBufferList { list, _ in
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer) else { return }
            writer.write(pcm)
        }
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?("Захват системного звука остановлен: \(error.localizedDescription)")
    }
}
