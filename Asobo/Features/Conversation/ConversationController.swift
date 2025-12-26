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

@MainActor
public final class ConversationController: NSObject, ObservableObject {

    // MARK: - UI State
    public enum Mode: String, CaseIterable { case localSTT, realtime }

    @Published public var mode: Mode = .localSTT
    @Published public var transcript: String = ""
    @Published public var isRecording: Bool = false
    @Published public var errorMessage: String?
    @Published public var isRealtimeActive: Bool = false
    @Published public var isRealtimeConnecting: Bool = false
    // ✅ 音声プレビュー用のローカル文字起こしを行うか（端末環境で kAFAssistantErrorDomain 1101 が多発するためデフォルトOFF）
    private let enableLocalUserTranscription: Bool = true
    
    // 追加: ユーザーが停止したかを覚えるフラグ
    private var userStoppedRecording = false
    
    // ✅ AI音声再生中フラグ（onAudioDeltaReceivedで設定、sendMicrophonePCMの早期returnを一元化）
    private var isAIPlayingAudio: Bool = false
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
    @Published private var turnState: TurnState = .idle
    
    // ✅ 「待つ→促す」タイマー
    private var nudgeTimer: Timer?
    // ✅ 促し回数の上限とカウンター
    private let maxNudgeCount = AppConfig.nudgeMaxCount
    private var nudgeCount = 0
    
    // ✅ 追加: 最後に「ユーザーの声（環境音含む）」が閾値を超えた時刻
    private var lastUserVoiceActivityTime: Date = Date()
    
    // ✅ 追加: 無音判定の閾値（-50dBより大きければ「何か音がしている」とみなす）
    // 調整目安: -40dB(普通) 〜 -60dB(静寂)。-50dBは「ささやき声や環境音」レベル
    private let silenceThresholdDb: Double = -50.0
    
    // ✅ 追加: speech_startedが来ていない警告のカウンター
    private var speechStartedMissingCount: Int = 0
    
    // MARK: - VAD (Hands-free Conversation)
    // 音声入力の音量がこの閾値を超えたら「発話中」とみなす
    private let vadSpeechThresholdDb: Double = -32.0   // 環境音での誤検知を防ぐために少し高め
    // この閾値未満の状態が一定時間続いたら「発話終了（静寂）」とみなす
    private let vadSilenceThresholdDb: Double = -46.0  // 環境音を静寂とみなしやすくする
    private let vadSilenceDuration: TimeInterval = 1.0 // 送信までの待ち時間も短縮
    private var isUserSpeaking: Bool = false
    private var silenceTimer: Timer?
    
    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false
    @Published public var liveSummary: String = ""                 // 会話の簡易要約（毎ターン更新）
    @Published public var liveInterests: [FirebaseInterestTag] = [] // セッション終了時に更新
    @Published public var liveNewVocabulary: [String] = []          // セッション終了時に更新
    
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
    private var receiveTextTask: Task<Void, Never>?
    private var receiveAudioTask: Task<Void, Never>?
    private var receiveInputTextTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?     // セッション開始タスクの管理
    private var liveSummaryTask: Task<Void, Never>?      // ライブ要約生成タスク
    private var inMemoryTurns: [FirebaseTurn] = []       // 会話ログ（要約用）
    
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
    private var turnCount: Int = 0
    
    // ✅ ユーザー情報を設定するメソッド
    public func setupUser(userId: String, childId: String) {
        self.currentUserId = userId
        self.currentChildId = childId
        print("✅ ConversationController: ユーザー情報を設定 - Parent=\(userId), Child=\(childId)")
    }
    
