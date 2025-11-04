import Foundation
import AVFoundation
import Domain


// 通信の中核：Domain.RealtimeClient を実装する最小骨組み
// - WebSocket一本で STT/LLM/TTS を双方向ストリーミング（OpenAI Realtime想定）
// - 先出し再生：音声チャンク(Data)を受け次第、上位へ渡す
// - 部分テキスト：吹き出し用に逐次流す
// - 再接続/バックオフ/ピン保持は最低限

public final class RealtimeClientOpenAI: RealtimeClient {
    public enum State { case idle, connecting, ready, closing, closed(Error?) }

    private let url: URL
    private let apiKey: String
    private let model: String
    private let session: URLSession

    private var wsTask: URLSessionWebSocketTask?
    private var state: State = .idle
    
    // 状態変更のコールバック
    public var onStateChange: ((State) -> Void)?
    
    // ① 追加: 会話イベントのコールバック
    public var onResponseDone: (() -> Void)?
    public var onInputCommitted: ((String) -> Void)?
    public var onSpeechStarted: (() -> Void)?
    public var onSpeechStopped: (() -> Void)?

    // 出力ストリーム（AsyncStream）
    private var audioContinuation: AsyncStream<Data>.Continuation?
    private var textContinuation: AsyncStream<String>.Continuation?
    private var inputTextContinuation: AsyncStream<String>.Continuation?
    
    // イテレータ（単一のイテレータを使用して重複を防ぐ）
    private var textIterator: AsyncStream<String>.AsyncIterator?
    private var inputTextIterator: AsyncStream<String>.AsyncIterator?

    // PTT時は即送信のため内部バッファは不要

    // Ping/Pong & 再接続
    private var pingTimer: Timer?
    private var reconnectAttempts = 0
    
    // ✅ ユーザー確定フラグ（自動レスポンスの即キャンセル用）
    private var userRequestedResponse = false
    
    // ✅ ターン内の累積ミリ秒（空コミット防止用）
    private var turnAccumulatedMs: Double = 0
    
    // ✅ キャンセル後の音声を破棄するフラグ
    private var suppressCurrentResponseAudio = false
    
    // ✅ VADモードフラグ（VADモード時は自動レスポンスをキャンセルしない）
    private var useServerVAD = true  // VADモードで運用
    
    // ✅ VADの「詰まり」対策（無音ハマり防止）
    private var vadIdleTimer: Timer?
    private var lastAppendAt: Date?

