import Foundation

/// Уровни и таймер обновляются десятки раз в секунду. Держать их в контроллере
/// нельзя: его слушает сцена приложения, и строка меню пересобиралась бы на
/// каждом аудиобуфере — окно начинало подвисать. Здесь их слушает только окно.
@MainActor
final class RecordingMeter: ObservableObject {
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var elapsed: TimeInterval = 0

    var elapsedText: String {
        let total = Int(elapsed)
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }

    func report(mic: Float) { micLevel = mic }
    func report(system: Float) { systemLevel = system }
    func setElapsed(_ value: TimeInterval) { elapsed = value }

    func decay() {
        micLevel *= 0.6
        systemLevel *= 0.6
    }

    func reset() {
        micLevel = 0
        systemLevel = 0
        elapsed = 0
    }

    var isLoud: Bool { micLevel > 0.02 || systemLevel > 0.02 }
}
