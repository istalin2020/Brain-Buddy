import SwiftData
import SwiftUI

/// Records a voice note — a thought, or a whole conversation — then shows you the
/// transcript so you can decide what to keep from it.
///
/// The ordering is deliberate and load-bearing: the audio is written and the
/// memory is saved *before* transcription starts, and before you see any of this.
/// A failed transcription, a crash, or you closing the sheet can never cost you
/// the recording. Everything after the save — transcript, summary — is additive.
@MainActor
struct VoiceCaptureView: View {
    @Environment(AppServices.self) private var services
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    private enum Stage: Equatable {
        case recording
        case saving
        /// The recording is already stored; this is the read-and-decide step.
        case review
    }

    @State private var stage: Stage = .recording
    @State private var saved: MemoryItem?
    @State private var summary: DiscussionSummarizer.Summary?
    @State private var isSummarizing = false
    @State private var notice: String?
    @State private var errorMessage: String?

    private var recorder: AudioRecorder { services.recorder }

    var body: some View {
        NavigationStack {
            Group {
                switch stage {
                case .recording: recordingStage
                case .saving: savingStage
                case .review: reviewStage
                }
            }
            .navigationTitle(stage == .review ? "Transcript" : "Voice note")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task {
                if stage == .recording, !recorder.isRecording { startRecording() }
            }
            .alert(
                "Recording problem",
                isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
            ) {
                Button("OK", role: .cancel) { errorMessage = nil; dismiss() }
            } message: {
                Text(errorMessage ?? "")
            }
        }
        .interactiveDismissDisabled(stage != .review)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            switch stage {
            case .recording:
                Button("Cancel") {
                    recorder.cancel()
                    dismiss()
                }
            case .saving:
                Button("Cancel") {}.disabled(true)
            case .review:
                // The memory is already saved; leaving keeps it, minus the summary.
                Button("Done") { dismiss() }
            }
        }
    }

    // MARK: - Recording

    private var recordingStage: some View {
        VStack(spacing: 28) {
            Spacer()

            Text(timeString)
                .font(.system(size: 46, weight: .light, design: .rounded))
                .monospacedDigit()
                .contentTransition(.numericText())

            WaveformView(
                levels: recorder.levels,
                tint: recorder.isPaused ? .orange : (recorder.isRecording ? .red : .accentColor)
            )
            .frame(height: 78)
            .padding(.horizontal)

            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(recorder.isPaused ? .primary : .secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if recorder.isPaused {
                // On failure `resume()` rewrites `pauseReason`, which is the text
                // above this button — so there is nothing to handle here.
                Button("Resume recording") { recorder.resume() }
                    .buttonStyle(.borderedProminent)
            }

            if recorder.secondsLostWhileAway > 1.5 {
                suspensionWarning
            }

            Spacer()

            MicButton(isActive: recorder.isRecording && !recorder.isPaused) {
                recorder.isRecording ? finishRecording() : startRecording()
            }

            Text(backgroundHint)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            Spacer(minLength: 24)
        }
    }

    /// Shown when measured time away exceeded audio captured — i.e. iOS froze the
    /// app instead of letting it record. Says so with a number rather than
    /// leaving a silently short recording to be discovered later.
    private var suspensionWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("iOS paused this app off screen", systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.orange)
            Text("About \(Int(recorder.secondsLostWhileAway.rounded())) seconds weren't recorded while Brain Buddy was in the background. Settings › Voice recording shows whether this build is allowed to record off screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal, 20)
    }

    private var savingStage: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(services.ingest.activity ?? "Saving…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Your recording is already saved. This is just the transcript.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    @ViewBuilder
    private var reviewStage: some View {
        if let item = saved {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    savedBanner(item)
                    transcriptSection(item)
                    summarySection(item)
                }
                .padding()
            }
        } else {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func savedBanner(_ item: MemoryItem) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text("Saved to your brain")
                    .font(.subheadline.weight(.medium))
                Text(recordingDetail(item))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func transcriptSection(_ item: MemoryItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Transcript")
                .font(.headline)
            if item.text.isEmpty {
                Text("No speech was recognized. The audio is saved and you can still play it back from your library.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Text(item.text)
                    .font(.callout)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ item: MemoryItem) -> some View {
        if !item.text.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Divider()

                if let summary {
                    Text("Summary")
                        .font(.headline)
                    SummaryBody(summary: summary)

                    HStack(spacing: 12) {
                        Button {
                            saveSummary(summary, on: item)
                        } label: {
                            Text("Save")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Discard") {
                            self.summary = nil
                        }
                        .buttonStyle(.bordered)
                    }

                    Text("Saving keeps the summary on this memory and indexes it, so you can find the recording by what mattered in it.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        makeSummary(from: item.text)
                    } label: {
                        if isSummarizing {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("Summarizing…")
                            }
                            .frame(maxWidth: .infinity)
                        } else {
                            Label("Create summary", systemImage: "list.bullet.rectangle")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSummarizing)

                    if let notice {
                        Text(notice)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pulls the key points and anything somebody committed to out of the discussion. Every line is quoted from the transcript above — nothing is invented.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    // MARK: - Labels

    private var timeString: String {
        let total = Int(recorder.duration)
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    private var statusText: String {
        if let reason = recorder.pauseReason { return reason }
        if recorder.isRecording { return "Listening. Tap stop when you're done." }
        return "Tap the microphone to start recording."
    }

    private var backgroundHint: String {
        guard AudioRecorder.declaresBackgroundAudio else {
            return "Keep Brain Buddy open — this build is missing the Background Modes › Audio capability, so iOS won't let it record off screen."
        }
        return recorder.allowsBackgroundRecording
            ? "You can lock the screen or switch apps — recording keeps going."
            : "Recording pauses if you leave the app. Turn on background recording in Settings to keep going with the screen off."
    }

    private func recordingDetail(_ item: MemoryItem) -> String {
        var parts: [String] = []
        if let audio = item.sortedAttachments.first(where: { $0.kind == .audio }) {
            parts.append(audio.formattedDuration)
        }
        let words = item.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
        if words > 0 { parts.append(words == 1 ? "1 word" : "\(words) words") }
        return parts.isEmpty ? "Audio saved" : parts.joined(separator: " · ")
    }

    // MARK: - Actions

    private func startRecording() {
        guard !recorder.isRecording else { return }
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

        stage = .saving
        Task {
            let item = await services.ingest.saveVoiceNote(
                audioURL: result.url,
                duration: result.duration,
                in: modelContext
            )
            saved = item
            stage = .review
            if item == nil {
                errorMessage = services.ingest.lastError ?? "The recording couldn't be saved."
            }
        }
    }

    /// Summarizing walks the transcript with `NLTagger` twice; on a long meeting
    /// that is long enough to drop a frame, so it runs off the main actor.
    private func makeSummary(from transcript: String) {
        guard !isSummarizing else { return }
        isSummarizing = true
        notice = nil
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DiscussionSummarizer.summarize(transcript)
            }.value
            isSummarizing = false
            if let result {
                summary = result
            } else {
                notice = "There isn't enough here to summarize — the transcript above is already the short version."
            }
        }
    }

    private func saveSummary(_ summary: DiscussionSummarizer.Summary, on item: MemoryItem) {
        let text = summary.text
        Task {
            await services.ingest.setSummary(text, on: item, in: modelContext)
            dismiss()
        }
    }
}

/// Renders a summary's topics, key points and follow-ups.
///
/// Shared by the review sheet and `MemoryDetailView` so a saved summary looks the
/// same as the one you approved.
@MainActor
struct SummaryBody: View {
    let summary: DiscussionSummarizer.Summary

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !summary.topics.isEmpty {
                Text("Topics: " + summary.topics.joined(separator: ", "))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            if !summary.keyPoints.isEmpty {
                group("Key points", lines: summary.keyPoints)
            }
            if !summary.followUps.isEmpty {
                group("Follow-ups", lines: summary.followUps)
            }
        }
    }

    private func group(_ title: String, lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•").foregroundStyle(.tertiary)
                    Text(line)
                        .font(.callout)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
