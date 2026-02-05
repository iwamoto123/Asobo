//
//  ConversationController.swift
//

import Foundation
import AVFoundation
import Speech
import Domain
import Services
import Support
import DataStores
import Network
#if canImport(UIKit)
import UIKit
#endif

@MainActor
public final class ConversationController: NSObject, ObservableObject {

    // MARK: - UI State
    public enum Mode: String, CaseIterable { case localSTT, realtime }

    // ✅ 機能トグル
    public static let localSTTEnabled: Bool = true
    public var isLocalSTTEnabled: Bool { Self.localSTTEnabled }

    @Published public var mode: Mode = .localSTT
    @Published public var transcript: String = ""
    /// 履歴/ログに積むのと同じ「確定ユーザー発話テキスト」。
    /// Homeのモニター表示など、"正確な確定文" を出したい箇所で使用する。
    @Published public var lastCommittedUserText: String = ""
    @Published public var isRecording: Bool = false
    @Published public var errorMessage: String?
    @Published public var isRealtimeActive: Bool = false
    @Published public var isRealtimeConnecting: Bool = false
    // ✅ 音声プレビュー用のローカル文字起こしを行うか（端末環境で kAFAssistantErrorDomain 1101 が多発するためデフォルトOFF）
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    let enableLocalUserTranscription: Bool = ConversationController.localSTTEnabled

    // MARK: - AudioMissing mitigation
    /// `gpt-4o-audio-preview` が「テキストのみ（audioMissing=true）」で返ることがあるため、
    /// 直近の連続回数を数えて systemPrompt にブースト指示を入れる。
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    var audioMissingConsecutiveCount: Int = 0

    // 追加: ユーザーが停止したかを覚えるフラグ
    private var userStoppedRecording = false

    // ✅ AI音声再生中フラグ（onAudioDeltaReceivedで設定、sendMicrophonePCMの早期returnを一元化）
    // NOTE: 別ファイルのextensionから更新するため internal（モジュール内限定）
    @Published var isAIPlayingAudio: Bool = false
    // ✅ ハンズフリーモードの有効化フラグ
    @Published public var isHandsFreeMode: Bool = false

    // ✅ ターン状態（拡張版）
    enum TurnState: Equatable {
        case idle               // セッション前 or 終了後
        case waitingUser        // 初回/毎ターン：まずユーザーの声を待つ
        case nudgedByAI(Int)   // 促し(何回目かインデックス)
        case listening          // VADが speech_started 〜 speech_stopped の間
        case thinking           // commit 済み〜応答生成中
        case speaking           // AIがTTS出力中
        case clarifying         // 聞き取り不可→聞き返し中
    }
    // NOTE: 別ファイルのextensionから状態更新するため internal(set) 相当（=制限なし）にする
    @Published var turnState: TurnState = .idle

    // ✅ 「待つ→促す」タイマー
    private var nudgeTimer: Timer?
    // ✅ 促し回数の上限とカウンター
    private let maxNudgeCount = AppConfig.nudgeMaxCount
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var nudgeCount = 0

    // ✅ 追加: 最後に「ユーザーの声（環境音含む）」が閾値を超えた時刻
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var lastUserVoiceActivityTime: Date = Date()
    var lastInputRMS: Double?

    /// デバッグ用：直近の入力RMS(dB)。VAD制御とは独立に「観測ウィンドウ」で参照する。
    public var debugLastInputRmsDb: Double? { lastInputRMS }
    /// デバッグ用：開始/終了のRMS閾値（入力ルートで変化し得るのでログ用に公開）
    public var debugActiveRmsStartThresholdDb: Double { activeRmsStartThresholdDb }
    public var debugActiveSpeechEndRmsThresholdDb: Double { activeSpeechEndRmsThresholdDb }

    // ✅ 追加: 無音判定の閾値（-50dBより大きければ「何か音がしている」とみなす）
    // 調整目安: -40dB(普通) 〜 -60dB(静寂)。-50dBは「ささやき声や環境音」レベル
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    let silenceThresholdDb: Double = -50.0

    // ✅ 追加: speech_startedが来ていない警告のカウンター
    private var speechStartedMissingCount: Int = 0

