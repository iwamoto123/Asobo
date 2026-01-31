import Foundation

// MARK: - カテゴリ定義
public enum PhraseCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case morning = "朝の準備"
    case meals = "食事"
    case bedtime = "就寝"
    case hygiene = "身支度"
    case play = "遊び"
    case praise = "ほめる"
    case custom = "その他"

    public var id: String { rawValue }

    public var icon: String {
        switch self {
        case .morning: return "sunrise.fill"
        case .meals: return "fork.knife"
        case .bedtime: return "moon.stars.fill"
        case .hygiene: return "hands.sparkles.fill"
        case .play: return "sportscourt.fill"
        case .praise: return "hand.thumbsup.fill"
        case .custom: return "square.grid.2x2"
        }
    }

    public var color: String {
        switch self {
        case .morning: return "orange"
        case .meals: return "green"
        case .bedtime: return "purple"
        case .hygiene: return "blue"
        case .play: return "pink"
        case .praise: return "yellow"
        case .custom: return "gray"
        }
    }
}

// MARK: - フレーズカード
public struct PhraseCard: Codable, Identifiable, Sendable {
    public let id: UUID
    public var text: String
    public var category: PhraseCategory
    public var isPreset: Bool          // 初期データか、ユーザー追加か
    public var priority: Int            // 表示順（小さいほど上位）
    public var usageCount: Int          // 使用回数
    public var lastUsedAt: Date?        // 最終使用日時
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        text: String,
        category: PhraseCategory,
        isPreset: Bool = false,
        priority: Int = 999,
        usageCount: Int = 0,
        lastUsedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.text = text
        self.category = category
        self.isPreset = isPreset
        self.priority = priority
        self.usageCount = usageCount
        self.lastUsedAt = lastUsedAt
        self.createdAt = createdAt
    }
}

// MARK: - リポジトリプロトコル
public protocol ParentPhrasesRepository: Sendable {
    func fetchAll() async throws -> [PhraseCard]
    func fetch(category: PhraseCategory) async throws -> [PhraseCard]
    func upsert(_ card: PhraseCard) async throws
    func delete(id: UUID) async throws
    func incrementUsage(id: UUID) async throws  // 使用回数+1、最終使用日時更新
    func updatePriority(id: UUID, priority: Int) async throws
}
