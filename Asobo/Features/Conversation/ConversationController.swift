//
//  ConversationController.swift
//

import Foundation
import AVFoundation
import Speech
import Domain
import Services
import Support

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
    enum TurnState {
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
    
    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false
    
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
    private var mic: MicrophoneCapture?
    private var player = PlayerNodeStreamer()            // 音声先出し（必要に応じて）
    private var realtimeClient: RealtimeClientOpenAI?
    private var receiveTextTask: Task<Void, Never>?
    private var receiveAudioTask: Task<Void, Never>?
    private var receiveInputTextTask: Task<Void, Never>?
    private var sessionStartTask: Task<Void, Never>?     // セッション開始タスクの管理

    // MARK: - Lifecycle
    public init(
        audioSession: AudioSessionManaging = SystemAudioSessionManager(),
        speech: SpeechRecognizing = SystemSpeechRecognizer(locale: "ja-JP")
    ) {
        self.audioSession = audioSession
        self.speech = speech
    }

    deinit {
        Task { @MainActor in
            self.stopLocalTranscription()
            self.stopRealtimeSession()
        }
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
            Task {
                try? await realtimeClient?.finishSession()
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
            
            // AudioSession設定後にPlayerNodeStreamerのエンジンを開始
            // ⚠️ 重要な順序：AudioSessionを設定してからエンジンを開始
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
        
        // Realtimeのイベントにフック
        realtimeClient?.onSpeechStarted = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ユーザー発話を検知 → 促しタイマーは止める & AI音声を即停止
                self.cancelNudge()
                self.turnState = .listening
                // ✅ ユーザーが話し始めたら即AI音声を止める
                self.player.stopImmediately()
            }
        }
        
        realtimeClient?.onSpeechStopped = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.turnState = .thinking
                // 以降は Realtime 側が commit → response.create を送信してくれる設計にしている
            }
        }
        
        realtimeClient?.onInputCommitted = { [weak self] transcript in
            Task { @MainActor in
                guard let self else { return }
                let t = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                if t.count < 2 {
                    // ✅ 聞き取り失敗時は必ず聞き返し（RealtimeClient側で処理済み）
                    self.turnState = .clarifying
                } else {
                    // ✅ 聞き取り成功 → 応答生成中
                    self.turnState = .thinking
                }
            }
        }
        
        realtimeClient?.onResponseCreated = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ 新しい応答が作成された時にテキストをクリア（前の応答のテキストを消す）
                self.aiResponseText = ""
                print("📝 ConversationController: 新しい応答開始 - aiResponseTextをクリア")
                // ✅ 音声再生を再開（stopImmediately()でvolume=0になった場合の復帰）
                self.player.resumeIfNeeded()
            }
        }
        
        realtimeClient?.onResponseDone = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ 応答が終わったら次ターンへ：まずは「待つ」
                // ✅ AI音声再生フラグをリセット（次のターンで録音を再開できるように）
                self.isAIPlayingAudio = false
                self.startWaiting()
            }
        }
        
        // ✅ 参考プロジェクトパターン：AI音声受信時に録音停止をトリガー
        realtimeClient?.onAudioDeltaReceived = { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // ✅ AI音声受信時にフラグを設定（sendMicrophonePCMの早期returnを一元化）
                self.isAIPlayingAudio = true
                print("🛑 ConversationController: AI音声受信 - 録音停止フラグ設定（isAIPlayingAudio=true）")
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
                case .idle:
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = false
                default:
                    self?.isRealtimeConnecting = false
                    self?.isRealtimeActive = false
                }
            }
        }
        
        transcript = ""
        aiResponseText = ""
        errorMessage = nil
        turnState = .waitingUser  // セッション開始時はユーザーが話すのを待つ

        sessionStartTask = Task {
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
                
                try await realtimeClient?.startSession(child: ChildProfile.sample(), context: [])
                print("✅ ConversationController: セッション開始成功")
                
                // 状態を更新
                await MainActor.run {
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = true
                    self.mode = .realtime
                    self.startReceiveLoops()
                    
                    // ✅ セッション開始時にマイクを開始して、常に音声入力を監視する
                    guard let client = self.realtimeClient else {
                        print("⚠️ ConversationController: セッション開始後、realtimeClientがnil")
                        return
                    }
                    self.mic?.stop()
                    self.mic = MicrophoneCapture { [weak self] buf in
                        guard let self = self else { return }
                        // ✅ AI音声再生中は音声送信をスキップ（onAudioDeltaReceivedで設定されたフラグをチェック）
                        if self.isAIPlayingAudio {
                            // AIが話している間は音声送信をスキップ
                            return
                        }
                        Task { try? await client.sendMicrophonePCM(buf) }
                    }
                    do {
                        try self.mic?.start()
                        print("✅ ConversationController: マイク開始成功（常時監視モード）")
                    } catch {
                        print("⚠️ ConversationController: マイク開始失敗 - \(error.localizedDescription)")
                        self.errorMessage = "マイク開始に失敗: \(error.localizedDescription)"
                    }
                    
                    // ✅ セッション開始後、まずはユーザーの声を待つ
                    self.startWaiting()
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
        
        Task {
            try? await realtimeClient?.finishSession()
            await MainActor.run {
                self.realtimeClient = nil
                print("✅ ConversationController: リソースクリーンアップ完了")
            }
        }
    }

    public func startPTTRealtime() {
        guard let client = realtimeClient else {
            self.errorMessage = "Realtimeクライアントが初期化されていません"; return
        }
        cancelNudge()             // ✅ ユーザーが話し始めるので促しを止める
        // 🔇 いま流れているAI音声を止める（barge-in 前提）
        player.stop()
        Task { try? await client.interruptAndYield() }   // ← サーバ側の発話も中断

        // ✅ 公式パターン: PTT開始時に input_audio_buffer.clear を送信（interruptAndYield内で送信されるため追加不要）
        // ✅ interruptAndYield() が既に input_audio_buffer.clear を送信しているため、ここでは追加不要

        mic?.stop()
        mic = MicrophoneCapture { [weak self] buf in
            guard let self = self else { return }
            // ✅ AI音声再生中は音声送信をスキップ（onAudioDeltaReceivedで設定されたフラグをチェック）
            if self.isAIPlayingAudio {
                // AIが話している間は音声送信をスキップ
                return
            }
            Task { try? await client.sendMicrophonePCM(buf) }
        }
        do {
            try mic?.start()
            isRecording = true
            transcript = ""
            turnState = .listening
        } catch {
            self.errorMessage = "マイク開始に失敗: \(error.localizedDescription)"
            isRecording = false
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
            while !Task.isCancelled {
                do {
                    if let part = try await self.realtimeClient?.nextPartialText() {
                        print("📝 ConversationController: AI応答テキスト受信 - \(part)")
                        await MainActor.run { 
                            // AI応答テキストを追記
                            if self.aiResponseText.isEmpty { 
                                self.aiResponseText = part 
                            } else { 
                                self.aiResponseText += part   // ← 追記
                            }
                            print("📝 ConversationController: aiResponseText更新 - \(self.aiResponseText)")
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000) // idle 50ms
                    }
                } catch { 
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
    
    // ✅ 「待つ→促す」タイマー実装
    private func startWaiting() {
        turnState = .waitingUser
        cancelNudge()
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            Task { await self?.sendNudge(index: 0) }
        }
    }
    
    private func scheduleNextNudge(_ idx: Int) {
        guard idx < 2 else { return } // 最大3回(0,1,2)で制限
        nudgeTimer?.invalidate()
        nudgeTimer = Timer.scheduledTimer(withTimeInterval: 8.0, repeats: false) { [weak self] _ in
            Task { await self?.sendNudge(index: idx + 1) }
        }
    }
    
    private func cancelNudge() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
    }
    
    private func sendNudge(index: Int) async {
        guard isRealtimeActive else { return }
        // ✅ ユーザーが話している最中は促しメッセージを送信しない
        if case .listening = turnState {
            print("⚠️ ConversationController: ユーザーが話しているため nudge をスキップ")
            cancelNudge()
            return
        }
        turnState = .nudgedByAI(index)
        await realtimeClient?.nudge(kind: index)
        scheduleNextNudge(index)
    }
}
