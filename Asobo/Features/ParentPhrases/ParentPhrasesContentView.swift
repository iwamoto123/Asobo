import SwiftUI
import Domain

@available(iOS 17.0, *)
struct ParentPhrasesContentView: View {
    @ObservedObject var controller: ParentPhrasesController
    @State private var selectedCategory: PhraseCategory = .morning
    @State private var searchText: String = ""
    @State private var sheet: Sheet?
    @State private var isAddCategoryPresented: Bool = false
    @State private var newCategoryName: String = ""

    private enum Sheet: Identifiable {
        case add(category: PhraseCategory, initialText: String?)
        case edit(card: PhraseCard)

        var id: String {
            switch self {
            case .add(let category, _): return "add:\(category.id)"
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
                    categories: controller.availableCategories(),
                    onAddCategory: { isAddCategoryPresented = true }
                )
                .padding(.top, 6)
                .padding(.bottom, 10)

                Group {
                    if !controller.hasLoadedCards {
                        VStack(spacing: 12) {
                            ProgressView()
                            Text("読み込み中…")
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundStyle(Color(hex: "5A4A42").opacity(0.8))
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        // 下部バーは safeAreaInset に任せる（余白を二重にしない）
                    } else if visibleCards.isEmpty {
                        ParentPhrasesEmptyStateView(
                            title: searchText.isEmpty ? "まだフレーズがないよ" : "見つからなかったよ",
                            message: searchText.isEmpty ? "よく使う声かけを\nカードにしておこう" : "別の言葉でも探してみてね",
                            actionTitle: "フレーズを追加"
                        ) {
                            sheet = .add(category: selectedCategory, initialText: nil)
                        }
                    } else {
                        List {
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
                                .swipeActions(edge: .leading, allowsFullSwipe: false) {
                                    Button {
                                        sheet = .edit(card: card)
                                    } label: {
                                        Label("編集", systemImage: "pencil")
                                    }
                                    .tint(.blue)
                                }
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        controller.deleteCard(card)
                                    } label: {
                                        Label("削除", systemImage: "trash")
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowBackground(Color.clear)
                                .listRowInsets(EdgeInsets(top: 7, leading: 16, bottom: 7, trailing: 16))
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                        .padding(.top, 6)
                        // 下部バーは safeAreaInset に任せる（余白を二重にしない）
                    }
                }
            }
        }
        .searchable(text: $searchText, prompt: "フレーズを検索")
        .safeAreaInset(edge: .bottom) {
            ParentPhrasesBottomBarView(
            ) {
                sheet = .add(category: selectedCategory, initialText: nil)
            }
        }
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .add(let category, let initialText):
                PhraseInputSheet(
                    card: nil,
                    category: category,
                    initialText: initialText,
                    availableCategories: controller.availableCategories(),
                    onCreateCategory: { controller.addCustomCategory($0) }
                ) { newCard in
                    controller.saveCard(newCard)
                }
            case .edit(let card):
                PhraseInputSheet(
                    card: card,
                    category: card.category,
                    availableCategories: controller.availableCategories(),
                    onCreateCategory: { controller.addCustomCategory($0) }
                ) { newCard in
                    controller.saveCard(newCard)
                }
            }
        }
        .alert("カテゴリを追加", isPresented: $isAddCategoryPresented) {
            TextField("カテゴリ名", text: $newCategoryName)
            Button("追加") {
                let c = PhraseCategory(newCategoryName)
                controller.addCustomCategory(c.name)
                selectedCategory = c
                newCategoryName = ""
            }
            Button("キャンセル", role: .cancel) { newCategoryName = "" }
        } message: {
            Text("あとでカードを追加すれば一覧にも残ります")
        }
        // NOTE: 音声入力UIは一旦オフ（将来また有効化できるよう関連実装は残している）
    }

    private var visibleCards: [PhraseCard] {
        let base = controller.filteredCards(for: selectedCategory)
        let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return base }
        return base.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }
}