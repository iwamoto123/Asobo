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

@MainActor
public final class ConversationController: NSObject, ObservableObject {

    // MARK: - UI State
    public enum Mode: String, CaseIterable { case localSTT, realtime }

    // ✅ 機能トグル
    public static let localSTTEnabled: Bool = true
    public var isLocalSTTEnabled: Bool { Self.localSTTEnabled }

    @Published public var mode: Mode = .localSTT
    @Published public var transcript: String = ""
    @Published public var isRecording: Bool = false
    @Published public var errorMessage: String?
    @Published public var isRealtimeActive: Bool = false
    @Published public var isRealtimeConnecting: Bool = false
    // ✅ 音声プレビュー用のローカル文字起こしを行うか（端末環境で kAFAssistantErrorDomain 1101 が多発するためデフォルトOFF）
    private let enableLocalUserTranscription: Bool = ConversationController.localSTTEnabled
    
    // 追加: ユーザーが停止したかを覚えるフラグ
    private var userStoppedRecording = false
    
    // ✅ AI音声再生中フラグ（onAudioDeltaReceivedで設定、sendMicrophonePCMの早期returnを一元化）
    @Published private(set) var isAIPlayingAudio: Bool = false
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
    @Published private(set) var turnState: TurnState = .idle
    
    // ✅ 「待つ→促す」タイマー
    private var nudgeTimer: Timer?
    // ✅ 促し回数の上限とカウンター
    private let maxNudgeCount = AppConfig.nudgeMaxCount
    private var nudgeCount = 0
    
    // ✅ 追加: 最後に「ユーザーの声（環境音含む）」が閾値を超えた時刻
    private var lastUserVoiceActivityTime: Date = Date()
    private var lastInputRMS: Double?
    
    // ✅ 追加: 無音判定の閾値（-50dBより大きければ「何か音がしている」とみなす）
    // 調整目安: -40dB(普通) 〜 -60dB(静寂)。-50dBは「ささやき声や環境音」レベル
    private let silenceThresholdDb: Double = -50.0
    
    // ✅ 追加: speech_startedが来ていない警告のカウンター
    private var speechStartedMissingCount: Int = 0
    
    // MARK: - VAD (Hands-free Conversation)
    enum VADState { case idle, speaking }
    // 🔧 Temporarily extremely low thresholds to force VAD triggering
    // 🔧 Loosened thresholds to verify sensitivity (see VAD logging)
    private let speechStartThreshold: Float = 0.005
    private let speechEndThreshold: Float = 0.002
    private let defaultRmsStartThresholdDb: Double = -35.0
    private let bluetoothRmsStartThresholdDb: Double = -45.0
    private let defaultSpeechEndRmsThresholdDb: Double = -45.0
    private let bluetoothSpeechEndRmsThresholdDb: Double = -42.0
    private let defaultMinSilenceDuration: TimeInterval = 1.0
    private let bluetoothMinSilenceDuration: TimeInterval = 1.0
    private let speechStartHoldDuration: TimeInterval = 0.15
    private let minSpeechDuration: TimeInterval = 0.25
    // ✅ 割り込み判定用（Silero VADを一定時間連続検出した場合のみ停止）
    private let bargeInVADThreshold: Float = 0.5
    private let bargeInHoldDuration: TimeInterval = 0.15  // 150ms ヒステリシス
    private var vadInterruptSpeechStart: Date?
    @Published private(set) var vadState: VADState = .idle
    private var speechStartTime: Date?
    private var silenceTimer: Timer?
    private var isUserSpeaking: Bool = false
    private var speechStartCandidateTime: Date?
    
    private var isBluetoothInput: Bool {
        let session = AVAudioSession.sharedInstance()
        return session.currentRoute.inputs.contains { $0.portType == .bluetoothHFP }
    }
    private var activeRmsStartThresholdDb: Double {
        isBluetoothInput ? bluetoothRmsStartThresholdDb : defaultRmsStartThresholdDb
    }
    private var activeSpeechEndRmsThresholdDb: Double {
        isBluetoothInput ? bluetoothSpeechEndRmsThresholdDb : defaultSpeechEndRmsThresholdDb
    }
    private var activeMinSilenceDuration: TimeInterval {
        isBluetoothInput ? bluetoothMinSilenceDuration : defaultMinSilenceDuration
    }
    
    // ✅ 各ターンのレイテンシ計測用
    private struct TurnMetrics {
        var listenStart: Date?
        var speechEnd: Date?
        var requestStart: Date?
        var firstByte: Date?
        var firstAudio: Date?
        var firstText: Date?
        var streamComplete: Date?
        var playbackEnd: Date?
    }
    private var turnMetrics = TurnMetrics()
    
    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false
    @Published public var liveSummary: String = ""                 // 会話の簡易要約（毎ターン更新）
    @Published public var liveInterests: [FirebaseInterestTag] = [] // セッション終了時に更新
    @Published public var liveNewVocabulary: [String] = []          // セッション終了時に更新
    // ✅ 割り込み後に流入する古いAIチャンクを無視するためのゲート
    private var ignoreIncomingAIChunks: Bool = false
    private var currentTurnId: Int = 0         // ターンの世代ID（単一の真実）
    private var listeningTurnId: Int = 0       // VAD/録音用の世代ID
    private var playbackTurnId: Int?           // 再生状態通知の世代ID
    
    // AI呼び出し用フィールド
    @Published public var isThinking: Bool = false   // ぐるぐる表示用
    private var lastAskedText: String = ""           // 同文の連投防止

    // MARK: - Local STT (Speech) - DI対応
    private let audioEngine = AVAudioEngine()
    private let audioSession: AudioSessionManaging
    private let speech: SpeechRecognizing
    private var sttRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sttTask: SpeechRecognitionTasking?

    // MARK: - Realtime (OpenAI)
    private let audioSessionManager = AudioSessionManager()
    // ✅ AEC有効化のため、共通のAVAudioEngineを使用
    private let sharedAudioEngine = AVAudioEngine()
    private var mic: MicrophoneCapture?
    private var player: PlayerNodeStreamer            // 音声先出し（必要に応じて）
    // ✅ Realtime API はコメントアウトして、gpt-4o-audio-preview ストリーミングに切り替え
    private var realtimeClient: RealtimeClientOpenAI?
    private var audioPreviewClient: AudioPreviewStreamingClient?
    private var recordedPCMData = Data()
    private var recordedSampleRate: Double = 24_000
    // ✅ 相槌再生ON/OFF（当面OFFにする）
    private let enableFillers = true
    // ✅ 再生する相槌ファイルのリスト（バンドルに追加したファイル名）
    private let fillerFiles = [
        "うんうん", "そっか", "ふーん", "へー"
    ]
    // ✅ 相槌再生中かのフラグ（AI音声が来たら一度だけ止める）
    private var isFillerPlaying = false
    private var receiveTextTask: Task<Void, Never>?
    private var receiveAudioTask: Task<Void, Never>?
    private var receiveInputTextTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?     // セッション開始タスクの管理
    private var liveSummaryTask: Task<Void, Never>?      // ライブ要約生成タスク
    private var inMemoryTurns: [FirebaseTurn] = []       // 会話ログ（要約用）
    private var routeChangeObserver: Any?
    
    // ✅ 会話文脈（過去のテキスト履歴）をステートレスAPIに渡すために保持
    struct HistoryItem: Codable {
        let role: String    // "user" or "assistant"
        let text: String
    }
    private var conversationHistory: [HistoryItem] = []
    
    // MARK: - Firebase保存
    private let firebaseRepository = FirebaseConversationsRepository()
    private var currentSessionId: String?
    // ✅ 認証情報（AuthViewModelから設定される）
    private var currentUserId: String?
    private var currentChildId: String?
    private var currentChildName: String?
    private var currentChildNickname: String?
    private var turnCount: Int = 0
    
    // 会話で呼ぶ名前（ニックネーム優先）
    private var childCallName: String? {
        if let nickname = currentChildNickname?.trimmingCharacters(in: .whitespacesAndNewlines), !nickname.isEmpty {
            return nickname
        }
        if let name = currentChildName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        return nil
    }
    
