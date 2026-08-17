import SwiftUI

@main
struct MeetingRecorderApp: App {
    @StateObject private var recorder = RecorderController()

    var body: some Scene {
        WindowGroup("Meeting Recorder") {
            ContentView()
                .environmentObject(recorder)
        }
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
    }
}
