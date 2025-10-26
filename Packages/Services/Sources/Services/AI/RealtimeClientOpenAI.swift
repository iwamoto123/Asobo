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

    // MARK: - Init
    public init(url: URL, apiKey: String, model: String = "gpt-4o-realtime-preview") {
        self.url = url
        self.apiKey = apiKey
        self.model = model
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
                "input_audio_format": "pcm16",
                "output_audio_format": "pcm16",
                "input_audio_transcription": ["model": "whisper-1", "language": "ja"],
                "voice": "alloy",
                "tools": [],
                "tool_choice": "none"
                // "turn_detection" は入れない（PTT前提）
            ]
        ]
        print("🔗 RealtimeClient: セッション設定送信")
        // 必ず WebSocket が running かつクライアント state が ready になってから送信
        try await send(json: sessionUpdate)
        
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
            let ptr = ch0.pointee
            let data = Data(bytes: ptr, count: n * MemoryLayout<Int16>.size)
            let b64  = data.base64EncodedString()
            try await send(json: ["type": "input_audio_buffer.append", "audio": b64])
        }
    }
    
    public func interruptAndYield() async throws {
        // ユーザーが割り込んだら（再録音開始前など）
        try await send(json: ["type": "response.cancel"])
        // 必要に応じて入力バッファもクリア
        try await send(json: ["type": "input_audio_buffer.clear"])
    }
    
    // ② 追加: コミットだけ送る（応答は送らない）
    public func commitInputOnly() async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        try await send(json: ["type": "input_audio_buffer.commit"])
    }
    
    // ③ 追加: 応答だけリクエスト（commit済みの入力を使う）
    public func requestResponse(instructions: String? = nil, temperature: Double = 0.3) async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        
        var resp: [String: Any] = [
            "type": "response.create",
            "response": [
                "modalities": ["audio","text"],
                "temperature": NSDecimalNumber(value: temperature)
            ]
        ]
        if let inst = instructions {
            // 任意の固定文や促しを"そのまま言わせる"用途にも使う
            resp["response"] = [
                "modalities": ["audio","text"],
                "temperature": NSDecimalNumber(value: temperature),
                "instructions": inst
            ]
        }
        try await send(json: resp)
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

    public func finishSession() async throws {
        state = .closing
        // OpenAI Realtime APIでは session.finish は不要
        stopPing()
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
                    if let b64 = obj["delta"] as? String,
                       let data = Data(base64Encoded: b64) {
                        print("🔊 RealtimeClient: 音声デルタ受信 - \(data.count) bytes")
                        audioContinuation?.yield(data)
                    }
                case "response.done":
                    print("✅ RealtimeClient: レスポンス完了")
                    onResponseDone?()
                    break
                case "response.audio.done",
                     "response.audio_transcript.done",
                     "response.content_part.added",
                     "response.content_part.done",
                     "response.output_item.added",
                     "response.output_item.done",
                     "response.created",
                     "conversation.item.created",
                     "rate_limits.updated":
                    // 正常イベント - 何もしないでもOK
                    break
                case "input_audio_buffer.speech_started":
                    print("🎤 RealtimeClient: 音声入力開始")
                    onSpeechStarted?()
                case "input_audio_buffer.speech_stopped":
                    print("🎤 RealtimeClient: 音声入力終了")
                    // 音声入力が停止した場合、空のテキストでも通知
                    print("📝 RealtimeClient: 音声入力停止 - テキスト確認")
                    inputTextContinuation?.yield("")
                    onSpeechStopped?()
                case "input_audio_buffer.committed":
                    if let transcript = obj["transcript"] as? String {
                        print("📝 RealtimeClient: 音声入力テキスト - \(transcript)")
                        inputTextContinuation?.yield(transcript)
                        onInputCommitted?(transcript)
                    }
                case "ping":
                    print("🏓 RealtimeClient: Ping受信 - Pong送信")
                    Task { try? await self.send(json: ["type": "pong"]) }
                case "session.created":
                    print("✅ RealtimeClient: セッション作成完了")
                case "session.updated":
                    print("✅ RealtimeClient: セッション更新完了")
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