    // ✅ ユーザー情報を設定するメソッド
    public func setupUser(userId: String, childId: String, childName: String? = nil, childNickname: String? = nil) {
        self.currentUserId = userId
        self.currentChildId = childId
        let trimmedName = childName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedNickname = childNickname?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.currentChildName = trimmedName?.isEmpty == true ? nil : trimmedName
        self.currentChildNickname = trimmedNickname?.isEmpty == true ? nil : trimmedNickname
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
    private func logFirebaseError(_ error: Error, operation: String) {
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
        speech: SpeechRecognizing = SystemSpeechRecognizer(locale: "ja-JP")
    ) {
        self.audioSession = audioSession
        self.speech = speech
        // ✅ 共通エンジンを使用してPlayerNodeStreamerを初期化（AEC有効化のため）
        self.player = PlayerNodeStreamer(sharedEngine: sharedAudioEngine)
        super.init()
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
        do { try audioSession.configure() }
        catch {
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

    // MARK: - Realtime（次の段階：会話）
    public func startRealtimeSession() {
        // 既に接続中または接続済みの場合は何もしない
        guard !isRealtimeActive && !isRealtimeConnecting else {
            print("⚠️ ConversationController: 既に音声プレビューセッションがアクティブまたは接続中です")
            return
        }
        // 既存のセッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        startRealtimeSessionInternal()
    }
    
    private func startRealtimeSessionInternal() {
        // 接続中フラグを設定
        isRealtimeConnecting = true
        nudgeCount = 0  // セッション開始時に促し回数をリセット
        logNetworkEnvironment()
        
        // オーディオセッションを構成
        do {
            try audioSessionManager.configure()
            
            // ✅ 共通エンジンを開始（AudioSession設定後）
            // ⚠️ 重要な順序：AudioSessionを設定してからエンジンを開始
            // ✅ 共通エンジンを開始することで、VoiceProcessingIO（AEC）が入出力の両方に効く
            try sharedAudioEngine.start()
            print("✅ ConversationController: 共通AudioEngine開始成功（AEC有効化）")
            
            // AudioSession設定後にPlayerNodeStreamerのエンジンを開始
            try player.start()
            
            // 音量確認（デバッグ用）
            let audioSession = AVAudioSession.sharedInstance()
            print("📊 ConversationController: オーディオ設定確認")
            print("   - OutputVolume: \(audioSession.outputVolume) (1.0が最大)")
            print("   - OutputChannels: \(audioSession.outputNumberOfChannels)")
            print("   - SampleRate: \(audioSession.sampleRate)Hz")
            
            if audioSession.outputVolume < 0.1 {
                print("⚠️ ConversationController: 音量が非常に低いです（\(audioSession.outputVolume)）。デバイスの音量設定を確認してください。")
            }
            
            print("✅ ConversationController: AudioSession設定とPlayerNodeStreamer開始成功")
        } catch {
            self.errorMessage = "AudioSession構成に失敗: \(error.localizedDescription)"
            print("❌ ConversationController: AudioSession構成失敗 - \(error.localizedDescription)")
            
            // 詳細なエラー情報をログに出力
            if let nsError = error as NSError? {
                print("   - Error Domain: \(nsError.domain)")
                print("   - Error Code: \(nsError.code)")
                print("   - Error Info: \(nsError.userInfo)")
            }
        }

        let key = AppConfig.openAIKey
        print("🔑 ConversationController: APIキー確認 - \(key.prefix(10))...")
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.errorMessage = "OPENAI_API_KEY が未設定です（Secrets.xcconfig を確認）"
            return
        }
        
        audioPreviewClient = AudioPreviewStreamingClient(
            apiKey: key,
            apiBase: URL(string: AppConfig.apiBase) ?? URL(string: "https://api.openai.com")!
        )
        
        // ✅ 重要: Playerの状態変化を監視して、正確なタイミングでマイクのゲートを開閉する
        player.onPlaybackStateChange = { [weak self] isPlaying in
            Task { @MainActor in
                guard let self = self else { return }
                guard let playbackId = self.playbackTurnId, playbackId == self.currentTurnId else {
                    if let playbackId = self.playbackTurnId {
                        print("⏭️ ConversationController: playback state change ignored for stale turn \(playbackId)")
                    }
                    if !isPlaying { self.playbackTurnId = nil }
                    return
                }
                self.isAIPlayingAudio = isPlaying
                self.isPlayingAudio = isPlaying
                self.mic?.setAIPlayingAudio(isPlaying)
                
                if isPlaying {
                    print("🔊 ConversationController: 再生開始 - マイクゲート閉 (AEC/BargeInモード)")
                    if self.turnMetrics.firstAudio == nil {
                        self.turnMetrics.firstAudio = Date()
                        self.logTurnStageTiming(event: "firstAudio", at: self.turnMetrics.firstAudio!)
                    }
                } else {
                    print("🔇 ConversationController: 再生完全終了 - マイクゲート開")
                    // ✅ AIが完全に話し終わったら、ユーザーの入力を待つ状態にしてタイマーを開始（ハンズフリー時は即再開）
                    if self.isHandsFreeMode && self.isRecording {
                        self.resumeListening()
                    } else if self.turnState == .speaking {
                        self.turnState = .waitingUser
                        print("⏰ ConversationController: AIの音声再生完全終了 -> 促しタイマーを開始")
                        self.startWaitingForResponse()
                    }
                    self.turnMetrics.playbackEnd = Date()
                    // firstAudio が未設定で playbackEnd が先に来た場合のフォールバック
                    if self.turnMetrics.firstAudio == nil {
                        self.turnMetrics.firstAudio = self.turnMetrics.requestStart ?? self.turnMetrics.playbackEnd
                    }
                    if let end = self.turnMetrics.playbackEnd {
                        self.logTurnStageTiming(event: "playbackEnd", at: end)
                    }
                    self.logTurnLatencySummary(context: "playback complete")
                    self.playbackTurnId = nil
                }
            }
        }
        
        transcript = ""
        print("🟥 aiResponseText cleared at:", #function)
        aiResponseText = ""
        liveSummary = ""
        liveInterests = []
        liveNewVocabulary = []
        inMemoryTurns.removeAll()
        errorMessage = nil
        turnState = .waitingUser  // セッション開始時はユーザーが話すのを待つ

        // ✅ Firebaseにセッションを作成
        guard let userId = self.currentUserId, let childId = self.currentChildId else {
            print("⚠️ ConversationController: ユーザー情報が設定されていないため、セッションを作成できません")
            self.errorMessage = "ユーザー情報が設定されていません。ログインしてください。"
            return
        }
        
        let newSessionId = UUID().uuidString
        self.currentSessionId = newSessionId
        self.turnCount = 0
        conversationHistory.removeAll()
        
        // オーディオルート変更時にグラフを立て直す
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.handleAudioRouteChange(note)
            }
        }
        
        let session = FirebaseConversationSession(
            id: newSessionId,
            mode: .freeTalk,
            startedAt: Date(),
            interestContext: [],
            summaries: [],
            newVocabulary: [],
            turnCount: 0
        )
        
        Task.detached { [weak self, userId, childId, session] in
            let repo = FirebaseConversationsRepository()
            do {
                try await repo.createSession(
                    userId: userId,
                    childId: childId,
                    session: session
                )
                print("✅ ConversationController: Firebaseセッション作成完了 - sessionId: \(session.id ?? "nil")")
            } catch {
                await MainActor.run {
                    self?.logFirebaseError(error, operation: "Firebaseセッション作成")
                }
            }
        }

        sessionStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                print("🚀 ConversationController: gpt-4o-audio-previewセッション開始")
                
                // 状態を更新
                await MainActor.run {
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = true
                    self.mode = .realtime
                    self.startWaitingForResponse()
                }
            } catch {
                print("❌ ConversationController: セッション開始失敗 - \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "音声プレビュー接続失敗: \(error.localizedDescription)"
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = false
                }
            }
        }
    }

    public func stopRealtimeSession() {
        print("🛑 ConversationController: Realtimeセッション終了")
        ignoreIncomingAIChunks = true
        currentTurnId = 0
        listeningTurnId = 0
        playbackTurnId = nil
        
        // セッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        sessionStartTask = nil
        
        // 受信タスクをキャンセル
        receiveTextTask?.cancel(); receiveTextTask = nil
        receiveAudioTask?.cancel(); receiveAudioTask = nil
        receiveInputTextTask?.cancel(); receiveInputTextTask = nil
        
        // マイクとプレイヤーを停止
        mic?.stop(); mic = nil
        stopPlayer(reason: "stopRealtimeSession")
        isAIPlayingAudio = false
        isPlayingAudio = false
        
        // ★ 重要：先にセッションを非アクティブ化（他アプリへも通知）
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: [.notifyOthersOnDeactivation])
        
        // ★ エンジンを完全に解体
        sharedAudioEngine.inputNode.removeTap(onBus: 0)   // 冪等
        if sharedAudioEngine.isRunning {
            sharedAudioEngine.stop()
        }
        sharedAudioEngine.reset()                          // ← これが2回目クラッシュの予防線
        
        // ✅ 促しタイマーを停止
        cancelNudge()
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // 状態をリセット
        isRecording = false
        isHandsFreeMode = false
        isRealtimeActive = false
        isRealtimeConnecting = false
        turnState = .idle
        nudgeCount = 0
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        inMemoryTurns.removeAll()
        conversationHistory.removeAll()
        
        // テキストをクリア
        transcript = ""
        print("🟥 aiResponseText cleared at:", #function)
        aiResponseText = ""
        
        // エラーメッセージをクリア
        errorMessage = nil
        
        Task { [weak self] in
            guard let self else { 
                print("⚠️ ConversationController: stopRealtimeSession - selfがnilのため処理をスキップ")
                return 
            }
            
            // ✅ Firebaseにセッション終了を記録
            guard let userId = self.currentUserId, let childId = self.currentChildId, let sessionId = self.currentSessionId else {
                print("⚠️ ConversationController: stopRealtimeSession - ユーザー情報またはセッションIDがnilのため、セッション終了処理をスキップ")
                return
            }
            print("🔄 ConversationController: stopRealtimeSession - セッション終了処理開始 - sessionId: \(sessionId)")
            let endedAt = Date()
            do {
                try await self.firebaseRepository.finishSession(
                    userId: userId,
                    childId: childId,
                    sessionId: sessionId,
                    endedAt: endedAt
                )
                print("✅ ConversationController: Firebaseセッション終了更新完了 - sessionId: \(sessionId)")
                
                // ✅ 会話終了後の分析処理を実行
                print("🔄 ConversationController: stopRealtimeSession - 分析処理を開始します - sessionId: \(sessionId), turnCount=\(self.inMemoryTurns.count)")
                await self.analyzeSession(sessionId: sessionId)
                print("✅ ConversationController: stopRealtimeSession - 分析処理完了 - sessionId: \(sessionId)")
            } catch {
                print("❌ ConversationController: stopRealtimeSession - エラー発生: \(error)")
                self.logFirebaseError(error, operation: "Firebaseセッション終了更新")
            }
            
            await MainActor.run {
                self.currentSessionId = nil
                self.turnCount = 0
                print("✅ ConversationController: リソースクリーンアップ完了")
            }
        }
    }
    
    public func startPTTRealtime() {
        // ハンズフリー中にPTTを開始したらハンズフリーを明示的に無効化
        if isHandsFreeMode {
            stopHandsFreeConversation()
        }
        guard audioPreviewClient != nil else {
            self.errorMessage = "音声プレビュークライアントが初期化されていません"; return
        }
        // 促しと既存の録音をリセット
        cancelNudge()
        recordedPCMData.removeAll()
        recordedSampleRate = 24_000
        
        // バージイン前提でAI音声を止める
        stopPlayer(reason: "startPTTRealtime (barge-in before PTT)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        
        // 共有エンジンが止まっていたら再開
        if !sharedAudioEngine.isRunning {
            do { try sharedAudioEngine.start() } catch {
                print("⚠️ ConversationController: エンジン再開失敗 - \(error.localizedDescription)")
            }
        }
        
        startPTTRealtimeInternal()
    }
    
    private func startPTTRealtimeInternal() {
        cancelNudge()             // ✅ ユーザーが話し始めるので促しを止める
        // 🔇 いま流れているAI音声を止める（barge-in 前提）
        stopPlayer(reason: "startPTTRealtimeInternal (barge-in before reconfigure)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        ignoreIncomingAIChunks = false

        mic?.stop()
        
        // ✅ Task内で実行
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 1. エンジンがいったん動いているなら停止（再構成のため）
            // VoiceProcessingIOは構成変更時に停止しているのが最も安全
            if self.sharedAudioEngine.isRunning {
                self.sharedAudioEngine.stop()
            }
            
            // 2. マイクを初期化 & Start (ここで Tap をインストール)
            // エンジンは停止状態だが、Tapインストールは可能
            self.mic = MicrophoneCapture(sharedEngine: self.sharedAudioEngine, onPCM: { [weak self] buf in
                self?.appendPCMBuffer(buf)
            }, outputMonitor: self.player.outputMonitor)
            self.mic?.onBargeIn = { [weak self] in
                self?.interruptAI()
            }
            
            // -------------------------------------------------------
            // ✅ 追加: マイクの音量を監視して、音がしていれば時刻を更新
            // -------------------------------------------------------
            self.mic?.onVolume = { [weak self] rms in
                // バックグラウンドスレッドから呼ばれるためMainActorへ
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.lastInputRMS = rms
                    
                    // 閾値(-50dB)より大きければ「音がしている」とみなして時刻更新
                    if rms > self.silenceThresholdDb {
                        self.lastUserVoiceActivityTime = Date()
                    }
                }
            }
            self.lastInputRMS = nil
            
            // マイク開始時に時刻をリセット
            self.lastUserVoiceActivityTime = Date()
            
            do {
                // ここで Tap がインストールされる (フォーマット補正込み)
                try self.mic?.start()
        } catch {
                self.errorMessage = "マイク設定失敗: \(error.localizedDescription)"
                self.isRecording = false
                return
            }
            
            // 3. その後で、エンジンを Prepare & Start
            self.sharedAudioEngine.prepare()
            do {
                try self.sharedAudioEngine.start()
                print("✅ ConversationController: エンジン再開成功")
            } catch {
                print("❌ ConversationController: エンジン開始失敗: \(error)")
                self.errorMessage = "オーディオエンジンの開始に失敗しました"
                self.isRecording = false
                return
            }
            
            // 4. 状態更新
            self.isRecording = true
            self.transcript = ""
            self.turnState = .listening
            self.markListeningTurn()
            self.turnMetrics = TurnMetrics()
            self.turnMetrics.listenStart = Date()
            print("⏱️ Latency: listen start (PTT) at \(self.turnMetrics.listenStart!)")
            
            // 注意: 促しタイマーは onResponseDone でのみセットする（AI応答完了時のみ）
            // ユーザーが話し始めた直後はタイマーをセットしない
            print("✅ ConversationController: PTT開始シーケンス完了")
        }
    }
    

    public func stopPTTRealtime() {
        isRecording = false
        isHandsFreeMode = false
        mic?.stop()
        if turnMetrics.speechEnd == nil {
            turnMetrics.speechEnd = Date()
        }
        turnState = .thinking
        Task { [weak self] in
            await self?.sendAudioPreviewRequest()
        }
    }
    
    // MARK: - Hands-free Conversation (VAD)
    /// 1回のタップで「聞く→送る→AI応答→再開」を繰り返すモード
    public func startHandsFreeConversation() {
        guard audioPreviewClient != nil else {
            self.errorMessage = "まず「開始」を押してセッションを開いてください"
            return
        }
        // PTT録音中に切り替えられないようガード
        if isRecording && !isHandsFreeMode {
            self.errorMessage = "現在の録音を停止してからハンズフリーを開始してください"
            return
        }
        
        cancelNudge()
        recordedPCMData.removeAll()
        recordedSampleRate = 24_000
        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // バージイン前提でAI音声を止める
        stopPlayer(reason: "startHandsFreeConversation (barge-in before HF start)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        
        if !sharedAudioEngine.isRunning {
            do { try sharedAudioEngine.start() } catch {
                print("⚠️ ConversationController: エンジン再開失敗 - \(error.localizedDescription)")
            }
        }
        
        isHandsFreeMode = true
        vadState = .idle
        speechStartTime = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        startHandsFreeInternal()
    }
    
    public func stopHandsFreeConversation() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isHandsFreeMode = false
        isRecording = false
        isUserSpeaking = false
        vadState = .idle
        speechStartTime = nil
        recordedPCMData.removeAll()
        mic?.stop()
        turnState = .waitingUser
    }
    
    private func startHandsFreeInternal() {
        cancelNudge()
        stopPlayer(reason: "startHandsFreeInternal (reset before VAD start)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        mic?.stop()
        ignoreIncomingAIChunks = false
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 1. エンジンを一度止めてから再構成
            if self.sharedAudioEngine.isRunning {
                self.sharedAudioEngine.stop()
            }
            
            self.mic = MicrophoneCapture(sharedEngine: self.sharedAudioEngine, onPCM: { [weak self] buf in
                self?.appendPCMBuffer(buf)
            }, outputMonitor: self.player.outputMonitor)
            
            self.mic?.onBargeIn = { [weak self] in
                self?.interruptAI()
            }
            self.mic?.onVADProbability = { [weak self] probability in
                Task { @MainActor [weak self] in
                    self?.handleVAD(probability: probability)
                }
            }
            self.mic?.onVolume = { [weak self] rms in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastInputRMS = rms
                    
                    if rms > self.silenceThresholdDb {
                        self.lastUserVoiceActivityTime = Date()
                    }
                }
            }
            self.lastInputRMS = nil
            
            recordedPCMData.removeAll()
            recordedSampleRate = 24_000
            
            do {
                try self.mic?.start()
            } catch {
                self.errorMessage = "マイク設定失敗: \(error.localizedDescription)"
                self.isRecording = false
                self.isHandsFreeMode = false
                return
            }
            
            self.sharedAudioEngine.prepare()
            do {
                try self.sharedAudioEngine.start()
                print("✅ ConversationController: ハンズフリー用エンジン開始")
            } catch {
                print("❌ ConversationController: エンジン開始失敗: \(error)")
                self.errorMessage = "オーディオエンジンの開始に失敗しました"
                self.isRecording = false
                self.isHandsFreeMode = false
                return
            }
            
            self.isRecording = true
            self.turnState = .listening
            self.markListeningTurn()
            self.vadState = .idle
            self.speechStartTime = nil
            self.turnMetrics = TurnMetrics()
            self.turnMetrics.listenStart = Date()
            print("⏱️ Latency: listen start (handsfree) at \(self.turnMetrics.listenStart!)")
            print("🟢 ハンズフリー会話開始: Listening...")
        }
    }

    private func handleVAD(probability: Float) {
        // AI再生中の割り込み判定：Silero VAD を一定時間連続検出した場合のみ停止
        if isAIPlayingAudio && turnState == .speaking {
            if probability >= bargeInVADThreshold {
                if vadInterruptSpeechStart == nil {
                    vadInterruptSpeechStart = Date()
                } else if let start = vadInterruptSpeechStart,
                          Date().timeIntervalSince(start) >= bargeInHoldDuration {
                    vadInterruptSpeechStart = nil
                    interruptAI()
                    return
                }
            } else {
                vadInterruptSpeechStart = nil
            }
        } else {
            vadInterruptSpeechStart = nil
        }
        
        if turnState == .thinking { return }
        guard listeningTurnId == currentTurnId else { return }
        
        switch vadState {
        case .idle:
            let now = Date()
            let rmsDb = lastInputRMS ?? -120.0
            let probTriggered = probability > speechStartThreshold
            let rmsTriggered = rmsDb > activeRmsStartThresholdDb
            if probTriggered || rmsTriggered {
                if speechStartCandidateTime == nil {
                    speechStartCandidateTime = now
                }
                let elapsed = now.timeIntervalSince(speechStartCandidateTime ?? now)
                if elapsed < speechStartHoldDuration {
                    return
                }
                speechStartCandidateTime = nil
                
                vadState = .speaking
                isUserSpeaking = true
                speechStartTime = Date()
                silenceTimer?.invalidate()
                silenceTimer = nil
                turnMetrics.listenStart = turnMetrics.listenStart ?? speechStartTime
                let probText = String(format: "%.4f", probability)
                let rmsText = String(format: "%.2f", rmsDb)
                let rmsStartText = String(format: "%.1f", activeRmsStartThresholdDb)
                let session = AVAudioSession.sharedInstance()
                let input = session.currentRoute.inputs.first
                let inputName = input?.portName ?? input?.portType.rawValue ?? "none"
                let preferredInput = session.preferredInput?.portName ?? session.preferredInput?.portType.rawValue ?? "none"
                print("⏱️ Latency: speech start detected at \(speechStartTime!) | prob=\(probText), rms=\(rmsText)dB, input=\(inputName), preferredInput=\(preferredInput), trigProb=\(probTriggered), trigRMS=\(rmsTriggered), rmsStartThresh=\(rmsStartText)")
            } else {
                speechStartCandidateTime = nil
            }
        case .speaking:
            let rmsDb = lastInputRMS ?? -120.0
            let isSilent = probability < speechEndThreshold || rmsDb < activeSpeechEndRmsThresholdDb
            if isSilent {
                if silenceTimer == nil {
                    let turnId = listeningTurnId
                    silenceTimer = Timer.scheduledTimer(withTimeInterval: activeMinSilenceDuration, repeats: false) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.handleSilenceTimeout(for: turnId)
                        }
                    }
                }
            } else {
                silenceTimer?.invalidate()
                silenceTimer = nil
            }
        }
    }
    private func handleSilenceTimeout(for turnId: Int) {
        guard turnId == currentTurnId, turnId == listeningTurnId else { return }
        guard vadState == .speaking else { return }
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        let now = Date()
        let speechBegan = speechStartTime ?? now
        let duration = now.timeIntervalSince(speechBegan)
        speechStartTime = nil
        turnMetrics.speechEnd = now
        if let listenStart = turnMetrics.listenStart {
            let totalListen = now.timeIntervalSince(listenStart)
            print("⏱️ Latency: speech end (listen->speechEnd=\(String(format: "%.2f", totalListen))s, speechDuration=\(String(format: "%.2f", duration))s)")
        } else {
            print("⏱️ Latency: speech end (duration=\(String(format: "%.2f", duration))s)")
        }
        
        if duration < minSpeechDuration {
            vadState = .idle
            isUserSpeaking = false
            recordedPCMData.removeAll()
            let formattedDuration = String(format: "%.2f", duration)
            print("🪫 短すぎる発話を破棄 (duration=\(formattedDuration)s)")
            return
        }
        
        vadState = .idle
        commitUserSpeech()
    }
    
    private func interruptAI() {
        guard turnState == .speaking else { return }
        print("⚡️ 割り込み検知: AI停止 -> 聞き取りへ")
        vadInterruptSpeechStart = nil
        ignoreIncomingAIChunks = true
        
        // 再生を即時停止し、マイクゲートを開く
        stopPlayer(reason: "interruptAI (barge-in)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        
        // ステートをListeningへ戻し、バッファを新規発話用にする
        turnState = .listening
        markListeningTurn()
        recordedPCMData.removeAll()
        isUserSpeaking = true
        turnMetrics = TurnMetrics()
        turnMetrics.listenStart = Date()
        print("⏱️ Latency: listen start (barge-in) at \(turnMetrics.listenStart!)")
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        // マイクが止まっていれば再開
        if !sharedAudioEngine.isRunning {
            try? sharedAudioEngine.start()
        }
        do {
            try mic?.start()
        } catch {
            errorMessage = "マイク再開に失敗しました: \(error.localizedDescription)"
            isRecording = false
            isHandsFreeMode = false
        }
    }
    
    private func commitUserSpeech() {
        guard isHandsFreeMode else { return }
        guard isUserSpeaking else { return }
        print("🚀 発話終了判定 -> ゲート通過チェック")
        
        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        let audioData = recordedPCMData
        recordedPCMData.removeAll()
        let sampleRate = recordedSampleRate > 0 ? recordedSampleRate : 16_000
        let durationSec = Double(audioData.count) / 2.0 / sampleRate
        guard durationSec >= 0.2 else {
            let formatted = String(format: "%.2f", durationSec)
            print("🎧 User speech too short, discarding (\(formatted)s)")
            return
        }
        
        let wavData = pcm16ToWav(pcmData: audioData, sampleRate: sampleRate)
        
        Task { [weak self] in
            guard let self else { return }
            
            let transcript = await ConversationController.transcribeUserAudio(wavData: wavData)
            let cleaned = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let formattedDuration = String(format: "%.2f", durationSec)
            if cleaned.isEmpty || cleaned == "(voice)" {
                print("🔎 Local STT returned empty, skip AI request (duration=\(formattedDuration)s, bytes=\(audioData.count))")
            } else {
                print("📝 Local STT succeeded: '\(cleaned)' (duration=\(formattedDuration)s)")
            }
            
            await MainActor.run {
                self.mic?.stop()
                self.turnState = .thinking
                if self.turnMetrics.speechEnd == nil { self.turnMetrics.speechEnd = Date() }
                if let listenStart = self.turnMetrics.listenStart, let speechEnd = self.turnMetrics.speechEnd {
                    print("⏱️ Latency: capture done (listen->speechEnd=\(String(format: "%.2f", speechEnd.timeIntervalSince(listenStart)))s)")
                }
            }
            
            if !cleaned.isEmpty, cleaned != "(voice)" {
                await self.sendTextPreviewRequest(userText: cleaned)
            } else {
                await self.persistVoiceOnlyTurn()
                await MainActor.run {
                    self.isThinking = false
                    self.turnState = .waitingUser
                    if self.isHandsFreeMode && self.isRecording {
                        self.resumeListening()
                    }
                }
            }
        }
    }
    
    private func resumeListening() {
        guard isHandsFreeMode else { return }
        print("👂 聞き取り再開")
        turnState = .listening
        markListeningTurn()
        recordedPCMData.removeAll()
        isUserSpeaking = false
        turnMetrics = TurnMetrics()
        turnMetrics.listenStart = Date()
        print("⏱️ Latency: listen start (resume) at \(turnMetrics.listenStart!)")
        silenceTimer?.invalidate()
        silenceTimer = nil
        ignoreIncomingAIChunks = false
        
        if !sharedAudioEngine.isRunning {
            try? sharedAudioEngine.start()
        }
        
        do {
            try mic?.start()
        } catch {
            errorMessage = "マイク再開に失敗しました: \(error.localizedDescription)"
            isRecording = false
            isHandsFreeMode = false
        }
    }

    private func startReceiveLoops() {
        print("🔄 ConversationController: startReceiveLoopsはgpt-4o-audio-previewモードでは使用されません（Realtime APIコードを無効化）")
    }
    
    // MARK: - Private Helpers
    private func advanceTurnId() -> Int {
        currentTurnId += 1
        playbackTurnId = nil
        return currentTurnId
    }
    
    private func markListeningTurn() {
        listeningTurnId = currentTurnId
        silenceTimer?.invalidate()
        silenceTimer = nil
    }
    
    private func isCurrentTurn(_ turnId: Int) -> Bool {
        turnId == currentTurnId
    }
    
    private func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let byteCount = frameLength * bytesPerFrame
        let data = Data(bytes: channelData[0], count: byteCount)
        recordedPCMData.append(data)
        recordedSampleRate = buffer.format.sampleRate
    }

    private func stopPlayer(reason: String, function: String = #function) {
        let playbackIdText = playbackTurnId.map(String.init) ?? "nil"
        print("🛑 PlayerNodeStreamer.stop() call - caller=\(function), reason=\(reason), playbackTurnId=\(playbackIdText), currentTurnId=\(currentTurnId), turnState=\(turnState)")
        player.stop()
    }

    // ✅ 相槌をランダム再生する
    private func playRandomFiller() {
        guard enableFillers else {
            isFillerPlaying = false
            return
        }
        guard let fileName = fillerFiles.randomElement(),
              let url = Bundle.main.url(forResource: fileName, withExtension: "wav") else {
            print("⚠️ 相槌ファイルが見つかりません: \(fillerFiles)")
            return
        }
        print("🗣️ 相槌再生: \(fileName)")
        player.playLocalFile(url)
        isFillerPlaying = true
    }
    
    private func pcm16ToWav(pcmData: Data, sampleRate: Double) -> Data {
        // シンプルなPCM16(LE)/モノラル -> WAVヘッダー付与
        var wav = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(numChannels * bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)
        
        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }
        
        wav.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(36 + dataSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))           // PCM fmt chunk size
        appendLE(UInt16(1))            // PCM format
        appendLE(numChannels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append("data".data(using: .ascii)!)
        appendLE(dataSize)
        wav.append(pcmData)
        return wav
    }
    
    /// ユーザー音声をローカルで文字起こし（会話履歴用）。失敗時は nil を返す。
    nonisolated private static func transcribeUserAudio(wavData: Data) async -> String? {
        // ✅ オフラインSTTが不安定な環境では早期に諦めてエラーを抑制
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
              recognizer.isAvailable else { return nil }
        
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("user_audio_\(UUID().uuidString).wav")
        do {
            try wavData.write(to: tmpURL)
        } catch {
            print("⚠️ UserAudioTranscribe: write failed - \(error)")
            return nil
        }
        
        return await withCheckedContinuation { continuation in
            var didFinish = false
            func finish(_ text: String?) {
                if didFinish { return }
                didFinish = true
                continuation.resume(returning: text)
                try? FileManager.default.removeItem(at: tmpURL)
            }
            
            let request = SFSpeechURLRecognitionRequest(url: tmpURL)
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                    task?.cancel()
                } else if let error = error {
                    // kAFAssistantErrorDomain 1101 は「ローカル認識不可」で頻発するため静かに無視
                    let nsError = error as NSError
                    if !(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101) {
                        print("⚠️ UserAudioTranscribe: recognition error - \(error)")
                    }
                    finish(nil)
                }
            }
        }
    }
    
    private func sendTextPreviewRequest(userText: String) async {
        guard let client = audioPreviewClient else {
            await MainActor.run { self.errorMessage = "音声プレビュークライアントが初期化されていません" }
            return
        }
        
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        await MainActor.run {
            // 新しい返答を開始するので前の表示テキストをクリア
            self.aiResponseText = ""
            self.turnMetrics.requestStart = Date()
            self.logTurnStageTiming(event: "request", at: self.turnMetrics.requestStart!)
        }

        let turnId = advanceTurnId()
        ignoreIncomingAIChunks = false

        // AIが考え始めるタイミングで相槌を打つ
        await MainActor.run {
            self.isThinking = true
            self.playRandomFiller()
            self.player.prepareForNextStream()
        }

        let tStart = Date()
        print("⏱️ ConversationController: sendTextPreviewRequest start - textLen=\(trimmed.count)")
        
        do {
            let result = try await client.streamResponseText(
                userText: trimmed,
                systemPrompt: currentSystemPrompt,
                history: conversationHistory,
                onText: { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        if self.turnMetrics.firstText == nil {
                            self.turnMetrics.firstText = Date()
                            self.logTurnStageTiming(event: "firstText", at: self.turnMetrics.firstText!)
                        }
                        let clean = self.sanitizeAIText(delta)
                        if clean.isEmpty { return }
                        print("🟦 onText delta (clean):", clean)
                        self.aiResponseText += clean
                    }
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        print("🔊 onAudioChunk bytes:", chunk.count)
                        self.playbackTurnId = turnId
                        self.turnState = .speaking
                        // 相槌が鳴っていても強制停止せず自然に終わらせる
                        if self.isFillerPlaying {
                            self.isFillerPlaying = false
                        }
                        self.handleFirstAudioChunk(for: turnId)
                        self.player.resumeIfNeeded()
                        // 出力はpcm16指定なのでそのまま再生
                        self.player.playChunk(chunk)
                    }
                },
                onFirstByte: { [weak self] firstByte in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        self.turnMetrics.firstByte = firstByte
                        self.logTurnStageTiming(event: "firstByte", at: firstByte)
                    }
                }
            )
            let tEnd = Date()
            print("⏱️ ConversationController: sendTextPreviewRequest completed in \(String(format: "%.2f", tEnd.timeIntervalSince(tStart)))s, finalText.count=\(result.text.count), finalText=\"\(result.text)\", audioMissing=\(result.audioMissing)")
            let cleanFinal = self.sanitizeAIText(result.text)
            guard self.isCurrentTurn(turnId) else { return }
            turnMetrics.streamComplete = tEnd
            logTurnStageTiming(event: "streamComplete", at: tEnd)
            logTurnLatencySummary(context: "stream complete (text)")
            
            await MainActor.run {
                // 吹き出し用に最終テキストをUIへ反映
                self.aiResponseText = cleanFinal
                if !result.audioMissing {
                    if self.isHandsFreeMode && self.isRecording && self.turnState != .speaking {
                        self.resumeListening()
                    } else if self.turnState != .speaking {
                        self.turnState = .waitingUser
                        self.startWaitingForResponse()
                    }
                } else {
                    print("🎺 ConversationController: text-only response -> fallback TTS will run")
                }
            }
            
            if result.audioMissing {
                await self.playFallbackTTS(text: cleanFinal, turnId: turnId)
            }
            
            // Firebase保存
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                let userTurn = FirebaseTurn(role: .child, text: trimmed, timestamp: Date())
                let aiTurn = FirebaseTurn(role: .ai, text: cleanFinal, timestamp: Date())
                print("🗂️ ConversationController: append inMemoryTurns (user:'\(userTurn.text ?? "nil")', ai:'\(aiTurn.text ?? "nil")')")
                inMemoryTurns.append(contentsOf: [userTurn, aiTurn])
                // ✅ 履歴にテキストを積む（直近の文脈としてステートレスAPIへ渡す）
                conversationHistory.append(HistoryItem(role: "user", text: trimmed))
                conversationHistory.append(HistoryItem(role: "assistant", text: cleanFinal))
                // 履歴が長くなりすぎないように6ターン分（12エントリ）に抑える
                if conversationHistory.count > 12 {
                    conversationHistory.removeFirst(conversationHistory.count - 12)
                }
                turnCount += 2
                let updatedTurnCount = turnCount
                Task.detached { [weak self, userId, childId, sessionId, userTurn, aiTurn, updatedTurnCount] in
                    let repo = FirebaseConversationsRepository()
                    do {
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: aiTurn)
                        try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
                    } catch {
                        await MainActor.run {
                            self?.logFirebaseError(error, operation: "テキスト会話の保存")
                        }
                    }
                }
                
                // 各ターンの終了時にライブ要約/タグ/新語を生成して即時保存
                liveSummaryTask?.cancel()
                liveSummaryTask = Task { [weak self] in
                    print("📝 ConversationController: live analysis task start (turnCount=\(self?.inMemoryTurns.count ?? 0))")
                    await self?.generateLiveAnalysisAndPersist()
                    print("📝 ConversationController: live analysis task end (summary='\(self?.liveSummary ?? "")', interests=\(self?.liveInterests.map { $0.rawValue } ?? []), newWords=\(self?.liveNewVocabulary ?? []))")
                }
            }
        } catch {
            print("❌ ConversationController: sendTextPreviewRequest failed - \(error)")
            await MainActor.run {
                guard self.isCurrentTurn(turnId) else { return }
                self.errorMessage = error.localizedDescription
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
        }
        
        await MainActor.run {
            if self.isCurrentTurn(turnId) {
                self.isThinking = false
            }
        }
    }
    
    private func sendAudioPreviewRequest() async {
        guard let client = audioPreviewClient else {
            await MainActor.run { self.errorMessage = "音声プレビュークライアントが初期化されていません" }
            return
        }

        await MainActor.run {
            // 新しい返答を開始するので前の表示テキストをクリア
            self.aiResponseText = ""
            self.turnMetrics.requestStart = Date()
            self.logTurnStageTiming(event: "request", at: self.turnMetrics.requestStart!)
        }
        
        let captured = recordedPCMData
        recordedPCMData.removeAll()
        guard !captured.isEmpty else {
            await MainActor.run {
                self.errorMessage = "音声が録音されていません"
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
            return
        }

        let turnId = advanceTurnId()
        ignoreIncomingAIChunks = false

        // AIが考え始めるタイミングで相槌を打つ
        await MainActor.run {
            self.isThinking = true
            self.playRandomFiller()
        }
        
        let wav = pcm16ToWav(pcmData: captured, sampleRate: recordedSampleRate)
        
        // ユーザー音声も会話履歴にテキストで残すため、ローカルで並行して文字起こしを試みる
        let userTranscriptionTask: Task<String?, Never>? = enableLocalUserTranscription
            ? Task.detached { [wavData = wav] in
                await ConversationController.transcribeUserAudio(wavData: wavData)
            }
            : nil
        
        let tStart = Date()
        print("⏱️ ConversationController: sendAudioPreviewRequest start - pcmBytes=\(captured.count), sampleRate=\(recordedSampleRate)")
        await MainActor.run {
            self.player.prepareForNextStream()
        }
        
        do {
            let result = try await client.streamResponse(
                audioData: wav,
                systemPrompt: currentSystemPrompt,
                history: conversationHistory,
                onText: { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        if self.turnMetrics.firstText == nil {
                            self.turnMetrics.firstText = Date()
                            self.logTurnStageTiming(event: "firstText", at: self.turnMetrics.firstText!)
                        }
                        let clean = self.sanitizeAIText(delta)
                        if clean.isEmpty { return }
                        print("🟦 onText delta (clean):", clean)
                        self.aiResponseText += clean
                    }
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        print("🔊 onAudioChunk bytes:", chunk.count)
                        self.playbackTurnId = turnId
                        self.turnState = .speaking
                        // 相槌が鳴っていても強制停止せず自然に終わらせる
                        if self.isFillerPlaying {
                            self.isFillerPlaying = false
                        }
                        self.handleFirstAudioChunk(for: turnId)
                        self.player.resumeIfNeeded()
                        // 出力はpcm16指定なのでそのまま再生
                        self.player.playChunk(chunk)
                    }
                },
                onFirstByte: { [weak self] firstByte in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        self.turnMetrics.firstByte = firstByte
                        self.logTurnStageTiming(event: "firstByte", at: firstByte)
                    }
                }
            )
            let tEnd = Date()
            print("⏱️ ConversationController: streamResponse completed in \(String(format: "%.2f", tEnd.timeIntervalSince(tStart)))s, finalText.count=\(result.text.count), finalText=\"\(result.text)\", audioMissing=\(result.audioMissing)")
            let cleanFinal = self.sanitizeAIText(result.text)
            guard self.isCurrentTurn(turnId) else { return }
            turnMetrics.streamComplete = tEnd
            logTurnStageTiming(event: "streamComplete", at: tEnd)
            logTurnLatencySummary(context: "stream complete")
            
            await MainActor.run {
                // 吹き出し用に最終テキストをUIへ反映（音声のみの場合でもテキストを入れる）
                self.aiResponseText = cleanFinal
                print("🟩 set aiResponseText final:", cleanFinal)
                if !result.audioMissing {
                    if self.isHandsFreeMode && self.isRecording && self.turnState != .speaking {
                        self.resumeListening()
                    } else if self.turnState != .speaking {
                        self.turnState = .waitingUser
                        self.startWaitingForResponse()
                    }
                } else {
                    print("🎺 ConversationController: audio missing from stream -> fallback TTS will run")
                }
            }
            
            if result.audioMissing {
                await self.playFallbackTTS(text: cleanFinal, turnId: turnId)
            }
            
            // Firebase保存（ユーザー音声もローカル文字起こししたテキストを保存）
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                let userText = await userTranscriptionTask?.value?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let userTurn = FirebaseTurn(role: .child, text: userText?.isEmpty == false ? userText! : "(voice)", timestamp: Date())
                let aiTurn = FirebaseTurn(role: .ai, text: cleanFinal, timestamp: Date())
                print("🗂️ ConversationController: append inMemoryTurns (user:'\(userTurn.text ?? "nil")', ai:'\(aiTurn.text ?? "nil")')")
                inMemoryTurns.append(contentsOf: [userTurn, aiTurn])
                // ✅ 履歴にテキストを積む（直近の文脈としてステートレスAPIへ渡す）
                let historyUserText = userText?.isEmpty == false ? userText! : "(不明瞭な音声)"
                conversationHistory.append(HistoryItem(role: "user", text: historyUserText))
                conversationHistory.append(HistoryItem(role: "assistant", text: cleanFinal))
                // 履歴が長くなりすぎないように6ターン分（12エントリ）に抑える
                if conversationHistory.count > 12 {
                    conversationHistory.removeFirst(conversationHistory.count - 12)
                }
                turnCount += 2
                let updatedTurnCount = turnCount
                Task.detached { [weak self, userId, childId, sessionId, userTurn, aiTurn, updatedTurnCount] in
                    let repo = FirebaseConversationsRepository()
                    do {
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: aiTurn)
                        try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
                    } catch {
                        await MainActor.run {
                            self?.logFirebaseError(error, operation: "音声会話の保存")
                        }
                    }
                }
                
                // 各ターンの終了時にライブ要約/タグ/新語を生成して即時保存
                liveSummaryTask?.cancel()
                liveSummaryTask = Task { [weak self] in
                    print("📝 ConversationController: live analysis task start (turnCount=\(self?.inMemoryTurns.count ?? 0))")
                    await self?.generateLiveAnalysisAndPersist()
                    print("📝 ConversationController: live analysis task end (summary='\(self?.liveSummary ?? "")', interests=\(self?.liveInterests.map { $0.rawValue } ?? []), newWords=\(self?.liveNewVocabulary ?? []))")
                }
            }
        } catch {
            print("❌ ConversationController: streamResponse failed - \(error)")
            await MainActor.run {
                guard self.isCurrentTurn(turnId) else { return }
                self.errorMessage = error.localizedDescription
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
        }
        
        await MainActor.run {
            if self.isCurrentTurn(turnId) {
                self.isThinking = false
            }
        }
    }
    
    private func persistVoiceOnlyTurn() async {
        let placeholder = "(voice)"
        print("🟨 persistVoiceOnlyTurn: saving placeholder '\(placeholder)'")
        inMemoryTurns.append(FirebaseTurn(role: .child, text: placeholder, timestamp: Date()))
        conversationHistory.append(HistoryItem(role: "user", text: placeholder))
        if conversationHistory.count > 12 {
            conversationHistory.removeFirst(conversationHistory.count - 12)
        }
        turnCount += 1
        let updatedTurnCount = turnCount
        
        guard let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId else { return }
        Task.detached { [weak self, userId, childId, sessionId, updatedTurnCount] in
            let repo = FirebaseConversationsRepository()
            do {
                let userTurn = FirebaseTurn(role: .child, text: placeholder, timestamp: Date())
                try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
            } catch {
                await MainActor.run {
                    self?.logFirebaseError(error, operation: "音声のみターンの保存")
                }
            }
        }
    }
    
    private func playFallbackTTS(text: String, turnId: Int) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("⚠️ ConversationController: fallback TTS skipped (empty text)")
            return
        }
        let apiKey = AppConfig.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !apiKey.isEmpty else {
            print("⚠️ ConversationController: fallback TTS skipped - APIキー未設定")
            return
        }
        
        let base = URL(string: AppConfig.apiBase) ?? URL(string: "https://api.openai.com")!
        let endpoint: URL
        if base.path.contains("/v1") {
            endpoint = base.appendingPathComponent("audio/speech")
        } else {
            endpoint = base.appendingPathComponent("v1").appendingPathComponent("audio/speech")
        }
        
        struct SpeechPayload: Encodable {
            let model: String
            let voice: String
            let input: String
            /// OpenAI TTSの正式キー（例: "mp3", "wav", "pcm"）
            let responseFormat: String
            /// 旧実装互換（無視される可能性あり）
            let format: String?
            
            enum CodingKeys: String, CodingKey {
                case model
                case voice
                case input
                case responseFormat = "response_format"
                case format
            }
        }
        // まずは raw PCM を要求（PlayerNodeStreamerがPCM16前提のため）
        // ただし実際には audio/mpeg が返ることがあるので、レスポンス側でMP3/WAVも安全にデコードする
        let payload = SpeechPayload(model: "gpt-4o-mini-tts", voice: "nova", input: trimmed, responseFormat: "pcm", format: "pcm")
        
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("audio/pcm, audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(payload)
        print("🎺 ConversationController: fallback TTS request - len=\(trimmed.count), model=\(payload.model), voice=\(payload.voice), response_format=\(payload.responseFormat), format=\(payload.format ?? "nil")")
        
        var startedPlayback = false
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                print("⚠️ ConversationController: fallback TTS invalid response")
                return
            }
            guard (200..<300).contains(http.statusCode) else {
                let body = String(data: data, encoding: .utf8) ?? "(binary)"
                print("❌ ConversationController: fallback TTS HTTP \(http.statusCode) - body: \(body)")
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type") ?? "(nil)"
            let headHex = Self.fallbackHexSnippet(data, length: 16)
            print("🎺 ConversationController: fallback TTS response - status=\(http.statusCode), bytes=\(data.count), contentType=\(contentType), head=\(headHex)")
            
            guard let pcmData = Self.fallbackPCM16Data(from: data, contentType: contentType) else {
                print("⚠️ ConversationController: fallback TTS decode failed (unsupported format)")
                startedPlayback = false
                return
            }
            
            playbackTurnId = turnId
            turnState = .speaking
            if isFillerPlaying { isFillerPlaying = false }
            player.prepareForNextStream()
            handleFirstAudioChunk(for: turnId)
            player.resumeIfNeeded()
            player.playChunk(pcmData)
            startedPlayback = true
        } catch {
            print("⚠️ ConversationController: fallback TTS失敗 - \(error.localizedDescription)")
        }
        
        if !startedPlayback {
            // 再生が始まらなかった場合も必ず Listening/Waiting に復帰させる
            playbackTurnId = nil
            if isHandsFreeMode && isRecording && turnState != .speaking {
                resumeListening()
            } else {
                turnState = .waitingUser
                startWaitingForResponse()
            }
        }
    }
    
    // MARK: - Fallback TTS helpers
    private static func fallbackHexSnippet(_ data: Data, length: Int) -> String {
        guard !data.isEmpty else { return "(empty)" }
        return data.prefix(length).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// TTS応答データを安全に24kHz/mono/PCM16データへ変換（WAV/PCM/MP3を安全に扱う）
    private static func fallbackPCM16Data(from data: Data, contentType: String?) -> Data? {
        // JSONや明らかなエラーを弾く
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return nil
        }
        
        let lowerCT = contentType?.lowercased()
        
        func looksLikeMP3(_ data: Data) -> Bool {
            if data.count >= 3, String(data: data.prefix(3), encoding: .ascii) == "ID3" {
                return true
            }
            // MP3 frame sync: 0xFF E? (よくある: FF FB / FF F3 / FF F2)
            if data.count >= 2 {
                let b0 = data[data.startIndex]
                let b1 = data[data.startIndex.advanced(by: 1)]
                if b0 == 0xFF, (b1 & 0xE0) == 0xE0 {
                    return true
                }
            }
            return false
        }
        
        func decodeByAVAudioFile(data: Data, fileExtension: String) -> Data? {
            let tmpURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("tts_fallback_\(UUID().uuidString).\(fileExtension)")
            do {
                try data.write(to: tmpURL)
                defer { try? FileManager.default.removeItem(at: tmpURL) }
                
                let file = try AVAudioFile(forReading: tmpURL)
                let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
                guard let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat) else {
                    return nil
                }
                
                var pcmData = Data()
                while true {
                    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { break }
                    try file.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 { break }
                    
                    let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
                    let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
                    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { break }
                    
                    var error: NSError?
                    let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    
                    if (status == .haveData || status == .endOfStream),
                       let ch = outBuffer.int16ChannelData?.pointee {
                        let sampleCount = Int(outBuffer.frameLength) * Int(targetFormat.channelCount)
                        pcmData.append(UnsafeBufferPointer(start: ch, count: sampleCount))
                    } else if let error {
                        print("⚠️ ConversationController: audio->PCM convert error - \(error.localizedDescription)")
                        return nil
                    }
                }
                return pcmData.isEmpty ? nil : pcmData
            } catch {
                print("⚠️ ConversationController: audio decode failed (\(fileExtension)) - \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: tmpURL)
                return nil
            }
        }
        
        // WAVならAVAudioFileで正規化
        let isWav = (lowerCT?.contains("wav") == true) ||
            (data.count >= 4 && String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        if isWav {
            return decodeByAVAudioFile(data: data, fileExtension: "wav")
        }
        
        // MP3（Content-Typeがaudio/mpeg、またはヘッダがID3/FrameSync）
        let isMP3 = (lowerCT?.contains("mpeg") == true) || looksLikeMP3(data)
        if isMP3 {
            return decodeByAVAudioFile(data: data, fileExtension: "mp3")
        }
        
        // PCM16前提のレスポンスの場合（audio/pcm 等）
        // ⚠️ contentTypeが嘘で「audio/pcm」なのにMP3が来るとザーッ事故になるため、MP3っぽいものは上で弾く/デコードする
        let isPCM =
            lowerCT?.contains("pcm") == true ||
            lowerCT?.contains("audio/raw") == true ||
            lowerCT?.contains("octet-stream") == true
        if isPCM {
            return data
        }
        
        // 不明形式は無音扱い
        print("⚠️ ConversationController: unknown TTS format (contentType=\(contentType ?? "nil")), cannot decode safely")
        return nil
    }
    
    private func handleFirstAudioChunk(for turnId: Int) {
        guard turnMetrics.firstAudio == nil else { return }
        player.clearStopRequestForPlayback(playbackTurnId: turnId, reason: "first audio chunk")
        turnMetrics.firstAudio = Date()
        logTurnStageTiming(event: "firstAudio", at: turnMetrics.firstAudio!)
        logFirstAudioChunkContext(turnId: turnId)
    }
    
    private func logFirstAudioChunkContext(turnId: Int) {
        let playbackIdText = playbackTurnId.map(String.init) ?? "nil"
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🎯 ConversationController: first audio chunk - turnId=\(turnId), playbackTurnId=\(playbackIdText), currentTurnId=\(currentTurnId)")
        print("🎯 ConversationController: route outputs=[\(outputs.isEmpty ? "none" : outputs)], inputs=[\(inputs.isEmpty ? "none" : inputs)], category=\(session.category.rawValue), mode=\(session.mode.rawValue), sampleRate=\(session.sampleRate)")
        player.logFirstChunkStateIfNeeded()
    }
    
    private func logTurnLatencySummary(context: String) {
        let m = turnMetrics
        var parts: [String] = []
        func add(_ label: String, _ start: Date?, _ end: Date?) {
            if let s = start, let e = end, e >= s {
                parts.append("\(label)=\(String(format: "%.2f", e.timeIntervalSince(s)))s")
            }
        }
        
        add("listen->speechEnd", m.listenStart, m.speechEnd)
        add("speechEnd->request", m.speechEnd, m.requestStart)
        add("request->firstByte", m.requestStart, m.firstByte)
        add("request->firstAudio", m.requestStart, m.firstAudio)
        add("request->firstText", m.requestStart, m.firstText)
        add("request->playbackEnd", m.requestStart, m.playbackEnd)
        add("firstByte->firstAudio", m.firstByte, m.firstAudio)
        add("firstByte->firstText", m.firstByte, m.firstText)
        add("request->streamComplete", m.requestStart, m.streamComplete)
        add("audioPlay->done", m.firstAudio, m.playbackEnd)
        
        if parts.isEmpty {
            print("⏱️ Latency: \(context) (no metrics)")
        } else {
            print("⏱️ Latency: \(context) | " + parts.joined(separator: ", "))
        }
    }
    
    private func logTurnStageTiming(event: String, at time: Date) {
        var parts: [String] = []
        func add(_ label: String, _ start: Date?) {
            guard let start else { return }
            let delta = time.timeIntervalSince(start)
            parts.append("\(label)=\(String(format: "%.2f", delta))s")
        }
        add("listen->\(event)", turnMetrics.listenStart)
        add("speechEnd->\(event)", turnMetrics.speechEnd)
        add("request->\(event)", turnMetrics.requestStart)
        if parts.isEmpty {
            print("⏱️ TurnTiming[\(event)]: (no anchors)")
        } else {
            print("⏱️ TurnTiming[\(event)]: " + parts.joined(separator: ", "))
        }
    }
    
    private func logNetworkEnvironment() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ConversationController.NetworkEnv")
        monitor.pathUpdateHandler = { path in
            let status: String
            switch path.status {
            case .satisfied: status = "satisfied"
            case .requiresConnection: status = "requiresConnection"
            case .unsatisfied: status = "unsatisfied"
            @unknown default: status = "unknown"
            }
            
            let activeInterfaces = path.availableInterfaces
                .filter { path.usesInterfaceType($0.type) }
                .map { iface -> String in
                    switch iface.type {
                    case .wifi: return "wifi"
                    case .cellular: return "cellular"
                    case .wiredEthernet: return "ethernet"
                    case .loopback: return "loopback"
                    case .other: return "other"
                    @unknown default: return "unknown"
                    }
                }
                .joined(separator: ",")
            
            let constrained = path.isConstrained ? "true" : "false"
            let expensive = path.isExpensive ? "true" : "false"
            print("📶 ConversationController: Network status=\(status), activeInterfaces=[\(activeInterfaces)], expensive=\(expensive), constrained=\(constrained)")
            
            monitor.cancel()
        }
        monitor.start(queue: queue)
        
        // 念のためタイムアウトでキャンセル
        queue.asyncAfter(deadline: .now() + 2.0) {
            monitor.cancel()
        }
    }

    private func handleAudioRouteChange(_ notification: Notification) {
        guard isRealtimeActive else { return }
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) ?? .unknown
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🔄 ConversationController: audio route change detected - reason=\(reason.rawValue), outputs=[\(outputs.isEmpty ? "none" : outputs)]")

        // ルート変更でパイプラインが途切れた場合に備えて再開を試みる
        player.prepareForNextStream()
        if !sharedAudioEngine.isRunning {
            do {
                try sharedAudioEngine.start()
                print("✅ ConversationController: sharedAudioEngine restarted after route change")
            } catch {
                print("⚠️ ConversationController: sharedAudioEngine restart failed after route change - \(error.localizedDescription)")
            }
        }
        player.resumeIfNeeded()
    }
    
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
    
    private static func isBenignSpeechError(_ error: Error) -> Bool {
        let e = error as NSError
        let msg = e.localizedDescription.lowercased()
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
                let messages: [[String:String]]
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
    private func sanitizeAIText(_ text: String) -> String {
        if text.isEmpty { return text }
        var allowed = CharacterSet()
        allowed.formUnion(.whitespacesAndNewlines)
        allowed.formUnion(CharacterSet(charactersIn: "。、！？・ー「」『』（）［］【】…〜"))
        // ひらがな・カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{30FF}"))
        // 半角カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{FF65}"..."\u{FF9F}"))
        // CJK統合漢字
        allowed.formUnion(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        
        let cleanedScalars = text.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(cleanedScalars))
    }
    
    /// 子ども向けのシステムプロンプト（文脈維持と聞き返しを強制）
    private var currentSystemPrompt: String {
        let callName = childCallName
        let nameInstruction: String
        if let callName {
            nameInstruction = """
        【子どもの名前】
        - 子どもは「\(callName)」。挨拶や励まし、問いかけなど自然なタイミングでときどき名前を呼んでください。
        - 同じ返答で連呼したり、文脈に合わない呼びかけはしないでください。
        """
        } else {
            nameInstruction = ""
        }
        
        var prompt = """
        あなたは3〜5歳の子どもと話す、優しくて楽しくて可愛いマスコットキャラクターです。日本語のみで答えます。
        最重要: 毎回答えの音声(TTS)も必ず生成し、テキストだけの応答は禁止です。音声チャンク「audio」も必ず生成してください。
        もしテキストのみの応答がきたらバグとみなし再生成してください。

        【キャラ設定と話し方】
        - 一人称は「ボク」、語尾は「〜だよ！」「〜だね！」「〜かな？」のようにカタカナを混ぜて元気よく話す。
        - 常にハイテンションで、オーバーリアクション気味に。
        
        ルール:
        1) 返答は1〜2文・40文字以内。長話は禁止。
        2) 聞き取れない/わからない時は勝手に話を作らず「ん？もういっかい言って？」「え？」などと聞き返す。
        3) 子どもが話しやすいように、最後に簡単な質問を添える（例:「くるまはすき？」「きょうはなにしたの？」）。
        4) むずかしい言葉を避け、ひらがな中心でやさしく。擬音語もOK。
        5) 直前の会話文脈を維持し、話題を飛ばさない。
        """
        
        if !nameInstruction.isEmpty {
            prompt += "\n\n\(nameInstruction)"
        }
        
        return prompt
    }
    
    // MARK: - ライブ要約生成
    
    /// 現在までの会話ログから要約/興味タグ/新語を生成し、即時Firestoreに反映する
    private func generateLiveAnalysisAndPersist() async {
        guard !inMemoryTurns.isEmpty else { return }
        print("📝 generateLiveAnalysis: start, inMemoryTurns=\(inMemoryTurns.count)")
        
        // プロンプトが大きくなりすぎないように直近12ターンを使用
        let recentTurns = Array(inMemoryTurns.suffix(12))
        let conversationLog = recentTurns.compactMap { turn -> String? in
            guard let text = turn.text, !text.isEmpty else { return nil }
            let roleLabel = turn.role == .child ? "子ども" : "AI"
            return "\(roleLabel): \(text)"
        }.joined(separator: "\n")
        let childOnlyLog = recentTurns.compactMap { turn -> String? in
            guard turn.role == .child, let text = turn.text, !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n")
        
        guard !conversationLog.isEmpty else { return }
        
        struct Payload: Encodable {
            let model: String
            let messages: [[String: String]]
            let response_format: [String: String]
            let max_tokens: Int
            let temperature: Double
        }
        
        let prompt = """
        以下のAIと子どもの会話を分析し、JSON形式で出力してください。
        - summary: 親向けに1行で要約（50文字以内）。AIの返答も加味して状況をまとめてください。
        - interests: 子どもが興味を示したトピック（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others の英語enum値配列）。子どもの発話を主に見てください。
        - newWords: 子どもが使った特徴的な言葉（3つまで）。必ず子どもの発話からのみ選んでください。
        
        会話ログ（子ども/AI両方）:
        \(conversationLog)
        
        子ども発話のみ:
        \(childOnlyLog.isEmpty ? "(なし)" : childOnlyLog)
        """
        
        let payload = Payload(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": "あなたは会話を短く要約し、興味タグと新出語を抽出するアシスタントです。JSONのみで返してください。"],
                ["role": "user", "content": prompt]
            ],
            response_format: ["type": "json_object"],
            max_tokens: 200,
            temperature: 0.3
        )
        
        let apiKey = AppConfig.openAIKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("⚠️ generateLiveAnalysis: APIキー未設定のためスキップ")
            return
        }
        
        let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
            .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!
        
        var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(payload)
        
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("⚠️ generateLiveAnalysis: HTTPエラー - \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return
            }
            
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            struct Resp: Decodable { let choices: [Choice] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            guard let content = decoded.choices.first?.message.content.data(using: .utf8) else {
                print("⚠️ generateLiveAnalysis: contentなし")
                return
            }
            struct Result: Decodable {
                let summary: String?
                let interests: [String]?
                let newWords: [String]?
            }
            let result = try JSONDecoder().decode(Result.self, from: content)
            
            if Task.isCancelled { return }
            
            let summaryText = result.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let interests = (result.interests ?? []).compactMap { FirebaseInterestTag(rawValue: $0) }
            let newWords = result.newWords ?? []
            
            await MainActor.run {
                if !summaryText.isEmpty { self.liveSummary = summaryText }
                self.liveInterests = interests
                self.liveNewVocabulary = newWords
            }
            
            // Firestoreにも即時反映
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                try await firebaseRepository.updateAnalysis(
                    userId: userId,
                    childId: childId,
                    sessionId: sessionId,
                    summaries: summaryText.isEmpty ? [] : [summaryText],
                    interests: interests,
                    newVocabulary: newWords
                )
                print("🟢 generateLiveAnalysis: Firestore更新 success - summary:'\(summaryText)', interests:\(interests.map { $0.rawValue }), newWords:\(newWords)")
            }
        } catch {
            if Task.isCancelled { return }
            print("⚠️ generateLiveAnalysis: 生成失敗 - \(error)")
        }
    }
    
    // MARK: - 促しタイマー機能
    
    // ✅ 修正: タイマー開始ロジック（10.0秒に延長、デバッグログ強化）
    private func startWaitingForResponse() {
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
    
    private func cancelNudge() {
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
    
    // MARK: - 会話分析機能
    
    /// 会話終了後の分析処理（要約・興味タグ・新出語彙の抽出）
    /// - Parameter sessionId: 分析対象のセッションID
    private func analyzeSession(sessionId: String) async {
        print("📊 ConversationController: 会話分析開始 - sessionId: \(sessionId)")
        
        guard let userId = currentUserId, let childId = currentChildId else {
            print("⚠️ ConversationController: analyzeSession - ユーザー情報が設定されていないため、分析をスキップ")
            return
        }
        
        do {
            print("📊 ConversationController: analyzeSession - エラーキャッチブロック開始")
            // 1. Firestoreからこのセッションの全ターンを取得
            let turns = try await firebaseRepository.fetchTurns(
                userId: userId,
                childId: childId,
                sessionId: sessionId
            )
            
            guard !turns.isEmpty else {
                print("⚠️ ConversationController: ターンが存在しないため分析をスキップ - sessionId: \(sessionId)")
                return
            }
            
            print("📊 ConversationController: 取得したターン数 - \(turns.count)")
            
            // 2. テキストを連結してプロンプト作成
            let conversationLog = turns.compactMap { turn -> String? in
                guard let text = turn.text, !text.isEmpty else { return nil }
                let roleLabel = turn.role == .child ? "子ども" : "AI"
                return "\(roleLabel): \(text)"
            }.joined(separator: "\n")
            
            print("📊 ConversationController: 会話テキストの長さ - \(conversationLog.count)文字, テキストありのターン数: \(turns.filter { $0.text != nil && !$0.text!.isEmpty }.count)")
            print("📒 ConversationController: 会話ログサンプル（先頭150文字）: \(conversationLog.prefix(150))")
            
            guard !conversationLog.isEmpty else {
                print("⚠️ ConversationController: 会話テキストが存在しないため分析をスキップ - sessionId: \(sessionId), ターン数: \(turns.count)")
                return
            }
            
            print("📝 ConversationController: 会話ログ（\(turns.count)ターン）\n\(conversationLog)")
            
            // 3. OpenAI Chat Completion (gpt-4o-mini) に投げる
            let prompt = """
            以下の親子の会話ログを分析し、JSON形式で出力してください。
            
            出力項目:
            - summary: 子どもの発話を中心に、親向けに1〜2行で簡潔にまとめる。返答が短い/雑談が少ない場合は状況だけ短く触れる（長い飾り付けはしない）。
            - interests: 子どもが興味を示したトピック（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others から選択。英語のenum値で配列で出力）
            - newWords: 子どもが使った特徴的な単語や成長を感じる言葉（3つまで、配列で出力）
            
            会話ログ:
            \(conversationLog)
            
            JSON形式で出力してください。例:
            {
              "summary": "子どもが恐竜の種類について詳しく話していました。ティラノサウルスとトリケラトプスの違いを説明したり、草食と肉食の違いについて興味深そうに質問していました。",
              "interests": ["dinosaurs", "animals"],
              "newWords": ["ティラノサウルス", "草食", "肉食"]
            }
            """
            
            struct Payload: Encodable {
                let model: String
                let messages: [[String: String]]
                let response_format: [String: String]
                let temperature: Double
            }
            
            let payload = Payload(
                model: "gpt-4o-mini",
                messages: [
                    ["role": "system", "content": "あなたは会話分析の専門家です。JSON形式のみで回答してください。"],
                    ["role": "user", "content": prompt]
                ],
                response_format: ["type": "json_object"],
                temperature: 0.3
            )
            
            let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
                .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!
            
            var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("Bearer \(AppConfig.openAIKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(payload)
            
            let (data, response) = try await URLSession.shared.data(for: req)
            
            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("❌ ConversationController: 分析API呼び出し失敗 - Status: \(httpResponse.statusCode)")
                if let errorData = String(data: data, encoding: .utf8) {
                    print("   Error: \(errorData)")
                }
                return
            }
            
            // 4. JSONレスポンスをパース
            struct AnalysisResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }
            
            struct AnalysisResult: Decodable {
                let summary: String?
                let interests: [String]?
                let newWords: [String]?
            }
            
            let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                print("❌ ConversationController: 分析結果が空です")
                return
            }
            
            // JSON文字列をパース
            print("🔍 ConversationController: 分析結果のJSON文字列 - content: \(content)")
            guard let jsonData = content.data(using: .utf8) else {
                print("❌ ConversationController: JSON文字列のdata変換失敗")
                return
            }
            
            let result: AnalysisResult
            do {
                result = try JSONDecoder().decode(AnalysisResult.self, from: jsonData)
                print("✅ ConversationController: 分析結果のJSONパース成功 - summary: \(result.summary ?? "nil"), interests: \(result.interests ?? []), newWords: \(result.newWords ?? [])")
            } catch {
                print("❌ ConversationController: 分析結果のJSONパース失敗 - error: \(error), content: \(content)")
                return
            }
            
            // 5. 結果をFirestoreに保存
            let summaries = result.summary.map { [$0] } ?? []
            let interests = (result.interests ?? []).compactMap { FirebaseInterestTag(rawValue: $0) }
            let newVocabulary = result.newWords ?? []
            
            print("🔍 ConversationController: 保存前のデータ - summaries: \(summaries), interests: \(interests.map { $0.rawValue }), newVocabulary: \(newVocabulary)")
            
            try await firebaseRepository.updateAnalysis(
                userId: userId,
                childId: childId,
                sessionId: sessionId,
                summaries: summaries,
                interests: interests,
                newVocabulary: newVocabulary
            )
            print("✅ ConversationController: 分析結果をFirebaseに保存完了")
            await MainActor.run {
                if let firstSummary = summaries.first, !firstSummary.isEmpty {
                    self.liveSummary = firstSummary
                }
                self.liveInterests = interests
                self.liveNewVocabulary = newVocabulary
                print("🟢 ConversationController: live fields updated - summary:'\(self.liveSummary)', interests:\(self.liveInterests.map { $0.rawValue }), newVocabulary:\(self.liveNewVocabulary)")
            }
            print("✅ ConversationController: 会話分析完了 - summary: \(summaries.first ?? "なし"), interests: \(interests.map { $0.rawValue }), vocabulary: \(newVocabulary)")
            
        } catch {
            print("❌ ConversationController: analyzeSession - エラー発生: \(error)")
            print("❌ ConversationController: analyzeSession - エラーの詳細: \(String(describing: error))")
            if let nsError = error as NSError? {
                print("❌ ConversationController: analyzeSession - NSError詳細 - domain: \(nsError.domain), code: \(nsError.code), userInfo: \(nsError.userInfo)")
            }
            logFirebaseError(error, operation: "会話分析")
        }
    }
}