    // MARK: - Init
    // ✅ デフォルトは gpt-realtime（GA版）- フォールバックを完全に排除
    public init(url: URL? = nil, apiKey: String, model: String = "gpt-realtime") {
        // URLが指定されていない場合はデフォルトURLを使用（gpt-realtime固定）
        let ws = url ?? URL(string: "wss://api.openai.com/v1/realtime?model=gpt-realtime")!
        self.url = ws
        self.apiKey = apiKey
        self.model = "gpt-realtime"  // ✅ フィールドも固定（フォールバック排除）
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 300
        // ネットワーク接続のテスト用設定
        cfg.waitsForConnectivity = true
        cfg.allowsCellularAccess = true
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - RealtimeClient
    public func startSession(child: ChildProfile, context: [InterestTag]) async throws {
        guard case .idle = state else { 
            print("⚠️ RealtimeClient: 既に接続中または接続済み - State: \(state)")
            return 
        }
        
        print("🔗 RealtimeClient: 接続開始 - URL: \(url)")
        state = .connecting
        onStateChange?(state)
        
        var req = URLRequest(url: url)
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.addValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        print("🔗 RealtimeClient: WebSocket接続中...")
        wsTask = session.webSocketTask(with: req)
        wsTask?.resume()
        
        // 接続確立を待つ（段階的に確認）
        print("🔗 RealtimeClient: 接続確立を待機中...")
        
        // 接続状態を段階的に確認
        for i in 1...5 {
            try await Task.sleep(nanoseconds: 500_000_000) // 0.5秒ずつ
            if let state = wsTask?.state {
                print("🔗 RealtimeClient: 接続状態確認 #\(i) - State: \(state.rawValue)")
                if state == .running {
                    break
                }
            }
        }
        
        // 最終確認
        if wsTask?.state != .running {
            print("❌ RealtimeClient: WebSocket接続失敗 - State: \(wsTask?.state.rawValue ?? -1)")
            throw NSError(domain: "RealtimeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocket接続に失敗しました"])
        }
        
        print("✅ RealtimeClient: WebSocket接続確立")
        listen()
        startPing()
        
        // 音声バッファをクリア（PTT時は不要だが念のため）
        // audioBuffer.removeAll() // ← 削除
        
        // イテレータをリセット（新しいセッション開始時）
        textIterator = nil
        inputTextIterator = nil
        
        // ✅ PTT 想定: turn_detection を外す（サーバが勝手に切らない）
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": [
                "instructions": """
                あなたは日本語のみで話す幼児向けのアシスタントです。
                かならず日本語で返答してください。ひらがな中心で、一文をみじかく、やさしく話します。
                ユーザーの話に合わせた返答をしてください。わからない時は聞き返したり、返事を待ったり、新たな質問をしてください。
                つみきやおえかきなどの具体的な遊びではなく、会話のみで成り立つような呼びかけをしてください。
                """,
                "modalities": ["text","audio"],
                // ✅ 入力も出力も24kHz/モノラルに統一（pcm16は24kHzが前提）
                "input_audio_format": [
                    "type": "pcm16",
                    "sample_rate_hz": 24000,
                    "channels": 1
                ],
                // ✅ 出力も24kHz/モノラルに統一
                "output_audio_format": [
                    "type": "pcm16",
                    "sample_rate_hz": 24000,
                    "channels": 1
                ],
                // ✅ Realtime向けのSTTモデル推奨名（gpt-4o-transcribe）
                "input_audio_transcription": ["model": "gpt-4o-transcribe", "language": "ja"],
                "voice": "alloy",
                "tools": [],
                "tool_choice": "none",
                // ✅ VADモード：サーバVADで自動区切り（10000以下に設定）
                // threshold を NSDecimalNumber で正確な小数桁で送る（エラー回避）
                "turn_detection": [
                    "type": "server_vad",
                    "threshold": NSDecimalNumber(string: "0.6"),  // ✅ 小数誤差を回避
                    "silence_duration_ms": 1500,   // ≤ 10000
                    "prefix_padding_ms": 150
                ]
            ]
        ]
        print("🔗 RealtimeClient: セッション設定送信")
        // 必ず WebSocket が running かつクライアント state が ready になってから送信
        try await send(json: sessionUpdate)
        
        // ✅ セッション確立直後にテスト応答を1回送る（配線テスト）
        print("🧪 RealtimeClient: テスト応答を送信（配線確認）")
        try await send(json: [
            "type": "response.create",
            "response": [
                "modalities": ["audio","text"],
                "instructions": "こんにちは。にほんごでおはなしのじっけんをします。"
            ]
        ])
        
        print("✅ RealtimeClient: セッション開始完了")
        state = .ready
        onStateChange?(state)
        reconnectAttempts = 0
    }

    public func sendMicrophonePCM(_ buffer: AVAudioPCMBuffer) async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }

        // ここで即 append（20ms/480フレームのバッファが来る想定）
        if let ch0 = buffer.int16ChannelData {
            let n = Int(buffer.frameLength)
            let sr = Double(buffer.format.sampleRate) // 48000 など
            let ms = (Double(n) / sr) * 1000.0
            turnAccumulatedMs += ms  // ✅ 累積ミリ秒を計算
            
            // ✅ VADの「詰まり」対策：最後のappend時刻を更新
            lastAppendAt = Date()
            
            let ptr = ch0.pointee
            let data = Data(bytes: ptr, count: n * MemoryLayout<Int16>.size)
            let b64  = data.base64EncodedString()
            try await send(json: ["type": "input_audio_buffer.append", "audio": b64])
        }
    }
    
    // ✅ 録音開始時/再録音時のリセット
    public func resetRecordingTurn() {
        turnAccumulatedMs = 0
    }
    
    public func interruptAndYield() async throws {
        // ✅ VADモードでは response.cancel を送らない（サーバが自動で区切るため）
        if !useServerVAD {
            // PTTモードなど、手動で止めたい時だけキャンセル
            if userRequestedResponse || suppressCurrentResponseAudio {
                suppressCurrentResponseAudio = true  // ✅ キャンセル後の音声を破棄
                try await send(json: ["type": "response.cancel"])
            }
        }
        // 必要に応じて入力バッファもクリア
        try await send(json: ["type": "input_audio_buffer.clear"])
        // ✅ 録音ターンをリセット
        turnAccumulatedMs = 0
    }
    
    // ② 追加: コミットだけ送る（応答は送らない）
    // ⚠️ VADモードでは使用しない（サーバが自動でcommitするため）
    public func commitInputOnly() async throws {
        // ✅ VADモードではcommitを送らない（サーバが自動で区切るため）
        if useServerVAD {
            print("⚠️ RealtimeClient: VADモードでは commitInputOnly() を使用しないでください（サーバが自動でcommitします）")
            return
        }
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        // ✅ 100ms 以上たまってから commit（空コミット防止）
        guard turnAccumulatedMs >= 120 else {
            print("⚠️ RealtimeClient: commitスキップ (<120ms) 現在: \(turnAccumulatedMs)ms")
            return
        }
        try await send(json: ["type": "input_audio_buffer.commit"])
        turnAccumulatedMs = 0  // ✅ リセット
    }
    
    // ③ 追加: 応答だけリクエスト（commit済みの入力を使う）
    public func requestResponse(instructions: String? = nil, temperature: Double = 0.3) async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        
        // ✅ ユーザー確定フラグを立てる（自動レスポンスの即キャンセルを防ぐ）
        userRequestedResponse = true
        
        // ✅ 日本語固定のデフォルト指示（念のため）
        let defaultJapaneseInstructions = "つねににほんごでこたえてください。ひらがなを中心に、やさしく、みじかく話します。"
        
        var responseDict: [String: Any] = [
            "modalities": ["audio","text"],
            "instructions": defaultJapaneseInstructions,
            "temperature": NSDecimalNumber(value: temperature)
        ]
        
        // カスタムinstructionsがある場合は、それに日本語強制を追加
        if let inst = instructions, !inst.isEmpty {
            responseDict["instructions"] = """
            \(defaultJapaneseInstructions)
            
            \(inst)
            """
        }
        
        let resp: [String: Any] = [
            "type": "response.create",
            "response": responseDict
        ]
        try await send(json: resp)
        
        // フラグは response.done でリセット
    }
    
    // ④ 追加: テキストイテレータをリセット（新しい会話ターン開始時）
    public func resetTextIterator() {
        textIterator = nil
        inputTextIterator = nil
    }

    public func nextAudioChunk() async throws -> Data? {
        if audioContinuation == nil { self.makeAudioStream() }
        return await withCheckedContinuation { cont in
            Task { [weak self] in
                guard let stream = self?.audioStream else { cont.resume(returning: nil); return }
                var iterator = stream.makeAsyncIterator()
                let chunk = try? await iterator.next()
                cont.resume(returning: chunk ?? nil)
            }
        }
    }

    public func nextPartialText() async throws -> String? {
        if textContinuation == nil { self.makeTextStream() }
        if textIterator == nil { textIterator = textStream.makeAsyncIterator() }
        
        return await withCheckedContinuation { cont in
            Task { [weak self] in
                guard let self = self, var iterator = self.textIterator else { cont.resume(returning: nil); return }
                let part = try? await iterator.next()
                self.textIterator = iterator  // Update the iterator state
                cont.resume(returning: part ?? nil)
            }
        }
    }
    
    public func nextInputText() async throws -> String? {
        if inputTextContinuation == nil { self.makeInputTextStream() }
        if inputTextIterator == nil { inputTextIterator = inputTextStream.makeAsyncIterator() }
        
        return await withCheckedContinuation { cont in
            Task { [weak self] in
                guard let self = self, var iterator = self.inputTextIterator else { cont.resume(returning: nil); return }
                let part = try? await iterator.next()
                self.inputTextIterator = iterator  // Update the iterator state
                cont.resume(returning: part ?? nil)
            }
        }
    }

    // ✅ VADの「詰まり」対策：アイドル監視を開始
    private func startVADIdleMonitoring() {
        stopVADIdleMonitoring()  // 既存のタイマーをクリア
        
        let timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            
            // 最後のappendから1.8秒以上経過していたら手動で締める
            if let lastAppend = self.lastAppendAt,
               Date().timeIntervalSince(lastAppend) > 1.8 {
                print("⚠️ RealtimeClient: VADが詰まっているため手動でcommit → response.create")
                self.stopVADIdleMonitoring()
                
                Task { [weak self] in
                    guard let self = self else { return }
                    // サーバが止めてくれないので手動 commit → response.create
                    do {
                        try await self.send(json: ["type": "input_audio_buffer.commit"])
                        try await self.send(json: [
                            "type": "response.create",
                            "response": [
                                "modalities": ["audio","text"],
                                "instructions": "つねににほんごでこたえてください。ひらがな中心で、やさしく、みじかく。"
                            ]
                        ])
                    } catch {
                        print("❌ RealtimeClient: VAD保険の手動commit失敗 - \(error)")
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        vadIdleTimer = timer
    }
    
    // ✅ VADの「詰まり」対策：アイドル監視を停止
    private func stopVADIdleMonitoring() {
        vadIdleTimer?.invalidate()
        vadIdleTimer = nil
    }
    
    public func finishSession() async throws {
        state = .closing
        // OpenAI Realtime APIでは session.finish は不要
        stopPing()
        // ✅ VADの「詰まり」対策：タイマーを停止
        stopVADIdleMonitoring()
        wsTask?.cancel(with: .goingAway, reason: nil)
        state = .closed(nil)
        audioContinuation?.finish()
        textContinuation?.finish()
        inputTextContinuation?.finish()
        
        // リソースを完全にクリーンアップ
        audioContinuation = nil
        textContinuation = nil
        inputTextContinuation = nil
        textIterator = nil
        inputTextIterator = nil
        // audioBuffer.removeAll() // ← PTT時は不要
        wsTask = nil
        reconnectAttempts = 0
        // ✅ フラグをリセット
        userRequestedResponse = false
        suppressCurrentResponseAudio = false
        turnAccumulatedMs = 0
        lastAppendAt = nil
        
        // 状態をidleに戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self else { return }
            self.state = .idle
            self.onStateChange?(self.state)
        }
    }

    // MARK: - Private
    private var audioStream: AsyncStream<Data>!
    private var textStream: AsyncStream<String>!
    private var inputTextStream: AsyncStream<String>!

    private func makeAudioStream() {
        audioStream = AsyncStream<Data> { [weak self] cont in
            self?.audioContinuation = cont
        }
    }
    private func makeTextStream() {
        textStream = AsyncStream<String> { [weak self] cont in
            self?.textContinuation = cont
        }
    }
    
    private func makeInputTextStream() {
        inputTextStream = AsyncStream<String> { [weak self] cont in
            self?.inputTextContinuation = cont
        }
    }

    private func listen() {
        wsTask?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let err):
                print("❌ RealtimeClient: WebSocket受信エラー - \(err.localizedDescription)")
                if let urlError = err as? URLError {
                    print("❌ RealtimeClient: URLError詳細 - Code: \(urlError.code.rawValue), Description: \(urlError.localizedDescription)")
                }
                self.handleFailure(err)
            case .success(let msg):
                print("📨 RealtimeClient: メッセージ受信")
                self.handleMessage(msg)
                self.listen()
            }
        }
    }

    private func handleMessage(_ msg: URLSessionWebSocketTask.Message) {
        switch msg {
        case .data(let data):
            guard let type = data.first else { return }
            let body = data.dropFirst()
            if type == 0xA0 { 
                print("📨 RealtimeClient: 音声データ受信 - \(body.count) bytes")
                audioContinuation?.yield(Data(body)) 
            }
            else if type == 0xB0, let s = String(data: body, encoding: .utf8) { 
                print("📨 RealtimeClient: テキストデータ受信 - \(s)")
                textContinuation?.yield(s) 
            }
        case .string(let text):
            // 長いBase64データはログに出力しない
            let logText = text.count > 100 ? String(text.prefix(100)) + "..." : text
            print("📨 RealtimeClient: JSONメッセージ受信 - \(logText)")
            if let d = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let type = obj["type"] as? String {
                print("📨 RealtimeClient: メッセージタイプ - \(type)")
                switch type {
                case "response.text.delta":
                    if let s = obj["delta"] as? String {
                        print("📝 RealtimeClient: テキストデルタ受信 - \(s)")
                        textContinuation?.yield(s)
                    }
                case "response.audio_transcript.delta":
                    if let s = obj["delta"] as? String {
                        print("📝 RealtimeClient: 音声文字起こしデルタ受信 - \(s)")
                        textContinuation?.yield(s)
                    }
                case "response.audio.delta":
                    // ✅ キャンセル後の音声は破棄（再生しない）
                    if suppressCurrentResponseAudio {
                        return
                    }
                    if let b64 = obj["delta"] as? String,
                       let data = Data(base64Encoded: b64) {
                        print("🔊 RealtimeClient: 音声デルタ受信 - \(data.count) bytes")
                        audioContinuation?.yield(data)
                    }
                case "response.done":
                    print("✅ RealtimeClient: レスポンス完了")
                    userRequestedResponse = false  // ✅ フラグをリセット
                    suppressCurrentResponseAudio = false  // ✅ フラグをリセット
                    onResponseDone?()
                    break
                case "response.created":
                    // ✅ VADモード：自動レスポンスをキャンセルしない（サーバが自動で区切る）
                    suppressCurrentResponseAudio = false  // ✅ 音声を許可
                    print("✅ RealtimeClient: VAD: response.created")
                    break
                case "response.audio.done",
                     "response.audio_transcript.done",
                     "response.content_part.added",
                     "response.content_part.done",
                     "response.output_item.added",
                     "response.output_item.done",
                     "conversation.item.created",
                     "rate_limits.updated":
                    // 正常イベント - 何もしないでもOK
                    break
                case "input_audio_buffer.speech_started":
                    print("🎤 RealtimeClient: 音声入力開始")
                    turnAccumulatedMs = 0  // ✅ 録音開始時に累積時間をリセット
                    lastAppendAt = Date()  // ✅ VADの「詰まり」対策：開始時刻を記録
                    // ✅ VADの「詰まり」対策：アイドル監視を開始
                    startVADIdleMonitoring()
                    onSpeechStarted?()
                case "input_audio_buffer.speech_stopped":
                    print("🎤 RealtimeClient: 音声入力終了")
                    // ✅ VADの「詰まり」対策：サーバが正常に区切ったなら保険は終了
                    stopVADIdleMonitoring()
                    onSpeechStopped?()
                    // ✅ VADは「区切り検出」であり「応答生成」ではないので、止まったら自分で response.create を送る
                    Task { [weak self] in
                        guard let self = self else { return }
                        // 念のため commit → 直後に response.create
                        do {
                            try await self.send(json: ["type": "input_audio_buffer.commit"])
                            try await self.send(json: [
                                "type": "response.create",
                                "response": [
                                    "modalities": ["audio","text"],
                                    "instructions": "つねににほんごでこたえてください。ひらがなを中心に、やさしく、みじかく話します。"
                                ]
                            ])
                            print("✅ RealtimeClient: 応答生成をリクエスト（speech_stopped → commit → response.create）")
                        } catch {
                            print("❌ RealtimeClient: 応答生成リクエスト失敗 - \(error)")
                        }
                    }
                case "input_audio_buffer.committed":
                    if let transcript = obj["transcript"] as? String {
                        print("📝 RealtimeClient: 音声入力テキスト - \(transcript)")
                        inputTextContinuation?.yield(transcript)
                        onInputCommitted?(transcript)
                    }
                case "input_audio_buffer.cleared":
                    // ✅ 正常イベント（バッファクリア）
                    print("ℹ️ RealtimeClient: input_audio_buffer.cleared")
                    turnAccumulatedMs = 0  // ✅ 累積時間をリセット
                    break
                case "conversation.item.input_audio_transcription.delta":
                    // ✅ 新イベント名：ユーザー入力側のSTTデルタ（部分テキスト表示用）
                    if let s = (obj["delta"] as? String) ?? (obj["text"] as? String) {
                        print("📝 RealtimeClient: 入力側STTデルタ - \(s)")
                        inputTextContinuation?.yield(s)
                    }
                    break
                case "conversation.item.input_audio_transcription.completed":
                    // ✅ 新イベント名：ユーザー入力側のSTT確定（完了テキスト）
                    if let t = (obj["transcript"] as? String) ?? (obj["text"] as? String) {
                        print("📝 RealtimeClient: 入力側STT確定 - \(t)")
                        inputTextContinuation?.yield(t)
                        onInputCommitted?(t)
                    }
                    break
                case "ping":
                    print("🏓 RealtimeClient: Ping受信 - Pong送信")
                    Task { try? await self.send(json: ["type": "pong"]) }
                case "session.created":
                    print("✅ RealtimeClient: セッション作成完了")
                case "session.updated":
                    print("✅ RealtimeClient: session.updated 受信（session.update 成功）")
                    // ✅ 日本語指示が反映されたか確認（先頭80文字を表示）
                    if let session = obj["session"] as? [String: Any],
                       let instructions = session["instructions"] as? String {
                        print("   📝 instructions(先頭80文字): \(instructions.prefix(80))\(instructions.count > 80 ? "..." : "")")
                        // 日本語指示が含まれているか確認
                        if instructions.contains("日本語") || instructions.contains("ja-JP") {
                            print("   ✅ 日本語指示が反映されています")
                        } else {
                            print("   ⚠️ 日本語指示が反映されていない可能性があります")
                        }
                    } else {
                        print("   ⚠️ session 本体が取得できませんでした")
                    }
                case "error":
                    if let error = obj["error"] as? [String: Any] {
                        print("❌ RealtimeClient: サーバーエラー - \(error)")
                        if let message = error["message"] as? String {
                            print("❌ RealtimeClient: エラーメッセージ - \(message)")
                        }
                        if let code = error["code"] as? String {
                            print("❌ RealtimeClient: エラーコード - \(code)")
                        }
                    }
                default: 
                    print("❓ RealtimeClient: 未知のメッセージタイプ - \(type)")
                    break
                }
            }
        @unknown default:
            break
        }
    }

    private func handleFailure(_ err: Error) {
        print("❌ RealtimeClient: 接続エラー - \(err.localizedDescription)")
        stopPing()
        state = .closed(err)
        onStateChange?(state)
        audioContinuation?.finish()
        textContinuation?.finish()
        inputTextContinuation?.finish()
        
        // リソースを完全にクリーンアップ
        audioContinuation = nil
        textContinuation = nil
        inputTextContinuation = nil
        // audioBuffer.removeAll() // ← PTT時は不要
        wsTask = nil
        
        // 再接続は自動的に行わない（手動で再開させる）
        reconnectAttempts += 1
        print("🔄 RealtimeClient: 接続エラー - 手動で再開してください")
        
        // 状態をidleに戻す
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self else { return }
            self.state = .idle
            self.onStateChange?(self.state)
        }
    }

    private func startPing() {
        stopPing()
        pingTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self, let ws = self.wsTask else { return }
            print("🏓 RealtimeClient: Ping送信")
            ws.sendPing { error in
                if let error = error {
                    print("❌ RealtimeClient: Ping失敗 - \(error.localizedDescription)")
                } else {
                    print("✅ RealtimeClient: Ping成功")
                }
            }
        }
        RunLoop.main.add(pingTimer!, forMode: .common)
    }
    private func stopPing() { pingTimer?.invalidate(); pingTimer = nil }

    private func send(json: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: json)
        guard let ws = wsTask else { 
            print("❌ RealtimeClient: WebSocketタスクが存在しません")
            return 
        }
        
        // 接続状態をチェック
        guard ws.state == .running else {
            print("❌ RealtimeClient: WebSocket接続が切れています - State: \(ws.state.rawValue)")
            throw NSError(domain: "RealtimeClient", code: -2, userInfo: [NSLocalizedDescriptionKey: "WebSocket接続が切れています"])
        }
        
        let jsonString = String(data: data, encoding: .utf8)!
        
        // 音声データの場合は長いBase64データをログに出力しない
        if jsonString.contains("input_audio_buffer.append") {
            print("📤 RealtimeClient: 音声データ送信 - \(data.count) bytes")
        } else {
            print("📤 RealtimeClient: 送信 - \(jsonString)")
        }
        
        try await ws.send(.string(jsonString))
    }

    private func sendBinary(type: UInt8, payload: Data) async throws {
        var buf = Data([type])
        buf.append(payload)
        guard let ws = wsTask else { return }
        try await ws.send(.data(buf))
    }
}