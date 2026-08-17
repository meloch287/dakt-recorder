import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var recorder: RecorderController
    @State private var pulse = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 20) {
            header

            // Таймер и уровни живут в отдельном объекте: их частые обновления
            // не должны дёргать всё окно и строку меню.
            MeterSection(meter: recorder.meter, isRecording: recorder.isRecording)

            HStack(spacing: 18) {
                recordButton
                if recorder.isRecording {
                    Button(action: recorder.togglePause) {
                        Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.plain)
                    .background(Circle().fill(Color.secondary.opacity(0.15)))
                    .help(recorder.isPaused ? "Продолжить" : "Пауза")
                }
            }

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
        .padding(24)
        .frame(width: 380)
        .sheet(isPresented: $showSettings) {
            SettingsView(preferences: recorder.preferences)
                .environmentObject(recorder)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(recorder.isRecording && !recorder.isPaused ? Color.red : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                // Анимация запускается один раз и идёт всегда; во время записи она
                // управляет прозрачностью точки, в покое точка статична.
                .opacity(recorder.isRecording && !recorder.isPaused ? (pulse ? 1 : 0.25) : 0.7)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                        pulse = true
                    }
                }
            Text("DaktRecorder")
                .font(.headline)
            Spacer()
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Настройки")
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

private struct MeterSection: View {
    @ObservedObject var meter: RecordingMeter
    let isRecording: Bool

    var body: some View {
        VStack(spacing: 20) {
            Text(meter.elapsedText)
                .font(.system(size: 44, weight: .light, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(isRecording ? Color.primary : Color.secondary)

            VStack(spacing: 10) {
                LevelRow(title: "Микрофон", level: meter.micLevel, tint: .green)
                LevelRow(title: "Zoom / системный звук", level: meter.systemLevel, tint: .blue)
            }
        }
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
