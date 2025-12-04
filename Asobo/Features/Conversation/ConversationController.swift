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
public final class ConversationController: ObservableObject {

    // MARK: - UI State
    public enum Mode: String, CaseIterable { case localSTT, realtime }

    @Published public var mode: Mode = .localSTT
    @Published public var transcript: String = ""
    @Published public var isRecording: Bool = false
    @Published public var errorMessage: String?
    @Published public var isRealtimeActive: Bool = false
    @Published public var isRealtimeConnecting: Bool = false
    
    // 追加: ユーザーが停止したかを覚えるフラグ
    private var userStoppedRecording = false
    
    // ✅ AI音声再生中フラグ（onAudioDeltaReceivedで設定、sendMicrophonePCMの早期returnを一元化）
    private var isAIPlayingAudio: Bool = false
    
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
    
    // ✅ 追加: 最後に「ユーザーの声（環境音含む）」が閾値を超えた時刻
    private var lastUserVoiceActivityTime: Date = Date()
    
    // ✅ 追加: 無音判定の閾値（-50dBより大きければ「何か音がしている」とみなす）
    // 調整目安: -40dB(普通) 〜 -60dB(静寂)。-50dBは「ささやき声や環境音」レベル
    private let silenceThresholdDb: Double = -50.0
    
    // ✅ 追加: speech_startedが来ていない警告のカウンター
    private var speechStartedMissingCount: Int = 0
    
    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false
    
    // ✅ 新しい応答が作成された時にtextBufferをクリアするためのフラグ
    private var shouldClearTextBuffer: Bool = false
    
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
    private var realtimeClient: RealtimeClientOpenAI?
    private var receiveTextTask: Task<Void, Never>?
    private var receiveAudioTask: Task<Void, Never>?
    private var receiveInputTextTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?     // セッション開始タスクの管理
    
