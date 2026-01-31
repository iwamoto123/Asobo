import SwiftUI
import Domain

struct PhraseInputSheet: View {
    @Environment(\.dismiss) private var dismiss
    let card: PhraseCard?
    let category: PhraseCategory
    let onSave: (PhraseCard) -> Void

    @State private var text: String
    @State private var selectedCategory: PhraseCategory

    init(card: PhraseCard?, category: PhraseCategory, onSave: @escaping (PhraseCard) -> Void) {
        self.card = card
        self.category = category
        self.onSave = onSave
        _text = State(initialValue: card?.text ?? "")
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
                        ForEach(PhraseCategory.allCases) { category in
                            HStack {
                                Image(systemName: category.icon)
                                Text(category.rawValue)
                            }
                            .tag(category)
                        }
                    }
                    .pickerStyle(.inline)
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
                    Button("保存") {
                        save()
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
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
        dismiss()
    }
}

#Preview {
    PhraseInputSheet(
        card: nil,
        category: .morning
    ) { card in
        print("Saved: \(card.text)")
    }
}
