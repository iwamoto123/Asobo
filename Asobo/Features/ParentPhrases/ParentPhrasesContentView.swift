import SwiftUI
import Domain

@available(iOS 17.0, *)
struct ParentPhrasesContentView: View {
    @ObservedObject var controller: ParentPhrasesController
    @State private var selectedCategory: PhraseCategory = .morning
    @State private var searchText: String = ""
    @State private var sheet: Sheet?

    private enum Sheet: Identifiable {
        case add(category: PhraseCategory)
        case edit(card: PhraseCard)

        var id: String {
            switch self {
            case .add(let category): return "add:\(category.id)"
            case .edit(let card): return "edit:\(card.id)"
            }
        }
    }

    var body: some View {
        ZStack {
            ParentPhrasesBackgroundView()

            VStack(spacing: 0) {
                CategorySelectorView(
                    selectedCategory: $selectedCategory,
                    categories: PhraseCategory.allCases
                )
                .padding(.top, 6)
                .padding(.bottom, 10)

                Group {
                    if visibleCards.isEmpty {
                        ParentPhrasesEmptyStateView(
                            title: searchText.isEmpty ? "まだフレーズがないよ" : "見つからなかったよ",
                            message: searchText.isEmpty ? "よく使う声かけを\nカードにしておこう" : "別の言葉でも探してみてね",
                            actionTitle: "フレーズを追加"
                        ) {
                            sheet = .add(category: selectedCategory)
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 14) {
                                ForEach(visibleCards) { card in
                                    PhraseCardView(
                                        card: card,
                                        isPlayingThisCard: controller.playingCardId == card.id,
                                        isPreparingThisCard: controller.preparingCardId == card.id,
                                        playbackProgress: controller.playingCardId == card.id ? controller.playbackProgress : 0.0,
                                        isAnyPlaying: controller.isPlaying || controller.preparingCardId != nil
                                    ) {
                                        controller.playPhrase(card)
                                    } onEdit: {
                                        sheet = .edit(card: card)
                                    } onDelete: {
                                        controller.deleteCard(card)
                                    }
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.top, 6)
                            .padding(.bottom, 80)
                        }
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "フレーズを検索")
        .safeAreaInset(edge: .bottom) {
            ParentPhrasesBottomBarView(
                isRecording: controller.isRecording
            ) {
                sheet = .add(category: selectedCategory)
            } onVoiceInput: {
                controller.startVoiceInput()
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let category):
                PhraseInputSheet(card: nil, category: category) { newCard in
                    controller.saveCard(newCard)
                }
            case .edit(let card):
                PhraseInputSheet(card: card, category: card.category) { newCard in
                    controller.saveCard(newCard)
                }
            }
        }
    }

    private var visibleCards: [PhraseCard] {
        let base = controller.filteredCards(for: selectedCategory)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}