    private static func pcmFromWavIfPossible(_ data: Data) -> Data? {
        // 最低限のWAVヘッダー検証とPCM16LE抽出（リトルエンディアン）
        if data.count < 44 { return nil }
        let riff = data[0..<4]
        let wave = data[8..<12]
        guard String(data: riff, encoding: .ascii) == "RIFF",
              String(data: wave, encoding: .ascii) == "WAVE" else { return nil }
        // fmtチャンクは16bit PCM想定（オフセット固定簡易版）
        let audioFormat = UInt16(littleEndian: data.subdata(in: 20..<22).withUnsafeBytes { $0.load(as: UInt16.self) })
        let bitsPerSample = UInt16(littleEndian: data.subdata(in: 34..<36).withUnsafeBytes { $0.load(as: UInt16.self) })
        guard audioFormat == 1, bitsPerSample == 16 else { return nil }
        // dataチャンク位置（簡易：通常44バイト固定）
        let dataOffset = 44
        guard data.count >= dataOffset else { return nil }
        return data.advanced(by: dataOffset)
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
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        
        // 受信タスクをキャンセル
        receiveTextTask?.cancel()
        receiveTextTask = nil
        receiveAudioTask?.cancel()
        receiveAudioTask = nil
        receiveInputTextTask?.cancel()
        receiveInputTextTask = nil
        
        // マイクとプレイヤーを停止
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
                self.isAIPlayingAudio = isPlaying
                self.mic?.setAIPlayingAudio(isPlaying)
                
                if isPlaying {
                    print("🔊 ConversationController: 再生開始 - マイクゲート閉 (AEC/BargeInモード)")
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
        
        let session = FirebaseConversationSession(
            id: newSessionId,
            mode: .freeTalk,
            startedAt: Date(),
            interestContext: [],
            summaries: [],
            newVocabulary: [],
            turnCount: 0
        )
        
        Task { [weak self] in
            guard let self = self else { return }
            do {
                try await self.firebaseRepository.createSession(
                    userId: userId,
                    childId: childId,
                    session: session
                )
                print("✅ ConversationController: Firebaseセッション作成完了 - sessionId: \(newSessionId)")
            } catch {
                self.logFirebaseError(error, operation: "Firebaseセッション作成")
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
        
        // セッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        sessionStartTask = nil
        
        // 受信タスクをキャンセル
        receiveTextTask?.cancel(); receiveTextTask = nil
        receiveAudioTask?.cancel(); receiveAudioTask = nil
        receiveInputTextTask?.cancel(); receiveInputTextTask = nil
        
        // マイクとプレイヤーを停止
        mic?.stop(); mic = nil
        player.stop()
        
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
        player.stop()
        
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
        player.stop()

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
                    
                    // 閾値(-50dB)より大きければ「音がしている」とみなして時刻更新
                    if rms > self.silenceThresholdDb {
                        self.lastUserVoiceActivityTime = Date()
                    }
                }
            }
            
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
            
            // 注意: 促しタイマーは onResponseDone でのみセットする（AI応答完了時のみ）
            // ユーザーが話し始めた直後はタイマーをセットしない
            print("✅ ConversationController: PTT開始シーケンス完了")
        }
    }
    

    public func stopPTTRealtime() {
        isRecording = false
        isHandsFreeMode = false
        mic?.stop()
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
        player.stop()
        
        if !sharedAudioEngine.isRunning {
            do { try sharedAudioEngine.start() } catch {
                print("⚠️ ConversationController: エンジン再開失敗 - \(error.localizedDescription)")
            }
        }
        
        isHandsFreeMode = true
        startHandsFreeInternal()
    }
    
