import SwiftUI

/// Playback for a stored recording, with a timeline you can drag.
///
/// A fourteen-minute conversation is unusable without one: transcription will
/// always get some of it wrong, and the recording is the source of truth you go
/// back to. Being able to scrub to the part you half-remember is the difference
/// between a recording you can check and one you can only replay from the start.
@MainActor
struct AudioPlayerRow: View {
    let attachment: MemoryAttachment

    @State private var player = AudioPlayerController()
    /// Where the thumb is while a drag is in progress. The ticker keeps writing
    /// `player.currentTime`, so during a scrub the slider has to follow the
    /// finger instead — otherwise the thumb fights back mid-drag.
    @State private var scrubbing: Double?

    private var total: TimeInterval {
        player.duration > 0 ? player.duration : attachment.duration
    }

    private var position: Double {
        scrubbing ?? min(player.currentTime, total)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            timeline
            controls
        }
        .padding(.vertical, 4)
        .task { load() }
        .onDisappear { player.stop() }
    }

    // MARK: - Timeline

    private var timeline: some View {
        VStack(spacing: 2) {
            Slider(
                value: Binding(
                    get: { position },
                    set: { scrubbing = $0 }
                ),
                in: 0...max(total, 0.1),
                onEditingChanged: { editing in
                    guard !editing else { return }
                    // Commit on release rather than on every pixel of movement:
                    // AVAudioPlayer reseeks audibly, and doing that continuously
                    // sounds like a scratched record.
                    if let target = scrubbing { player.seek(to: target) }
                    scrubbing = nil
                }
            )
            .disabled(total <= 0)

            HStack {
                Text(Self.clock(position))
                Spacer()
                Text(Self.clock(total))
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        HStack(spacing: 22) {
            skipButton(seconds: -15, systemImage: "gobackward.15")

            Button {
                player.togglePlayback()
            } label: {
                Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 40))
            }
            .buttonStyle(.plain)
            .disabled(attachment.payload == nil)
            .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

            skipButton(seconds: 15, systemImage: "goforward.15")

            Spacer(minLength: 0)

            VStack(alignment: .trailing, spacing: 2) {
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if attachment.payload == nil {
                    Text("Downloading from iCloud")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    private func skipButton(seconds: TimeInterval, systemImage: String) -> some View {
        Button {
            player.seek(to: player.currentTime + seconds)
        } label: {
            Image(systemName: systemImage)
                .font(.title3)
        }
        .buttonStyle(.plain)
        .disabled(attachment.payload == nil || total <= 0)
        .accessibilityLabel(seconds < 0 ? "Back 15 seconds" : "Forward 15 seconds")
    }

    // MARK: - Helpers

    /// The stored filename is a UUID, which tells the reader nothing. Name it by
    /// what it is instead.
    private var label: String {
        "Recording · \(attachment.formattedSize)"
    }

    private func load() {
        guard player.duration == 0, let url = attachment.temporaryFileURL() else { return }
        player.load(url: url)
    }

    /// `h:mm:ss` past an hour, `m:ss` below it — a 13-minute recording shouldn't
    /// be labelled `0:13:48`.
    static func clock(_ time: TimeInterval) -> String {
        guard time.isFinite, time >= 0 else { return "0:00" }
        let total = Int(time.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }
}
