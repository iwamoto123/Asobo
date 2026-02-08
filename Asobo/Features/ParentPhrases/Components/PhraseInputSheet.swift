import SwiftUI
import Domain

struct PhraseInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: PhraseCard?
    let category: PhraseCategory
    let initialText: String?
    let availableCategories: [PhraseCategory]
    let onCreateCategory: ((String) -> Void)?
    let onPlay: ((String) -> Void)?
    let isPlaying: Bool
    let onSave: (PhraseCard) -> Void

    @State private var text: String
    @State private var selectedCategory: PhraseCategory
    @State private var newCategoryName: String = ""

    init(
        card: PhraseCard?,
        category: PhraseCategory,
        initialText: String? = nil,
        availableCategories: [PhraseCategory] = PhraseCategory.builtinAllCases,
        onCreateCategory: ((String) -> Void)? = nil,
        onPlay: ((String) -> Void)? = nil,
        isPlaying: Bool = false,
        onSave: @escaping (PhraseCard) -> Void
    ) {
        self.card = card
        self.category = category
        self.initialText = initialText
        self.availableCategories = availableCategories
        self.onCreateCategory = onCreateCategory
        self.onPlay = onPlay
        self.isPlaying = isPlaying
        self.onSave = onSave
        _text = State(initialValue: card?.text ?? initialText ?? "")
        _selectedCategory = State(initialValue: card?.category ?? category)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("フレーズ") {
                    TextField("例: 早くお着替えしようね", text: $text, axis: .vertical)
                        .lineLimit(3...6)
                }

                Section("カテゴリ") {
                    Picker("カテゴリ", selection: $selectedCategory) {
                        ForEach(availableCategories) { category in
                            HStack {
                                Image(systemName: category.icon)
                                Text(category.rawValue)
                            }
                            .tag(category)
                        }
                    }
                    .pickerStyle(.inline)

                    TextField("新しいカテゴリ名（任意）", text: $newCategoryName)
                        .textInputAutocapitalization(.never)
                }
            }
            .navigationTitle(card == nil ? "新しいフレーズ" : "フレーズを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    HStack(spacing: 12) {
                        if onPlay != nil {
                            Button {
                                onPlay?(text)
                            } label: {
                                if isPlaying {
                                    ProgressView()
                                } else {
                                    Image(systemName: "play.circle.fill")
                                }
                            }
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isPlaying)
                        }

                        Button("保存") {
                            save()
                        }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
        }
    }

    private func save() {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedText.isEmpty else { return }

        let newCatName = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalCategory: PhraseCategory
        if !newCatName.isEmpty {
            finalCategory = PhraseCategory(newCatName)
            onCreateCategory?(newCatName)
        } else {
            finalCategory = selectedCategory
        }

        let newCard = PhraseCard(
            id: card?.id ?? UUID(),
            text: trimmedText,
            category: finalCategory,
            isPreset: false,
            priority: card?.priority ?? 999,
            usageCount: card?.usageCount ?? 0,
            lastUsedAt: card?.lastUsedAt,
            createdAt: card?.createdAt ?? Date()
        )

        onSave(newCard)
        dismiss()
    }
}

#Preview {
    PhraseInputSheet(
        card: nil,
        category: .morning,
        availableCategories: PhraseCategory.builtinAllCases,
        onCreateCategory: { _ in },
        onPlay: { text in print("Play: \(text)") }
    ) { card in
        print("Saved: \(card.text)")
    }
}