    // MARK: - Firebase保存
    private let firebaseRepository = FirebaseConversationsRepository()
    private var currentSessionId: String?
    // TODO: 本来はFirebase Authから取得する必要がある
    private var currentUserId: String = "dummy_parent_uid"
    // TODO: 選択中の子供IDを設定する必要がある
    private var currentChildId: String = "dummy_child_uid"
    private var turnCount: Int = 0
    
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
    }

    deinit {
        // ✅ deinitは同期的に実行される必要があるため、非同期処理は行わない
        // 同期的に実行可能なクリーンアップのみを行う
        
        // セッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        sessionStartTask = nil
        
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
            print("⚠️ ConversationController: 既にRealtimeセッションがアクティブまたは接続中です")
            return
        }
        
        // 既存のセッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        
        // 既存のクライアントがあれば完全にクリーンアップ
        if realtimeClient != nil {
            print("🧹 ConversationController: 既存のクライアントをクリーンアップ中...")
            Task { [weak self] in
                guard let self else { return }
                try? await self.realtimeClient?.finishSession()
                await MainActor.run {
                    self.realtimeClient = nil
                    self.startRealtimeSessionInternal()
                }
            }
            return
        }
        
        startRealtimeSessionInternal()
    }
    
    private func startRealtimeSessionInternal() {
        // 接続中フラグを設定
        isRealtimeConnecting = true
        
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

        // エンドポイントURL（REALTIME_WSS_URL があれば優先）
        let url: URL = {
            if let s = Bundle.main.object(forInfoDictionaryKey: "REALTIME_WSS_URL") as? String,
               let u = URL(string: s) { 
                print("🔗 ConversationController: 直接URL使用 - \(s)")
                return u 
            }

            if let https = URL(string: AppConfig.realtimeEndpoint),
               var comps = URLComponents(url: https, resolvingAgainstBaseURL: false) {
                let isHTTP = comps.scheme?.lowercased() == "http"
                comps.scheme = isHTTP ? "ws" : "wss"   // 読みと書きを分離
                let finalUrl = comps.url ?? https
                print("🔗 ConversationController: 構築URL使用 - \(finalUrl)")
                return finalUrl
            }

            // ✅ gpt-realtime に固定（フォールバックを完全排除）
            let fallbackUrl = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
            print("🔗 ConversationController: フォールバックURL使用 - \(fallbackUrl)")
            return fallbackUrl
        }()

        let key = AppConfig.openAIKey
        print("🔑 ConversationController: APIキー確認 - \(key.prefix(10))...")
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.errorMessage = "OPENAI_API_KEY が未設定です（Secrets.xcconfig を確認）"
            return
        }
        
        // APIキーの形式をチェック
        guard key.hasPrefix("sk-") else {
            self.errorMessage = "APIキーの形式が正しくありません（sk-で始まる必要があります）"
            return
        }

        realtimeClient = RealtimeClientOpenAI(url: url, apiKey: key)
        
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
                    // ✅ AIが完全に話し終わったら、ユーザーの入力を待つ状態にしてタイマーを開始
                    // 注意: 実際の音声再生が終了した時点でタイマーをセットする（onResponseDoneではなく）
                    if self.turnState == .speaking {
                        self.turnState = .waitingUser
                        print("⏰ ConversationController: AIの音声再生完全終了 -> 促しタイマーを開始")
                        self.startWaitingForResponse()
                    }
                }
            }
        }
        
        // Realtimeのイベントにフック
        realtimeClient?.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ユーザー発話を検知 → 促しタイマーは止める & AI音声を即停止
                print("🎤 ConversationController: ユーザー発話検知 -> タイマーキャンセル")
                self.cancelNudge()  // ✅ ユーザーが話し始めたので促しをキャンセル
                self.speechStartedMissingCount = 0  // ✅ カウンターをリセット
                self.turnState = .listening
                // ✅ ユーザーが話し始めたら即AI音声を止める
                self.player.stopImmediately()
            }
        }
        
        // ✅ 追加: speech_startedが来ていない警告のコールバック
        realtimeClient?.onSpeechStartedMissing = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.speechStartedMissingCount += 1
                print("⚠️ ConversationController: speech_started未検出警告 #\(self.speechStartedMissingCount)")
                
                // 2回警告が出たら促しメッセージを送信
                if self.speechStartedMissingCount >= 2 {
                    print("🚀 ConversationController: speech_started未検出が2回に達したため、促しメッセージを送信します")
                    self.speechStartedMissingCount = 0  // リセット
                    await self.sendNudgeIfNoResponse()
                }
            }
        }
        
        realtimeClient?.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.turnState = .thinking
                // ✅ 応答生成中なので促しをキャンセル
                self.cancelNudge()
                self.speechStartedMissingCount = 0  // ✅ カウンターをリセット
                // 以降は Realtime 側が commit → response.create を送信してくれる設計にしている
            }
        }
        
        realtimeClient?.onInputCommitted = { [weak self] transcript in
            Task { @MainActor in
                guard let self else { return }
                // ✅ 入力がコミットされたので促しをキャンセル
                self.cancelNudge()
                self.speechStartedMissingCount = 0  // ✅ カウンターをリセット
                let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.isEmpty || t.count < 2 {
                    // ✅ 聞き取り失敗時は必ず聞き返し
                    print("⚠️ ConversationController: 聞き取り失敗 - テキスト: 「\(t)」（空または2文字未満）")
                    self.turnState = .clarifying
                    
                    // ✅ 既存の応答をキャンセルして、聞き返しメッセージを送信
                    Task { [weak self] in
                        guard let self else { return }
                        do {
                            try await self.realtimeClient?.requestClarification()
                            print("✅ ConversationController: 聞き返しメッセージ送信完了")
                        } catch {
                            print("❌ ConversationController: 聞き返しメッセージ送信失敗 - \(error)")
                        }
                    }
                } else {
                    // ✅ 聞き取り成功 → 応答生成中
                    self.turnState = .thinking
                    
                    // ✅ Firebaseにユーザーの発言を保存
                    if let sessionId = self.currentSessionId {
                        let turn = FirebaseTurn(
                            role: .child,
                            text: t,
                            timestamp: Date()
                        )
                        Task {
                            do {
                                try await self.firebaseRepository.addTurn(
                                    userId: self.currentUserId,
                                    childId: self.currentChildId,
                                    sessionId: sessionId,
                                    turn: turn
                                )
                                // ターン数を更新
                                self.turnCount += 1
                                try? await self.firebaseRepository.updateTurnCount(
                                    userId: self.currentUserId,
                                    childId: self.currentChildId,
                                    sessionId: sessionId,
                                    turnCount: self.turnCount
                                )
                                print("✅ ConversationController: ユーザーの発言をFirebaseに保存 - 「\(t)」")
                            } catch {
                                self.logFirebaseError(error, operation: "ユーザーの発言保存")
                            }
                        }
                    }
                }
            }
        }
        
        realtimeClient?.onResponseCreated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ 既にAIが話している場合は新しい応答をブロック（ターン制御のため）
                if case .speaking = self.turnState {
                    print("⚠️ ConversationController: 既にAIが話しているため、新しい応答をブロック（turnState: .speaking）")
                    return
                }
                // ✅ 新しい応答が作成された時にテキストをクリア（前の応答のテキストを消す）
                self.aiResponseText = ""
                // ✅ textBufferもクリアするためのフラグを立てる
                self.shouldClearTextBuffer = true
                print("📝 ConversationController: 新しい応答開始 - aiResponseTextをクリア、textBufferクリアフラグを設定")
                // ✅ 応答が来たので促しをキャンセル
                self.cancelNudge()
                self.turnState = .speaking
                // ✅ 音声再生を再開（stopImmediately()でvolume=0になった場合の復帰）
                self.player.resumeIfNeeded()
            }
        }
        
        realtimeClient?.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                
                print("✅ ConversationController: AIの応答完了 (onResponseDone)")
                
                // ✅ FirebaseにAIの応答を保存
                if let sessionId = self.currentSessionId, !self.aiResponseText.isEmpty {
                    let aiText = self.aiResponseText.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !aiText.isEmpty {
                        let turn = FirebaseTurn(
                            role: .ai,
                            text: aiText,
                            timestamp: Date()
                        )
                        Task {
                            do {
                                try await self.firebaseRepository.addTurn(
                                    userId: self.currentUserId,
                                    childId: self.currentChildId,
                                    sessionId: sessionId,
                                    turn: turn
                                )
                                // ターン数を更新
                                self.turnCount += 1
                                try? await self.firebaseRepository.updateTurnCount(
                                    userId: self.currentUserId,
                                    childId: self.currentChildId,
                                    sessionId: sessionId,
                                    turnCount: self.turnCount
                                )
                                print("✅ ConversationController: AIの応答をFirebaseに保存 - 「\(aiText)」")
                            } catch {
                                self.logFirebaseError(error, operation: "AIの応答保存")
                            }
                        }
                    }
                }
                
                // ✅ 応答が終わったら次ターンへ
                // ✅ ここでの isAIPlayingAudio = false は【削除】する
                // 理由: サーバ送信完了 != 再生終了。ここでfalseにすると、まだ喋ってるのにマイクが開いてしまう。
                // 実際の再生終了は player.onPlaybackStateChange で検知する
                
                // self.isAIPlayingAudio = false  // <-- 削除
                // self.mic?.setAIPlayingAudio(false) // <-- 削除
                
                // ✅ 状態更新: サーバー送信完了時点では turnState を変更しない
                // 理由: 実際の音声再生が終了するまで .speaking のままにしておくことで、
                // AIが話している途中で新しい応答が生成されるのを防ぐ
                // 実際の音声再生が終了した時点（player.onPlaybackStateChange）で .waitingUser に変更する
                // これにより、AIが話している途中でタイマーが発火するのを防ぐ
                print("📊 ConversationController: onResponseDone - turnStateは.speakingのまま（実際の音声再生終了まで待機）")
                
                // 注意: タイマーは player.onPlaybackStateChange で再生完全終了時にセットする
            }
        }
        
        // ✅ 参考プロジェクトパターン：AI音声受信時の処理
        // 注意: isAIPlayingAudio フラグの制御は player.onPlaybackStateChange に移行
        // ここではログ出力のみ（デバッグ用）
        realtimeClient?.onAudioDeltaReceived = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ ここでの isAIPlayingAudio = true は【削除】する（Playerに任せる）
                // 理由: サーバ受信 != 再生開始。実際の再生開始は player.onPlaybackStateChange で検知する
                
                // self.isAIPlayingAudio = true  // <-- 削除
                // self.mic?.setAIPlayingAudio(true) // <-- 削除
                
                print("📥 ConversationController: AI音声受信（再生状態はPlayerが管理）")
            }
        }
        
        // ✅ session.updated受信時の処理（マイクはstartPTTRealtime()で開始するため、ここでは開始しない）
        realtimeClient?.onSessionUpdated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ セッション確立完了をログに記録
                print("✅ ConversationController: session.updated受信完了 - 音声入力ボタンを押してマイクを開始してください")
            }
        }
        
        // 状態変更を監視
        realtimeClient?.onStateChange = { [weak self] state in
            Task { @MainActor in
                switch state {
                case .connecting:
                    self?.isRealtimeConnecting = true
                    self?.isRealtimeActive = false
                case .ready:
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = true
                case .closed(let error):
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = false
                    if let error = error {
                        self?.errorMessage = "接続エラー: \(error.localizedDescription)"
                    }
                    // ✅ 接続が閉じられた場合、セッション終了処理を実行
                    // これにより、エラー時でも確実にanalyzeSessionが呼ばれる
                    print("🔄 ConversationController: onStateChange(.closed) - stopRealtimeSessionを呼び出します")
                    self?.stopRealtimeSession()
                case .idle:
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = false
                default:
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = false
                }
            }
        }
        
        // ✅ エラーコールバックを設定（onStateChangeの補完として）
        realtimeClient?.onError = { [weak self] error in
            Task { @MainActor in
                print("❌ ConversationController: RealtimeClientエラー検出 - \(error.localizedDescription)")
                self?.errorMessage = "エラー: \(error.localizedDescription)"
                // 注意: onStateChangeで既にstopRealtimeSessionが呼ばれるため、ここでは呼ばない
                // ただし、onStateChangeが呼ばれない場合の保険として、ここでも呼ぶ
                if self?.isRealtimeActive == true {
                    print("🔄 ConversationController: onError - stopRealtimeSessionを呼び出します（保険）")
                    self?.stopRealtimeSession()
                }
            }
        }
        
        transcript = ""
        aiResponseText = ""
        errorMessage = nil
        turnState = .waitingUser  // セッション開始時はユーザーが話すのを待つ

        // ✅ Firebaseにセッションを作成
        let newSessionId = UUID().uuidString
        self.currentSessionId = newSessionId
        self.turnCount = 0
        
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
                    userId: self.currentUserId,
                    childId: self.currentChildId,
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
                print("🚀 ConversationController: Realtimeセッション開始")
                
                // ネットワーク接続テスト
                print("🌐 ConversationController: ネットワーク接続テスト中...")
                let testUrl = URL(string: "https://api.openai.com/v1/models")!
                var testRequest = URLRequest(url: testUrl)
                testRequest.addValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                testRequest.timeoutInterval = 10
                
                let (_, response) = try await URLSession.shared.data(for: testRequest)
                if let httpResponse = response as? HTTPURLResponse {
                    print("🌐 ConversationController: ネットワークテスト結果 - Status: \(httpResponse.statusCode)")
                    if httpResponse.statusCode == 401 {
                        await MainActor.run {
                            self.errorMessage = "APIキーが無効です（401 Unauthorized）"
                            self.isRealtimeConnecting = false
                        }
                        return
                    }
                }
                
                try await self.realtimeClient?.startSession(child: ChildProfile.sample(), context: [])
                print("✅ ConversationController: セッション開始成功")
                
                // 状態を更新
                await MainActor.run {
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = true
                    self.mode = .realtime
                    self.startReceiveLoops()
                    
                    // ✅ マイクの開始は onSessionUpdated コールバックで行う（初期ノイズ対策のため）
                    // session.updated受信後、500ms待ってからマイクを開始することで、
                    // マイク開始直後の初期ノイズが誤って音声として認識されるのを防ぐ
                    
                    // ---------------------------------------------------
                    // ✅ 追加: セッション開始時も、ユーザーの声を待つためにタイマー始動
                    // 無音が続いた場合、5秒後に促しメッセージが送信される
                    // ---------------------------------------------------
                    self.startWaitingForResponse()
                }
            } catch {
                print("❌ ConversationController: セッション開始失敗 - \(error.localizedDescription)")
                await MainActor.run {
                    if let urlError = error as? URLError {
                        switch urlError.code {
                        case .notConnectedToInternet:
                            self.errorMessage = "インターネット接続がありません"
                        case .timedOut:
                            self.errorMessage = "接続がタイムアウトしました"
                        case .cannotConnectToHost:
                            self.errorMessage = "サーバーに接続できません"
                        default:
                            self.errorMessage = "ネットワークエラー: \(urlError.localizedDescription)"
                        }
                    } else {
                        self.errorMessage = "Realtime接続失敗: \(error.localizedDescription)"
                    }
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
        
        // 状態をリセット
        isRecording = false
        isRealtimeActive = false
        isRealtimeConnecting = false
        turnState = .idle
        
        // テキストをクリア
        transcript = ""
        aiResponseText = ""
        
        // エラーメッセージをクリア
        errorMessage = nil
        
        // ✅ realtimeClientのクリーンアップ（非同期処理）
        // finishSession()は非同期処理のため、Task内で実行
        Task { [weak self] in
            guard let self else { 
                print("⚠️ ConversationController: stopRealtimeSession - selfがnilのため処理をスキップ")
                return 
            }
            
            print("🔄 ConversationController: stopRealtimeSession - realtimeClient.finishSession()を呼び出し中...")
            try? await self.realtimeClient?.finishSession()
            print("✅ ConversationController: stopRealtimeSession - realtimeClient.finishSession()完了")
            
            // ✅ Firebaseにセッション終了を記録
            if let sessionId = self.currentSessionId {
                print("🔄 ConversationController: stopRealtimeSession - セッション終了処理開始 - sessionId: \(sessionId)")
                let endedAt = Date()
                do {
                    try await self.firebaseRepository.finishSession(
                        userId: self.currentUserId,
                        childId: self.currentChildId,
                        sessionId: sessionId,
                        endedAt: endedAt
                    )
                    print("✅ ConversationController: Firebaseセッション終了更新完了 - sessionId: \(sessionId)")
                    
                    // ✅ 会話終了後の分析処理を実行
                    print("🔄 ConversationController: stopRealtimeSession - 分析処理を開始します - sessionId: \(sessionId)")
                    await self.analyzeSession(sessionId: sessionId)
                    print("✅ ConversationController: stopRealtimeSession - 分析処理完了 - sessionId: \(sessionId)")
                } catch {
                    print("❌ ConversationController: stopRealtimeSession - エラー発生: \(error)")
                    self.logFirebaseError(error, operation: "Firebaseセッション終了更新")
                }
            } else {
                print("⚠️ ConversationController: stopRealtimeSession - currentSessionIdがnilのため、セッション終了処理をスキップ")
            }
            
            await MainActor.run {
                self.realtimeClient = nil
                self.currentSessionId = nil
                self.turnCount = 0
                print("✅ ConversationController: リソースクリーンアップ完了")
            }
        }
    }

    public func startPTTRealtime() {
        guard let client = realtimeClient else {
            self.errorMessage = "Realtimeクライアントが初期化されていません"; return
        }
        
        // ✅ 初回接続時の音声認識問題対策：session.updated受信まで待機
        // sessionIsUpdatedがfalseの場合は、session.updated受信まで待機してからマイクを開始
        if !client.isSessionUpdated {
            print("⚠️ ConversationController: session.updated未受信のため、受信まで待機してからマイクを開始します")
            Task { [weak self, weak client] in
                guard let self, let client else { return }
                // session.updated受信を待機（最大5秒）
                var waited = 0.0
                let maxWait = 5.0  // 最大5秒待機
                let checkInterval = 0.1  // 100msごとにチェック
                
                while !client.isSessionUpdated && waited < maxWait {
                    try? await Task.sleep(nanoseconds: UInt64(checkInterval * 1_000_000_000))
                    waited += checkInterval
                }
                
                if client.isSessionUpdated {
                    print("✅ ConversationController: session.updated受信確認 - マイクを開始します")
                    await MainActor.run {
                        self.startPTTRealtimeInternal()
                    }
                } else {
                    print("⚠️ ConversationController: session.updated受信タイムアウト - マイクを開始しますが、音声認識が正常に動作しない可能性があります")
                    await MainActor.run {
                        self.startPTTRealtimeInternal()
                    }
                }
            }
            return
        }
        
        // ✅ session.updated受信済みの場合は即座にマイクを開始
        startPTTRealtimeInternal()
    }
    
    private func startPTTRealtimeInternal() {
        guard let client = realtimeClient else {
            self.errorMessage = "Realtimeクライアントが初期化されていません"; return
        }
        cancelNudge()             // ✅ ユーザーが話し始めるので促しを止める
        // 🔇 いま流れているAI音声を止める（barge-in 前提）
        player.stop()
        Task { [weak client] in
            try? await client?.interruptAndYield()   // ← サーバ側の発話も中断
        }

        // ✅ 公式パターン: PTT開始時に input_audio_buffer.clear を送信（interruptAndYield内で送信されるため追加不要）
        // ✅ interruptAndYield() が既に input_audio_buffer.clear を送信しているため、ここでは追加不要

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
                guard let self = self else { return }
                Task { [weak client = self.realtimeClient] in
                    try? await client?.sendMicrophonePCM(buf)
                }
            }, outputMonitor: self.player.outputMonitor)
            
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
        mic?.stop()
        // ✅ 公式パターン: PTT終了時に commit → response.create を送信
        Task { [weak self] in
            guard let self = self, let client = self.realtimeClient else { return }
            do {
                try await client.commitInputAndRequestResponse()
                print("✅ ConversationController: PTT終了 - commit → response.create送信完了")
            } catch {
                print("⚠️ ConversationController: PTT終了処理失敗 - \(error)")
            }
        }
    }

    private func startReceiveLoops() {
        print("🔄 ConversationController: startReceiveLoops開始")
        
        // 返答テキスト（partial）ループ
        receiveTextTask?.cancel()
        receiveTextTask = Task { [weak self] in
            guard let self else { return }
            print("🔄 ConversationController: AI応答テキストループ開始")
            // ✅ UIの無駄な再描画を抑制：テキスト更新をスロットリング（16-33ms程度でまとめて描画）
            var textBuffer = ""
            var lastUpdateTime = Date()
            let throttleInterval: TimeInterval = 0.03  // 33ms（約30fps）
            
            while !Task.isCancelled {
                do {
                    // ✅ 新しい応答が作成された場合はtextBufferをクリア
                    if await MainActor.run { self.shouldClearTextBuffer } {
                        await MainActor.run {
                            self.shouldClearTextBuffer = false
                        }
                        textBuffer = ""
                        print("📝 ConversationController: 新しい応答検出 - textBufferをクリア")
                    }
                    
                    if let part = try await self.realtimeClient?.nextPartialText() {
                        print("📝 ConversationController: AI応答テキスト受信 - \(part)")
                        // ✅ テキストをバッファに追加
                        textBuffer += part
                        
                        // ✅ スロットリング：33ms経過したらUIに反映
                        let now = Date()
                        if now.timeIntervalSince(lastUpdateTime) >= throttleInterval {
                            await MainActor.run {
                                // AI応答テキストを更新
                                if self.aiResponseText.isEmpty {
                                    self.aiResponseText = textBuffer
                                } else {
                                    self.aiResponseText += textBuffer
                                }
                                print("📝 ConversationController: aiResponseText更新（スロットリング後） - \(self.aiResponseText)")
                            }
                            textBuffer = ""  // バッファをクリア
                            lastUpdateTime = now
                        }
                    } else {
                        // ✅ 新しい応答が作成された場合はtextBufferをクリア（最終処理前にもチェック）
                        if await MainActor.run { self.shouldClearTextBuffer } {
                            await MainActor.run {
                                self.shouldClearTextBuffer = false
                            }
                            textBuffer = ""
                            print("📝 ConversationController: 新しい応答検出（最終処理前） - textBufferをクリア")
                        }
                        
                        // ✅ バッファに残っているテキストがあれば反映
                        if !textBuffer.isEmpty {
                            await MainActor.run {
                                if self.aiResponseText.isEmpty {
                                    self.aiResponseText = textBuffer
                                } else {
                                    self.aiResponseText += textBuffer
                                }
                                print("📝 ConversationController: aiResponseText更新（最終） - \(self.aiResponseText)")
                            }
                            textBuffer = ""
                        }
                        try await Task.sleep(nanoseconds: 50_000_000) // idle 50ms
                    }
                } catch { 
                    // ✅ 新しい応答が作成された場合はtextBufferをクリア（エラー処理前にもチェック）
                    if await MainActor.run { self.shouldClearTextBuffer } {
                        await MainActor.run {
                            self.shouldClearTextBuffer = false
                        }
                        textBuffer = ""
                        print("📝 ConversationController: 新しい応答検出（エラー処理前） - textBufferをクリア")
                    }
                    
                    // ✅ エラー時もバッファに残っているテキストがあれば反映
                    if !textBuffer.isEmpty {
                        await MainActor.run {
                            if self.aiResponseText.isEmpty {
                                self.aiResponseText = textBuffer
                            } else {
                                self.aiResponseText += textBuffer
                            }
                        }
                        textBuffer = ""
                    }
                    // CancellationErrorは正常な終了なのでログに出力しない
                    if !(error is CancellationError) {
                        print("❌ ConversationController: AI応答テキストループエラー - \(error)")
                    }
                    break 
                }
            }
        }

        // 音声入力のテキスト処理
        receiveInputTextTask?.cancel()
        receiveInputTextTask = Task { [weak self] in
            guard let self else { return }
            print("🔄 ConversationController: 音声入力テキストループ開始")
            var lastLogTime = Date()
            while !Task.isCancelled {
                do {
                    if let inputText = try await self.realtimeClient?.nextInputText() {
                        let trimmed = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("🎤 ConversationController: ユーザーの発言テキスト受信 - 「\(trimmed)」")
                        await MainActor.run { 
                            // テキストを追記（部分テキストの場合は置換）
                            if inputText.count < self.transcript.count {
                                // 部分テキストが来た場合は置換
                                self.transcript = inputText
                                print("📝 ConversationController: 部分テキスト更新 - 「\(self.transcript)」")
                            } else {
                                // 確定テキストが来た場合は置換
                                self.transcript = inputText
                                print("✅ ConversationController: 確定テキスト更新 - 「\(self.transcript)」")
                            }
                        }
                    } else {
                        // 1秒に1回程度、STTイベントが来ていないことをログに出力
                        let now = Date()
                        if now.timeIntervalSince(lastLogTime) >= 1.0 {
                            print("⚠️ ConversationController: STTイベント待機中...（conversation.item.input_audio_transcription.* または input_audio_buffer.committed が来ていません）")
                            lastLogTime = now
                        }
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch { 
                    // CancellationErrorは正常な終了なのでログに出力しない
                    if !(error is CancellationError) {
                        print("❌ ConversationController: 音声入力テキストループエラー - \(error)")
                    }
                    break 
                }
            }
        }

        // 返答音声の先出し再生（任意）
        receiveAudioTask?.cancel()
        receiveAudioTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let chunk = try await self.realtimeClient?.nextAudioChunk() {
                        await MainActor.run { self.isPlayingAudio = true }
                        
                        // ✅ エンジンが停止している場合は再開を試みる（初回接続時やBluetooth接続時の問題対策）
                        if !self.sharedAudioEngine.isRunning {
                            do {
                                try self.sharedAudioEngine.start()
                                print("✅ ConversationController: 共通エンジンを再開（音声再生ループ内）")
                            } catch {
                                print("⚠️ ConversationController: 共通エンジン再開失敗 - \(error.localizedDescription)")
                                // エンジン再開に失敗しても、playChunk内で再試行される可能性があるため、続行
                            }
                        }
                        
                        // ✅ 音声再生を再開（stopImmediately()でvolume=0になった場合の復帰）
                        // 注: onResponseCreatedでも呼び出しているが、念のためここでも呼び出す
                        self.player.resumeIfNeeded()
                        self.player.playChunk(chunk)
                        await MainActor.run { self.isPlayingAudio = false }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch { 
                    // CancellationErrorは正常な終了なのでログに出力しない
                    if !(error is CancellationError) {
                        print("❌ ConversationController: 音声再生ループエラー - \(error)")
                    }
                    break 
                }
            }
        }
    }
    
    // MARK: - Private Helpers
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
    
    // MARK: - 促しタイマー機能
    
    // ✅ 修正: タイマー開始ロジック（10.0秒に延長、デバッグログ強化）
    private func startWaitingForResponse() {
        print("⏰ ConversationController: 促しタイマーをセットしました (10秒後に発火)")
        
        // 既存のタイマーがあればキャンセル
        cancelNudge()
        
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
        print("🚀 ConversationController: 条件クリア -> 促しメッセージ送信実行")
        await realtimeClient?.nudge(kind: 0)
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
            await realtimeClient?.nudge(kind: 0)
        }
    }
    
    // MARK: - 会話分析機能
    
    /// 会話終了後の分析処理（要約・興味タグ・新出語彙の抽出）
    /// - Parameter sessionId: 分析対象のセッションID
    private func analyzeSession(sessionId: String) async {
        print("📊 ConversationController: 会話分析開始 - sessionId: \(sessionId)")
        
        do {
            print("📊 ConversationController: analyzeSession - エラーキャッチブロック開始")
            // 1. Firestoreからこのセッションの全ターンを取得
            let turns = try await firebaseRepository.fetchTurns(
                userId: currentUserId,
                childId: currentChildId,
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
            
            guard !conversationLog.isEmpty else {
                print("⚠️ ConversationController: 会話テキストが存在しないため分析をスキップ - sessionId: \(sessionId), ターン数: \(turns.count)")
                return
            }
            
            print("📝 ConversationController: 会話ログ（\(turns.count)ターン）\n\(conversationLog)")
            
            // 3. OpenAI Chat Completion (gpt-4o-mini) に投げる
            let prompt = """
            以下の親子の会話ログを分析し、JSON形式で出力してください。
            
            出力項目:
            - summary: 30文字程度の要約（親向け）
            - interests: 子どもが興味を示したトピック（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others から選択。英語のenum値で配列で出力）
            - newWords: 子どもが使った特徴的な単語や成長を感じる言葉（3つまで、配列で出力）
            
            会話ログ:
            \(conversationLog)
            
            JSON形式で出力してください。例:
            {
              "summary": "恐竜について話しました",
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
                userId: currentUserId,
                childId: currentChildId,
                sessionId: sessionId,
                summaries: summaries,
                interests: interests,
                newVocabulary: newVocabulary
            )
            print("✅ ConversationController: 分析結果をFirebaseに保存完了")
            
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