// MARK: - gpt-4o-audio-preview クライアント
fileprivate final class AudioPreviewStreamingClient {
    private let apiKey: String
    private let apiBase: URL
    private let decoder = JSONDecoder()
    // 🔊 音声生成を強く促す隠しリマインド（毎ターン先頭に挿入）
    private let audioReminder = "必ず音声つきで返して。音声が作れないなら、内容を短くしてでも音声を出して。"
    
    struct AudioPreviewResult {
        let text: String
        let audioMissing: Bool
    }
    
    init(apiKey: String, apiBase: URL) {
        self.apiKey = apiKey
        self.apiBase = apiBase
    }
    
    func streamResponse(
        audioData: Data,
        systemPrompt: String,
        history: [ConversationController.HistoryItem],
        onText: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void,
        onFirstByte: ((Date) -> Void)? = nil,
        emitText: Bool = true
    ) async throws -> AudioPreviewResult {
        var messages: [AudioPreviewPayload.Message] = []
        messages.append(.init(role: "system", content: [.text(systemPrompt)]))
        for item in history {
            let role = (item.role == "assistant") ? "assistant" : "user"
            messages.append(.init(role: role, content: [.text(item.text)]))
        }
        // ✅ 音声出力を逃さないためのリマインドを追加
        messages.append(.init(role: "user", content: [.text(audioReminder)]))
        messages.append(.init(role: "user", content: [.inputAudio(.init(data: audioData.base64EncodedString(), format: "wav"))]))

        return try await stream(
            messages: messages,
            inputSummary: "audioBytes=\(audioData.count)",
            emitText: emitText,
            onText: onText,
            onAudioChunk: onAudioChunk,
            onFirstByte: onFirstByte
        )
    }
    
    func streamResponseText(
        userText: String,
        systemPrompt: String,
        history: [ConversationController.HistoryItem],
        onText: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void,
        onFirstByte: ((Date) -> Void)? = nil,
        emitText: Bool = true
    ) async throws -> AudioPreviewResult {
        var messages: [AudioPreviewPayload.Message] = []
        messages.append(.init(role: "system", content: [.text(systemPrompt)]))
        for item in history {
            let role = (item.role == "assistant") ? "assistant" : "user"
            messages.append(.init(role: role, content: [.text(item.text)]))
        }
        // ✅ 音声出力を逃さないためのリマインドを追加
        messages.append(.init(role: "user", content: [.text(audioReminder)]))
        messages.append(.init(role: "user", content: [.text(userText)]))
        
        return try await stream(
            messages: messages,
            inputSummary: "textChars=\(userText.count)",
            emitText: emitText,
            onText: onText,
            onAudioChunk: onAudioChunk,
            onFirstByte: onFirstByte
        )
    }
    
    private func stream(
        messages: [AudioPreviewPayload.Message],
        inputSummary: String,
        emitText: Bool,
        onText: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void,
        onFirstByte: ((Date) -> Void)? = nil
    ) async throws -> AudioPreviewResult {
        var request = URLRequest(url: completionsURL())
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // audio-preview専用ヘッダ（環境によって不要な場合はコメントアウト可）
        request.addValue("audio-preview", forHTTPHeaderField: "OpenAI-Beta")
        // 音声生成がテキストより遅れた場合のためにタイムアウトを少し長めに
        request.timeoutInterval = 60.0
        
        let t0 = Date()
        
        let payload = AudioPreviewPayload(
            model: "gpt-4o-audio-preview",
            stream: true,
            modalities: ["text", "audio"],
            // 出力はヘッダなしPCM16で受信する（ストリーミング再生が安定）
            audio: .init(voice: "nova", format: "pcm16"),
            messages: messages
        )
        request.httpBody = try JSONEncoder().encode(payload)
        print("⏱️ AudioPreviewStreamingClient: stream start - \(inputSummary)")
        print("🎯 AudioPreviewStreamingClient: request config - model=\(payload.model), modalities=\(payload.modalities), audio.voice=\(payload.audio.voice), audio.format=\(payload.audio.format), messages=\(messages.count)")
        
        var finalTextClean = ""
        var didReceiveAudio = false
        var textChunkCount = 0
        var audioChunkCount = 0
        var emptyChunkCount = 0
        var audioFieldNullCount = 0
        var finishReasons: [String: Int] = [:]
        var refusalSummaries: [String] = []
        var audioMissingPayloadSamples: [String] = []
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let tReqDone = Date()
        print("⏱️ AudioPreviewStreamingClient: request sent -> awaiting first byte (\(String(format: "%.2f", tReqDone.timeIntervalSince(t0)))s)")
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AudioPreviewStreamingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "不正なレスポンスです"])
        }
        onFirstByte?(tReqDone)
        print("📦 AudioPreviewStreamingClient: response status=\(http.statusCode), headers=\(http.allHeaderFields)")
        if !(200..<300).contains(http.statusCode) {
            // レスポンスボディを文字列化
            let bodyString: String
            if let data = try? await bytes.reduce(into: Data(), { $0.append($1) }),
               let str = String(data: data, encoding: .utf8) {
                bodyString = str
            } else {
                bodyString = "(bodyなし)"
            }
            print("❌ AudioPreviewStreamingClient: HTTP \(http.statusCode) - body: \(bodyString)")
            throw NSError(domain: "AudioPreviewStreamingClient", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "HTTP \(http.statusCode)"])
        }
        
        for try await line in bytes.lines {
            guard line.hasPrefix("data:") else { continue }
            let payloadString = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payloadString == "[DONE]" { break }
            guard let data = payloadString.data(using: .utf8) else {
                print("⚠️ AudioPreviewStreamingClient: payloadString decode失敗 len=\(payloadString.count)")
                continue
            }
            
            // choicesのないイベントを先にふるい分け（エラー/ハートビート等）
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if json["choices"] == nil {
                    let type = json["type"] ?? json["event"] ?? json["object"] ?? "(unknown)"
                    if json["error"] != nil {
                        print("⚠️ AudioPreviewStreamingClient: non-choice event (error) type=\(type)")
                    } else {
                        print("ℹ️ AudioPreviewStreamingClient: non-choice event skipped type=\(type)")
                    }
                    continue
                }
            }
            
            do {
                let chunk = try decoder.decode(AudioPreviewStreamChunk.self, from: data)
                for choice in chunk.choices {
                    if let fr = choice.finishReason {
                        finishReasons[fr, default: 0] += 1
                    }
                    if let refusal = choice.message?.refusal {
                        let summary = "reason=\(refusal.reason ?? "nil"), message=\(refusal.message ?? "nil")"
                        refusalSummaries.append(summary)
                    }
                    
                    if let messageAudio = choice.message?.audio {
                        if let audioString = messageAudio.data {
                            if let audioData = Data(base64Encoded: audioString) {
                                didReceiveAudio = true
                                audioChunkCount += 1
                                onAudioChunk(audioData)
                            } else {
                                print("⚠️ AudioPreviewStreamingClient: message.audio decode失敗 - length=\(audioString.count)")
                            }
                        } else {
                            audioFieldNullCount += 1
                            print("⚠️ AudioPreviewStreamingClient: message.audio present but data=null")
                        }
                    }
                    
                    guard let delta = choice.delta else { continue }
                    var textFragments: [String] = []
                    
                    if let parts = delta.content {
                        textFragments.append(contentsOf: parts.compactMap { $0.text })
                    }
                    if let contentString = delta.contentString, !contentString.isEmpty {
                        textFragments.append(contentString)
                    }
                    if let outputs = delta.outputText {
                        for block in outputs {
                            if let blockText = block.text, !blockText.isEmpty {
                                textFragments.append(blockText)
                            }
                            if let parts = block.content {
                                textFragments.append(contentsOf: parts.compactMap { $0.text })
                            }
                        }
                    }
                    if let transcript = delta.audio?.transcript, !transcript.isEmpty {
                        textFragments.append(transcript)
                    }
                    
                    let mergedRaw = textFragments.joined()
                    let merged = sanitizeJapanese(mergedRaw)
                    let ratio = mergedRaw.isEmpty ? 0.0 : Double(merged.count) / Double(mergedRaw.count)
                    if merged.isEmpty {
                        // drop pure noise
                    } else if ratio < 0.5 {
                        print("⚠️ AudioPreviewStreamingClient: text delta dropped (non-ja dominant). raw='\(mergedRaw.prefix(60))...'")
                    } else {
                        print("📝 AudioPreviewStreamingClient: text delta (ja) = \(merged)")
                        finalTextClean += merged
                        textChunkCount += 1
                        if emitText { onText(merged) }
                    }
                    
                    if merged.isEmpty {
                        print("⚠️ AudioPreviewStreamingClient: no text in chunk. contentParts=\(delta.content?.count ?? 0), contentString=\(delta.contentString ?? "nil"), outputText=\(delta.outputText?.count ?? 0)")
                        print("   raw payload omitted (base64 audio may be large)")
                    }
                    
                    if let audioString = delta.audio?.data {
                        if let audioData = Data(base64Encoded: audioString) {
                            didReceiveAudio = true
                            audioChunkCount += 1
                            onAudioChunk(audioData)
                        } else {
                            print("⚠️ AudioPreviewStreamingClient: audio chunk decode失敗 - length=\(audioString.count)")
                        }
                    } else if delta.audio != nil {
                        audioFieldNullCount += 1
                        print("⚠️ AudioPreviewStreamingClient: delta.audio present but data=null")
                    }
                    if delta.audio?.data == nil && (delta.content?.isEmpty ?? true) && (delta.outputText?.isEmpty ?? true) {
                        print("⚠️ AudioPreviewStreamingClient: chunk has no text/audio; skipping")
                        emptyChunkCount += 1
                    }
                }
            } catch {
                print("⚠️ AudioPreviewStreamingClient: チャンクパース失敗 - \(error)")
                if payloadString.count < 200 { print("   payloadString='\(payloadString)'") }
            }
            
            if !didReceiveAudio && audioMissingPayloadSamples.count < 3 {
                audioMissingPayloadSamples.append(Self.redactedPayloadSample(payloadString))
            }
        }
        
        if !didReceiveAudio {
            print("❌ AudioPreviewStreamingClient: 音声チャンクなし（テキストのみの応答） - model=\(payload.model), modalities=\(payload.modalities), audio.voice=\(payload.audio.voice), audio.format=\(payload.audio.format)")
        }
        print("📊 AudioPreviewStreamingClient: chunk summary -> text:\(textChunkCount), audio:\(audioChunkCount), empty:\(emptyChunkCount), audioMissing=\(!didReceiveAudio)")
        if audioFieldNullCount > 0 {
            print("📄 AudioPreviewStreamingClient: audio objects without data count=\(audioFieldNullCount)")
        }
        if !finishReasons.isEmpty {
            let summary = finishReasons.map { "\($0.key):\($0.value)" }.joined(separator: ", ")
            print("📄 AudioPreviewStreamingClient: finish_reason summary -> \(summary)")
        }
        if !refusalSummaries.isEmpty {
            print("📄 AudioPreviewStreamingClient: refusal summaries (\(refusalSummaries.count)) -> \(refusalSummaries.prefix(3).joined(separator: " | "))")
        }
        if !audioMissingPayloadSamples.isEmpty && !didReceiveAudio {
            print("🧪 AudioPreviewStreamingClient: audioMissing payload samples (redacted) ->")
            audioMissingPayloadSamples.forEach { print("   \( $0 )") }
        }
        if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            print("📦 AudioPreviewStreamingClient: response headers - Content-Type: \(contentType)")
        }
        
        let final = finalTextClean.isEmpty ? "(おへんじができなかったよ)" : finalTextClean
        return AudioPreviewResult(text: final, audioMissing: !didReceiveAudio)
    }
    
    private func completionsURL() -> URL {
        if apiBase.path.contains("/v1") {
            return apiBase.appendingPathComponent("chat/completions")
        } else {
            return apiBase
                .appendingPathComponent("v1")
                .appendingPathComponent("chat/completions")
        }
    }
    
    private static func redactedPayloadSample(_ payload: String) -> String {
        var s = payload
        while let range = s.range(of: "\"data\":\"") {
            if let endQuote = s[range.upperBound...].firstIndex(of: "\"") {
                let replacement = "\"data\":\"<base64:\(s[range.upperBound..<endQuote].count) bytes>\""
                s.replaceSubrange(range.lowerBound...endQuote, with: replacement)
            } else {
                break
            }
        }
        if s.count > 240 {
            let prefix = s.prefix(240)
            return "\(prefix)...(truncated, len=\(s.count))"
        }
        return s
    }
    
    private static func hexSnippet(_ data: Data, length: Int) -> String {
        guard !data.isEmpty else { return "(empty)" }
        return data.prefix(length).map { String(format: "%02X", $0) }.joined(separator: " ")
    }
    
    /// TTS応答データを安全に24kHz/mono/PCM16データへ変換
    private static func pcm16Data(from data: Data, contentType: String?) -> Data? {
        // JSONや明らかなエラーを弾く
        if let first = data.first, first == UInt8(ascii: "{") || first == UInt8(ascii: "[") {
            return nil
        }
        
        // WAVならAVAudioFileで正規化
        let isWav = (contentType?.lowercased().contains("wav") == true) ||
            (data.count >= 4 && String(data: data.prefix(4), encoding: .ascii) == "RIFF")
        if isWav {
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("tts_fallback_\(UUID().uuidString).wav")
            do {
                try data.write(to: tmpURL)
                let file = try AVAudioFile(forReading: tmpURL)
                let targetFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000, channels: 1, interleaved: true)!
                let converter = AVAudioConverter(from: file.processingFormat, to: targetFormat)!
                
                var pcmData = Data()
                while true {
                    guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024) else { break }
                    try file.read(into: inputBuffer)
                    if inputBuffer.frameLength == 0 { break }
                    
                    let ratio = targetFormat.sampleRate / file.processingFormat.sampleRate
                    let outFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio + 16)
                    guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outFrames) else { break }
                    
                    var error: NSError?
                    let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    if status == .haveData || status == .endOfStream,
                       let ch = outBuffer.int16ChannelData?.pointee {
                        let sampleCount = Int(outBuffer.frameLength) * Int(targetFormat.channelCount)
                        pcmData.append(UnsafeBufferPointer(start: ch, count: sampleCount))
                    } else if let error {
                        print("⚠️ ConversationController: WAV->PCM convert error - \(error.localizedDescription)")
                        return nil
                    }
                }
                try? FileManager.default.removeItem(at: tmpURL)
                return pcmData.isEmpty ? nil : pcmData
            } catch {
                print("⚠️ ConversationController: WAV decode failed - \(error.localizedDescription)")
                try? FileManager.default.removeItem(at: tmpURL)
                return nil
            }
        }
        
        // PCM16前提のレスポンスの場合（audio/pcm 等）
        let isPCM = contentType?.lowercased().contains("pcm") == true || contentType?.lowercased().contains("audio/raw") == true
        if isPCM {
            return data
        }
        
        // 不明形式は無音扱い
        print("⚠️ ConversationController: unknown TTS format (contentType=\(contentType ?? "nil")), cannot decode safely")
        return nil
    }
    
    /// 簡易サニタイズ（日本語中心の文字だけ残す）
    private func sanitizeJapanese(_ text: String) -> String {
        if text.isEmpty { return text }
        var allowed = CharacterSet()
        allowed.formUnion(.whitespacesAndNewlines)
        allowed.formUnion(CharacterSet(charactersIn: "。、！？・ー「」『』（）［］【】…〜"))
        // ひらがな・カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{30FF}"))
        // 半角カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{FF65}"..."\u{FF9F}"))
        // CJK統合漢字
        allowed.formUnion(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))
        
        let cleanedScalars = text.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(cleanedScalars))
    }
}

