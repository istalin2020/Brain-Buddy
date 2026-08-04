import SwiftData
import SwiftUI

/// Records a voice note. Recording and transcription are deliberately
/// sequential: the file is written first and saved unconditionally, then the
/// transcript is added. A failed transcription never costs you the recording.
@MainActor
struct VoiceCaptureView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @State private var errorMessage: String?
    @State private var isSaving = false

    private var recorder: AudioRecorder { services.recorder }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Text(timeString)
                    .font(.system(size: 46, weight: .light, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())

                WaveformView(levels: recorder.levels, tint: recorder.isRecording ? .red : .accentColor)
                    .frame(height: 78)
                    .padding(.horizontal)

                Text(statusText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)

                Spacer()

                if isSaving {
                    ProgressView(services.ingest.activity ?? "Saving…")
                } else {
                    MicButton(isActive: recorder.isRecording) {
                        recorder.isRecording ? finishRecording() : startRecording()
                    }
                }

                Spacer(minLength: 24)
            }
            .navigationTitle("Voice note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        recorder.cancel()
                        dismiss()
                    }
                    .disabled(isSaving)
                }
            }
            .task { startRecording() }
            .alert(
                "Recording problem",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil; dismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(recorder.isRecording || isSaving)
    }

    private var timeString: String {
        let total = Int(recorder.duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var statusText: String {
        if isSaving { return "Transcribing so you can search this later…" }
        if recorder.isRecording { return "Listening. Tap stop when you're done." }
        return "Tap the microphone to start recording."
    }

    private func startRecording() {
        guard !recorder.isRecording, !isSaving else { return }
        Task {
            do {
                try await recorder.start()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func finishRecording() {
        guard let result = recorder.stop() else {
            dismiss()
            return
        }
        // Very short taps are almost always accidental.
        guard result.duration >= 0.6 else {
            try? FileManager.default.removeItem(at: result.url)
            errorMessage = "That recording was too short to save."
            return
        }

        isSaving = true
        Task {
            await services.ingest.capture(
                audioURL: result.url,
                duration: result.duration,
                in: modelContext
            )
            isSaving = false
            dismiss()
        }
    }
}
