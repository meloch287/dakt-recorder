import Foundation
import AVFoundation
import CoreMedia
import ScreenCaptureKit

/// Захват системного звука через ScreenCaptureKit: либо всё, что звучит в системе,
/// либо только выбранное приложение. Виртуальные аудиодрайверы не нужны.
final class SystemAudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Application: Identifiable, Hashable {
        var id: String { bundleID }
        let bundleID: String
        let name: String
    }

    private let audioQueue = DispatchQueue(label: "recorder.system.audio")
    private let videoQueue = DispatchQueue(label: "recorder.system.video")
    private let writer: PCMWriter
    private let targetBundleID: String
    private var stream: SCStream?

    /// См. комментарий к паузе в MicCapture.
    var isPaused = false

    /// Момент первого сэмпла в секундах хост-таймера — нужен для синхронизации дорожек.
    private(set) var startHostSeconds: Double?

    var onError: ((String) -> Void)?
    var onLevel: ((Float) -> Void)?

    var frameCount: AVAudioFramePosition { writer.frameCount }
    var fileURL: URL { writer.url }

    init(url: URL, targetBundleID: String = "", compressed: Bool = false) {
        self.targetBundleID = targetBundleID
        writer = PCMWriter(url: url, compressed: compressed)
        super.init()
        writer.onError = { [weak self] in self?.onError?($0) }
        writer.onLevel = { [weak self] in self?.onLevel?($0) }
    }

    /// Приложения, которые можно выбрать источником звука.
    static func applications() async throws -> [Application] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        var seen = Set<String>()
        var result: [Application] = []
        for app in content.applications {
            let bundleID = app.bundleIdentifier
            guard !bundleID.isEmpty, seen.insert(bundleID).inserted else { continue }
            let name = app.applicationName.isEmpty ? bundleID : app.applicationName
            result.append(Application(bundleID: bundleID, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func start() async throws {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw RecorderError.message("Не найден дисплей — системный звук захватить нельзя.")
        }

        let filter: SCContentFilter
        if !targetBundleID.isEmpty,
           let app = content.applications.first(where: { $0.bundleIdentifier == targetBundleID }) {
            filter = SCContentFilter(display: display, including: [app], exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        }

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
        guard type == .audio, !isPaused, CMSampleBufferDataIsReady(sampleBuffer) else { return }
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
