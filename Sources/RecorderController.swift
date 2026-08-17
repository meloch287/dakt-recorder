import Foundation
import AVFoundation
import AppKit

@MainActor
final class RecorderController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isPaused = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Готов к записи"
    @Published private(set) var lastMix: URL?
    @Published private(set) var freeSpaceText = ""
    /// Папки, где остались сырые дорожки без сведения — например после падения.
    @Published private(set) var unfinished: [URL] = []
    @Published var errorMessage: String?

    let preferences: Preferences
    let meter = RecordingMeter()

    /// Микрофон и системный звук складываются, поэтому каждой дорожке оставляем запас
    /// по громкости — иначе одновременная речь уходит в лимитер.
    private let trackGain: Float = 0.8

    private var mic: MicCapture?
    private var system: SystemAudioCapture?
    private var folder: URL?
    private var timer: Timer?
    private var startDate: Date?
    private var pausedTotal: TimeInterval = 0
    private var pauseStarted: Date?
    private var lastLoudDate: Date?

    init(preferences: Preferences) {
        self.preferences = preferences
        refreshFreeSpace()
        refreshUnfinished()
    }

    // MARK: - Управление

    func toggle() {
        if isRecording {
            Task { await stop() }
        } else {
            Task { await start() }
        }
    }

    func togglePause() {
        guard isRecording else { return }
        isPaused.toggle()
        mic?.isPaused = isPaused
        system?.isPaused = isPaused
        if isPaused {
            pauseStarted = Date()
            status = "Пауза"
            meter.reset()
        } else {
            if let pauseStarted {
                pausedTotal += Date().timeIntervalSince(pauseStarted)
            }
            pauseStarted = nil
            lastLoudDate = Date()
            status = "Идёт запись"
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
        if preferences.transcribe {
            let granted = await Transcription.requestAuthorization()
            if !granted {
                errorMessage = "Нет доступа к распознаванию речи — запись пойдёт без расшифровки."
            }
        }

        do {
            let folder = try makeFolder()
            self.folder = folder
            let ext = preferences.rawExtension

            var options = MicCapture.Options()
            options.deviceUID = preferences.inputDeviceUID
            options.highPassFilter = preferences.highPassFilter
            options.noiseGate = preferences.noiseGate
            options.compressed = preferences.compressRawTracks

            let mic = MicCapture(url: folder.appendingPathComponent("mic.\(ext)"), options: options)
            mic.onError = { [weak self] text in Task { @MainActor in self?.errorMessage = text } }
            mic.onLevel = { [weak self] level in Task { @MainActor in self?.meter.report(mic: level) } }
            try mic.start()
            self.mic = mic

            let system = SystemAudioCapture(
                url: folder.appendingPathComponent("system.\(ext)"),
                targetBundleID: preferences.source == .application ? preferences.targetBundleID : "",
                compressed: preferences.compressRawTracks)
            system.onError = { [weak self] text in Task { @MainActor in self?.errorMessage = text } }
            system.onLevel = { [weak self] level in Task { @MainActor in self?.meter.report(system: level) } }
            try await system.start()
            self.system = system

            isRecording = true
            isPaused = false
            startDate = Date()
            pausedTotal = 0
            pauseStarted = nil
            lastLoudDate = Date()
            meter.reset()
            status = "Идёт запись"
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
        isPaused = false
        stopTimer()
        status = "Сохраняю…"
        meter.reset()

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
        await finish(folder: folder, sources: sources, warnAboutSystemAudio: !hasSystemAudio)
        isBusy = false
    }

    /// Сводит дорожки, при желании расшифровывает и подчищает сырые файлы.
    private func finish(folder: URL, sources: [MixSource], warnAboutSystemAudio: Bool) async {
        let output = folder.appendingPathComponent("mix.m4a")
        let normalize = preferences.normalizeTracks
        do {
            let written = try await Task.detached(priority: .userInitiated) {
                try Mixdown.mix(sources: sources, to: output, normalize: normalize)
            }.value
            lastMix = written
            errorMessage = nil
            status = warnAboutSystemAudio
                ? "Готово, но системный звук пустой — проверьте разрешение на запись экрана"
                : "Готово: \(folder.lastPathComponent)"

            if preferences.transcribe {
                await transcribe(folder: folder, sources: sources)
            }
            if preferences.removeRawAfterMix {
                for source in sources {
                    try? FileManager.default.removeItem(at: source.url)
                }
            }
        } catch {
            errorMessage = describe(error)
            status = "Готов к записи"
        }
        refreshFreeSpace()
        refreshUnfinished()
    }

    private func transcribe(folder: URL, sources: [MixSource]) async {
        status = "Расшифровываю…"
        let mic = sources.first { $0.url.lastPathComponent.hasPrefix("mic") }?.url
        let system = sources.first { $0.url.lastPathComponent.hasPrefix("system") }?.url
        let output = folder.appendingPathComponent("transcript.txt")
        let locale = preferences.transcriptionLocale
        do {
            try await Transcription.makeTranscript(mic: mic, system: system, locale: locale, to: output)
            status = "Готово с расшифровкой: \(folder.lastPathComponent)"
        } catch {
            errorMessage = "Расшифровка не удалась: \(describe(error))"
        }
    }

    /// Собирает mix из сырых дорожек папки, оставшейся после падения или выключения.
    func recover(folder: URL) async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        status = "Собираю запись из сырых дорожек…"
        var sources: [MixSource] = []
        for name in ["mic", "system"] {
            for ext in ["caf", "m4a"] {
                let url = folder.appendingPathComponent("\(name).\(ext)")
                if FileManager.default.fileExists(atPath: url.path) {
                    // Время старта после падения неизвестно, поэтому дорожки
                    // выравниваются по нулю — расхождение в пределах пары буферов.
                    sources.append(MixSource(url: url, startOffset: 0, gain: trackGain))
                }
            }
        }
        if sources.isEmpty {
            errorMessage = "В папке \(folder.lastPathComponent) нет сырых дорожек."
            status = "Готов к записи"
        } else {
            await finish(folder: folder, sources: sources, warnAboutSystemAudio: false)
        }
        isBusy = false
    }

    func revealLastRecording() {
        guard let lastMix else { return }
        NSWorkspace.shared.activateFileViewerSelecting([lastMix])
    }

    func openRecordingsFolder() {
        NSWorkspace.shared.open(Self.root)
    }

    // MARK: - Служебное

    static var root: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DaktRecorder", isDirectory: true)
    }

    func refreshFreeSpace() {
        let values = try? Self.root.deletingLastPathComponent()
            .resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        guard let bytes = values?.volumeAvailableCapacityForImportantUsage else {
            freeSpaceText = ""
            return
        }
        let gigabytes = Double(bytes) / 1_000_000_000
        // Сырые дорожки съедают около 2 ГБ в час, поэтому переводим место в часы записи.
        let hours = gigabytes / 2
        freeSpaceText = String(format: "Свободно %.0f ГБ — примерно %.0f ч записи", gigabytes, hours)
    }

    func refreshUnfinished() {
        let manager = FileManager.default
        guard let folders = try? manager.contentsOfDirectory(at: Self.root,
                                                            includingPropertiesForKeys: nil) else {
            unfinished = []
            return
        }
        unfinished = folders.filter { folder in
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { return false }
            let names = (try? manager.contentsOfDirectory(atPath: folder.path)) ?? []
            let hasRaw = names.contains { $0.hasPrefix("mic.") || $0.hasPrefix("system.") }
            let hasMix = names.contains { $0.hasPrefix("mix.") }
            return hasRaw && !hasMix
        }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private func requestMicrophoneAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    private func makeFolder() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let folder = Self.root.appendingPathComponent(formatter.string(from: Date()), isDirectory: true)
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
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let start = startDate else { return }
        if !isPaused {
            meter.setElapsed(Date().timeIntervalSince(start) - pausedTotal)
            if meter.isLoud {
                lastLoudDate = Date()
            }
            checkSilence()
        }
        // Индикаторы плавно опадают, если звука нет.
        meter.decay()
    }

    private func checkSilence() {
        guard preferences.autoStopOnSilence, let lastLoudDate else { return }
        let limit = TimeInterval(max(1, preferences.silenceMinutes) * 60)
        guard Date().timeIntervalSince(lastLoudDate) > limit else { return }
        status = "Тишина \(preferences.silenceMinutes) мин — останавливаю запись"
        Task { await stop() }
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
            return "Нет доступа к записи экрана и системного звука. Откройте Системные настройки → Конфиденциальность и безопасность → Запись экрана, включите DaktRecorder и перезапустите приложение."
        }
        return nsError.localizedDescription
    }
}
