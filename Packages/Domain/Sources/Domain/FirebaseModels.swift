// MARK: - Firebase Firestore Models
// Firebaseに保存するためのデータモデル定義
import Foundation

// MARK: - Enums (Firestore保存用 String RawValue)

/// Firebase用の興味タグ（enum版）
public enum FirebaseInterestTag: String, Codable, CaseIterable {
    case dinosaurs, space, cooking, animals, vehicles
    case music, sports, crafts, stories, insects
    case princess, heroes, robots, nature, others
}

/// Firebase用のセッションモード
public enum FirebaseSessionMode: String, Codable {
    case freeTalk     // 自由会話
    case story        // 物語モード
}

/// Firebase用のロール（既存のRoleと互換性を保つため、型エイリアスも提供）
public enum FirebaseRole: String, Codable {
    case child        // 子ども
    case ai           // AI
    case parent       // 親（録音再生など）
}

/// Firebase用の安全性フラグ
public enum FirebaseSafetyFlag: String, Codable {
    case selfHarm, violence, sexual, hate, bullying, other
}

/// Firebase用の音声ペイロード種別
public enum FirebaseVoicePayloadKind: String, Codable {
    case recorded     // 親の録音音声
    case tts          // テキスト読み上げ
}

/// Firebase用のトリガー種別
public enum FirebaseTriggerType: String, Codable {
    case manual       // 手動再生
    case timeBased    // 時刻指定（アプリ内ローカル通知トリガー）
}

/// Firebase用の共有レベル
public enum FirebaseSharingLevel: String, Codable {
    case none         // 履歴を残さない
    case summaryOnly  // 要約のみ保存
    case full         // 全文保存
}

// MARK: - Firestore DTOs (Data Transfer Objects)

/// 親ユーザープロフィール (/users/{userId})
public struct FirebaseParentProfile: Codable, Identifiable {
    public var id: String? // userId (Auth UID)
    public var displayName: String
    public var parentName: String? // 親の呼び名（ママ、パパなど）- オンボーディングで設定
    public var email: String? // メールアドレス（Apple Sign Inから取得）
    public var currentChildId: String? // 現在選択中の子どものID
    public var createdAt: Date

    public init(id: String? = nil, displayName: String = "", parentName: String? = nil, email: String? = nil, currentChildId: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.parentName = parentName
        self.email = email
        self.currentChildId = currentChildId
        self.createdAt = createdAt
    }
}

/// 子どもプロフィール (/users/{userId}/children/{childId})
public struct FirebaseChildProfile: Codable, Identifiable {
    public var id: String? // childId
    public var displayName: String // 名前
    public var nickName: String? // 呼び名
    public var birthDate: Date         // 生年月日（年齢計算用）
    public var photoURL: String? // 顔写真のURL（Firebase Storage）
    public var teddyName: String? // ぬいぐるみの名前
    public var interests: [FirebaseInterestTag]
    public var createdAt: Date

    // 計算プロパティ: 現在の年齢を返す
    public var currentAge: Int {
        let calendar = Calendar.current
        let ageComponents = calendar.dateComponents([.year], from: birthDate, to: Date())
        return ageComponents.year ?? 0
    }

    // イニシャライザ: 年齢(Int)から生年月日を逆算して生成する便利init
    public init(id: String? = nil, displayName: String, nickName: String? = nil, birthDate: Date? = nil, age: Int? = nil, photoURL: String? = nil, teddyName: String? = nil, interests: [FirebaseInterestTag] = [], createdAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.nickName = nickName
        self.photoURL = photoURL
        self.teddyName = teddyName
        self.interests = interests
        self.createdAt = createdAt

        // 生年月日が指定されていればそれを使用、なければ年齢から逆算
        if let birthDate = birthDate {
            self.birthDate = birthDate
        } else if let age = age {
            let calendar = Calendar.current
            self.birthDate = calendar.date(byAdding: .year, value: -age, to: Date()) ?? Date()
        } else {
            // デフォルトは3歳
            let calendar = Calendar.current
            self.birthDate = calendar.date(byAdding: .year, value: -3, to: Date()) ?? Date()
        }
    }
}

/// 会話セッション・メタデータ (/users/{userId}/children/{childId}/sessions/{sessionId})
public struct FirebaseConversationSession: Codable, Identifiable {
    public var id: String? // sessionId
    public var mode: FirebaseSessionMode
    public var startedAt: Date
    public var endedAt: Date?
    /// きょうだいがいる場合に「この会話は誰（どの子）の会話として記録したいか」を保持する。
    /// - Note: Firestore上の保存パス(/children/{childId}/...)とは独立に、UI表示/区別用のメタ情報として使う。
    public var speakerChildId: String?
    public var speakerChildName: String?
    public var interestContext: [FirebaseInterestTag] // この会話で触れられた興味タグ
    public var summaries: [String]            // 会話の短い要約（履歴一覧表示用）
    public var newVocabulary: [String]        // 新しく使った言葉
    public var turnCount: Int                 // ターンの総数

    public init(
        id: String? = nil,
        mode: FirebaseSessionMode,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        speakerChildId: String? = nil,
        speakerChildName: String? = nil,
        interestContext: [FirebaseInterestTag] = [],
        summaries: [String] = [],
        newVocabulary: [String] = [],
        turnCount: Int = 0
    ) {
        self.id = id
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.speakerChildId = speakerChildId
        self.speakerChildName = speakerChildName
        self.interestContext = interestContext
        self.summaries = summaries
        self.newVocabulary = newVocabulary
        self.turnCount = turnCount
    }
}

