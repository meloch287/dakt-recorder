import SwiftUI
import AppKit
import Combine

@main
struct DaktRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var preferences: Preferences
    @StateObject private var recorder: RecorderController

    init() {
        let preferences = Preferences()
        let recorder = RecorderController(preferences: preferences)
        _preferences = StateObject(wrappedValue: preferences)
        _recorder = StateObject(wrappedValue: recorder)
    }

    var body: some Scene {
        WindowGroup("DaktRecorder") {
            ContentView()
                .environmentObject(recorder)
                .onAppear { delegate.attach(recorder: recorder, preferences: preferences) }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        MenuBarExtra("DaktRecorder", systemImage: recorder.isRecording ? "record.circle" : "mic",
                     isInserted: $preferences.showMenuBarItem) {
            Button(recorder.isRecording ? "Остановить запись" : "Начать запись") { recorder.toggle() }
            if recorder.isRecording {
                Button(recorder.isPaused ? "Продолжить" : "Пауза") { recorder.togglePause() }
            }
            Divider()
            Text(recorder.status)
            Button("Папка записей") { recorder.openRecordingsFolder() }
            Divider()
            Button("Выйти") { NSApp.terminate(nil) }
        }
    }
}

/// Горячая клавиша, значок в строке меню и корректное завершение во время записи.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private weak var recorder: RecorderController?
    private weak var preferences: Preferences?
    private let hotKey = GlobalHotKey()
    private var cancellable: AnyCancellable?

    func attach(recorder: RecorderController, preferences: Preferences) {
        guard self.recorder == nil else { return }
        self.recorder = recorder
        self.preferences = preferences
        updateHotKey()
        // Переключатель горячей клавиши должен срабатывать сразу, а не после перезапуска.
        cancellable = preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateHotKey() }
    }

    func updateHotKey() {
        guard let preferences else { return }
        if preferences.globalHotKeyEnabled {
            hotKey.register { [weak self] in self?.recorder?.toggle() }
        } else {
            hotKey.unregister()
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.finishBeforeTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
