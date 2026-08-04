import SwiftUI

/// Live microphone level bars shown while recording or dictating.
struct WaveformView: View {
    var levels: [Double]
    var barCount: Int = 32
    var tint: Color = .accentColor

    var body: some View {
        GeometryReader { proxy in
            let spacing: CGFloat = 3
            let width = max(2, (proxy.size.width - spacing * CGFloat(barCount - 1)) / CGFloat(barCount))
            HStack(alignment: .center, spacing: spacing) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(tint.opacity(0.85))
                        .frame(width: width, height: height(at: index, in: proxy.size.height))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeOut(duration: 0.12), value: levels.count)
        }
    }

    /// Reads the tail of the level buffer so the newest audio is on the right.
    private func height(at index: Int, in available: CGFloat) -> CGFloat {
        let window = levels.suffix(barCount)
        let padding = barCount - window.count
        let level: Double
        if index < padding {
            level = 0
        } else {
            let offset = index - padding
            level = Array(window)[offset]
        }
        let minimum: CGFloat = 3
        return minimum + CGFloat(level) * max(0, available - minimum)
    }
}

struct KindBadge: View {
    let kind: MemoryKind

    var body: some View {
        Label(kind.title, systemImage: kind.systemImage)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Color.accentColor.opacity(0.12), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text("#\(name)")
                .font(.caption)
            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.caption2)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove tag \(name)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.12), in: Capsule())
    }
}

struct EmptyStateView: View {
    let systemImage: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: 320)
        .padding(32)
    }
}

/// A large circular capture button, used for both recording and dictation.
struct MicButton: View {
    var isActive: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(isActive ? Color.red : Color.accentColor)
                    .frame(width: 76, height: 76)
                    .shadow(radius: isActive ? 10 : 4)
                Image(systemName: isActive ? "stop.fill" : "mic.fill")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isActive ? "Stop" : "Start listening")
    }
}

extension Date {
    var relativeShortDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}
