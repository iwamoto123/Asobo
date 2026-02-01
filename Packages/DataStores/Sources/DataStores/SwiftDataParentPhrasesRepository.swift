import Foundation
import SwiftData
import Domain

// MARK: - SwiftData Entity
@available(iOS 17.0, *)
@Model
final class PhraseCardEntity {
    @Attribute(.unique) var id: UUID
    var text: String
    var categoryRawValue: String
    var isPreset: Bool
    var priority: Int
    var usageCount: Int
    var lastUsedAt: Date?
    var createdAt: Date

    init(id: UUID, text: String, category: PhraseCategory, isPreset: Bool,
         priority: Int, usageCount: Int, lastUsedAt: Date?, createdAt: Date) {
        self.id = id
        self.text = text
        self.categoryRawValue = category.rawValue
        self.isPreset = isPreset
        self.priority = priority
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }

    func toDomain() -> PhraseCard {
        PhraseCard(
            id: id,
            text: text,
            category: PhraseCategory(rawValue: categoryRawValue.isEmpty ? PhraseCategory.other.rawValue : categoryRawValue),
            isPreset: isPreset,
            priority: priority,
            usageCount: usageCount,
            lastUsedAt: lastUsedAt,
            createdAt: createdAt
        )
    }

    static func fromDomain(_ card: PhraseCard) -> PhraseCardEntity {
        PhraseCardEntity(
            id: card.id,
            text: card.text,
            category: card.category,
            isPreset: card.isPreset,
            priority: card.priority,
            usageCount: card.usageCount,
            lastUsedAt: card.lastUsedAt,
            createdAt: card.createdAt
        )
    }
}

// MARK: - Repository Implementation
@available(iOS 17.0, *)
@MainActor
public final class SwiftDataParentPhrasesRepository: ParentPhrasesRepository {
    private let modelContainer: ModelContainer
    private let modelContext: ModelContext

    public init() throws {
        let schema = Schema([PhraseCardEntity.self])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        self.modelContainer = try ModelContainer(for: schema, configurations: [config])
        self.modelContext = modelContainer.mainContext

        // 初回起動時に初期データを挿入
        Task { await insertPresetDataIfNeeded() }
    }

    private func insertPresetDataIfNeeded() async {
        let descriptor = FetchDescriptor<PhraseCardEntity>()
        let count = (try? modelContext.fetchCount(descriptor)) ?? 0

        if count == 0 {
            print("📦 初期フレーズデータを挿入します")
            let presets = PresetPhrases.createCards()
            for card in presets {
                let entity = PhraseCardEntity.fromDomain(card)
                modelContext.insert(entity)
            }
            try? modelContext.save()
            print("✅ 初期フレーズデータ挿入完了: \(presets.count)件")
        }
    }

    public func fetchAll() async throws -> [PhraseCard] {
        let descriptor = FetchDescriptor<PhraseCardEntity>(
            sortBy: [SortDescriptor(\.priority), SortDescriptor(\.createdAt, order: .reverse)]
        )
        let entities = try modelContext.fetch(descriptor)
        return entities.map { $0.toDomain() }
    }

    public func fetch(category: PhraseCategory) async throws -> [PhraseCard] {
        let predicate = #Predicate<PhraseCardEntity> {
            $0.categoryRawValue == category.rawValue
        }
        let descriptor = FetchDescriptor<PhraseCardEntity>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.priority), SortDescriptor(\.usageCount, order: .reverse)]
        )
        let entities = try modelContext.fetch(descriptor)
        return entities.map { $0.toDomain() }
    }

    public func upsert(_ card: PhraseCard) async throws {
        let predicate = #Predicate<PhraseCardEntity> { $0.id == card.id }
        let descriptor = FetchDescriptor<PhraseCardEntity>(predicate: predicate)
        let existing = try modelContext.fetch(descriptor).first

        if let existing = existing {
            existing.text = card.text
            existing.categoryRawValue = card.category.rawValue
            existing.priority = card.priority
            existing.usageCount = card.usageCount
            existing.lastUsedAt = card.lastUsedAt
        } else {
            let entity = PhraseCardEntity.fromDomain(card)
            modelContext.insert(entity)
        }
        try modelContext.save()
    }

    public func delete(id: UUID) async throws {
        let predicate = #Predicate<PhraseCardEntity> { $0.id == id }
        let descriptor = FetchDescriptor<PhraseCardEntity>(predicate: predicate)
        if let entity = try modelContext.fetch(descriptor).first {
            modelContext.delete(entity)
            try modelContext.save()
        }
    }

    public func incrementUsage(id: UUID) async throws {
        let predicate = #Predicate<PhraseCardEntity> { $0.id == id }
        let descriptor = FetchDescriptor<PhraseCardEntity>(predicate: predicate)
        if let entity = try modelContext.fetch(descriptor).first {
            entity.usageCount += 1
            entity.lastUsedAt = Date()
            try modelContext.save()
        }
    }

    public func updatePriority(id: UUID, priority: Int) async throws {
        let predicate = #Predicate<PhraseCardEntity> { $0.id == id }
        let descriptor = FetchDescriptor<PhraseCardEntity>(predicate: predicate)
        if let entity = try modelContext.fetch(descriptor).first {
            entity.priority = priority
            try modelContext.save()
        }
    }
}
