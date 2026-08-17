import SwiftUI
import AppKit

@main
struct DaktRecorderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        WindowGroup("DaktRecorder") {
            ContentView()
                .environmentObject(recorder)
                .onAppear { delegate.recorder = recorder }
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}

/// Выход из приложения во время записи не должен терять запись: просим систему
/// подождать, дописываем файлы, сводим дорожки и только потом завершаемся.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var recorder: RecorderController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let recorder, recorder.isRecording else { return .terminateNow }
        Task {
            await recorder.finishBeforeTermination()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
