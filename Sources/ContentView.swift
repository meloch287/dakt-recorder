import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderController
    @State private var pulse = false

    var body: some View {
        VStack(spacing: 22) {
            header

            Text(recorder.elapsedText)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(recorder.isRecording ? Color.primary : Color.secondary)

            VStack(spacing: 10) {
                LevelRow(title: "Микрофон", level: recorder.micLevel, tint: .green)
                LevelRow(title: "Zoom / системный звук", level: recorder.systemLevel, tint: .blue)
            }

            recordButton

            VStack(spacing: 6) {
                Text(recorder.status)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                if let error = recorder.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if recorder.lastMix != nil && !recorder.isRecording {
                    Button("Показать запись в Finder") { recorder.revealLastRecording() }
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            .frame(minHeight: 54, alignment: .top)
        }
        .padding(28)
        .frame(width: 380)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.isRecording ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                // Анимация запускается один раз и идёт всегда; во время записи она
                // управляет прозрачностью точки, в покое точка статична.
                .opacity(recorder.isRecording ? (pulse ? 1 : 0.25) : 0.7)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text("Meeting Recorder")
                .font(.headline)
            Spacer()
        }
    }

    private var recordButton: some View {
        Button(action: recorder.toggle) {
            ZStack {
                Circle()
                    .fill(recorder.isRecording ? Color.red.opacity(0.15) : Color.red)
                    .frame(width: 92, height: 92)
                if recorder.isRecording {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.red)
                        .frame(width: 30, height: 30)
                } else {
                    Image(systemName: "mic.fill")
                        .font(.system(size: 30, weight: .semibold))
                        .foregroundStyle(.white)
                }
                if recorder.isBusy {
                    Circle()
                        .stroke(Color.white.opacity(0.5), lineWidth: 3)
                        .frame(width: 92, height: 92)
                }
            }
            .overlay(
                Circle()
                    .stroke(Color.red.opacity(recorder.isRecording ? 0.6 : 0), lineWidth: 3)
                    .frame(width: 92, height: 92)
            )
        }
        .buttonStyle(.plain)
        .disabled(recorder.isBusy)
        .help(recorder.isRecording ? "Остановить запись" : "Начать запись")
    }
}

private struct LevelRow: View {
    let title: String
    let level: Float
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule()
                        .fill(tint)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, level * 1.4))))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 6)
        }
    }
}
