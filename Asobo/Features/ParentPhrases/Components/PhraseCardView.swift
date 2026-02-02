import SwiftUI
import Domain

struct PhraseCardView: View {
    let card: PhraseCard
    let isPlayingThisCard: Bool
    let isPreparingThisCard: Bool
    let playbackProgress: Double
    let isAnyPlaying: Bool
    let onPlay: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(.white)

            // 再生進捗バー（左から右に色が変わる）
            if isPlayingThisCard {
                GeometryReader { geometry in
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(Color.anoneButton.opacity(0.14))
                        .frame(width: geometry.size.width * playbackProgress)
                        .animation(.linear(duration: 0.05), value: playbackProgress)
                }
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }

            HStack(alignment: .center, spacing: 14) {
                ZStack {
                    Circle()
                        .fill(card.category.tintColor.opacity(0.18))
                    Image(systemName: card.category.icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(card.category.tintColor)
                }
                .frame(width: 40, height: 40)

                VStack(alignment: .leading, spacing: 8) {
                    Text(card.text)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "5A4A42"))
                        .lineLimit(2)

                    HStack(spacing: 10) {
                        Text("\(card.usageCount)回")
                            .font(.caption)
                            .foregroundColor(.gray.opacity(0.75))

                        if let lastUsed = card.lastUsedAt {
                            Text("最終: \(formattedDate(lastUsed))")
                                .font(.caption)
                                .foregroundColor(.gray.opacity(0.75))
                        }
                    }
                }

                Spacer(minLength: 0)

                Button(action: onPlay) {
                    if isPreparingThisCard {
                        ProgressView()
                            .tint(.anoneButton)
                            .frame(width: 34, height: 34)
                    } else {
                        Image(systemName: isPlayingThisCard ? "pause.circle.fill" : "play.circle.fill")
                            .font(.system(size: 34))
                            .foregroundColor(isPlayingThisCard ? .anoneButton : Color(hex: "5A4A42"))
                    }
                }
                .disabled(isPreparingThisCard || (isAnyPlaying && !isPlayingThisCard))
                .opacity(isPreparingThisCard || (isAnyPlaying && !isPlayingThisCard) ? 0.45 : 1.0)
            }
            .padding(16)
        }
        .shadow(color: .anoneShadowDark.opacity(0.14), radius: 10, x: 5, y: 5)
        .shadow(color: .white.opacity(0.9), radius: 10, x: -5, y: -5)
        .contextMenu {
            Button {
                onEdit()
            } label: {
                Label("編集", systemImage: "pencil")
            }

            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("削除", systemImage: "trash")
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        formatter.locale = Locale(identifier: "ja-JP")
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

#Preview {
    VStack(spacing: 12) {
        PhraseCardView(
            card: PhraseCard(
                text: "おはよう！今日も元気に行こうね",
                category: .morning,
                isPreset: true,
                usageCount: 5,
                lastUsedAt: Date().addingTimeInterval(-3600)
            ),
            isPlayingThisCard: false,
            isPreparingThisCard: false,
            playbackProgress: 0.0,
            isAnyPlaying: false,
            onPlay: { print("Play") },
            onEdit: { print("Edit") },
            onDelete: { print("Delete") }
        )

        PhraseCardView(
            card: PhraseCard(
                text: "早くお着替えしようね",
                category: .morning,
                isPreset: true,
                usageCount: 0
            ),
            isPlayingThisCard: true,
            isPreparingThisCard: true,
            playbackProgress: 0.6,
            isAnyPlaying: true,
            onPlay: { print("Play") },
            onEdit: { print("Edit") },
            onDelete: { print("Delete") }
        )
    }
    .padding()
}
