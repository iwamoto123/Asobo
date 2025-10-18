// MARK: - Domain primitives
import Foundation
import AVFoundation

// 年齢帯に応じて会話ガードレールや語彙制限に使用
public enum AgeGroup: Int, Codable, CaseIterable {
    case toddler = 3    // 3-4歳
    case preschool = 5  // 5-6歳
    case earlyPrimary = 7 // 7-8歳
    case upperPrimary = 10 // 9-10歳
    case junior = 12    // 11-12歳
    case teen = 15      // 13-15歳
}

public struct InterestTag: Hashable, Codable, Identifiable {
    public let id: UUID
    public var label: String           // "恐竜", "宇宙", "料理" など
    public var weight: Double          // 最近の関心度（集計用）
    public init(id: UUID = .init(), label: String, weight: Double = 0) {
        self.id = id; self.label = label; self.weight = weight
    }
}

public enum SharingLevel: String, Codable, CaseIterable {
    case none        // 非共有
    case summaryOnly // 要約のみ（デフォルト）
    case keyTopics   // 重要トピックのみ
}

public struct QuietHours: Codable, Equatable {
    public var start: DateComponents   // 例: 21:00
    public var end: DateComponents     // 例: 7:00
}

public struct AppSettings: Codable {
    public var sharingLevel: SharingLevel
    public var quietHours: QuietHours?
    public var languageCode: String // "ja-JP" / "en-US" など
    public var enableEnglishMode: Bool
    public init(sharingLevel: SharingLevel = .summaryOnly,
                quietHours: QuietHours? = nil,
                languageCode: String = "ja-JP",
                enableEnglishMode: Bool = false) {
        self.sharingLevel = sharingLevel
        self.quietHours = quietHours
        self.languageCode = languageCode
        self.enableEnglishMode = enableEnglishMode
    }
}

// MARK: - Users
public struct ChildProfile: Codable, Identifiable {
    public let id: UUID
    public var displayName: String         // 子供の表示名（フルネーム）
    public var nickName: String?           // 会話で呼ぶときの名前（愛称など）
    public var ageGroup: AgeGroup
    public var interests: [InterestTag]
    public var createdAt: Date
}

public struct ParentProfile: Codable, Identifiable {
    public let id: UUID
    public var displayName: String
    public var lineUserId: String?   // LINE連携用
    public var createdAt: Date
}

// MARK: - 親の声（録音/テキスト→音声）
public enum VoicePayload: Codable {
    case recorded(audioURL: URL, duration: TimeInterval)
    case tts(text: String, voiceHint: String?) // 将来: 親声色近似のためのヒント
}

public enum Trigger: Codable {
    case manual
    case timeBased(DateComponents) // ローカル通知と連動
}

public struct VoiceStamp: Codable, Identifiable {
    public let id: UUID
    public var title: String                  // 例: 「お片付けの時間だよ」
    public var payload: VoicePayload
    public var trigger: Trigger               // 時刻指定/手動
    public var isEnabled: Bool
    public var createdAt: Date
    public var lastPlayedAt: Date?
}

// MARK: - 会話/物語
public enum Role: String, Codable { case child, ai, parent }

public struct SafetyFlag: Codable, Identifiable {
    public enum Category: String, Codable { case selfHarm, violence, sexual, hate, other }
    public let id: UUID
    public let category: Category
    public let severity: Int // 1-5
    public let message: String
    public let timestamp: Date
}

public struct TurnTiming: Codable { // レイテンシ測定や先出し進捗に使用
    public var captureStart: Date?  // 録音開始
    public var captureEnd: Date?    // 録音終了（VAD終端）
    public var firstTokenAt: Date?  // LLM最初のトークン
    public var firstAudioAt: Date?  // TTS最初のチャンク
    public var playbackStart: Date? // 再生開始
    public var playbackEnd: Date?   // 再生完了
}

public struct Turn: Codable, Identifiable {
    public let id: UUID
    public var role: Role
    public var text: String?            // STT/LLM 文字列
    public var audioURL: URL?           // 録音/合成音声のローカルURL
    public var duration: TimeInterval?  // 再生長
    public var safety: [SafetyFlag]     // 入出力両側の検知
    public var timing: TurnTiming       // パフォーマンス可視化
}

public enum SessionMode: String, Codable { case freeTalk, story }

public struct ConversationSession: Codable, Identifiable {
    public let id: UUID
    public var childId: UUID
    public var mode: SessionMode
    public var startedAt: Date
    public var endedAt: Date?
    public var interestContext: [InterestTag] // セッション前の推定関心
    public var turns: [Turn]
    public var summaries: [String]    // 短縮要約（後で週次に集約）
}

public struct StorySpec: Codable, Identifiable {
    public let id: UUID
    public var title: String
    public var seedPrompt: String     // プロンプトテンプレ＋タグ
    public var tags: [InterestTag]
    public var targetDurationSec: Int // 1–2分
}

