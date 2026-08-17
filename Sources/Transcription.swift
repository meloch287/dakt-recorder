import Foundation
import Speech

/// Расшифровка дорожек встроенным распознавателем macOS. Модели скачивать не нужно,
/// распознавание идёт на устройстве, если система это поддерживает для языка.
enum Transcription {
    struct Line {
        let start: TimeInterval
        let speaker: String
        let text: String
    }

    static func requestAuthorization() async -> Bool {
        if SFSpeechRecognizer.authorizationStatus() == .authorized { return true }
        return await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }

    /// Сводит расшифровки двух дорожек в один текст с ролями, отсортированный по времени.
    static func makeTranscript(mic: URL?, system: URL?, locale: String, to output: URL) async throws {
        var lines: [Line] = []
        if let mic {
            lines += try await recognize(url: mic, speaker: "Я", locale: locale)
        }
        if let system {
            lines += try await recognize(url: system, speaker: "Собеседник", locale: locale)
        }
        guard !lines.isEmpty else {
            throw RecorderError.message("Распознаватель не нашёл речи в записи.")
        }

        let sorted = lines.sorted { $0.start < $1.start }
        var text = ""
        var lastSpeaker = ""
        for line in sorted {
            if line.speaker != lastSpeaker {
                text += "\n\(timecode(line.start)) \(line.speaker):\n"
                lastSpeaker = line.speaker
            }
            text += line.text + " "
        }
        try text.trimmingCharacters(in: .whitespacesAndNewlines)
            .appending("\n")
            .write(to: output, atomically: true, encoding: .utf8)
    }

    private static func recognize(url: URL, speaker: String, locale: String) async throws -> [Line] {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale)) else {
            throw RecorderError.message("Язык \(locale) не поддерживается распознавателем.")
        }
        guard recognizer.isAvailable else {
            throw RecorderError.message("Распознаватель недоступен: нужен интернет либо загруженный языковой пакет.")
        }

        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }

        let transcription: SFTranscription = try await withCheckedThrowingContinuation { continuation in
            var finished = false
            recognizer.recognitionTask(with: request) { result, error in
                guard !finished else { return }
                if let error {
                    finished = true
                    continuation.resume(throwing: error)
                    return
                }
                if let result, result.isFinal {
                    finished = true
                    continuation.resume(returning: result.bestTranscription)
                }
            }
        }

        // Сегменты склеиваем в реплики: новая реплика начинается после паузы.
        var lines: [Line] = []
        var current = ""
        var start: TimeInterval = 0
        var previousEnd: TimeInterval = -1
        for segment in transcription.segments {
            if previousEnd < 0 || segment.timestamp - previousEnd > 1.5 {
                if !current.isEmpty {
                    lines.append(Line(start: start, speaker: speaker, text: current))
                }
                current = segment.substring
                start = segment.timestamp
            } else {
                current += " " + segment.substring
            }
            previousEnd = segment.timestamp + segment.duration
        }
        if !current.isEmpty {
            lines.append(Line(start: start, speaker: speaker, text: current))
        }
        return lines
    }

    private static func timecode(_ seconds: TimeInterval) -> String {
        let total = Int(seconds)
        return String(format: "[%02d:%02d:%02d]", total / 3600, (total % 3600) / 60, total % 60)
    }
}
