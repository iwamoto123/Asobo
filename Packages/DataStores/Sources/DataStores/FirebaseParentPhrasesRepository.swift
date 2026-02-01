import Foundation
import FirebaseFirestore
import Domain

/// Firebase Firestoreを使用した保護者フレーズリポジトリ
@MainActor
public final class FirebaseParentPhrasesRepository: ParentPhrasesRepository {
    private let db = Firestore.firestore()
    private let userId: String

    private var phrasesCollection: CollectionReference {
        db.collection("users").document(userId).collection("parentPhrases")
    }

    public init(userId: String) {
        self.userId = userId
    }

    // MARK: - Fetch

    public func fetchAll() async throws -> [PhraseCard] {
        let snapshot = try await phrasesCollection
            .order(by: "priority")
            .getDocuments()

        let cards = snapshot.documents.compactMap { doc -> PhraseCard? in
            try? doc.data(as: PhraseCardDTO.self).toDomain()
        }

        // 初回起動時に初期データを挿入
        if cards.isEmpty {
            try await insertPresetData()
            return try await fetchAll()
        }

        return cards
    }

    public func fetch(category: PhraseCategory) async throws -> [PhraseCard] {
        let snapshot = try await phrasesCollection
            .whereField("category", isEqualTo: category.rawValue)
            .order(by: "priority")
            .getDocuments()

        return snapshot.documents.compactMap { doc -> PhraseCard? in
            try? doc.data(as: PhraseCardDTO.self).toDomain()
        }
    }

    // MARK: - Upsert

    public func upsert(_ card: PhraseCard) async throws {
        let dto = PhraseCardDTO.fromDomain(card)
        try phrasesCollection.document(card.id.uuidString).setData(from: dto)
    }

    // MARK: - Delete

    public func delete(id: UUID) async throws {
        try await phrasesCollection.document(id.uuidString).delete()
    }

    // MARK: - Increment Usage

    public func incrementUsage(id: UUID) async throws {
        let docRef = phrasesCollection.document(id.uuidString)
        try await docRef.updateData([
            "usageCount": FieldValue.increment(Int64(1)),
            "lastUsedAt": Timestamp(date: Date())
        ])
    }

    // MARK: - Update Priority

    public func updatePriority(id: UUID, priority: Int) async throws {
        let docRef = phrasesCollection.document(id.uuidString)
        try await docRef.updateData(["priority": priority])
    }

    // MARK: - Private Helpers

    private func insertPresetData() async throws {
        let presets = PresetPhrases.createCards()
        print("🔥 FirebaseParentPhrasesRepository: プリセットデータ挿入開始 - \(presets.count)件")

        for card in presets {
            try await upsert(card)
        }

        print("✅ FirebaseParentPhrasesRepository: プリセットデータ挿入完了")
    }
}

// MARK: - Firestore DTO

private struct PhraseCardDTO: Codable {
    let id: String
    let text: String
    let category: String
    let isPreset: Bool
    let priority: Int
    let usageCount: Int
    let lastUsedAt: Timestamp?
    let createdAt: Timestamp

    func toDomain() -> PhraseCard {
        PhraseCard(
            id: UUID(uuidString: id) ?? UUID(),
            text: text,
            category: PhraseCategory(rawValue: category.isEmpty ? PhraseCategory.other.rawValue : category),
            isPreset: isPreset,
            priority: priority,
            usageCount: usageCount,
            lastUsedAt: lastUsedAt?.dateValue(),
            createdAt: createdAt.dateValue()
        )
    }

    static func fromDomain(_ card: PhraseCard) -> PhraseCardDTO {
        PhraseCardDTO(
            id: card.id.uuidString,
            text: card.text,
            category: card.category.rawValue,
            isPreset: card.isPreset,
            priority: card.priority,
            usageCount: card.usageCount,
            lastUsedAt: card.lastUsedAt.map { Timestamp(date: $0) },
            createdAt: Timestamp(date: card.createdAt)
        )
    }
}
