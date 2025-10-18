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
    
    // デバッグ用プロパティ
    @Published public var aiResponseText: String = ""
    @Published public var isPlayingAudio: Bool = false
    @Published public var hasMicrophonePermission: Bool = false

    // MARK: - Local STT (Speech)
    private let audioEngine = AVAudioEngine()
    private let speechRecognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP"))
    private var sttRequest: SFSpeechAudioBufferRecognitionRequest?
    private var sttTask: SFSpeechRecognitionTask?

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
    public init() {}

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

    // MARK: - Local STT (まずはここから)
    public func startLocalTranscription() {
        guard !isRecording else { return }
        guard speechRecognizer?.isAvailable == true else {
            self.errorMessage = "音声認識が現在利用できません。"
            return
        }

        // 1) AudioSession を先に構成（サンプルレート/モードを確定）
        do { try audioSessionManager.configure() }
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

        // 5) 認識（部分テキストを随時反映）
        sttTask = speechRecognizer?.recognitionTask(with: req) { [weak self] result, err in
            guard let self else { return }
            if let r = result {
                Task { @MainActor in
                    self.transcript = r.bestTranscription.formattedString
                }
            }
            if err != nil || (result?.isFinal == true) {
                Task { @MainActor in self.stopLocalTranscription() }
            }
        }

        isRecording = true
        mode = .localSTT
    }

    public func stopLocalTranscription() {
        guard isRecording || sttTask != nil else { return }
        audioEngine.inputNode.removeTap(onBus: 0)
        audioEngine.stop()
        sttRequest?.endAudio()
        sttTask?.cancel()
        sttRequest = nil
        sttTask = nil
        isRecording = false
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
        
        // 接続中フラグを設定
        isRealtimeConnecting = true
        
        // オーディオセッションを構成
        do { try audioSessionManager.configure() }
        catch { self.errorMessage = "AudioSession構成に失敗: \(error.localizedDescription)" }

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

            let fallbackUrl = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview")!
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
        
        receiveTextTask?.cancel(); receiveTextTask = nil
        receiveAudioTask?.cancel(); receiveAudioTask = nil
        receiveInputTextTask?.cancel(); receiveInputTextTask = nil
        mic?.stop(); mic = nil
        player.stop()
        isRecording = false
        isRealtimeActive = false
        isRealtimeConnecting = false
        
        Task {
            try? await realtimeClient?.finishSession()
            await MainActor.run {
                self.realtimeClient = nil
            }
        }
    }

    public func startPTTRealtime() {
        guard let client = realtimeClient else { 
            self.errorMessage = "Realtimeクライアントが初期化されていません"
            return 
        }
        mic?.stop()
        mic = MicrophoneCapture { buf in
            Task { try? await client.sendMicrophonePCM(buf) }
        }
        do { 
            try mic?.start()
            isRecording = true
            transcript = "" // 録音開始時にテキストをクリア
        }
        catch { 
            self.errorMessage = "マイク開始に失敗: \(error.localizedDescription)"
            isRecording = false
        }
    }

    public func stopPTTRealtime() {
        isRecording = false
        mic?.stop()
        Task {
            // interrupt から commitAndRequestResponse に変更
            try? await realtimeClient?.commitAndRequestResponse()
        }
    }

    private func startReceiveLoops() {
        // 返答テキスト（partial）ループ
        receiveTextTask?.cancel()
        receiveTextTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let part = try await self.realtimeClient?.nextPartialText() {
                        await MainActor.run { 
                            // AI応答テキストを追記
                            if self.aiResponseText.isEmpty { 
                                self.aiResponseText = part 
                            } else { 
                                self.aiResponseText += part   // ← 追記
                            }
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000) // idle 50ms
                    }
                } catch { break }
            }
        }

        // 音声入力のテキスト処理
        receiveInputTextTask?.cancel()
        receiveInputTextTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                do {
                    if let inputText = try await self.realtimeClient?.nextInputText() {
                        await MainActor.run { 
                            self.transcript = inputText
                        }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch { break }
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
                        self.player.playChunk(chunk)
                        await MainActor.run { self.isPlayingAudio = false }
                    } else {
                        try await Task.sleep(nanoseconds: 50_000_000)
                    }
                } catch { break }
            }
        }
    }
}
