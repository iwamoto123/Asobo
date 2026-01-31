import SwiftUI
import Domain

/// LINEスタイルのテキスト入力UI（画面下部からキーボードがせり上がる）
struct LINEStyleInputView: View {
    @Binding var isPresented: Bool
    let card: PhraseCard?
    let category: PhraseCategory
    let onSave: (PhraseCard) -> Void

    @State private var text: String
    @State private var selectedCategory: PhraseCategory
    @FocusState private var isFocused: Bool

    init(
        isPresented: Binding<Bool>,
        card: PhraseCard?,
        category: PhraseCategory,
        onSave: @escaping (PhraseCard) -> Void
    ) {
        self._isPresented = isPresented
        self.card = card
        self.category = category
        self.onSave = onSave
        _text = State(initialValue: card?.text ?? "")
        _selectedCategory = State(initialValue: card?.category ?? category)
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()

            VStack(spacing: 12) {
                // カテゴリ選択（横スクロール）
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PhraseCategory.allCases) { cat in
                            Button {
                                selectedCategory = cat
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: cat.icon)
                                    Text(cat.rawValue)
                                        .font(.caption)
                                }
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(selectedCategory == cat ? Color.blue : Color.gray.opacity(0.2))
                                .foregroundColor(selectedCategory == cat ? .white : .primary)
                                .cornerRadius(16)
                            }
                        }
                    }
                    .padding(.horizontal)
                }

                // テキスト入力 + 送信ボタン
                HStack(spacing: 12) {
                    TextField("フレーズを入力...", text: $text, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .focused($isFocused)

                    Button {
                        save()
                    } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 28))
                            .foregroundColor(canSave ? .blue : .gray)
                    }
                    .disabled(!canSave)
                }
                .padding(.horizontal)
            }
            .padding(.vertical, 12)
            .background(Color(UIColor.systemBackground))
            .shadow(color: .black.opacity(0.1), radius: 10, y: -5)
        }
        .background(
            Color.black.opacity(0.3)
                .ignoresSafeArea()
                .onTapGesture {
                    close()
                }
        )
        .onAppear {
            // 0.1秒後にフォーカス（アニメーション完了後）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }

    private var canSave: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func save() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let newCard = PhraseCard(
            id: card?.id ?? UUID(),
            text: trimmedText,
            category: selectedCategory,
            isPreset: false,
            priority: card?.priority ?? 999,
            usageCount: card?.usageCount ?? 0,
            lastUsedAt: card?.lastUsedAt,
            createdAt: card?.createdAt ?? Date()
        )

        onSave(newCard)
        close()
    }

    private func close() {
        isFocused = false
        isPresented = false
    }
}

#Preview {
    @Previewable @State var isPresented = true

    ZStack {
        Color.gray.ignoresSafeArea()

        if isPresented {
            LINEStyleInputView(
                isPresented: $isPresented,
                card: nil,
                category: .morning
            ) { card in
                print("Saved: \(card.text)")
            }
            .transition(.move(edge: .bottom))
        }
    }
}