    // MARK: - VAD (Hands-free Conversation)
    enum VADState { case idle, speaking }
    // 🔧 Temporarily extremely low thresholds to force VAD triggering
    // 🔧 Loosened thresholds to verify sensitivity (see VAD logging)
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    let speechStartThreshold: Float = 0.005
    let speechEndThreshold: Float = 0.002
    let defaultRmsStartThresholdDb: Double = -40.0
    // Bluetooth/HFPは入力レベルが小さめ/ばらつきやすいので、開始判定を少し甘くする（より負の値にすると開始しやすい）
    let bluetoothRmsStartThresholdDb: Double = -45.0
    // ✅ 発話終了側のRMS閾値（dBFS）
    // iPhone内蔵マイク + VoiceChat/VoiceProcessing だと静かな環境でもノイズフロアが -45〜-50dB 付近に張り付くことがあり、
    // -55dBを要求すると「無音にならない」扱いで speaking が終わらないことがあるため、少し高めにする。
    let defaultSpeechEndRmsThresholdDb: Double = -50.0
    // Bluetooth/HFPはノイズフロアが高く、-55dB未満に落ちにくいため終了できずspeaking張り付きになりやすい
    let bluetoothSpeechEndRmsThresholdDb: Double = -45.0
    let defaultMinSilenceDuration: TimeInterval = 1.2
    let bluetoothMinSilenceDuration: TimeInterval = 1.2
    let speechStartHoldDuration: TimeInterval = 0.15
    let minSpeechDuration: TimeInterval = 0.25
    // ✅ 割り込み判定用（Silero VADを一定時間連続検出した場合のみ停止）
    let bargeInVADThreshold: Float = 0.5
    let bargeInHoldDuration: TimeInterval = 0.15  // 150ms ヒステリシス
    var vadInterruptSpeechStart: Date?
    // NOTE: 別ファイルのextensionから参照/更新するため internal(set) 相当（=制限なし）にする
    @Published var vadState: VADState = .idle
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var speechStartTime: Date?
    var silenceTimer: Timer?
    var isUserSpeaking: Bool = false
    var speechStartCandidateTime: Date?
    // ✅ VAD確率(prob)が壊れて常に低い/張り付く場合、終了判定に使うと即終了し得る。
    //    「開始がprobでトリガされていない」ターンでは、終了判定ではprobを信用しない。
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var speechStartTriggeredByProb: Bool = false

    // MARK: - STT-based VAD (New policy)
    // SileroVAD/RMSは測定・可視化用途として残すが、発話開始/終了の判定はライブSTTで行う
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    let sttVADSpeechStartMinChars: Int = 1
    let sttVADEndSilenceDuration: TimeInterval = 1.5
    var sttVADEndTimer: Timer?

    // MARK: - Hands-free Realtime STT Monitor (for end-of-speech fallback)
    // 「テキスト化を検知後、雑音などテキスト化できないものが続いたら発話終了」用
    // ✅ STTフォールバック用の猶予（sttStagnation / sttNoText を統一）
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    let sttFallbackDuration: TimeInterval = 3.0
    var sttStagnationDuration: TimeInterval { sttFallbackDuration }
    let sttStagnationMinChars: Int = 2
    // 「テキストが全く出ないまま、音だけが続く（音楽/雑音）」ケースのフォールバック
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var sttNoTextDuration: TimeInterval { sttFallbackDuration }

    // ✅ 状態モニター用：ハンズフリー並走STTのリアルタイム表示
    @Published public var handsFreeMonitorTranscript: String = ""
    @Published public var handsFreeMonitorStatus: String = "off" // off / running / error
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    let handsFreeMonitorUIUpdateMinInterval: TimeInterval = 0.15
    var handsFreeMonitorLastUIUpdateAt: Date?

    // ✅ SpeechEnd後のフォールバック送信用（Local STTが空のときに使う）
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var handsFreeMonitorFinalCandidate: String = ""

    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var handsFreeSTTRequest: SFSpeechAudioBufferRecognitionRequest?
    var handsFreeSTTTask: SpeechRecognitionTasking?
    var handsFreeSTTLastNormalized: String = ""
    var handsFreeSTTLastChangeAt: Date?
    var handsFreeSTTRestartTask: Task<Void, Never>?
    var handsFreeSTTLastAutoStartAt: Date?
    // バージイン検知専用の「前回テキスト」。AI再生開始時/割り込み後にリセットして取りこぼしを減らす。
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var handsFreeBargeInLastNormalized: String = ""
    var handsFreeSTTAppendCount: UInt64 = 0
    var handsFreeSTTLastAppendLogAt: Date?

