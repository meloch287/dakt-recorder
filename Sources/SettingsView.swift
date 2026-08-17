import SwiftUI

/// Всё под шестерёнкой: устройство, источник, обработка, файлы, автостоп, расшифровка.
struct SettingsView: View {
    @EnvironmentObject private var recorder: RecorderController
    @ObservedObject var preferences: Preferences
    @Environment(\.dismiss) private var dismiss

    @State private var devices: [AudioInputDevice] = []
    @State private var applications: [SystemAudioCapture.Application] = []
    @State private var applicationsError: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Настройки").font(.headline)
                Spacer()
                Button("Готово") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    section("Микрофон") {
                        Picker("Устройство", selection: $preferences.inputDeviceUID) {
                            Text("По умолчанию в системе").tag("")
                            ForEach(devices) { device in
                                Text(device.name).tag(device.uid)
                            }
                        }
                        Toggle("Убрать гул и рокот ниже 90 Гц", isOn: $preferences.highPassFilter)
                        Toggle("Шумодав: глушить тихие участки", isOn: $preferences.noiseGate)
                    }

                    section("Источник звука собеседников") {
                        Picker("Захватывать", selection: $preferences.source) {
                            ForEach(Preferences.Source.allCases) { source in
                                Text(source.title).tag(source)
                            }
                        }
                        if preferences.source == .application {
                            Picker("Приложение", selection: $preferences.targetBundleID) {
                                Text("Не выбрано").tag("")
                                ForEach(applications) { app in
                                    Text(app.name).tag(app.bundleID)
                                }
                            }
                            Text("В записи будет только звук этого приложения — без уведомлений и музыки.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let applicationsError {
                                Text(applicationsError)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                        }
                    }

                    section("Сведение") {
                        Toggle("Выравнивать громкость дорожек", isOn: $preferences.normalizeTracks)
                        Text("Тихий собеседник и громкий микрофон в mix звучат одинаково.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    section("Файлы") {
                        Toggle("Сжимать сырые дорожки", isOn: $preferences.compressRawTracks)
                        Toggle("Удалять сырые дорожки после сведения", isOn: $preferences.removeRawAfterMix)
                        if !recorder.freeSpaceText.isEmpty {
                            Text(recorder.freeSpaceText)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Button("Открыть папку записей") { recorder.openRecordingsFolder() }
                            .buttonStyle(.link)
                            .font(.caption)
                    }

                    section("Автостоп") {
                        Toggle("Останавливать запись после тишины", isOn: $preferences.autoStopOnSilence)
                        if preferences.autoStopOnSilence {
                            Stepper("Тишина: \(preferences.silenceMinutes) мин",
                                    value: $preferences.silenceMinutes, in: 1...60)
                        }
                    }

                    section("Расшифровка") {
                        Toggle("Расшифровывать после остановки", isOn: $preferences.transcribe)
                        if preferences.transcribe {
                            Picker("Язык", selection: $preferences.transcriptionLocale) {
                                ForEach(Preferences.locales, id: \.code) { locale in
                                    Text(locale.title).tag(locale.code)
                                }
                            }
                            Text("Текст с ролями «Я» и «Собеседник» ложится рядом с записью в transcript.txt.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    section("Окно и клавиши") {
                        Toggle("Значок в строке меню", isOn: $preferences.showMenuBarItem)
                        Toggle("Горячая клавиша \(GlobalHotKey.shortcutTitle)", isOn: $preferences.globalHotKeyEnabled)
                        Text("Клавиша работает и когда окно закрыто: старт и стоп записи.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    if !recorder.unfinished.isEmpty {
                        section("Незавершённые записи") {
                            ForEach(recorder.unfinished, id: \.self) { folder in
                                HStack {
                                    Text(folder.lastPathComponent)
                                        .font(.caption)
                                    Spacer()
                                    Button("Собрать") {
                                        Task { await recorder.recover(folder: folder) }
                                    }
                                    .font(.caption)
                                }
                            }
                            Text("Сырые дорожки есть, а сведения нет — так бывает после сбоя.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(20)
            }
        }
        .frame(width: 420, height: 560)
        .task {
            devices = AudioDevices.inputs()
            recorder.refreshFreeSpace()
            recorder.refreshUnfinished()
            await loadApplications()
        }
    }

    private func loadApplications() async {
        do {
            applications = try await SystemAudioCapture.applications()
            applicationsError = nil
        } catch {
            applicationsError = "Список приложений недоступен без разрешения на запись экрана."
        }
    }

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            content()
        }
    }
}
