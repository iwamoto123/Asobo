import Foundation

// MARK: - カテゴリ定義
/// ✅ ユーザーが自由に追加できるカテゴリ
/// - note: 既存データ互換のため、Codableは「単一の文字列」としてエンコード/デコードします
public struct PhraseCategory: Codable, Hashable, Identifiable, Sendable {
    public let name: String

    public init(_ name: String) {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var id: String { name }

    // 既存コード互換（旧rawValue参照を徐々に置換するまでのブリッジ）
    public var rawValue: String { name }
    public init(rawValue: String) { self.init(rawValue) }

    // MARK: - Built-in categories
    public static let morning = PhraseCategory("朝の準備")
    public static let meals = PhraseCategory("食事")
    public static let bedtime = PhraseCategory("就寝")
    public static let hygiene = PhraseCategory("身支度")
    public static let play = PhraseCategory("遊び")
    public static let praise = PhraseCategory("ほめる")
    public static let cleanup = PhraseCategory("お片付け")
    public static let other = PhraseCategory("その他")

    public static var builtinAllCases: [PhraseCategory] {
        [.morning, .meals, .bedtime, .hygiene, .play, .praise, .cleanup, .other]
    }

    public var isBuiltin: Bool {
        Self.builtinAllCases.contains(self)
    }

    public var icon: String {
        switch name {
        case Self.morning.name: return "alarm.fill"
        case Self.meals.name: return "fork.knife"
        case Self.bedtime.name: return "moon.stars.fill"
        case Self.hygiene.name: return "hands.sparkles.fill"
        case Self.play.name: return "sportscourt.fill"
        case Self.praise.name: return "hand.thumbsup.fill"
        case Self.cleanup.name: return "tray.full.fill"
        case Self.other.name: return "square.grid.2x2"
        default: return "tag.fill"
        }
    }

    public var color: String {
        switch name {
        case Self.morning.name: return "orange"
        case Self.meals.name: return "green"
        case Self.bedtime.name: return "purple"
        case Self.hygiene.name: return "blue"
        case Self.play.name: return "pink"
        case Self.praise.name: return "yellow"
        case Self.cleanup.name: return "brown"
        case Self.other.name: return "gray"
        default: return "gray"
        }
    }

    // MARK: - Codable (single-value for backward compatibility)
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        self.name = s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(name)
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
