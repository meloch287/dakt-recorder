import Foundation
import AVFoundation
import AppKit

@MainActor
final class RecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Готов к записи"
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var lastMix: URL?
    @Published var errorMessage: String?

    /// Микрофон и системный звук складываются, поэтому каждой дорожке оставляем запас
    /// по громкости — иначе одновременная речь уходит в лимитер.
    private let trackGain: Float = 0.8

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var folder: URL?
    private var timer: Timer?
    private var startDate: Date?

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    // MARK: - Управление

    func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    /// Вызывается при выходе из приложения: дописывает файлы и сводит дорожки,
    /// чтобы запись не потерялась.
    func finishBeforeTermination() async {
        guard isRecording else { return }
        await stop()
    }

    private func start() async {
        guard !isRecording, !isBusy else { return }
        isBusy = true
        defer { isBusy = false }
        errorMessage = nil
        status = "Запрашиваю доступ…"

        guard await requestMicrophoneAccess() else {
            status = "Готов к записи"
            errorMessage = "Нет доступа к микрофону. Системные настройки → Конфиденциальность и безопасность → Микрофон."
            return
        }

        do {
            let folder = try makeFolder()
            self.folder = folder

            let mic = MicCapture(url: folder.appendingPathComponent("mic.caf"))
            mic.onError = { [weak self] text in Task { @MainActor in self?.errorMessage = text } }
            mic.onLevel = { [weak self] level in Task { @MainActor in self?.micLevel = level } }
            try mic.start()
            self.mic = mic

            let system = SystemAudioCapture(url: folder.appendingPathComponent("system.caf"))
            system.onError = { [weak self] text in Task { @MainActor in self?.errorMessage = text } }
            system.onLevel = { [weak self] level in Task { @MainActor in self?.systemLevel = level } }
            try await system.start()
            self.system = system

            isRecording = true
            startDate = Date()
            elapsed = 0
            status = "Идёт запись: микрофон + системный звук"
            startTimer()
        } catch {
            mic?.stop()
            mic = nil
            await system?.stop()
            system = nil
            discardEmptyFolder()
            status = "Готов к записи"
            errorMessage = describe(error)
        }
    }

    private func stop() async {
        guard isRecording, !isBusy else { return }
        isBusy = true
        isRecording = false
        stopTimer()
        status = "Сохраняю…"
        micLevel = 0
        systemLevel = 0

        let mic = self.mic
        let system = self.system
        let folder = self.folder
        self.mic = nil
        self.system = nil
        self.folder = nil

        mic?.stop()
        await system?.stop()

        guard let folder else {
            isBusy = false
            status = "Готов к записи"
            return
        }

        let micStart = mic?.startHostSeconds
        let systemStart = system?.startHostSeconds
        let base = [micStart, systemStart].compactMap { $0 }.min() ?? 0

        var sources: [MixSource] = []
        if let mic, mic.frameCount > 0 {
            sources.append(MixSource(url: mic.fileURL, startOffset: (micStart ?? base) - base, gain: trackGain))
        }
        if let system, system.frameCount > 0 {
            sources.append(MixSource(url: system.fileURL, startOffset: (systemStart ?? base) - base, gain: trackGain))
        }

        let hasSystemAudio = (system?.frameCount ?? 0) > 0
        let output = folder.appendingPathComponent("mix.m4a")

        do {
            let written = try await Task.detached(priority: .userInitiated) {
                try Mixdown.mix(sources: sources, to: output)
            }.value
            lastMix = written
            errorMessage = nil
            status = hasSystemAudio
                ? "Готово: \(folder.lastPathComponent)"
                : "Готово, но системный звук пустой — проверь разрешение на запись экрана"
        } catch {
            errorMessage = describe(error)
            status = "Готов к записи"
        }
        isBusy = false
    }

    func revealLastRecording() {
        guard let lastMix else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastMix])
    }

    // MARK: - Служебное

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeFolder() throws -> URL {
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingRecorder", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Если запись не стартовала, пустая папка на диске не нужна.
    private func discardEmptyFolder() {
        guard let folder else { return }
        self.folder = nil
        let contents = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
        if contents?.isEmpty ?? false {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let start = self.startDate else { return }
                self.elapsed = Date().timeIntervalSince(start)
                // Индикаторы плавно опадают, если звука нет.
                self.micLevel *= 0.6
                self.systemLevel *= 0.6
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    private func describe(_ error: Error) -> String {
        if let recorderError = error as? RecorderError {
            return recorderError.localizedDescription
        }
        let nsError = error as NSError
        if nsError.domain.contains("SCStream") {
            return "Нет доступа к записи экрана и системного звука. Открой Системные настройки → Конфиденциальность и безопасность → Запись экрана, включи MeetingRecorder и перезапусти приложение."
        }
        return nsError.localizedDescription
    }
}