public struct StoryState: Codable {
    public var chapterIndex: Int
    public var isPlaying: Bool
    public var lastInterruptionAt: Date?
}

// MARK: - レポート
public struct WeeklyReport: Codable, Identifiable {
    public let id: UUID
    public var childId: UUID
    public var weekStartISO: String   // 例: "2025-W36"
    public var summary: String        // 週次まとめ（保護者向け）
    public var topInterests: [InterestTag]
    public var newVocabulary: [String]
    public var reportURL: URL?        // LINEで送る遷移先
    public var createdAt: Date
}

// MARK: - BLE / 外部機器
public enum BLEConnectionState: String, Codable { case disconnected, scanning, connecting, connected }

public struct BLEDevice: Codable, Identifiable {
    public let id: UUID // CBPeripheral.identifier を保持
    public var name: String?
    public var rssi: Int?
    public var batteryLevel: UInt8?
    public var isPreferred: Bool
    public var state: BLEConnectionState
}

public struct PTTEvent: Codable, Identifiable {
    public let id: UUID
    public let deviceId: UUID
    public let isPressed: Bool
    public let timestamp: Date
}

// MARK: - 保存ポリシー / ライフサイクル
public struct RetentionPolicy: Codable {
    public var rawAudioHours: Int      // 72
    public var textDays: Int           // 90
}

// MARK: - 抽象クライアント（AI/BLE/保存層）
// 音声→LLM→音声 のストリーミング一体型を優先（OpenAI Realtime想定）
public protocol RealtimeClient {
    func startSession(child: ChildProfile, context: [InterestTag]) async throws
    func sendMicrophonePCM(_ buffer: AVAudioPCMBuffer) async throws
    func interruptAndYield() async throws         // PTT割り込み
    func nextAudioChunk() async throws -> Data?   // PCM/Opusなど（先出し再生）
    func nextPartialText() async throws -> String?// 吹き出し用部分文字列
    func nextInputText() async throws -> String?  // 音声入力のテキスト
    func finishSession() async throws
}

// フォールバック用（分離実装）
public protocol STTClient { func start() async throws; func send(_ buffer: AVAudioPCMBuffer) async; func finish() async throws -> String }
public protocol LLMClient { func reply(to prompt: String, context: [InterestTag], age: AgeGroup) async throws -> AsyncStream<String> }
public protocol TTSClient { func speakStream(_ text: String, voice: String?) async throws -> AsyncStream<Data> }

// BLE土台
public protocol BLERepository {
    func startScan() async
    func connect(to id: UUID) async
    func preferredDevice() -> BLEDevice?
    func observePTT() -> AsyncStream<PTTEvent>
    func writeLED(mode: UInt8) async throws
}

// 永続化リポジトリ（CoreData/SwiftDataの裏側を差し替え可）
public protocol ConversationsRepository {
    func save(session: ConversationSession) async throws
    func recentSessions(childId: UUID, limit: Int) async throws -> [ConversationSession]
}

public protocol VoiceStampRepository {
    func list() async throws -> [VoiceStamp]
    func upsert(_ item: VoiceStamp) async throws
    func delete(id: UUID) async throws
}

public protocol ReportsRepository {
    func latest(childId: UUID, count: Int) async throws -> [WeeklyReport]
}

public protocol SettingsRepository {
    func load() async throws -> AppSettings
    func save(_ settings: AppSettings) async throws
}

// MARK: - 集計/サマリ（アプリ内最小レベル）
public struct ConversationAnalytics {
    public static func extractTopInterests(from sessions: [ConversationSession], topK: Int = 3) -> [InterestTag] {
        var map: [String: Double] = [:]
        for s in sessions {
            for t in s.interestContext { map[t.label, default: 0] += t.weight }
        }
        return map.sorted { $0.value > $1.value }.prefix(topK).map { InterestTag(label: $0.key, weight: $0.value) }
    }

    public static func extractNewVocabulary(from sessions: [ConversationSession], known: Set<String>) -> [String] {
        var vocab: Set<String> = []
        for s in sessions {
            for turn in s.turns where turn.role == .child {
                if let text = turn.text { text.split(separator: " ").forEach { token in
                    let t = token.trimmingCharacters(in: .punctuationCharacters)
                    if !t.isEmpty && !known.contains(t) { vocab.insert(t) }
                }}
            }
        }
        return Array(vocab).sorted()
    }
}

// MARK: - サンプル初期データ
public extension ChildProfile {
    static func sample() -> ChildProfile {
        .init(id: .init(), displayName: "たろう", nickName: "たろちゃん", ageGroup: .earlyPrimary, interests: [InterestTag(label: "恐竜", weight: 0.8), InterestTag(label: "宇宙", weight: 0.6)], createdAt: Date())
    }
}