// MARK: - Payload/Stream Models
private struct AudioPreviewPayload: Encodable {
    struct AudioConfig: Encodable {
        let voice: String
        let format: String
    }
    
    struct Message: Encodable {
        let role: String
        let content: [MessageContent]
    }
    
    enum MessageContent: Encodable {
        case text(String)
        case inputAudio(AudioData)
        
        struct AudioData: Encodable {
            let data: String
            let format: String
        }
        
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .text(let text):
                try container.encode("text", forKey: .type)
                try container.encode(text, forKey: .text)
            case .inputAudio(let audio):
                try container.encode("input_audio", forKey: .type)
                // OpenAI audio-preview expects input_audio payload under key "input_audio"
                try container.encode(audio, forKey: .inputAudio)
            }
        }
        
        enum CodingKeys: String, CodingKey { case type, text, audio, inputAudio = "input_audio" }
    }
    
    let model: String
    let stream: Bool
    let modalities: [String]
    let audio: AudioConfig
    let messages: [Message]
}

private struct AudioPreviewStreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            let content: [ContentPart]?
            let contentString: String?
            let outputText: [OutputText]?
            let audio: AudioDelta?
            
            enum CodingKeys: String, CodingKey {
                case content
                case outputText = "output_text"
                case audio
            }
            
            init(from decoder: Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                if let parts = try? container.decode([ContentPart].self, forKey: .content) {
                    self.content = parts
                    self.contentString = nil
                } else {
                    self.content = nil
                    self.contentString = try? container.decode(String.self, forKey: .content)
                }
                self.outputText = try? container.decode([OutputText].self, forKey: .outputText)
                self.audio = try? container.decode(AudioDelta.self, forKey: .audio)
            }
        }
        let delta: Delta?
        let message: Message?
        let finishReason: String?
        
        enum CodingKeys: String, CodingKey {
            case delta
            case message
            case finishReason = "finish_reason"
        }
    }
    
    struct ContentPart: Decodable {
        let type: String?
        let text: String?
    }
    
    struct AudioDelta: Decodable {
        let id: String?
        let data: String?
        let transcript: String?
        
        enum CodingKeys: String, CodingKey {
            case id
            case data
            case transcript
        }
    }
    
    struct OutputText: Decodable {
        let id: String?
        let content: [OutputTextPart]?
        let text: String?
    }
    
    struct OutputTextPart: Decodable {
        let type: String?
        let text: String?
    }
    
    struct Message: Decodable {
        let audio: AudioDelta?
        let refusal: Refusal?
        let content: [ContentPart]?
    }
    
    struct Refusal: Decodable {
        let reason: String?
        let message: String?
    }
    
    let choices: [Choice]
}