/// 会話のターン・詳細データ (.../sessions/{sessionId}/turns/{turnId})
/// ※ サブコレクション
public struct FirebaseTurn: Codable, Identifiable {
    public var id: String? // turnId
    public var role: FirebaseRole
    public var text: String?           // 会話テキスト
    public var audioPath: String?      // Storageパス
    public var duration: TimeInterval? // 音声の長さ(秒)
    public var safety: [FirebaseSafetyFlag]    // 安全性フラグ
    public var timestamp: Date         // 発話時刻

    public init(id: String? = nil, role: FirebaseRole, text: String?, audioPath: String? = nil, duration: TimeInterval? = nil, safety: [FirebaseSafetyFlag] = [], timestamp: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.audioPath = audioPath
        self.duration = duration
        self.safety = safety
        self.timestamp = timestamp
    }
}

/// 親の声スタンプ (/users/{userId}/voiceStamps/{stampId})
public struct FirebaseVoiceStamp: Codable, Identifiable {
    public var id: String? // stampId
    public var title: String
    public var payloadKind: FirebaseVoicePayloadKind
    public var trigger: FirebaseTriggerType
    public var isEnabled: Bool
    public var audioPath: String?      // Storageパス
    public var ttsText: String?        // TTSの場合のテキスト
    public var createdAt: Date
    public var lastPlayedAt: Date?

    public init(id: String? = nil, title: String, payloadKind: FirebaseVoicePayloadKind, trigger: FirebaseTriggerType, isEnabled: Bool = true, audioPath: String? = nil, ttsText: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.title = title
        self.payloadKind = payloadKind
        self.trigger = trigger
        self.isEnabled = isEnabled
        self.audioPath = audioPath
        self.ttsText = ttsText
        self.createdAt = createdAt
    }
}

/// 週次レポート (/users/{userId}/children/{childId}/reports/{weekISO})
/// LINE通知の代わりにアプリ内で表示するためのデータ
public struct FirebaseWeeklyReport: Codable, Identifiable {
    public struct SpeakerSection: Codable, Identifiable, Hashable {
        public var id: String { (speakerChildId ?? "") + "|" + (speakerChildName ?? "") }
        public var speakerChildId: String?
        public var speakerChildName: String?
        public var summary: String

        public init(speakerChildId: String? = nil, speakerChildName: String? = nil, summary: String) {
            self.speakerChildId = speakerChildId
            self.speakerChildName = speakerChildName
            self.summary = summary
        }
    }

    public var id: String? // weekISO (例: "2025-W47")
    /// 期間開始（週の開始日）。未設定の場合は createdAt / id から推定して表示側でフォールバックする。
    public var periodStart: Date?
    /// 期間終了（週の最終日）。未設定の場合は createdAt / id から推定して表示側でフォールバックする。
    public var periodEnd: Date?
    /// 「このレポートを生成した時点でのセッション数」。10セッション増えたら再生成、の判定に使う。
    public var sessionCountAtGeneration: Int?
    /// きょうだいがいる場合に、子ごとに分けた要約（任意）
    public var sections: [SpeakerSection]?

    public var summary: String         // 全体の要約（=画面の「まとめ」）
    public var topInterests: [FirebaseInterestTag] // よく話した話題TOP3
    public var newVocabulary: [String]     // 新しく使った言葉
    public var adviceForParent: String?    // 親へのアドバイス（AI生成）
    public var createdAt: Date

    public init(
        id: String? = nil,
        periodStart: Date? = nil,
        periodEnd: Date? = nil,
        sessionCountAtGeneration: Int? = nil,
        sections: [SpeakerSection]? = nil,
        summary: String,
        topInterests: [FirebaseInterestTag],
        newVocabulary: [String],
        adviceForParent: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.periodStart = periodStart
        self.periodEnd = periodEnd
        self.sessionCountAtGeneration = sessionCountAtGeneration
        self.sections = sections
        self.summary = summary
        self.topInterests = topInterests
        self.newVocabulary = newVocabulary
        self.adviceForParent = adviceForParent
        self.createdAt = createdAt
    }
}

/// アプリ設定 - 静かな時間帯 (/users/{userId}/settings/config)
public struct FirebaseQuietHours: Codable {
    public var start: String // "21:00"
    public var end: String   // "07:00"

    public init(start: String, end: String) {
        self.start = start
        self.end = end
    }
}

/// アプリ設定 (/users/{userId}/settings/config)
public struct FirebaseAppSettings: Codable, Identifiable {
    public var id: String? // "config" 固定
    public var sharingLevel: FirebaseSharingLevel
    public var quietHours: FirebaseQuietHours?
    public var languageCode: String
    public var enableEnglishMode: Bool

    public init(id: String? = "config", sharingLevel: FirebaseSharingLevel = .summaryOnly, quietHours: FirebaseQuietHours? = nil, languageCode: String = "ja-JP", enableEnglishMode: Bool = false) {
        self.id = id
        self.sharingLevel = sharingLevel
        self.quietHours = quietHours
        self.languageCode = languageCode
        self.enableEnglishMode = enableEnglishMode
    }
}
