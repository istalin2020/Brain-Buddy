import SwiftUI

/// The compartments of your brain, as a grid of cards you tap to filter.
@MainActor
struct BrainBoxGrid: View {
    let boxes: [BrainBox]
    @Binding var selection: String

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 150), spacing: 10)],
            spacing: 10
        ) {
            ForEach(boxes) { box in
                card(box)
            }
        }
    }

    private func card(_ box: BrainBox) -> some View {
        let isSelected = box.id == selection

        return Button {
            // Tapping the open box closes it, rather than leaving no way back to
            // everything except hunting for the first card.
            selection = isSelected ? "everything" : box.id
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: box.systemImage)
                        .font(.footnote)
                    Spacer(minLength: 0)
                    Text("\(box.count)")
                        .font(.caption.weight(.semibold))
                        .monospacedDigit()
                }
                Text(box.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 74, alignment: .topLeading)
            .padding(12)
            .background(
                isSelected ? Color.accentColor.opacity(0.22) : Color.accentColor.opacity(0.08),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.accentColor.opacity(isSelected ? 0.85 : 0), lineWidth: 1.5)
            }
            .foregroundStyle(Color.accentColor)
            .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(box.title), \(box.count) memories")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
