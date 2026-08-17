import Foundation
import Combine

/// Всё, что настраивается через шестерёнку. Значения переживают перезапуск.
///
/// Здесь сознательно нет @Published и @AppStorage. @AppStorage внутри
/// ObservableObject не рассылает изменения вовсе, а @Published рассылает их на
/// каждую запись, даже если значение не изменилось. Второе приводило к
/// зацикливанию: MenuBarExtra пишет в привязку isInserted то же самое значение
/// при каждом обновлении сцены, @Published уведомлял, сцена перестраивалась,
/// MenuBarExtra писал снова — главный поток уходил в бесконечную перерисовку.
/// Поэтому каждый сеттер сам проверяет изменение и только тогда уведомляет.
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

    private var storedInputDeviceUID: String
    private var storedSource: Source
    private var storedTargetBundleID: String
    private var storedHighPassFilter: Bool
    private var storedNoiseGate: Bool
    private var storedNormalizeTracks: Bool
    private var storedCompressRawTracks: Bool
    private var storedRemoveRawAfterMix: Bool
    private var storedAutoStopOnSilence: Bool
    private var storedSilenceMinutes: Int
    private var storedTranscribe: Bool
    private var storedTranscriptionLocale: String
    private var storedShowMenuBarItem: Bool
    private var storedGlobalHotKeyEnabled: Bool

    var inputDeviceUID: String {
        get { storedInputDeviceUID }
        set { update(&storedInputDeviceUID, newValue, "inputDeviceUID") }
    }

    var source: Source {
        get { storedSource }
        set { update(&storedSource, newValue, "source", raw: newValue.rawValue) }
    }

    var targetBundleID: String {
        get { storedTargetBundleID }
        set { update(&storedTargetBundleID, newValue, "targetBundleID") }
    }

    var highPassFilter: Bool {
        get { storedHighPassFilter }
        set { update(&storedHighPassFilter, newValue, "highPassFilter") }
    }

    var noiseGate: Bool {
        get { storedNoiseGate }
        set { update(&storedNoiseGate, newValue, "noiseGate") }
    }

    var normalizeTracks: Bool {
        get { storedNormalizeTracks }
        set { update(&storedNormalizeTracks, newValue, "normalizeTracks") }
    }

    var compressRawTracks: Bool {
        get { storedCompressRawTracks }
        set { update(&storedCompressRawTracks, newValue, "compressRawTracks") }
    }

    var removeRawAfterMix: Bool {
        get { storedRemoveRawAfterMix }
        set { update(&storedRemoveRawAfterMix, newValue, "removeRawAfterMix") }
    }

    var autoStopOnSilence: Bool {
        get { storedAutoStopOnSilence }
        set { update(&storedAutoStopOnSilence, newValue, "autoStopOnSilence") }
    }

    var silenceMinutes: Int {
        get { storedSilenceMinutes }
        set { update(&storedSilenceMinutes, newValue, "silenceMinutes") }
    }

    var transcribe: Bool {
        get { storedTranscribe }
        set { update(&storedTranscribe, newValue, "transcribe") }
    }

    var transcriptionLocale: String {
        get { storedTranscriptionLocale }
        set { update(&storedTranscriptionLocale, newValue, "transcriptionLocale") }
    }

    var showMenuBarItem: Bool {
        get { storedShowMenuBarItem }
        set { update(&storedShowMenuBarItem, newValue, "showMenuBarItem") }
    }

    var globalHotKeyEnabled: Bool {
        get { storedGlobalHotKeyEnabled }
        set { update(&storedGlobalHotKeyEnabled, newValue, "globalHotKeyEnabled") }
    }

    init() {
        let defaults = UserDefaults.standard
        storedInputDeviceUID = defaults.string(forKey: "inputDeviceUID") ?? ""
        storedSource = Source(rawValue: defaults.string(forKey: "source") ?? "") ?? .system
        storedTargetBundleID = defaults.string(forKey: "targetBundleID") ?? ""
        storedHighPassFilter = defaults.bool(forKey: "highPassFilter")
        storedNoiseGate = defaults.bool(forKey: "noiseGate")
        storedNormalizeTracks = defaults.object(forKey: "normalizeTracks") as? Bool ?? true
        storedCompressRawTracks = defaults.bool(forKey: "compressRawTracks")
        storedRemoveRawAfterMix = defaults.bool(forKey: "removeRawAfterMix")
        storedAutoStopOnSilence = defaults.bool(forKey: "autoStopOnSilence")
        storedSilenceMinutes = defaults.object(forKey: "silenceMinutes") as? Int ?? 5
        storedTranscribe = defaults.bool(forKey: "transcribe")
        storedTranscriptionLocale = defaults.string(forKey: "transcriptionLocale") ?? "ru-RU"
        storedShowMenuBarItem = defaults.object(forKey: "showMenuBarItem") as? Bool ?? true
        storedGlobalHotKeyEnabled = defaults.object(forKey: "globalHotKeyEnabled") as? Bool ?? true
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

    /// Уведомляем и пишем на диск только при настоящем изменении.
    private func update<T: Equatable>(_ storage: inout T, _ value: T, _ key: String, raw: Any? = nil) {
        guard storage != value else { return }
        objectWillChange.send()
        storage = value
        defaults.set(raw ?? value, forKey: key)
    }
}
