import Foundation
import Combine

/// Всё, что настраивается через шестерёнку. Значения переживают перезапуск.
/// @AppStorage здесь не подходит: внутри ObservableObject он не рассылает
/// изменения, и зависимые части интерфейса не обновлялись бы.
@MainActor
final class Preferences: ObservableObject {
    enum Source: String, CaseIterable, Identifiable {
        case system
        case application

        var id: String { rawValue }
        var title: String {
            switch self {
            case .system: return "Вся система"
            case .application: return "Одно приложение"
            }
        }
    }

    private let defaults = UserDefaults.standard

    @Published var inputDeviceUID: String { didSet { save(inputDeviceUID, "inputDeviceUID") } }
    @Published var source: Source { didSet { save(source.rawValue, "source") } }
    @Published var targetBundleID: String { didSet { save(targetBundleID, "targetBundleID") } }

    @Published var highPassFilter: Bool { didSet { save(highPassFilter, "highPassFilter") } }
    @Published var noiseGate: Bool { didSet { save(noiseGate, "noiseGate") } }
    @Published var normalizeTracks: Bool { didSet { save(normalizeTracks, "normalizeTracks") } }

    @Published var compressRawTracks: Bool { didSet { save(compressRawTracks, "compressRawTracks") } }
    @Published var removeRawAfterMix: Bool { didSet { save(removeRawAfterMix, "removeRawAfterMix") } }

    @Published var autoStopOnSilence: Bool { didSet { save(autoStopOnSilence, "autoStopOnSilence") } }
    @Published var silenceMinutes: Int { didSet { save(silenceMinutes, "silenceMinutes") } }

    @Published var transcribe: Bool { didSet { save(transcribe, "transcribe") } }
    @Published var transcriptionLocale: String { didSet { save(transcriptionLocale, "transcriptionLocale") } }

    @Published var showMenuBarItem: Bool { didSet { save(showMenuBarItem, "showMenuBarItem") } }
    @Published var globalHotKeyEnabled: Bool { didSet { save(globalHotKeyEnabled, "globalHotKeyEnabled") } }

    init() {
        let defaults = UserDefaults.standard
        inputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        source = Source(rawValue: defaults.string(forKey: "source") ?? "") ?? .system
        targetBundleID = defaults.string(forKey: "targetBundleID") ?? ""
        highPassFilter = defaults.bool(forKey: "highPassFilter")
        noiseGate = defaults.bool(forKey: "noiseGate")
        normalizeTracks = defaults.object(forKey: "normalizeTracks") as? Bool ?? true
        compressRawTracks = defaults.bool(forKey: "compressRawTracks")
        removeRawAfterMix = defaults.bool(forKey: "removeRawAfterMix")
        autoStopOnSilence = defaults.bool(forKey: "autoStopOnSilence")
        silenceMinutes = defaults.object(forKey: "silenceMinutes") as? Int ?? 5
        transcribe = defaults.bool(forKey: "transcribe")
        transcriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "ru-RU"
        showMenuBarItem = defaults.object(forKey: "showMenuBarItem") as? Bool ?? true
        globalHotKeyEnabled = defaults.object(forKey: "globalHotKeyEnabled") as? Bool ?? true
    }

    /// Расширение сырых дорожек зависит от того, сжимаем ли мы их на ходу.
    var rawExtension: String { compressRawTracks ? "m4a" : "caf" }

    static let locales: [(code: String, title: String)] = [
        ("ru-RU", "Русский"),
        ("en-US", "English"),
        ("de-DE", "Deutsch"),
        ("es-ES", "Español"),
        ("fr-FR", "Français")
    ]

    private func save(_ value: Any, _ key: String) {
        defaults.set(value, forKey: key)
    }
}
