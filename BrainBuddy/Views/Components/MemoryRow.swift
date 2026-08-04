import SwiftUI

/// One memory in a list. Deliberately renders from the cached thumbnail and
/// preview text only — never the attachment payload — so scrolling a library of
/// thousands of PDFs stays smooth.
struct MemoryRow: View {
    let item: MemoryItem
    var snippet: String?
    var footnote: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            thumbnail

            VStack(alignment: .leading, spacing: 4) {
                Text(item.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                let body = snippet ?? item.preview
                if !body.isEmpty {
                    Text(body)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }

                HStack(spacing: 8) {
                    KindBadge(kind: item.kind)
                    Text(item.createdAt.relativeShortDescription)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if item.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if let footnote {
                        Text(footnote)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var thumbnail: some View {
        let preview = item.sortedAttachments.compactMap(\.thumbnail).first
        if let preview, let image = UIImage(data: preview) {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(width: 52, height: 52)
                .overlay {
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(Color.accentColor)
                }
        }
    }
}