    public func stopHandsFreeConversation() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        isHandsFreeMode = false
        isRecording = false
        isUserSpeaking = false
        recordedPCMData.removeAll()
        mic?.stop()
        turnState = .waitingUser
    }
    
    private func startHandsFreeInternal() {
        cancelNudge()
        player.stop()
        mic?.stop()
        
        Task { @MainActor [weak self] in
            guard let self = self else { return }
            
            // 1. エンジンを一度止めてから再構成
            if self.sharedAudioEngine.isRunning {
                self.sharedAudioEngine.stop()
            }
            
            self.mic = MicrophoneCapture(sharedEngine: self.sharedAudioEngine, onPCM: { [weak self] buf in
                self?.appendPCMBuffer(buf)
            }, outputMonitor: self.player.outputMonitor)
            
            self.mic?.onVolume = { [weak self] rms in
                Task { @MainActor [weak self] in
                    self?.handleVAD(rms: rms)
                }
            }
            self.mic?.onBargeIn = { [weak self] in
                self?.interruptAI()
            }
            
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
            print("🟢 ハンズフリー会話開始: Listening...")
        }
    }
    
    private func handleVAD(rms: Double) {
        // AI発話中の割り込み判定（MicrophoneCaptureのonBargeInからも呼ばれるが二重保険）
        if turnState == .speaking && rms > vadSpeechThresholdDb {
            interruptAI()
            return
        }
        if turnState == .thinking { return }
        
        // 発話検知
        if rms > vadSpeechThresholdDb {
            if !isUserSpeaking {
                print("🗣️ 発話検知開始")
                isUserSpeaking = true
                silenceTimer?.invalidate()
                silenceTimer = nil
            }
        }
        
        // 静寂検知
        if isUserSpeaking && rms < vadSilenceThresholdDb {
            if silenceTimer == nil {
                print("🤫 静寂検知...タイマーセット")
                silenceTimer = Timer.scheduledTimer(withTimeInterval: vadSilenceDuration, repeats: false) { [weak self] _ in
                    Task { @MainActor [weak self] in
                        self?.commitUserSpeech()
                    }
                }
            }
        } else if rms > vadSpeechThresholdDb {
            silenceTimer?.invalidate()
            silenceTimer = nil
        }
    }
    
    private func interruptAI() {
        guard turnState == .speaking else { return }
        print("⚡️ 割り込み検知: AI停止 -> 聞き取りへ")
        
        // 再生を即時停止し、マイクゲートを開く
        player.stopImmediately()
        isAIPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        
        // ステートをListeningへ戻し、バッファを新規発話用にする
        turnState = .listening
        recordedPCMData.removeAll()
        isUserSpeaking = true
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
        guard isUserSpeaking else { return }
        print("🚀 発話終了判定 -> 送信")
        
        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        
        mic?.stop()
        turnState = .thinking
        
        Task {
            await self.sendAudioPreviewRequest()
        }
    }
    
    private func resumeListening() {
        guard isHandsFreeMode else { return }
        print("👂 聞き取り再開")
        turnState = .listening
        recordedPCMData.removeAll()
        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil
        
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
    
    private func sendAudioPreviewRequest() async {
        guard let client = audioPreviewClient else {
            await MainActor.run { self.errorMessage = "音声プレビュークライアントが初期化されていません" }
            return
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
        
        let wav = pcm16ToWav(pcmData: captured, sampleRate: recordedSampleRate)
        
        // ユーザー音声も会話履歴にテキストで残すため、ローカルで並行して文字起こしを試みる
        let userTranscriptionTask: Task<String?, Never>? = enableLocalUserTranscription
            ? Task.detached { [wavData = wav] in
                await ConversationController.transcribeUserAudio(wavData: wavData)
            }
            : nil
        
        await MainActor.run { self.isThinking = true }
        let tStart = Date()
        print("⏱️ ConversationController: sendAudioPreviewRequest start - pcmBytes=\(captured.count), sampleRate=\(recordedSampleRate)")
        
        do {
            let finalText = try await client.streamResponse(
                audioData: wav,
                systemPrompt: currentSystemPrompt,
                history: conversationHistory,
                onText: { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        let clean = self.sanitizeAIText(delta)
                        if clean.isEmpty { return }
                        print("🟦 onText delta (clean):", clean)
                        self.aiResponseText += clean
                    }
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        print("🔊 onAudioChunk bytes:", chunk.count)
                        self.turnState = .speaking
                        self.player.resumeIfNeeded()
                        // 出力はpcm16指定なのでそのまま再生
                        self.player.playChunk(chunk)
                    }
                }
            )
            let tEnd = Date()
            print("⏱️ ConversationController: streamResponse completed in \(String(format: "%.2f", tEnd.timeIntervalSince(tStart)))s, finalText.count=\(finalText.count), finalText=\"\(finalText)\"")
            let cleanFinal = self.sanitizeAIText(finalText)
            
            await MainActor.run {
                // 吹き出し用に最終テキストをUIへ反映（音声のみの場合でもテキストを入れる）
                self.aiResponseText = cleanFinal
                print("🟩 set aiResponseText final:", cleanFinal)
                if self.isHandsFreeMode && self.isRecording && self.turnState != .speaking {
                    self.resumeListening()
                } else if self.turnState != .speaking {
                    self.turnState = .waitingUser
                    self.startWaitingForResponse()
                }
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
                do {
                    try await firebaseRepository.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                    try await firebaseRepository.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: aiTurn)
                    turnCount += 2
                    try? await firebaseRepository.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: turnCount)
                } catch {
                    logFirebaseError(error, operation: "音声会話の保存")
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
                self.errorMessage = error.localizedDescription
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
        }
        
        await MainActor.run { self.isThinking = false }
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
            
            let payload = Payload(
                model: "gpt-4o-mini",
                messages: [
                    ["role": "system", "content": "あなたは幼児向けのAIアシスタントです。日本語のみで答えてください。ひらがな中心・一文を短く・やさしく・むずかしい言葉をさけます。"],
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
        """
        あなたは3〜5歳の子どもと話す、優しくて楽しくて可愛い「マスコットキャラクター」です。日本語のみで答えます。
        最重要: 毎回答えの音声(TTS)も必ず生成し、テキストだけの応答は禁止です。音声チャンクを省略しないでください。
        もしテキストのみの応答がきたらバグとみなし再生成してください。

        【キャラ設定と話し方】
        - 一人称は「ボク」、語尾は「〜だヨ！」「〜だね！」「〜かな？」のようにカタカナを混ぜて元気よく話す。
        - 常にハイテンションで、オーバーリアクション気味に。

        ルール:
        1) 返答は1〜2文・40文字以内。長話は禁止。
        2) 聞き取れない/わからない時は勝手に話を作らず「ん？もういっかい言って？」「え？」などと聞き返す。
        3) 子どもが話しやすいように、最後に簡単な質問を添える（例:「くるまはすき？」「きょうはなにしたの？」）。
        4) むずかしい言葉を避け、ひらがな中心でやさしく。擬音語もOK。
        5) 直前の会話文脈を維持し、話題を飛ばさない。
        """
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
        以下の親子の会話を分析し、JSON形式で出力してください。
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
        print("⏰ ConversationController: 促しタイマーをセットしました (10秒後に発火)")
        
        // 既存のタイマーがあればキャンセル
        cancelNudge()
        
        // 促し上限に達している場合はタイマーを張らない
        guard nudgeCount < maxNudgeCount else {
            print("⏹ ConversationController: 促し上限(\(maxNudgeCount)回)に達したためタイマーを開始しません")
            return
        }
        
        // メインスレッドで安全にタイマーを作成
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            
            self.nudgeTimer = Timer.scheduledTimer(withTimeInterval: 10.0, repeats: false) { [weak self] _ in
                Task { @MainActor [weak self] in
                    print("⏰ ConversationController: 促しタイマー発火！ -> 状態チェック開始")
                    await self?.sendNudgeIfNoResponse()
                }
            }
        }
    }
    
    // ✅ 修正: サーバーの状態に関わらず、実際の無音時間が長ければ促す
    private func sendNudgeIfNoResponse() async {
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
    
    init(apiKey: String, apiBase: URL) {
        self.apiKey = apiKey
        self.apiBase = apiBase
    }
    
    func streamResponse(
        audioData: Data,
        systemPrompt: String,
        history: [ConversationController.HistoryItem],
        onText: @escaping (String) -> Void,
        onAudioChunk: @escaping (Data) -> Void
    ) async throws -> String {
        var request = URLRequest(url: completionsURL())
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // audio-preview専用ヘッダ（環境によって不要な場合はコメントアウト可）
        request.addValue("audio-preview", forHTTPHeaderField: "OpenAI-Beta")
        
        let t0 = Date()
        
        // ✅ システム + 履歴 + 今回の音声をまとめて渡す
        var messages: [AudioPreviewPayload.Message] = []
        messages.append(.init(role: "system", content: [.text(systemPrompt)]))
        for item in history {
            let role = (item.role == "assistant") ? "assistant" : "user"
            messages.append(.init(role: role, content: [.text(item.text)]))
        }
        messages.append(.init(role: "user", content: [.inputAudio(.init(data: audioData.base64EncodedString(), format: "wav"))]))
        
        let payload = AudioPreviewPayload(
            model: "gpt-4o-audio-preview",
            stream: true,
            modalities: ["text", "audio"],
            // 出力はヘッダなしPCM16で受信する（ストリーミング再生が安定）
            audio: .init(voice: "nova", format: "pcm16"),
            messages: messages
        )
        request.httpBody = try JSONEncoder().encode(payload)
        
        var finalTextClean = ""
        var didReceiveAudio = false
        var textChunkCount = 0
        var audioChunkCount = 0
        var emptyChunkCount = 0
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let tReqDone = Date()
        print("⏱️ AudioPreviewStreamingClient: request sent -> awaiting first byte (\(String(format: "%.2f", tReqDone.timeIntervalSince(t0)))s)")
        guard let http = response as? HTTPURLResponse else {
            throw NSError(domain: "AudioPreviewStreamingClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "不正なレスポンスです"])
        }
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
            
            do {
                let chunk = try decoder.decode(AudioPreviewStreamChunk.self, from: data)
                if let delta = chunk.choices.first?.delta {
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
                        onText(merged)
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
        }
        
        if !didReceiveAudio {
            print("⚠️ AudioPreviewStreamingClient: 音声チャンクなし（テキストのみの応答）")
        }
        print("📊 AudioPreviewStreamingClient: chunk summary -> text:\(textChunkCount), audio:\(audioChunkCount), empty:\(emptyChunkCount)")
        if let contentType = http.value(forHTTPHeaderField: "Content-Type") {
            print("📦 AudioPreviewStreamingClient: response headers - Content-Type: \(contentType)")
        }
        
        let final = finalTextClean.isEmpty ? "(おへんじができなかったよ)" : finalTextClean
        return final
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
    
    let choices: [Choice]
}