    // MARK: - STT-based Barge-in (while AI speaking)
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var aiPlaybackStartedAt: Date?
    var lastSTTBargeInAt: Date?
    let sttBargeInIgnoreWindowAfterPlaybackStart: TimeInterval = 0.2
    let sttBargeInMinInterval: TimeInterval = 0.8
    let sttBargeInMinChars: Int = 2

    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    var isBluetoothInput: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }
    var activeRmsStartThresholdDb: Double {
        isBluetoothInput ? bluetoothRmsStartThresholdDb : defaultRmsStartThresholdDb
    }
    var activeSpeechEndRmsThresholdDb: Double {
        isBluetoothInput ? bluetoothSpeechEndRmsThresholdDb : defaultSpeechEndRmsThresholdDb
    }
    var activeMinSilenceDuration: TimeInterval {
        isBluetoothInput ? bluetoothMinSilenceDuration : defaultMinSilenceDuration
    }

    // ✅ 各ターンのレイテンシ計測用
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）にしている
    struct TurnMetrics {
        var listenStart: Date?
        var speechEnd: Date?
        var requestStart: Date?
        var firstByte: Date?
        var firstAudio: Date?
        var firstText: Date?
        var streamComplete: Date?
        var playbackEnd: Date?
    }
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var turnMetrics = TurnMetrics()

    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false
    @Published public var liveSummary: String = ""                 // 会話の簡易要約（毎ターン更新）
    @Published public var liveInterests: [FirebaseInterestTag] = [] // セッション終了時に更新
    @Published public var liveNewVocabulary: [String] = []          // セッション終了時に更新
    // ✅ 割り込み後に流入する古いAIチャンクを無視するためのゲート
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var ignoreIncomingAIChunks: Bool = false
    var currentTurnId: Int = 0         // ターンの世代ID（単一の真実）
    var listeningTurnId: Int = 0       // VAD/録音用の世代ID
    var playbackTurnId: Int?           // 再生状態通知の世代ID

    // AI呼び出し用フィールド
    @Published public var isThinking: Bool = false   // ぐるぐる表示用
    private var lastAskedText: String = ""           // 同文の連投防止

    // MARK: - Local STT (Speech) - DI対応
    private let audioEngine = AVAudioEngine()
    private let audioSession: AudioSessionManaging
    /// 確定用（PTT/録音後のローカルSTT）
    private let speech: SpeechRecognizing
    /// ハンズフリー監視用（バージイン/ライブ表示）
    /// iOSでは同一recognizerで複数taskを回すとキャンセル競合しやすいので分ける
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    let handsFreeSpeech: SpeechRecognizing
    private var sttRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sttTask: SpeechRecognitionTasking?

    // MARK: - Realtime (OpenAI)
    // NOTE: 別ファイルのextensionから参照するため internal（モジュール内限定）
    let audioSessionManager = AudioSessionManager()
    // ✅ AEC有効化のため、共通のAVAudioEngineを使用
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    let sharedAudioEngine = AVAudioEngine()
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var mic: MicrophoneCapture?
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    var player: PlayerNodeStreamer            // 音声先出し（必要に応じて）
    // ✅ Realtime API はコメントアウトして、gpt-4o-audio-preview ストリーミングに切り替え
    private var realtimeClient: RealtimeClientOpenAI?
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var audioPreviewClient: AudioPreviewStreamingClient?
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    var recordedPCMData = Data()
    var recordedSampleRate: Double = 24_000
    // ✅ 相槌再生ON/OFF（当面OFFにする）
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    let enableFillers = true
    // ✅ 再生する相槌ファイルのリスト（バンドルに追加したファイル名）
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    let fillerFiles = [
        "うんうん", "そっか", "ふーん", "へー"
    ]
    // ✅ 相槌再生中かのフラグ（AI音声が来たら一度だけ止める）
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    var isFillerPlaying = false

    // ✅ フォールバックTTS時だけ「マスコット声」を強めにして、終わったら元に戻す
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var fallbackTTSVoiceFXRestore: PlayerNodeStreamer.VoiceFXState?
    var isFallbackTTSPlaybackActive: Bool = false
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var receiveTextTask: Task<Void, Never>?
    var receiveAudioTask: Task<Void, Never>?
    var receiveInputTextTask: Task<Void, Never>?
    var sessionStartTask: Task<Void, Never>?     // セッション開始タスクの管理
    var liveSummaryTask: Task<Void, Never>?      // ライブ要約生成タスク
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var inMemoryTurns: [FirebaseTurn] = []       // 会話ログ（要約用）
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var routeChangeObserver: Any?
    
    // MARK: - App lifecycle / background keep-alive
    var lifecycleObserverTokens: [NSObjectProtocol] = []
    #if canImport(UIKit)
    var backgroundTaskId: UIBackgroundTaskIdentifier = .invalid
    #endif
    /// 他アプリ（YouTube等）にオーディオを奪われて `shouldResume=false` になった場合に、
    /// フォアグラウンド復帰時に自動でハンズフリーを復旧するためのフラグ。
    var needsHandsFreeRecoveryOnForeground: Bool = false

    // MARK: - Fallback TTS tuning (audio-only; UIテキストは変えない)
    /// フォールバックTTSの音声は、入力テキスト側の軽い整形と再生側のVoice FXでテンションを調整する。

    /// gpt-4o-audio-preview に渡す user メッセージ先頭の共通プレフィックス。
    /// - Note: systemPrompt とは別に、user 側にも「必ず音声を返す」指示を毎回付与する（音声欠落の再発を抑える目的）。
    var audioPreviewUserMessagePrefix: String {
        """
        【重要】
        - 返答は必ず音声（audio）を含めてください。テキストだけの返答は禁止です。
        - 出力は「audio voice=nova, format=pcm16」で、必ず audio チャンクを送ってください。

        """
    }

    // ✅ 会話文脈（過去のテキスト履歴）をステートレスAPIに渡すために保持
    struct HistoryItem: Codable {
        let role: String    // "user" or "assistant"
        let text: String
    }
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var conversationHistory: [HistoryItem] = []

    // MARK: - Firebase保存
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    let firebaseRepository = FirebaseConversationsRepository()
    var currentSessionId: String?
    // ✅ 認証情報（AuthViewModelから設定される）
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）にしている
    var currentUserId: String?
    var currentChildId: String?
    private var currentChildName: String?
    private var currentChildNickname: String?
    /// HomeなどのUIから「今はこの名前を優先して呼んでほしい」を指定するためのオーバーライド
    /// - Note: ここで指定された場合、systemPrompt側で優先的に呼びかけるよう指示する
    var preferredCallNameOverride: String?
    /// きょうだいがいる場合に「いま話しているのはこの子」をUIから一時指定するためのオーバーライド。
    /// - Note: Firestore上の保存パス(childId)は変えず、セッションにメタ情報として保存して履歴表示に使う。
    var speakerChildIdOverride: String?
    var speakerChildNameOverride: String?
    /// 録音中に押されていた「話者（子）」を、このターンの保存に確実に反映するためのロック。
    /// - Note: ボタンが離されても、録音中に押されていた事実を保持したい。
    var lockedSpeakerChildIdForTurn: String?
    var lockedSpeakerChildNameForTurn: String?
    // NOTE: 別ファイルのextensionから参照/更新するため internal（モジュール内限定）
    var turnCount: Int = 0

    // 会話で呼ぶ名前（ニックネーム優先）
    // NOTE: extensionファイルから参照するため internal（モジュール内限定）にしている
    var childCallName: String? {
        if let nickname = currentChildNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname
        }
        if let name = currentChildName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return nil
    }

    /// systemPromptで使う呼び名（UI指定のオーバーライドがあればそれを優先）
    var effectiveCallName: String? {
        if let override = preferredCallNameOverride?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty {
            return override
        }
        return childCallName
    }

    /// Homeの名前ボタンなどから呼び出す
    public func setPreferredCallNameOverride(_ name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        preferredCallNameOverride = (trimmed?.isEmpty == true) ? nil : trimmed
    }

    /// Homeの「きょうだい名前ボタン（押している間だけ有効）」などから呼び出す
    /// - Note: ここで指定された値は Firestore の session にメタ情報として保存し、履歴カード表示で使う。
    public func setSpeakerAttributionOverride(childId: String?, childName: String?) {
        let trimmedId = childId?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = childName?.trimmingCharacters(in: .whitespacesAndNewlines)
        speakerChildIdOverride = (trimmedId?.isEmpty == true) ? nil : trimmedId
        speakerChildNameOverride = (trimmedName?.isEmpty == true) ? nil : trimmedName

        // 録音中なら、このターンに紐付く値としてロックする（押下が離れても保持）
        if isRecording {
            if let id = speakerChildIdOverride, let name = speakerChildNameOverride {
                lockedSpeakerChildIdForTurn = id
                lockedSpeakerChildNameForTurn = name
            }
        }
    }

    // ✅ ユーザー情報を設定するメソッド
    public func setupUser(userId: String, childId: String, childName: String? = nil, childNickname: String? = nil) {
        self.currentUserId = userId
        self.currentChildId = childId
        let trimmedName = childName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNickname = childNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentChildName = trimmedName?.isEmpty == true ? nil : trimmedName
        self.currentChildNickname = trimmedNickname?.isEmpty == true ? nil : trimmedNickname
        // childが切り替わったらオーバーライドはリセット（別の子に引きずらない）
        self.preferredCallNameOverride = nil
        self.speakerChildIdOverride = nil
        self.speakerChildNameOverride = nil
        self.lockedSpeakerChildIdForTurn = nil
        self.lockedSpeakerChildNameForTurn = nil
        print("✅ ConversationController: ユーザー情報を設定 - Parent=\(userId), Child=\(childId), Name=\(childCallName ?? "n/a")")
    }

    private static func pcmFromWavIfPossible(_ data: Data) -> Data? {
        // RIFF/WAVEヘッダチェック
        guard data.count >= 12,
              String(data: data[0..<4], encoding: .ascii) == "RIFF",
              String(data: data[8..<12], encoding: .ascii) == "WAVE" else {
            return nil
        }

        var offset = 12 // RIFFヘッダの後からチャンクを走査
        var fmtFound = false
        var audioFormat: UInt16 = 0
        var bitsPerSample: UInt16 = 0

        while offset + 8 <= data.count {
            let chunkIDData = data[offset..<offset+4]
            let chunkSize = data[offset+4..<offset+8].withUnsafeBytes { $0.load(as: UInt32.self) }
            let chunkID = String(data: chunkIDData, encoding: .ascii) ?? ""
            let chunkStart = offset + 8
            let chunkEnd = chunkStart + Int(chunkSize)
            guard chunkEnd <= data.count else { return nil }

            if chunkID == "fmt " {
                // PCM16フォーマット確認
                guard chunkSize >= 16 else { return nil }
                audioFormat = data[chunkStart..<chunkStart+2].withUnsafeBytes { $0.load(as: UInt16.self) }
                bitsPerSample = data[chunkStart+14..<chunkStart+16].withUnsafeBytes { $0.load(as: UInt16.self) }
                fmtFound = true
            } else if chunkID == "data" {
                guard fmtFound, audioFormat == 1, bitsPerSample == 16 else { return nil }
                let pcmRange = chunkStart..<chunkEnd
                return data.subdata(in: pcmRange)
            }

            // チャンクサイズは偶数境界に揃うためパディング考慮
            offset = chunkEnd + (chunkSize % 2 == 1 ? 1 : 0)
        }
        return nil
    }

    /// Firebaseエラーの詳細ログ出力（Permission deniedの場合にセキュリティルールの設定方法を案内）
    // NOTE: 別ファイルのextensionから呼ぶため internal（モジュール内限定）にしている
    func logFirebaseError(_ error: Error, operation: String) {
        let errorString = String(describing: error)
        print("❌ ConversationController: \(operation)失敗 - \(errorString)")

        // Permission deniedエラーの場合、セキュリティルールの設定方法を案内
        if errorString.contains("Permission denied") || errorString.contains("Missing or insufficient permissions") {
            print("""
            ⚠️ セキュリティルールエラーが発生しました。
            開発環境では、Firebaseコンソールで以下のルールを設定してください:

            rules_version = '2';
            service cloud.firestore {
              match /databases/{database}/documents {
                match /{document=**} {
                  allow read, write: if true;
                }
              }
            }

            詳細は FIREBASE_SUMMARY.md を参照してください。
            """)
        }
    }

    // MARK: - Lifecycle
    public init(
        audioSession: AudioSessionManaging = SystemAudioSessionManager(),
        speech: SpeechRecognizing = SystemSpeechRecognizer(locale: "ja-JP"),
        handsFreeSpeech: SpeechRecognizing = SystemSpeechRecognizer(locale: "ja-JP")
    ) {
        self.audioSession = audioSession
        self.speech = speech
        self.handsFreeSpeech = handsFreeSpeech
        // ✅ 共通エンジンを使用してPlayerNodeStreamerを初期化（AEC有効化のため）
        self.player = PlayerNodeStreamer(sharedEngine: sharedAudioEngine)
        // ✅ HFP時の二重再生対策：毎回PlayerNodeを作り直してバッファ残留を防ぐ
        self.player.setHardResetPlayerOnPrepare(true)
        super.init()
        setupAppLifecycleObservers()
    }

    deinit {
        // ✅ deinitは同期的に実行される必要があるため、非同期処理は行わない
        // 同期的に実行可能なクリーンアップのみを行う

        // セッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        sessionStartTask = nil
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        liveSummaryTask?.cancel()
        liveSummaryTask = nil

        // 受信タスクをキャンセル
        receiveTextTask?.cancel()
        receiveTextTask = nil
        receiveAudioTask?.cancel()
        receiveAudioTask = nil
        receiveInputTextTask?.cancel()
        receiveInputTextTask = nil

        // マイクとプレイヤーを停止（deinitは非isolatedなので直接停止）
        mic?.stop()
        mic = nil
        player.stop()

        // 共通エンジンを停止
        if sharedAudioEngine.isRunning {
            sharedAudioEngine.stop()
        }

        // 促しタイマーを停止（deinit内では直接無効化）
        // ✅ cancelNudge()は@MainActorで分離されているため、deinit内では直接タイマーを無効化
        nudgeTimer?.invalidate()
        nudgeTimer = nil

        // Local STTのクリーンアップ
        // ✅ removeTapはタップが存在しない場合でもエラーを投げないため、安全に呼び出せる
        audioEngine.inputNode.removeTap(onBus: 0)
        if audioEngine.isRunning {
            audioEngine.stop()
        }
        sttRequest?.endAudio()
        sttTask?.cancel()
        sttRequest = nil
        sttTask = nil

        // realtimeClientのクリーンアップ（非同期処理は実行しない）
        // finishSession()は非同期処理のため、deinit内では実行しない
        // 代わりに、realtimeClientの参照をnilにして、deinit時に自動的にクリーンアップされるようにする
        realtimeClient = nil
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
        
        lifecycleObserverTokens.forEach { NotificationCenter.default.removeObserver($0) }
        lifecycleObserverTokens.removeAll()
        #if canImport(UIKit)
        if backgroundTaskId != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskId)
            backgroundTaskId = .invalid
        }
        #endif

        print("✅ ConversationController: deinit - リソースクリーンアップ完了")
    }

    // MARK: - Permissions
    public func requestPermissions() {
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            DispatchQueue.main.async {
                self?.hasMicrophonePermission = granted
            }
        }
        SFSpeechRecognizer.requestAuthorization { _ in }
    }

    // MARK: - Local STT (DI対応版)
    public func startLocalTranscription() {
        guard !isRecording else { return }
        guard speech.isAvailable else {
            self.errorMessage = "音声認識が現在利用できません。"
            return
        }
        if isHandsFreeMode {
            stopHandsFreeConversation()
        }

        // 1) AudioSession を先に構成（DI経由）
        do { try audioSession.configure() } catch {
            self.errorMessage = "AudioSession開始に失敗: \(error.localizedDescription)"
            return
        }

        // 2) リクエスト作成
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        self.sttRequest = req
        self.transcript = ""
        self.errorMessage = nil

        // 3) マイクをリクエストへ流す（format: nil で装置の正しいフォーマットに追随）
        let input = audioEngine.inputNode
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            self?.sttRequest?.append(buffer)
        }

        // 4) エンジン起動
        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            self.errorMessage = "AudioEngine開始に失敗: \(error.localizedDescription)"
            input.removeTap(onBus: 0)
            self.sttRequest = nil
            return
        }

        // 5) 認識（プロトコル経由）
        sttTask = speech.startTask(
            request: req,
            onResult: { [weak self] text, isFinal in
                Task { @MainActor in
                    self?.transcript = text
                    if isFinal { self?.stopLocalTranscription() }
                }
            },
            onError: { [weak self] err in
                guard let self else { return }

                // キャンセル/無音などの"正常終了扱い"は UI に出さない
                if self.userStoppedRecording || Self.isBenignSpeechError(err) {
                    Task { @MainActor in self.finishSTTCleanup() }
                    return
                }

                // それ以外のみエラー表示
                Task { @MainActor in
                    self.errorMessage = err.localizedDescription
                    self.finishSTTCleanup()
                }
            }
        )

        isRecording = true
        mode = .localSTT
    }

    public func stopLocalTranscription() {
        guard isRecording || sttTask != nil else { return }
        userStoppedRecording = true                // フラグを立ててから
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        sttRequest?.endAudio()
        sttTask?.cancel()                          // キャンセルは必要。上で無害扱いにする
        finishSTTCleanup()
    }

    // NOTE: Realtime session lifecycle was moved to:
    // - ConversationController/ConversationController+RealtimeSession.swift

    // NOTE: PTT was moved to:
    // - ConversationController/ConversationController+PTT.swift

    // NOTE: HandsFree VAD was moved to:
    // - ConversationController/ConversationController+HandsFreeVAD.swift
    //
    // NOTE: Audio-preview request senders + helpers were moved to:
    // - ConversationController/ConversationController+AudioPreviewRequests.swift
    // NOTE: fallbackTTSInput was moved to:
    // - ConversationController/ConversationController+Prompts.swift

    // NOTE: fallback TTS was moved to:
    // - ConversationController/ConversationController+FallbackTTS.swift

    // NOTE: Diagnostics helpers were moved to:
    // - ConversationController/ConversationController+Diagnostics.swift

    private func finishSTTCleanup() {
        sttRequest = nil
        sttTask = nil
        isRecording = false
        let finalText = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let userStopped = userStoppedRecording
        userStoppedRecording = false

        // ユーザー停止 or 最終確定後に、本文があればAIへ
        if !finalText.isEmpty, userStopped || !finalText.isEmpty {
            askAI(with: finalText)
        }
    }

    static func isBenignSpeechError(_ error: Error) -> Bool {
        let e = error as NSError
        let msg = e.localizedDescription.lowercased()
        // iOSのローカル音声認識で頻発するエラーは“監視用途”では無害扱いにして再起動する
        if e.domain == "kAFAssistantErrorDomain" && (e.code == 1101 || e.code == 1110) {
            return true
        }
        // Speech.framework側（端末/OSで揺れる）も「監視用途」では無害扱い
        if e.domain == "kLSRErrorDomain" && (e.code == 301 || e.code == 203 || e.code == 216) {
            return true
        }
        // "canceled""no speech detected" などは無害扱い
        return msg.contains("canceled") || msg.contains("no speech")
        // 必要ならコードで分岐（環境で異なるが 203/216 を見ることが多い）
        // || e.code == 203 || e.code == 216
    }

    // MARK: - AI呼び出し
    public func askAI(with userText: String) {
        // 同じテキストを連投しない
        guard userText != lastAskedText else { return }
        lastAskedText = userText

        print("🟥 aiResponseText cleared at:", #function)
        aiResponseText = ""              // 新しいターンの開始
        isThinking = true
        errorMessage = nil

        Task {
            defer {
                Task { @MainActor in
                    self.isThinking = false
                }
            }

            // OpenAI Chat Completions
            struct Payload: Encodable {
                let model: String
                let messages: [[String: String]]
                let max_tokens: Int?
                let temperature: Double?
            }

            let nameNote: String
            if let callName = childCallName {
                nameNote = "こどものなまえは「\(callName)」。あいさつやこたえの中で、ようすにあわせてやさしく名前を入れてね（れんこは禁止）。"
            } else {
                nameNote = ""
            }

            let payload = Payload(
                model: "gpt-4o-mini",
                messages: [
                    ["role": "system", "content": "あなたは幼児向けのAIアシスタントです。日本語のみで答えてください。ひらがな中心・一文を短く・やさしく・むずかしい言葉をさけます。" + (nameNote.isEmpty ? "" : " " + nameNote)],
                    ["role": "user", "content": userText]
                ],
                max_tokens: 120,
                temperature: 0.3
            )

            let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
                .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!

            var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("Bearer \(AppConfig.openAIKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try? JSONEncoder().encode(payload)

            // 429 バックオフ（最大3回、0.5s→1s→2s）
            var attempt = 0
            let maxAttempts = 3
            var backoff: UInt64 = 500_000_000 // 0.5s

            while attempt < maxAttempts {
                do {
                    let (data, response) = try await URLSession.shared.data(for: req)
                    guard let http = response as? HTTPURLResponse else {
                        throw URLError(.badServerResponse)
                    }

                    if http.statusCode == 429 {
                        // エラーボディを解析して文言化
                        let msg = Self.readable429Message(from: data)
                        attempt += 1
                        if attempt >= maxAttempts {
                            await MainActor.run {
                                self.errorMessage = msg
                                self.isThinking = false
                            }
                            return
                        }
                        try await Task.sleep(nanoseconds: backoff)
                        backoff *= 2
                        continue
                    }

                    guard (200..<300).contains(http.statusCode) else {
                        // 429 以外のエラー
                        let body = String(data: data, encoding: .utf8) ?? ""
                        throw NSError(domain: "OpenAI", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode): \(body)"])
                    }

                    struct Choice: Decodable {
                        struct Message: Decodable { let role: String; let content: String }
                        let message: Message
                    }
                    struct Resp: Decodable { let choices: [Choice] }
                    let decoded = try JSONDecoder().decode(Resp.self, from: data)
                    let text = decoded.choices.first?.message.content ?? "(おへんじができなかったよ)"

                    await MainActor.run {
                        self.aiResponseText = text
                        self.isThinking = false
                    }
                    return
                } catch {
                    // ネットワーク例外など
                    await MainActor.run {
                        self.errorMessage = Self.humanReadable(error)
                        self.isThinking = false
                    }
                    return
                }
            }
        }
    }

    private static func readable429Message(from data: Data) -> String {
        // OpenAI エラー形式に対応
        struct OpenAIError: Decodable {
            struct Inner: Decodable {
                let message: String
                let type: String?
                let code: String?
            }
            let error: Inner
        }
        if let e = try? JSONDecoder().decode(OpenAIError.self, from: data) {
            if let code = e.error.code?.lowercased(), code.contains("insufficient_quota") {
                return "クレジット残高が不足しています（insufficient_quota）。請求/クレジットを確認してください。"
            }
            if let code = e.error.code?.lowercased(), code.contains("rate_limit") {
                return "リクエストが多すぎます（rate limit）。少し待ってからもう一度ためしてね。"
            }
            return e.error.message
        }
        return "429: しばらく待ってからもう一度ためしてね。"
    }

private static func humanReadable(_ error: Error) -> String {
    if let u = error as? URLError {
        switch u.code {
        case .cannotFindHost: return "ネットワークエラー：ホスト名が見つかりません（API_BASEを確認）"
            case .notConnectedToInternet: return "インターネットに接続できません"
            case .userAuthenticationRequired, .userCancelledAuthentication: return "APIキーが無効です（401）"
            default: break
            }
        }
        return error.localizedDescription
    }

    /// 日本語以外や余計なフッタを取り除く軽いサニタイズ
    // NOTE: prompt/sanitize helpers were moved to:
    // - ConversationController/ConversationController+Prompts.swift

    // NOTE: Live analysis was moved to:
    // - ConversationController/ConversationController+Analysis.swift

    // MARK: - 促しタイマー機能

    // ✅ 修正: タイマー開始ロジック（10.0秒に延長、デバッグログ強化）
    func startWaitingForResponse() {
        print("⏹ ConversationController: 促し機能は無効化中（タイマーをセットしません）")
        cancelNudge()
    }

    // ✅ 修正: サーバーの状態に関わらず、実際の無音時間が長ければ促す
    private func sendNudgeIfNoResponse() async {
        // 促し機能を停止中
        print("⏹ ConversationController: 促し機能は無効化中（nudge送信も行いません）")
        cancelNudge()
        return

        guard isRealtimeActive else {
            print("⚠️ ConversationController: セッションがアクティブでないため nudge スキップ")
            return
        }

        // 最後に音がしてから何秒経過したか
        let silenceDuration = Date().timeIntervalSince(lastUserVoiceActivityTime)
        print("🧐 ConversationController: Nudge判定 - State: \(turnState), 実際の無音経過時間: \(String(format: "%.1f", silenceDuration))秒")

        // ---------------------------------------------------------
        // 判定ロジック:
        // 1. ユーザーが話している(.listening)ことになっているが、
        // 2. 実はここ4秒以上、マイク入力が静か(-50dB以下)である場合
        //    → 「VADの誤検知（または張り付き）」とみなして、強制的に促しを実行する
        // ---------------------------------------------------------

        let isActuallySilent = silenceDuration > 4.0 // 少し余裕を見て4.0秒以上静かなら無音とする

        if case .listening = turnState {
            if isActuallySilent {
                print("🚀 ConversationController: Stateはlisteningですが、実際には無音(\(String(format: "%.1f", silenceDuration))s)のため、促しを強制実行します")
                // そのまま下へ流して実行させる
            } else {
                print("⚠️ ConversationController: ユーザーが実際に話している(音量大)ため nudge をスキップ")
                cancelNudge()
                return
            }
        }

        // 他の状態（AIが考えている、話している）の場合は従来どおりスキップ
        if case .thinking = turnState {
            print("⚠️ ConversationController: 応答生成中(thinking)のため nudge をスキップ")
            cancelNudge()
            return
        }
        if case .speaking = turnState {
            print("⚠️ ConversationController: AIが話している(speaking)のため nudge をスキップ")
            cancelNudge()
            return
        }

        // ここまで来たら送信
        guard nudgeCount < maxNudgeCount else {
            print("⏹ ConversationController: 促し送信を\(maxNudgeCount)回で停止します")
            cancelNudge()
            return
        }
        print("🚀 ConversationController: 条件クリア -> 促しメッセージ送信実行")
        print("ℹ️ ConversationController: Realtime API無効化中のため nudge はスキップ（gpt-4o-audio-previewに合わせて後続で実装検討）")
        nudgeCount += 1
    }

    // NOTE: 別ファイルのextensionから呼ぶため internal（モジュール内限定）
    func cancelNudge() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
    }

    // ✅ セッション開始時に最初の質問を生成する
    public func requestInitialGreeting() {
        guard isRealtimeActive else {
            print("⚠️ ConversationController: セッションがアクティブでないため initial greeting スキップ")
            return
        }

        Task {
            print("🚀 ConversationController: 最初の質問を生成中...")
            print("ℹ️ ConversationController: Realtime API無効化中のため nudge はスキップ（gpt-4o-audio-previewに合わせて後続で実装検討）")
        }
    }

    // NOTE: Session analysis was moved to:
    // - ConversationController/ConversationController+Analysis.swift
}

// NOTE: AudioPreviewStreamingClient + payload models were moved to:
// - ConversationController/AudioPreviewStreamingClient.swift
