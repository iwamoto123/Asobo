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
    public var onResponseCreated: (() -> Void)?  // ✅ 新しい応答が作成された時に呼ばれる
    public var onInputCommitted: ((String) -> Void)?
    public var onSpeechStarted: (() -> Void)?
    public var onSpeechStopped: (() -> Void)?
    public var onError: ((Error) -> Void)?  // ✅ エラー発生時に呼ばれる（response.doneでstatus == "failed"の場合など）
    public var onAudioDeltaReceived: (() -> Void)?  // ✅ 参考プロジェクトパターン：AI音声受信時に録音停止をトリガー

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
    // ⚠️ 注意: 現在はVADモード（useServerVAD = true）で運用
    // PTTモードに切り替える場合は、useServerVAD = false に変更し、turn_detection を外す
    private var useServerVAD = true  // VADモードで運用
    
    // ✅ ターン状態管理（commit/clearの一元管理）
    private enum TurnState {
        case cleared       // clear済み（次のターン準備完了）
        case collecting    // 音声収集中
        case committed     // commit済み（STT待機中）
    }
    private var turnState: TurnState = .cleared
    private var hasAppendedSinceClear: Bool = false  // clear後にappendがあったか
    private var hasCommittedThisTurn: Bool = false   // このターンでcommit済みか
    private var clearSentForItem: Set<String> = []   // ✅ item_id単位でclearを1回だけ送信するためのセット
    private var pendingCompletedWatchdog: DispatchSourceTimer?  // ✅ completed待ちのwatchdog
    
    // ✅ セッション確立フラグ（session.updated受信までappendを送らない）
    private var sessionIsUpdated: Bool = false
    
    // ✅ 参考プロジェクトパターン：送信中の重複送信を防ぐフラグ
    private var isSendingAudioData: Bool = false
    
    // ✅ 音声入力確認フラグ（最初の確認が完了したら通常の会話モードに切り替え）
    private var audioInputVerified: Bool = false
    
    // ✅ 音声レベル測定（薄い音声の検出用）
    private struct AudioMeter {
        private var recentFrames: [(maxAmplitude: Double, ms: Double)] = []
        private let windowMs: Double = 300.0  // 300msウィンドウ
        
        mutating func addFrame(maxAmplitude: Double, ms: Double) {
            recentFrames.append((maxAmplitude: maxAmplitude, ms: ms))
            // ウィンドウを超えた古いフレームを削除
            var totalMs: Double = 0
            var removeCount = 0
            for frame in recentFrames.reversed() {
                totalMs += frame.ms
                if totalMs > windowMs {
                    break
                }
                removeCount += 1
            }
            if removeCount < recentFrames.count {
                recentFrames.removeFirst(recentFrames.count - removeCount)
            }
        }
        
        func voicedMs(windowMs: Double = 300.0) -> Double {
            // 有声フレーム（最大振幅が閾値以上）の累積時間を計算
            // 音声レベルが低い場合でも検出できるように、閾値を緩和（0.5% → 0.1% → 0.05% → 0.01%）
            // 実際の音声レベルが0.0%〜0.2%程度の場合でも検出できるように、閾値を0.01%に設定
            // これにより、非常に低音声レベルでも有声フレームとして検出され、voicedMsが0.0にならなくなる
            let threshold: Double = 0.01  // 0.01%以上を有声とする（極めて低音声レベルでも検出可能にする）
            var voiced: Double = 0
            var totalMs: Double = 0
            for frame in recentFrames.reversed() {
                totalMs += frame.ms
                if totalMs > windowMs {
                    break
                }
                if frame.maxAmplitude >= threshold {
                    voiced += frame.ms
                }
            }
            return voiced
        }
        
        func isSilence(maxAmplitude: Double, rmsThreshold: Double = -45.0) -> Bool {
            // RMS閾値（dBFS）で判定（簡易版：最大振幅から推定）
            // -45dBFS ≈ 0.56% (maxAmplitude ≈ 0.56)
            let amplitudeThreshold = pow(10.0, rmsThreshold / 20.0) * 100.0
            return maxAmplitude < amplitudeThreshold
        }
        
        mutating func reset() {
            recentFrames.removeAll()
        }
    }
    private var audioMeter = AudioMeter()
    
    // ✅ VADの「詰まり」対策（無音ハマり防止）
    private var vadIdleTimer: DispatchSourceTimer?
    private var lastAppendAt: Date?
    private var speechStartedAt: Date? // ✅ speech_startedの時刻を記録
    
    // ✅ 空コミット対策：バッファされたバイト数を追跡（24kHz/mono/16bit前提）
    private var bufferedBytes: Int = 0
    private let minBytesForCommit: Int = {
        // 100ms以上のPCM16を貯める（24kHz/mono/16bit）
        let bytesPerSample = 2 // pcm16
        let channels = 1
        let sampleRate = 24000  // ✅ 24kHzに変更（OpenAI Realtime APIの要求仕様に合わせる）
        return Int(Double(sampleRate) * 0.1) * channels * bytesPerSample // 100ms=0.1s
    }()
    
    // ✅ response.cancel の送信をガードするためのアクティブレスポンスID
    private var activeResponseId: String?
    
    // ✅ ログ用カウンター（最初の10回は毎回ログを出す）
    private var appendCount = 0
    
    // ✅ AI応答音声デルタ受信のログ用カウンター
    private var audioDeltaCount = 0
    
    // ✅ 短文聞き返しの猶予タイマー（800ms待機）
    private var clarificationTimer: DispatchSourceTimer?
    private var lastCompletedTranscript: String?
    private var lastCompletedTime: Date?
    
    // ✅ 簡易アイドル検知：最後の有声時刻とcommitタイマー
    private var lastVoiceAt: Date?
    private var commitTimer: DispatchSourceTimer?
    
    // ✅ 5秒アイドル保険：speech_startedが来ない場合の強制commit→response.create
    private var idleGuardTimer: DispatchSourceTimer?
    
    // ✅ deltaをitem_idごとに連結してUIに表示
    private var interimTranscripts: [String: String] = [:]  // item_id -> 暫定テキスト
    
    // ✅ UIの重複表示を止める：response_idごとにバッファ管理（response.output_text.deltaのみ使用）
    private var streamText: [String: String] = [:]  // response_id -> partial text

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
        
        // ✅ 音声入力確認フラグをリセット（新しいセッション開始時）
        audioInputVerified = false
        
        // ✅ 記事のフローに合わせて、session.createdを受信してからsession.updateを送信
        // 注意: session.updateはsession.createdの後に送信する（記事の実装に合わせる）
        // session.createdの受信を待つため、ここではsession.updateを送信しない
        
        print("✅ RealtimeClient: セッション開始完了 - session.created待機中（音声入力確認モード）")
        state = .ready
        onStateChange?(state)
        reconnectAttempts = 0
    }
    
    // ✅ セッション更新を送信（session.createdの後に呼び出す）
    private func sendSessionUpdate() async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else {
            print("⚠️ RealtimeClient: sendSessionUpdate - セッションが準備できていません")
            return
        }
        
        // ✅ セッション設定：VADモードまたはPTTモードに応じてturn_detectionを設定
        // ✅ 通常の会話用プロンプト
        let instructions = """
あなたは かならず日本語で話す、やさしい会話アシスタントです。
ひらがな中心・一文みじかめ・ゆっくり を基本にします。
■最重要ポリシー
1) ユーザーが話しはじめたら ただちに話すのをやめて きく。
2) ききとれない ときは かならず 聞き返す（勝手に話を作らない）。
3) しばらく反応がない ときは やさしく会話を促す。

【言語設定】
以後の応答は全て日本語で、丁寧語で簡潔に回答してください。
英語や他言語は一切使用せず、日本語のみで応答してください。
"""
        
        var sessionDict: [String: Any] = [
                "instructions": instructions,
            "modalities": ["text","audio"],
            // ✅ input_audio_format は文字列形式（オブジェクト形式はサーバーが拒否する）
            "input_audio_format": "pcm16",
            // ✅ output_audio_format も文字列形式
            "output_audio_format": "pcm16",
            // ✅ 公式設定：STTモデル（gpt-4o-mini-transcribe）
            "input_audio_transcription": ["model": "gpt-4o-mini-transcribe", "language": "ja"],
            "voice": "alloy",
                "tools": [],
                "tool_choice": "none"
        ]
        
        // ✅ サーバーVADを有効化（推奨：まずはこれで正常化）
        // ✅ このモードでは、こちらから response.create を送らないでOK（サーバーが自動で応答を生成）
        // 
        // ## サーバーVAD設定の最適化（音声入力が正常に動作するための設定）
        // - threshold: 0.3（0.5 → 0.3に下げて低振幅の日本語でも検出可能に）
        // - silence_duration_ms: 700（無音が700ms続いたら発話終了と判定）
        // - prefix_padding_ms: 500（300 → 500に増やして語頭欠落を防ぐ）
        // - create_response: true（サーバーが自動で応答を生成）
        sessionDict["turn_detection"] = [
            "type": "server_vad",
            "threshold": NSDecimalNumber(string: "0.3"),  // ✅ 0.5 → 0.3（低振幅の日本語でも検出可能に）
            "silence_duration_ms": 700,
            "prefix_padding_ms": 500,  // ✅ 300 → 500（語頭欠落を防ぐ）
            "create_response": true
        ]
        
        let sessionUpdate: [String: Any] = [
            "type": "session.update",
            "session": sessionDict
        ]
        print("🔗 RealtimeClient: セッション設定送信（session.createdの後）")
        let threshold = (sessionDict["turn_detection"] as? [String: Any])?["threshold"] as? NSDecimalNumber ?? NSDecimalNumber(string: "0.3")
        let silenceDuration = (sessionDict["turn_detection"] as? [String: Any])?["silence_duration_ms"] as? Int ?? 700
        let prefixPadding = (sessionDict["turn_detection"] as? [String: Any])?["prefix_padding_ms"] as? Int ?? 500
        print("📊 RealtimeClient: session.update詳細 - モード: サーバーVAD, turn_detection: server_vad (threshold: \(threshold), silence_duration_ms: \(silenceDuration), prefix_padding_ms: \(prefixPadding), create_response: true), input_audio_format: pcm16, output_audio_format: pcm16, STTモデル: gpt-4o-mini-transcribe")
        // 必ず WebSocket が running かつクライアント state が ready になってから送信
        try await send(json: sessionUpdate)
        
        print("✅ RealtimeClient: session.update送信完了、session.updated待機中")
    }

    /// ✅ マイク入力音声データをサーバーに送信
    /// 
    /// ## 重要な処理ポイント
    /// 1. **フォーマット検証**: 24kHz/mono/PCM16であることを確認
    /// 2. **無音スキップ**: 完全にやめる（VADが文脈を掴めるようにする）
    /// 3. **音声レベル測定**: 最大振幅と平均振幅を測定してVADの精度向上に貢献
    /// 4. **重複送信防止**: isSendingAudioDataフラグで送信中の重複を防ぐ
    /// 
    /// ## 送信フォーマット
    /// - 形式: base64エンコードされたPCM16データ
    /// - サンプルレート: 24kHz
    /// - チャンネル: モノラル（1ch）
    /// - エンコーディング: PCM16LE
    public func sendMicrophonePCM(_ buffer: AVAudioPCMBuffer) async throws {
        // ✅ 参考プロジェクトパターン：送信中の重複送信を防ぐ
        guard !isSendingAudioData else {
            // 最初の数回だけログを出す
            if appendCount < 5 {
                print("⚠️ RealtimeClient: sendMicrophonePCM - 送信中のためスキップ（isSendingAudioData=true）")
            }
            return
        }
        
        // ✅ 接続前ドロップ & セッション確立までは送らない
        guard case .ready = state,
              let ws = wsTask,
              ws.state == .running,
              sessionIsUpdated else {
            // ✅ 接続確立前のフレームは捨てる（ゴミが混ざるのを防ぐ）
            if !sessionIsUpdated {
                // 最初の数回だけログを出す
                if appendCount < 3 {
                    print("⚠️ RealtimeClient: sendMicrophonePCM - セッション未確立のためスキップ（session.updated待機中）")
                }
            } else {
                print("⚠️ RealtimeClient: sendMicrophonePCM - state=\(state), wsState=\(wsTask?.state.rawValue ?? -1)")
            }
            return 
        }

        // ✅ 音声データの詳細ログを追加
        let n = Int(buffer.frameLength)
        let sr = Double(buffer.format.sampleRate)
        let ch = buffer.format.channelCount
        let ms = (Double(n) / sr) * 1000.0
        
        // ✅ 音声レベルの簡易チェック（最大値・平均値）
        var maxAmplitude: Int16 = 0
        var sumAmplitude: Int64 = 0

        // ここで即 append（20ms/480フレームのバッファが来る想定）
        if let ch0 = buffer.int16ChannelData {
            let ptr = ch0.pointee
            for i in 0..<n {
                let sample = abs(ptr[i])
                maxAmplitude = max(maxAmplitude, sample)
                sumAmplitude += Int64(sample)
            }
            
            let avgAmplitude = n > 0 ? Double(sumAmplitude) / Double(n) : 0.0
            let maxAmplitudePercent = Double(maxAmplitude) / 32768.0 * 100.0  // 16bit PCMの最大値に対する割合
            
            // ✅ 無音スキップを完全にやめる：常にappendする（VADが文脈を掴めるようにする）
            // ✅ 無音も含めてそのままappendすることで、VADが正しく動作し、「短く切れすぎる」「別の文字に化ける」問題が解消される
            
            // ✅ 音声レベル測定に追加
            audioMeter.addFrame(maxAmplitude: maxAmplitudePercent, ms: ms)
            
            // ✅ 簡易アイドル検知：-40dBくらいを有声判定の目安（ざっくりでOK）
            // ✅ 最大振幅から簡易的にRMSを推定（-40dB相当は約1%）
            if maxAmplitudePercent > 1.0 {
                lastVoiceAt = Date()
                // ✅ 5秒アイドル保険をリセット（有声が検出されたため）
                idleGuardTimer?.cancel()
                idleGuardTimer = nil
            }
            
            turnAccumulatedMs += ms  // ✅ 累積ミリ秒を計算
            
            // ✅ 空コミット対策：バッファされたバイト数を累積
            let bytes = n * MemoryLayout<Int16>.size
            bufferedBytes += bytes
            
            // ✅ ターン状態管理：appendがあったことを記録
            hasAppendedSinceClear = true
            if turnState == .cleared {
                turnState = .collecting
            }
            
            // ✅ フォーマット検証：24kHz/monoであることを確認
            appendCount += 1
            if appendCount == 1 {
                print("📊 RealtimeClient: 音声入力フォーマット確認 - サンプルレート: \(sr)Hz, チャンネル: \(ch), フレーム長: \(n), バイト数: \(bytes)")
                // ✅ preferredSampleRate(24_000)は「希望値」です。多くのiOS機種は48kHzのままです。
                // 送信用にMicrophoneCaptureで24kHzへ変換しているのでOK。ログはINFOレベルに変更。
                if abs(sr - 24000.0) > 100.0 {
                    print("ℹ️ RealtimeClient: サンプルレートが24kHzではありません（実際の値: \(sr)Hz）。MicrophoneCaptureで24kHzに変換されます。")
                }
                if ch != 1 {
                    print("ℹ️ RealtimeClient: チャンネル数が1（モノラル）ではありません（実際の値: \(ch)）。MicrophoneCaptureでモノラルに変換されます。")
                }
            }
            
            // ✅ 音声レベルの診断
            // 音声レベルが低い場合でも検出できるように、警告閾値を緩和（0.5% → 0.1%）
            if maxAmplitudePercent < 0.1 {
                if appendCount <= 10 || appendCount % 20 == 0 {
                    print("⚠️ RealtimeClient: 音声レベルが非常に低いです（最大振幅: \(String(format: "%.2f", maxAmplitudePercent))%）- マイクの音量を確認してください")
                }
            } else if maxAmplitudePercent < 0.5 {
                // 0.1%以上0.5%未満の場合はINFOレベルに変更（低音声レベルでも正常に動作する可能性がある）
                if appendCount <= 10 || appendCount % 50 == 0 {
                    print("ℹ️ RealtimeClient: 音声レベルが低めです（最大振幅: \(String(format: "%.2f", maxAmplitudePercent))%）- 正常に動作する可能性があります")
                }
            }
            
            // ✅ VADの「詰まり」対策：最後のappend時刻を更新
            let now = Date()
            lastAppendAt = now
            
            // ✅ speech_startedが来ていない場合の警告（最初の数回と定期的に）
            if speechStartedAt == nil && turnAccumulatedMs > 300.0 {
                if appendCount <= 10 || appendCount % 20 == 0 {
                    print("⚠️ RealtimeClient: speech_startedが来ていません（累積時間: \(String(format: "%.1f", turnAccumulatedMs))ms, バッファ: \(bufferedBytes)bytes, 最大振幅: \(String(format: "%.1f", maxAmplitudePercent))%）- VADが音声を検出できていない可能性があります")
                }
            }
            
            // ✅ 詳細ログ（最初の10回は毎回、その後は20回に1回程度）
            if appendCount <= 10 || appendCount % 20 == 0 {
                print("🎤 RealtimeClient: 音声データ送信 #\(appendCount) - フレーム: \(n), サンプルレート: \(sr)Hz, チャンネル: \(ch), 長さ: \(String(format: "%.1f", ms))ms, 累積時間: \(String(format: "%.1f", turnAccumulatedMs))ms, 累積バイト: \(bufferedBytes)bytes, 最大振幅: \(String(format: "%.1f", maxAmplitudePercent))%, speechStartedAt: \(speechStartedAt?.description ?? "nil")")
            }
            
           
            let data = Data(bytes: ptr, count: bytes)
            let b64  = data.base64EncodedString()
            
            // ✅ 参考プロジェクトパターン：送信フラグを立てて送信
            isSendingAudioData = true
            do {
            try await send(json: ["type": "input_audio_buffer.append", "audio": b64])
                // ✅ 送信完了後にフラグをリセット
                isSendingAudioData = false
                
                // ✅ サーバーVADモードでは、手動commit→response.createは不要（サーバーが自動で処理）
                // ✅ 簡易アイドル検知と5秒アイドル保険は無効化（サーバーVADが自動で処理するため）
            } catch {
                // ✅ エラー時もフラグをリセット
                isSendingAudioData = false
                throw error
            }
        } else {
            print("⚠️ RealtimeClient: sendMicrophonePCM - int16ChannelDataがnil")
        }
    }
    
    // ✅ 録音開始時/再録音時のリセット
    public func resetRecordingTurn() {
        turnAccumulatedMs = 0
        bufferedBytes = 0  // ✅ 空コミット対策：バッファもリセット
        appendCount = 0  // ✅ ログカウンターもリセット
        speechStartedAt = nil  // ✅ speech_startedの時刻をクリア
        // ✅ ターン状態管理：リセット時
        stopCompletedWatchdog()
        turnState = .cleared
        hasAppendedSinceClear = false
        hasCommittedThisTurn = false
        clearSentForItem.removeAll()
        audioMeter.reset()  // ✅ 音声レベル測定をリセット
    }
    
    public func interruptAndYield() async throws {
        print("⚠️ RealtimeClient: interruptAndYield 呼び出し - speechStartedAt: \(speechStartedAt?.description ?? "nil"), activeResponseId: \(activeResponseId ?? "nil")")
        // ✅ 常に「現在応答の中断」を送れるように修正（VADモードでも常に中断可能）
        suppressCurrentResponseAudio = true
        
        // ✅ response.cancel の送信を厳密に制御（activeResponseId != nil の時のみ一度だけ送信）
        // ✅ activeResponseIdを即座にクリアして重複送信を防ぐ
        if let responseId = activeResponseId {
            activeResponseId = nil  // ✅ 即座にクリアして重複送信を防ぐ
        try await send(json: ["type": "response.cancel"])
            print("✅ RealtimeClient: interruptAndYield - response.cancel送信 (ID: \(responseId))")
        } else {
            print("ℹ️ RealtimeClient: interruptAndYield - アクティブレスポンスなし - response.cancel をスキップ")
        }
        
        // ✅ 注意: speech_startedが来ている場合は、input_audio_buffer.clearを送信しない
        // ✅ サーバー側が音声を処理しているため、バッファをクリアしない
        // ✅ また、speech_startedが来る前にclearを送ると、初期音声データが消去されてしまうため、
        // ✅ 通常はVADモードでは手動でclearを送らない（サーバー側が自動で処理する）
        if speechStartedAt == nil {
            // ✅ VADモードでは通常はclearを送らない（サーバー側が自動で処理する）
            // ✅ ただし、明示的にクリアが必要な場合のみ送信
            if useServerVAD {
                print("⚠️ RealtimeClient: interruptAndYield - VADモードでは通常はinput_audio_buffer.clearを送りません（サーバー側が自動で処理します）")
            } else {
        try await send(json: ["type": "input_audio_buffer.clear"])
                print("📊 RealtimeClient: interruptAndYield - input_audio_buffer.clear送信（PTTモード）")
                // ✅ 録音ターンをリセット
                turnAccumulatedMs = 0
                bufferedBytes = 0  // ✅ 空コミット対策：バッファもリセット
            }
        } else {
            print("⚠️ RealtimeClient: interruptAndYield - input_audio_buffer.clearをスキップ（speech_startedが来ているため、サーバー側が処理中）")
        }
    }
    
    // ✅ 簡易アイドル検知と5秒アイドル保険用：commit→response.createを強制実行
    private func forceCommitAndCreateResponse() async {
        // ✅ 既にcommit済みの場合はスキップ
        guard !hasCommittedThisTurn else {
            print("⚠️ RealtimeClient: forceCommitAndCreateResponse - 既にcommit済みのためスキップ")
            return
        }
        
        // ✅ バッファが空の場合はスキップ
        guard bufferedBytes > 0 else {
            print("⚠️ RealtimeClient: forceCommitAndCreateResponse - バッファが空のためスキップ")
            return
        }
        
        do {
            // ✅ 1. commitを送信
            try await send(json: ["type": "input_audio_buffer.commit"])
            print("✅ RealtimeClient: forceCommitAndCreateResponse - input_audio_buffer.commit送信")
            
            // ✅ ターン状態管理：commit送信後
            hasCommittedThisTurn = true
            turnState = .committed
            turnAccumulatedMs = 0
            speechStartedAt = nil
            
            // ✅ タイマーをクリア
            commitTimer?.cancel()
            commitTimer = nil
            idleGuardTimer?.cancel()
            idleGuardTimer = nil
            
            // ✅ 2. 300ms待ってもresponse.createdが来なければ明示生成（保険）
            try await Task.sleep(nanoseconds: 300_000_000)  // 300ms
            if activeResponseId == nil {
                try await send(json: [
                    "type": "response.create",
                    "response": [
                        "modalities": ["audio","text"]
                    ]
                ])
                print("✅ RealtimeClient: forceCommitAndCreateResponse - response.create送信（保険）")
            } else {
                print("✅ RealtimeClient: forceCommitAndCreateResponse - response.createdが既に来ているためresponse.createをスキップ")
            }
        } catch {
            print("❌ RealtimeClient: forceCommitAndCreateResponse - エラー: \(error)")
        }
    }
    
    // ② PTTモード用: コミットと応答生成を送信（公式パターンに合わせる）
    public func commitInputAndRequestResponse() async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        // ✅ ターン状態管理：commit送信前の共通ガード
        guard turnState == .collecting,
              !hasCommittedThisTurn,
              bufferedBytes >= minBytesForCommit else {
            print("⚠️ RealtimeClient: commitInputAndRequestResponse - commitスキップ: state=\(turnState), committed=\(hasCommittedThisTurn), bytes=\(bufferedBytes)/\(minBytesForCommit) - manual")
            return
        }
        
        // ✅ 1. commitを送信（公式パターン）
        try await send(json: ["type": "input_audio_buffer.commit"])
        print("✅ RealtimeClient: PTT - input_audio_buffer.commit送信 - manual")
        
        // ✅ ターン状態管理：commit送信後
        hasCommittedThisTurn = true
        turnState = .committed
        // ✅ 注意: bufferedBytesはリセットしない（サーバー側が処理中）
        turnAccumulatedMs = 0
        speechStartedAt = nil
        
        // ✅ 2. response.createを送信（公式パターン）
        guard activeResponseId == nil else {
            print("⚠️ RealtimeClient: アクティブレスポンスが存在するため response.create をスキップ (ID: \(activeResponseId!))")
            return
        }
        
        try await send(json: [
            "type": "response.create",
            "response": [
                "modalities": ["audio","text"],
                "instructions": "つねににほんごでこたえてください。ひらがなを中心に、やさしく、みじかく話します。"
            ]
        ])
        print("✅ RealtimeClient: PTT - response.create送信")
        
        userRequestedResponse = true  // ✅ ユーザーが明示的にリクエストしたことを記録
    }
    
    // ② 追加: コミットだけ送る（応答は送らない）- 非推奨（PTTモードでは commitInputAndRequestResponse() を使用）
    @available(*, deprecated, message: "PTTモードでは commitInputAndRequestResponse() を使用してください")
    public func commitInputOnly() async throws {
        // ✅ VADモードではcommitを送らない（サーバが自動で区切るため）
        if useServerVAD {
            print("⚠️ RealtimeClient: VADモードでは commitInputOnly() を使用しないでください（サーバが自動でcommitします）")
            return
        }
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        // ✅ ターン状態管理：commit送信前の共通ガード
        guard turnState == .collecting,
              !hasCommittedThisTurn,
              bufferedBytes >= minBytesForCommit else {
            print("⚠️ RealtimeClient: commitInputOnly - commitスキップ: state=\(turnState), committed=\(hasCommittedThisTurn), bytes=\(bufferedBytes)/\(minBytesForCommit) - manual")
            return
        }
        try await send(json: ["type": "input_audio_buffer.commit"])
        print("✅ RealtimeClient: commitInputOnly - input_audio_buffer.commit送信 - manual")
        // ✅ ターン状態管理：commit送信後
        hasCommittedThisTurn = true
        turnState = .committed
        // ✅ 注意: bufferedBytesはリセットしない（サーバー側が処理中）
        turnAccumulatedMs = 0
        speechStartedAt = nil  // ✅ speech_startedの時刻をクリア
    }
    
    // ✅ 「黙っていたらAIが促す（ヌッジ）」用のAPI
    public func nudge(kind: Int = 0) async {
        // ✅ 多重送信を防ぐ（アクティブレスポンスがある場合は送信しない）
        guard activeResponseId == nil else {
            print("⚠️ RealtimeClient: アクティブレスポンスが存在するため nudge をスキップ (ID: \(activeResponseId!))")
            return
        }
        
        // ✅ ユーザーが話している最中は促しメッセージを送信しない（lastAppendAtが最近更新されている場合）
        if let lastAppend = lastAppendAt, Date().timeIntervalSince(lastAppend) < 2.0 {
            print("⚠️ RealtimeClient: ユーザーが話している可能性があるため nudge をスキップ（最後のappendから \(String(format: "%.1f", Date().timeIntervalSince(lastAppend)))秒経過）")
            return
        }
        
        let variants = [
            "どうしたの？きょうは なにを はなそうか？",
            "おはなし きいてるよ。すきなこと、なんでも いってみてね。",
            "もしもし？きこえてるよ。いま どんな きぶん？"
        ]
        let line = variants[kind % variants.count]
        do {
            try await send(json: [
                "type": "response.create",
                "response": [
                    "modalities": ["audio","text"],
                    "instructions": line
                ]
            ])
            print("✅ RealtimeClient: 促しメッセージ送信（kind: \(kind)）")
        } catch {
            print("❌ RealtimeClient: 促しメッセージ送信失敗 - \(error)")
        }
    }
    
    // ③ 追加: 応答だけリクエスト（commit済みの入力を使う）
    public func requestResponse(instructions: String? = nil, temperature: Double = 0.3) async throws {
        guard case .ready = state, let ws = wsTask, ws.state == .running else { return }
        
        // ✅ 多重送信を防ぐ（アクティブレスポンスがある場合は送信しない）
        guard activeResponseId == nil else {
            print("⚠️ RealtimeClient: アクティブレスポンスが存在するため requestResponse をスキップ")
            return
        }
        
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
        
        print("📊 RealtimeClient: VADアイドル監視開始 - チェック間隔: 0.3秒, タイムアウト: 2.0秒（無音が2秒続いたらcommit/response.create）")
        
        let queue = DispatchQueue(label: "com.asobo.realtime.vad.idle", qos: .userInteractive)
        var checkCount = 0  // チェック回数をカウント
        var lastLogTime = Date()  // 最後のログ出力時刻
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(300))
        
        timer.setEventHandler { [weak self] in
            guard let self = self else {
                print("⚠️ RealtimeClient: VADアイドル監視タイマー - selfがnil")
                return
            }
            
            checkCount += 1
            let now = Date()
            
            // ✅ 最後のappendからの経過時間のみをチェック（音声データが継続的に送られている間はcommitしない）
            // ✅ speech_startedからの経過時間はチェックしない（ユーザーが長く話す可能性があるため）
            if let lastAppend = self.lastAppendAt {
                let elapsed = now.timeIntervalSince(lastAppend)
                
                // 最初の20回は毎回ログを出す、その後は1秒に1回程度
                if checkCount <= 20 || now.timeIntervalSince(lastLogTime) >= 1.0 {
                    let speechElapsedStr = self.speechStartedAt != nil ? String(format: "%.2f", now.timeIntervalSince(self.speechStartedAt!)) : "nil"
                    print("📊 RealtimeClient: VADアイドル監視 #\(checkCount) - 最後のappendからの経過: \(String(format: "%.2f", elapsed))秒, speech_startedからの経過: \(speechElapsedStr)秒, 累積バイト: \(self.bufferedBytes)bytes, 累積時間: \(String(format: "%.1f", self.turnAccumulatedMs))ms")
                    lastLogTime = now
                }
                
                // ✅ 音声認識モード：speech_startedから5秒以上経過したら強制的にcommitを送ってSTTイベントを発火させる
                // ✅ speech_stoppedが来ない場合の保険として、speech_startedから5秒経過したらcommitを送る
                let speechElapsed = self.speechStartedAt != nil ? now.timeIntervalSince(self.speechStartedAt!) : 0
                if speechElapsed > 5.0 {
                    // ✅ idle_guardの強化（"薄い音声"ではcommitしない）
                    // 直近300msの有声時間を計算
                    let voicedMs = self.audioMeter.voicedMs(windowMs: 300.0)
                    let minBytes = 2400 /* 24kHz mono PCM16 ≒ 50ms */ * 6 // ≒ 300ms
                    
                    // ✅ VADアイドル保険のcommitを厳格に抑制：次の条件をすべて満たす時のみ実行
                    // 音声レベルが低い場合でも検出できるように、voicedMsの閾値を緩和（250ms → 100ms）
                    guard self.turnState == .collecting,
                          !self.hasCommittedThisTurn,
                          self.hasAppendedSinceClear,
                          voicedMs >= 100.0,  // ✅ だいたい100ms以上の有声が必要（低音声レベルでも検出可能にする）
                          self.bufferedBytes >= minBytes else {
                        print("⚠️ RealtimeClient: VADアイドル保険のcommitスキップ: state=\(self.turnState), committed=\(self.hasCommittedThisTurn), appended=\(self.hasAppendedSinceClear), voicedMs=\(String(format: "%.1f", voicedMs)), bytes=\(self.bufferedBytes)/\(minBytes) - idle_guard")
                        return
                    }
                    // ✅ speech_startedから5秒以上経過している場合、音声データが継続的に送信されていても強制的にcommitを送る
                    print("⚠️ RealtimeClient: speech_startedから\(String(format: "%.2f", speechElapsed))秒経過したため、強制的にcommitを送信（STTイベントを発火させるため - idle_guard）")
                    print("📊 RealtimeClient: 最後のappendからの経過: \(String(format: "%.2f", elapsed))秒, 累積バイト: \(self.bufferedBytes)bytes, 必要: \(self.minBytesForCommit)bytes")
                    self.stopVADIdleMonitoring()
                    self.speechStartedAt = nil
                    
            Task { [weak self] in
                        guard let self = self else { return }
                        print("📤 RealtimeClient: VADアイドル保険の手動commit送信開始（speech_startedから5秒経過 - idle_guard）")
                        do {
                            try await self.send(json: ["type": "input_audio_buffer.commit"])
                            // ✅ ターン状態管理：強制commit実行後
                            self.hasCommittedThisTurn = true
                            self.turnState = .committed
                            // ✅ 注意: bufferedBytesはリセットしない（サーバー側が処理中）
                            // ✅ 注意: clearは送らない（transcription.completedでのみ送る）
                            print("✅ RealtimeClient: VADアイドル保険のcommit送信成功（STTイベントを待機中...）")
                        } catch {
                            print("❌ RealtimeClient: VADアイドル保険の手動commit失敗 - \(error)")
                        }
                    }
                    return  // ✅ タイマーを停止
                } else if elapsed > 3.0 {
                    // ✅ ログのみ出力（無音が続いているが、speech_startedから5秒経過していない場合）
                    if checkCount % 10 == 0 {
                        print("📊 RealtimeClient: 無音が\(String(format: "%.2f", elapsed))秒続いています（音声認識モード：speech_startedから\(String(format: "%.2f", speechElapsed))秒経過）")
                    }
                }
            } else {
                print("⚠️ RealtimeClient: VADアイドル監視 #\(checkCount) - lastAppendAtがnil")
            }
        }
        
        timer.resume()
        vadIdleTimer = timer
        print("✅ RealtimeClient: VADアイドル監視タイマー登録完了（DispatchSourceTimer）")
    }
    
    // ✅ VADの「詰まり」対策：アイドル監視を停止
    private func stopVADIdleMonitoring() {
        if let timer = vadIdleTimer {
            print("📊 RealtimeClient: VADアイドル監視を停止")
            timer.cancel()
            vadIdleTimer = nil
        }
    }

    public func finishSession() async throws {
        state = .closing
        // OpenAI Realtime APIでは session.finish は不要
        stopPing()
        // ✅ VADの「詰まり」対策：タイマーを停止
        stopVADIdleMonitoring()
        // ✅ 短文聞き返しタイマーを停止
        clarificationTimer?.cancel()
        clarificationTimer = nil
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
        activeResponseId = nil  // ✅ アクティブレスポンスIDをクリア
        userRequestedResponse = false
        suppressCurrentResponseAudio = false
        turnAccumulatedMs = 0
        bufferedBytes = 0  // ✅ 空コミット対策：バッファをリセット
        lastAppendAt = nil
        speechStartedAt = nil  // ✅ speech_startedの時刻をクリア
        interimTranscripts.removeAll()  // ✅ 暫定テキストをクリア
        lastCompletedTranscript = nil
        lastCompletedTime = nil
        
        // ✅ ターン状態管理：セッション終了時のクリーンアップ
        stopCompletedWatchdog()
        turnState = .cleared
        hasAppendedSinceClear = false
        hasCommittedThisTurn = false
        clearSentForItem.removeAll()
        sessionIsUpdated = false  // ✅ セッション確立フラグをリセット
        audioInputVerified = false  // ✅ 音声入力確認フラグをリセット
        audioMeter.reset()  // ✅ 音声レベル測定をリセット
        audioDeltaCount = 0  // ✅ AI応答音声デルタ受信のログ用カウンターをリセット
        
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
            // ✅ OpenAI Realtimeはバイナリ多重化をしていません。音声はJSONの response.audio.delta にbase64で来ます。
            // .dataフレームの先頭1バイトで種別を判定（0xA0/0xB0）は削除。JSONのみに統一。
            print("⚠️ RealtimeClient: 予期しないバイナリデータ受信 - \(data.count) bytes（OpenAI RealtimeはJSONのみ）")
        case .string(let text):
            // 長いBase64データはログに出力しない
            let logText = text.count > 100 ? String(text.prefix(100)) + "..." : text
            print("📨 RealtimeClient: JSONメッセージ受信 - \(logText)")
            if let d = text.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
               let type = obj["type"] as? String {
                print("📨 RealtimeClient: メッセージタイプ - \(type)")
                
                // ✅ STT関連イベントの有無を確認（より包括的に）
                let sttEventTypes = [
                    "conversation.item.input_audio_transcription.delta",
                    "conversation.item.input_audio_transcription.completed",
                    "input_audio_buffer.committed",
                    "input_audio_buffer.speech_started",
                    "input_audio_buffer.speech_stopped"
                ]
                if sttEventTypes.contains(type) {
                    print("✅ RealtimeClient: STT関連イベント検出 - \(type)")
                }
                
                // ✅ STT関連のイベントがitemオブジェクト内に含まれている可能性を確認
                if let item = obj["item"] as? [String: Any],
                   let itemType = item["type"] as? String,
                   itemType.contains("input_audio_transcription") {
                    print("⚠️ RealtimeClient: STT関連のイベントがitemオブジェクト内にあります - type: \(type), itemType: \(itemType)")
                    print("📊 RealtimeClient: item詳細 - \(item)")
                }
                
                switch type {
                case "response.output_text.delta":
                    // ✅ 公式イベント名：response.output_text.delta（AI応答のテキストデルタ）
                    // ✅ response_idが設定されていない場合は設定を試みる
                    let responseId = obj["response_id"] as? String ?? activeResponseId
                    if activeResponseId == nil, let id = responseId {
                        activeResponseId = id
                        print("✅ RealtimeClient: response.output_text.delta - response_idを設定: \(id)")
                    }
                    
                    if let s = obj["delta"] as? String, let id = responseId {
                        // ✅ response_idごとにバッファに集約（重複表示を防ぐ）
                        streamText[id, default: ""] += s
                        print("📝 RealtimeClient: AI応答テキストデルタ受信 - 「\(s)」, response_id: \(id), 累積: 「\(streamText[id] ?? "")」")
                        // ✅ UIに送信（response.output_text.deltaのみ使用）
                        textContinuation?.yield(s)
                    } else {
                        print("⚠️ RealtimeClient: response.output_text.delta - deltaまたはresponse_idが見つかりません")
                    }
                case "response.text.delta":
                    // ✅ 旧仕様：無視（重複表示を防ぐため、新仕様 response.output_text.delta のみ使用）
                    print("⚠️ RealtimeClient: response.text.delta（旧仕様） - 無視（新仕様 response.output_text.delta を使用）")
                    break
                case "response.audio_transcript.delta":
                    // ✅ 非公式イベント：互換性のため処理（サーバー側が旧仕様を送信している場合がある）
                    // ✅ response_idが設定されていない場合は設定を試みる
                    let responseId = obj["response_id"] as? String ?? activeResponseId
                    if activeResponseId == nil, let id = responseId {
                        activeResponseId = id
                        print("✅ RealtimeClient: response.audio_transcript.delta - response_idを設定: \(id)")
                    }
                    
                    if let s = obj["delta"] as? String, let id = responseId {
                        // ✅ response_idごとにバッファに集約（重複表示を防ぐ）
                        streamText[id, default: ""] += s
                        print("📝 RealtimeClient: AI応答テキストデルタ受信（非公式イベント） - 「\(s)」, response_id: \(id), 累積: 「\(streamText[id] ?? "")」")
                        // ✅ UIに送信
                        textContinuation?.yield(s)
                    } else {
                        print("⚠️ RealtimeClient: response.audio_transcript.delta - deltaまたはresponse_idが見つかりません")
                    }
                    break
                case "response.output_audio.delta":
                    // ✅ 公式イベント名：response.output_audio.delta（response.audio.delta は旧仕様）
                    // ✅ response_idが設定されていない場合は設定を試みる
                    if activeResponseId == nil, let responseId = obj["response_id"] as? String {
                        activeResponseId = responseId
                        print("✅ RealtimeClient: response.output_audio.delta - response_idを設定: \(responseId)")
                    }
                    
                    // ✅ バージイン後のTTSは再生しない（キャンセル後の音声は破棄）
                    if suppressCurrentResponseAudio {
                        print("📊 RealtimeClient: response.output_audio.delta - 音声再生をスキップ（suppressCurrentResponseAudio=true）")
                        print("⚠️ RealtimeClient: 音声再生がスキップされています - activeResponseId: \(activeResponseId ?? "nil"), suppressCurrentResponseAudio: \(suppressCurrentResponseAudio)")
                        return
                    }
                    if let b64 = obj["delta"] as? String ?? obj["audio"] as? String,
                       let data = Data(base64Encoded: b64) {
                        // ✅ AI応答音声のデルタを受信（PCM16 @ 24kHz / mono）
                        // ✅ 詳細ログ（最初の10回と、その後100回に1回程度）
                        audioDeltaCount += 1
                        let shouldLog = audioDeltaCount <= 10 || Int.random(in: 0..<100) == 0
                        if shouldLog {
                            print("🔊 RealtimeClient: AI応答音声デルタ受信 #\(audioDeltaCount) - \(data.count) bytes (PCM16 @ 24kHz / mono), activeResponseId: \(activeResponseId ?? "nil"), suppressCurrentResponseAudio: \(suppressCurrentResponseAudio)")
                        }
                        audioContinuation?.yield(data)
                        // ✅ 参考プロジェクトパターン：AI音声受信時に録音停止をトリガー
                        onAudioDeltaReceived?()
                    } else {
                        print("⚠️ RealtimeClient: response.output_audio.delta - データのデコードに失敗（delta/audioが見つかりません）")
                        print("📊 RealtimeClient: response.output_audio.delta - イベント内容: \(obj)")
                    }
                case "response.audio.delta":
                    // ✅ 旧仕様：互換性のため処理（サーバー側が旧仕様を送信している場合がある）
                    // ✅ response_idが設定されていない場合は設定を試みる
                    if activeResponseId == nil, let responseId = obj["response_id"] as? String {
                        activeResponseId = responseId
                        print("✅ RealtimeClient: response.audio.delta - response_idを設定: \(responseId)")
                    }
                    
                    // ✅ バージイン後のTTSは再生しない（キャンセル後の音声は破棄）
                    if suppressCurrentResponseAudio {
                        print("📊 RealtimeClient: response.audio.delta - 音声再生をスキップ（suppressCurrentResponseAudio=true）")
                        print("⚠️ RealtimeClient: 音声再生がスキップされています - activeResponseId: \(activeResponseId ?? "nil"), suppressCurrentResponseAudio: \(suppressCurrentResponseAudio)")
                        return
                    }
                    if let b64 = obj["delta"] as? String ?? obj["audio"] as? String,
                       let data = Data(base64Encoded: b64) {
                        // ✅ AI応答音声のデルタを受信（PCM16 @ 24kHz / mono）
                        // ✅ 詳細ログ（最初の10回と、その後100回に1回程度）
                        audioDeltaCount += 1
                        let shouldLog = audioDeltaCount <= 10 || Int.random(in: 0..<100) == 0
                        if shouldLog {
                            print("🔊 RealtimeClient: AI応答音声デルタ受信（旧仕様） #\(audioDeltaCount) - \(data.count) bytes (PCM16 @ 24kHz / mono), activeResponseId: \(activeResponseId ?? "nil"), suppressCurrentResponseAudio: \(suppressCurrentResponseAudio)")
                        }
                        audioContinuation?.yield(data)
                        // ✅ 参考プロジェクトパターン：AI音声受信時に録音停止をトリガー
                        onAudioDeltaReceived?()
                    } else {
                        print("⚠️ RealtimeClient: response.audio.delta - データのデコードに失敗（delta/audioが見つかりません）")
                        print("📊 RealtimeClient: response.audio.delta - イベント内容: \(obj)")
                    }
                    break
                case "response.done":
                    // ✅ アクティブレスポンスIDを厳密にクリア（response.cancelの送信制御のため）
                    let previousId = activeResponseId
                    if let id = previousId {
                        // ✅ UIの重複表示を止める：response_idごとのバッファをクリア
                        streamText.removeValue(forKey: id)
                        print("✅ RealtimeClient: レスポンス完了 - ID: \(id)（activeResponseIdをクリア、streamTextもクリア）")
                    } else {
                        print("✅ RealtimeClient: レスポンス完了 - 前のID: nil（activeResponseIdをクリア）")
                    }
                    activeResponseId = nil
                    if let responseId = obj["response_id"] as? String {
                        print("📊 RealtimeClient: response.done詳細 - response_id: \(responseId)")
                    }
                    
                    // ✅ エラーハンドリング：status == "failed"の場合にエラーメッセージを処理
                    if let response = obj["response"] as? [String: Any],
                       let status = response["status"] as? String,
                       status == "failed" {
                        var errorMessage: String? = nil
                        if let statusDetails = response["status_details"] as? [String: Any],
                           let error = statusDetails["error"] as? [String: Any],
                           let message = error["message"] as? String {
                            errorMessage = message
                        }
                        let finalMessage = errorMessage ?? "レスポンス生成に失敗しました"
                        print("❌ RealtimeClient: response.done - レスポンス生成失敗 - \(finalMessage)")
                        // ✅ エラーコールバックを呼び出す（UI側でエラーメッセージを表示）
                        onError?(NSError(domain: "RealtimeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: finalMessage]))
                        // ✅ エラー時は録音を停止
                    onResponseDone?()
                    break
                    }
                    
                    userRequestedResponse = false  // ✅ フラグをリセット
                    suppressCurrentResponseAudio = false  // ✅ フラグをリセット
                    print("📊 RealtimeClient: response.done - フラグリセット完了")
                    
                    // ✅ 次のターンの準備：音声バッファをクリアして次の入力を待つ
                    // ✅ speech_startedが立っている間はclearを送らない、立っていない時は必ず送る
                    // ✅ 二重送信/取りこぼしを防ぐためフラグを明確化
                    if speechStartedAt == nil {
                        Task { [weak self] in
                            guard let self = self else { return }
                            do {
                                try await self.send(json: ["type": "input_audio_buffer.clear"])
                                print("✅ RealtimeClient: response.done - 音声バッファをクリア（次のターン準備 - speech_startedが立っていないため）")
                                // ✅ ターン状態管理：clear送信後、毎回リセット
                                self.bufferedBytes = 0
                                self.turnAccumulatedMs = 0
                                self.turnState = .cleared
                                self.hasAppendedSinceClear = false
                                self.hasCommittedThisTurn = false
                                self.clearSentForItem.removeAll()  // ✅ 次のターンのためにクリア
                                self.audioMeter.reset()  // ✅ 音声レベル測定をリセット
                            } catch {
                                print("⚠️ RealtimeClient: 音声バッファクリア失敗 - \(error)")
                            }
                        }
                    } else {
                        print("⚠️ RealtimeClient: response.done - 音声バッファは保持（speech_startedが立っているため、サーバー側が処理中）")
                    }
                    onResponseDone?()
                    break
                case "response.created":
                    // ✅ アクティブレスポンスIDを保存（複数の場所から取得を試みる）
                    var responseId: String? = nil
                    if let id = obj["response_id"] as? String {
                        responseId = id
                    } else if let response = obj["response"] as? [String: Any],
                              let id = response["id"] as? String {
                        responseId = id
                    } else if let response = obj["response"] as? [String: Any],
                              let id = response["response_id"] as? String {
                        responseId = id
                    }
                    
                    if let id = responseId {
                        // ✅ アクティブレスポンスIDを厳密にトラッキング（response.cancelの送信制御のため）
                        activeResponseId = id
                        // ✅ UIの重複表示を止める：新しいresponse_idのバッファを初期化
                        streamText[id] = ""
                        print("✅ RealtimeClient: response.created - ID: \(id)（activeResponseIdを設定、streamTextを初期化）")
                        print("📊 RealtimeClient: response.created - 以降、response.output_text.delta / response.output_audio.delta を待機中...")
                    } else {
                        print("⚠️ RealtimeClient: response.created - response_idが見つかりません")
                        print("📊 RealtimeClient: response.created - イベント内容: \(obj)")
                        // フォールバック：response_idがなくても、後続のresponse.output_audio.deltaで設定する
                    }
                    suppressCurrentResponseAudio = false  // ✅ 音声を許可
                    print("📊 RealtimeClient: response.created - 音声再生を許可（suppressCurrentResponseAudio = false）")
                    print("📊 RealtimeClient: response.created - 以降のresponse.output_audio.deltaは再生されます")
                    // ✅ 新しい応答が作成されたことを通知（テキストをクリアするため）
                    onResponseCreated?()
                    break
                case "response.output_audio.done":
                    // ✅ 公式イベント名：response.output_audio.done（音声ストリーミング完了）
                    print("✅ RealtimeClient: response.output_audio.done 受信（音声ストリーミング完了）")
                    break
                case "response.audio.done":
                    // ✅ 旧仕様との互換性のため、response.audio.done も処理（非推奨）
                    print("⚠️ RealtimeClient: response.audio.done（旧仕様） - 音声ストリーミング完了")
                    break
                case "response.output_text.done":
                    // ✅ 公式イベント名：response.output_text.done（音声の文字起こし完了）
                    print("✅ RealtimeClient: response.output_text.done 受信")
                    // ✅ 確定トランスクリプトを取得
                    if let transcript = obj["text"] as? String ?? obj["transcript"] as? String {
                        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("📝 RealtimeClient: response.output_text.done - 確定トランスクリプト: 「\(trimmed)」")
                        // ✅ 確定トランスクリプトをUIに送信
                        textContinuation?.yield(transcript)
                        
                    } else {
                        print("ℹ️ RealtimeClient: response.output_text.done - text/transcriptは含まれていません")
                    }
                    break
                case "response.audio_transcript.done":
                    // ✅ 非公式イベント：無視（重複表示を防ぐため、新仕様 response.output_text.done のみ使用）
                    print("⚠️ RealtimeClient: response.audio_transcript.done（非公式イベント） - 無視（新仕様 response.output_text.done を使用）")
                    break
                case "response.content_part.added",
                     "response.content_part.done",
                     "response.output_item.added",
                     "response.output_item.done",
                     "conversation.item.created":
                    // 正常イベント - 何もしないでもOK
                    break
                case "rate_limits.updated":
                    // ✅ レート制限更新
                    if let rateLimits = obj["rate_limits"] as? [[String: Any]] {
                        print("📊 RealtimeClient: rate_limits.updated 受信 - \(rateLimits.count)件の制限")
                    }
                    break
                case "input_audio_buffer.speech_started":
                    print("🎤 RealtimeClient: 音声入力開始")
                    if let audioStartMs = obj["audio_start_ms"] as? Double {
                        print("📊 RealtimeClient: speech_started詳細 - audio_start_ms: \(audioStartMs)ms")
                        // ✅ デバッグ：audio_start_msが示す「音声開始時刻」と、実際に送信したデータの時刻を比較
                        let currentAccumulatedMs = turnAccumulatedMs
                        let expectedStartMs = currentAccumulatedMs - audioStartMs
                        if expectedStartMs < 0 {
                            // ✅ INFOに格下げ（prefix_padding_msとサーバ側先読みの影響で正常系でも起こる）
                            print("ℹ️ RealtimeClient: 音声開始時刻の不一致 - audio_start_ms(\(audioStartMs)ms)が累積時間(\(currentAccumulatedMs)ms)より大きい（prefix_padding_ms: 300で補正済み、正常系の可能性あり）")
                        } else {
                            print("📊 RealtimeClient: 音声開始時刻の整合性 - audio_start_ms: \(audioStartMs)ms, 累積時間: \(currentAccumulatedMs)ms, 期待される開始時刻: \(expectedStartMs)ms（prefix_padding_ms: 300で補正済み）")
                        }
                    }
                    // ✅ ターン状態管理：speech_started受信時
                    turnState = .collecting
                    hasAppendedSinceClear = false  // ここからの追加でtrueになる
                    hasCommittedThisTurn = false
                    
                    // ✅ speech_startedが来る前に送信された音声データはサーバー側で処理されているため、
                    // ✅ クライアント側では累積時間とバッファサイズをリセットせず、継続してカウントする
                    // ✅ ただし、speech_started時点からの累積を正確に追跡するため、ここでリセットする
                    // ✅ サーバー側はspeech_startedを発火する前に送信された音声も処理しているため、
                    // ✅ クライアント側では新しいターンとして扱うが、バッファはリセットしない（サーバー側が処理している）
                    let previousTurnAccumulatedMs = turnAccumulatedMs
                    let previousBufferedBytes = bufferedBytes
                    // ✅ 注意: bufferedBytesはリセットしない（サーバー側が処理しているため）
                    // ✅ ただし、speech_started時点からの累積を追跡するため、turnAccumulatedMsはリセットする
                    turnAccumulatedMs = 0  // ✅ 録音開始時に累積時間をリセット（speech_started時点からの追跡）
                    appendCount = 0  // ✅ ログカウンターもリセット
                    let now = Date()
                    lastAppendAt = now  // ✅ VADの「詰まり」対策：開始時刻を記録
                    speechStartedAt = now  // ✅ speech_startedの時刻を記録
                    print("📊 RealtimeClient: speech_started - バッファ状態: 前ターン累積時間: \(String(format: "%.1f", previousTurnAccumulatedMs))ms, 前ターン累積バイト: \(previousBufferedBytes)bytes, 新ターン開始（bufferedBytesは保持: \(bufferedBytes)bytes）")
                    print("📊 RealtimeClient: speech_started - 以降、STTイベント（conversation.item.input_audio_transcription.* または input_audio_buffer.committed）を待機中...")
                    // ✅ バージイン（ユーザー発話を検知したらAI応答を即中断）
                    suppressCurrentResponseAudio = true
                    // ✅ response.cancel の送信を有声判定つきに（直近300msに150ms以上の有声がある時だけ）
                    // ✅ これで「ちょっとした環境ノイズ」では返答を止めません。実際に話したときだけバージインします
                    let voicedMs = audioMeter.voicedMs(windowMs: 300.0)
                    if let responseId = activeResponseId, voicedMs >= 150.0 {
                        print("📊 RealtimeClient: アクティブレスポンス検出 - ID: \(responseId), 有声時間: \(String(format: "%.1f", voicedMs))ms（150ms以上）, response.cancel送信")
                        // ✅ activeResponseIdを即座にクリアして重複送信を防ぐ
                        activeResponseId = nil
                        Task { [weak self] in
                            guard let self = self else { return }
                            do {
                                try await self.send(json: ["type": "response.cancel"])
                                print("✅ RealtimeClient: ユーザー発話検知でAI応答を中断 (ID: \(responseId))")
                            } catch {
                                // ✅ cancel_not_active エラーは握りつぶしてOK（競合しがち）
                                print("ℹ️ RealtimeClient: response.cancel エラー（無視） - \(error)")
                            }
                        }
                    } else if let responseId = activeResponseId {
                        print("ℹ️ RealtimeClient: アクティブレスポンスありだが有声判定不十分 - ID: \(responseId), 有声時間: \(String(format: "%.1f", voicedMs))ms（150ms未満）, response.cancel をスキップ（環境ノイズの可能性）")
                    } else {
                        print("ℹ️ RealtimeClient: アクティブレスポンスなし - response.cancel をスキップ")
                    }
                    // ✅ VADの「詰まり」対策：アイドル監視を開始
                    print("📊 RealtimeClient: VADアイドル監視を開始")
                    startVADIdleMonitoring()
                    onSpeechStarted?()
                case "input_audio_buffer.speech_stopped":
                    // ✅ speech_stoppedでは何もしない（commit/clearは送らない）
                    print("🎤 RealtimeClient: 音声入力終了 - speech_stopped 受信")
                    if let audioEndMs = obj["audio_end_ms"] as? Double {
                        print("📊 RealtimeClient: speech_stopped詳細 - audio_end_ms: \(audioEndMs)ms")
                    }
                    print("📊 RealtimeClient: speech_stopped - 累積時間: \(String(format: "%.1f", turnAccumulatedMs))ms, 累積バイト: \(bufferedBytes)bytes")
                    // ✅ VADの「詰まり」対策：サーバが正常に区切ったなら保険は終了
                    stopVADIdleMonitoring()
                    speechStartedAt = nil  // ✅ speech_startedの時刻をクリア
                    print("📊 RealtimeClient: VADアイドル監視を停止")
                    onSpeechStopped?()
                    // ✅ 注意: commit/clearは送らない（input_audio_buffer.committed / transcription.completedでのみ処理）
                case "input_audio_buffer.committed":
                    // ✅ 音声バッファがコミットされ、サーバーが音声認識を開始
                    // ✅ server_vad.create_response: true の場合、サーバーが自動的に応答を生成する
                    print("✅ RealtimeClient: input_audio_buffer.committed 受信（サーバーが音声認識を開始、create_response: true の場合は自動応答を生成）")
                    
                    // ✅ ターン状態管理：committed受信で必ずcommittedに遷移
                    guard turnState == .collecting, !hasCommittedThisTurn else {
                        print("⚠️ RealtimeClient: input_audio_buffer.committed - 状態が不正のためスキップ: state=\(turnState), committed=\(hasCommittedThisTurn)")
                        break
                    }
                    hasCommittedThisTurn = true
                    turnState = .committed
                    
                    // ✅ completed待ちのwatchdogを開始（1.5〜2.0秒）
                    startCompletedWatchdog(timeoutSec: 2.0)
                    
                    // ✅ トランスクリプトがあれば表示（通常はconversation.item.input_audio_transcription.completedに含まれる）
                    if let transcript = obj["transcript"] as? String {
                        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("🎤 ユーザーの発言（確定）: 「\(trimmed)」")
                        inputTextContinuation?.yield(transcript)
                        onInputCommitted?(transcript)
                    } else {
                        print("ℹ️ RealtimeClient: input_audio_buffer.committed - transcriptは含まれていません（通常はconversation.item.input_audio_transcription.completedに含まれます）")
                    }
                    // ✅ 音声認識モード：AI応答は生成しない
                case "input_audio_buffer.cleared":
                    // ✅ 正常イベント（バッファクリア）
                    print("ℹ️ RealtimeClient: input_audio_buffer.cleared")
                    // ✅ ターン状態管理：cleared受信時、念のためturnStateをclearedに寄せる
                    turnState = .cleared
                    // ✅ 注意: ここでcommitは絶対に送らない
                    turnAccumulatedMs = 0  // ✅ 累積時間をリセット
                    bufferedBytes = 0  // ✅ 空コミット対策：バッファをリセット
                    hasAppendedSinceClear = false
                    hasCommittedThisTurn = false
                    print("📊 RealtimeClient: input_audio_buffer.cleared - バッファをリセット、ターン状態をclearedに設定")
                    break
                case "conversation.item.input_audio_transcription.delta":
                    // ✅ 新イベント名：ユーザー入力側のSTTデルタ（部分テキスト表示用）
                    let itemId = (obj["item_id"] as? String) ?? "unknown"
                    if let delta = (obj["delta"] as? String) ?? (obj["text"] as? String) {
                        // ✅ item_idごとに暫定テキストを連結
                        let current = interimTranscripts[itemId] ?? ""
                        let updated = current + delta
                        interimTranscripts[itemId] = updated
                        
                        print("🎤 ユーザーの発言（部分認識）: 「\(delta)」 (item_id: \(itemId), 暫定全文: 「\(updated)」)")
                        // ✅ 連結した暫定テキストをUIに送信
                        inputTextContinuation?.yield(updated)
                    } else {
                        print("⚠️ RealtimeClient: conversation.item.input_audio_transcription.delta - delta/textが見つかりません")
                        print("📊 RealtimeClient: イベント内容 - \(obj)")
                    }
                    break
                case "conversation.item.input_audio_transcription.completed":
                    // ✅ 新イベント名：ユーザー入力側のSTT確定（完了テキスト）
                    let itemId = (obj["item_id"] as? String) ?? "unknown"
                    
                    // ✅ completed待ちのwatchdogを停止
                    stopCompletedWatchdog()
                    
                    if let t = (obj["transcript"] as? String) ?? (obj["text"] as? String) {
                        let trimmed = t.trimmingCharacters(in: .whitespacesAndNewlines)
                        print("🎤 ユーザーの発言（確定）: 「\(trimmed)」 (item_id: \(itemId))")
                        print("📊 RealtimeClient: 発言詳細 - 文字数: \(trimmed.count)文字, activeResponseId: \(activeResponseId ?? "nil")")
                        
                        // ✅ 暫定テキストをクリア
                        interimTranscripts.removeValue(forKey: itemId)
                        
                        // ✅ 確定テキストをUIに送信
                        inputTextContinuation?.yield(t)
                        onInputCommitted?(t)
                        
                        // ✅ 音声認識完了（サーバーが自動応答を生成する場合は、response.doneの後にclearを送る）
                        print("✅ RealtimeClient: 音声認識完了 - 「\(trimmed)」 (文字数: \(trimmed.count)文字)")
                        print("📊 RealtimeClient: transcription.completed - サーバーが自動応答を生成する場合は、response.doneの後にinput_audio_buffer.clearを送信します")
                        
                        // ✅ ターン状態管理：transcription.completed受信時、item_idを記録（clearはresponse.doneの後に送信）
                        guard turnState == .committed,
                              hasCommittedThisTurn else {
                            print("⚠️ RealtimeClient: transcription.completed - 状態が不正のためスキップ: state=\(turnState), committed=\(hasCommittedThisTurn)")
                            break
                        }
                        
                        // ✅ clearは送信しない（response.doneの後に送信する）
                        // ✅ item_idを記録して、response.doneの後にclearを送信する際の重複チェックに使用
                        clearSentForItem.insert(itemId)
                    } else {
                        print("⚠️ RealtimeClient: conversation.item.input_audio_transcription.completed - transcript/textが見つかりません")
                        print("📊 RealtimeClient: イベント内容 - \(obj)")
                    }
                    break
                case "ping":
                    print("🏓 RealtimeClient: Ping受信 - Pong送信")
                    Task { try? await self.send(json: ["type": "pong"]) }
                case "session.created":
                    print("✅ RealtimeClient: セッション作成完了")
                    // ✅ 記事のフローに合わせて、session.createdの後にsession.updateを送信
                    Task { [weak self] in
                        guard let self = self else { return }
                        do {
                            try await self.sendSessionUpdate()
                            print("✅ RealtimeClient: session.created - session.update送信完了")
                        } catch {
                            print("❌ RealtimeClient: session.created - session.update送信失敗 - \(error)")
                            self.onError?(error)
                        }
                    }
                case "session.updated":
                    print("✅ RealtimeClient: session.updated 受信（session.update 成功）")
                    // ✅ セッション確立フラグを立てる（これ以降appendを送信可能）
                    sessionIsUpdated = true
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
                    print("📊 RealtimeClient: イベント内容（全文） - \(obj)")
                    // ✅ STT関連のイベントが含まれているか確認
                    if let item = obj["item"] as? [String: Any],
                       let itemType = item["type"] as? String,
                       itemType.contains("input_audio_transcription") {
                        print("⚠️ RealtimeClient: STT関連のイベントが未知タイプとして処理されています - itemType: \(itemType)")
                        print("📊 RealtimeClient: item詳細 - \(item)")
                    }
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
        
        // ✅ 切断時のコールバックを確実に発火（onDisconnect相当）
        // 注意: 現在の実装にはonDisconnectコールバックがないため、onStateChangeで通知
        
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
    
    deinit {
        // ✅ 切断時のクリーンアップを確実に実行
        wsTask?.cancel(with: .goingAway, reason: nil)
        stopPing()
        stopVADIdleMonitoring()
        stopCompletedWatchdog()
        clarificationTimer?.cancel()
        print("🧹 RealtimeClient: deinit - リソースクリーンアップ完了")
    }
    
    // ✅ completed待ちのwatchdog（committedのままcompletedが来ない場合に保険でclear）
    private func startCompletedWatchdog(timeoutSec: TimeInterval) {
        stopCompletedWatchdog()
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.main)
        timer.schedule(deadline: .now() + timeoutSec)
        timer.setEventHandler { [weak self] in
            guard let self = self else { return }
            // ✅ watchdogの強化：最低条件を満たすときだけ発火
            // ① committed済み ② 直近に有声 ③ bufferedBytes >= 最低量
            let voicedMs = self.audioMeter.voicedMs(windowMs: 300.0)
            let minBytes = 2400 /* 24kHz mono PCM16 ≒ 50ms */ * 6 // ≒ 300ms
            
            // 音声レベルが低い場合でも検出できるように、voicedMsの閾値を緩和（200ms → 50ms）
            if self.turnState == .committed,
               self.hasCommittedThisTurn,
               voicedMs >= 50.0,  // ✅ だいたい50ms以上の有声が必要（低音声レベルでも検出可能にする）
               self.bufferedBytes >= minBytes {
                print("⚠️ RealtimeClient: completed待ちのwatchdog発火 - transcription.completedが来なかったため、保険でclearを送信（voicedMs: \(String(format: "%.1f", voicedMs)), bytes: \(self.bufferedBytes)）")
                Task { [weak self] in
                    guard let self = self else { return }
                    do {
                        try await self.send(json: ["type": "input_audio_buffer.clear"])
                        print("✅ RealtimeClient: watchdog - input_audio_buffer.clear送信完了")
                        // ✅ ターン状態管理：clear送信後
                        self.bufferedBytes = 0
                        self.turnAccumulatedMs = 0
                        self.turnState = .cleared
                        self.hasAppendedSinceClear = false
                        self.hasCommittedThisTurn = false
                        self.clearSentForItem.removeAll()
                        self.audioMeter.reset()  // ✅ 音声レベル測定をリセット
                    } catch {
                        print("❌ RealtimeClient: watchdog - clear送信失敗 - \(error)")
                    }
                }
            } else {
                print("⚠️ RealtimeClient: completed待ちのwatchdog - 条件未満のためスキップ: state=\(self.turnState), committed=\(self.hasCommittedThisTurn), voicedMs=\(String(format: "%.1f", voicedMs)), bytes=\(self.bufferedBytes)/\(minBytes)")
            }
        }
        pendingCompletedWatchdog = timer
        timer.resume()
    }
    
    private func stopCompletedWatchdog() {
        pendingCompletedWatchdog?.cancel()
        pendingCompletedWatchdog = nil
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
            throw NSError(domain: "RealtimeClient", code: -1, userInfo: [NSLocalizedDescriptionKey: "WebSocketタスクが存在しません"])
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
        
        // ✅ iOSのURLSessionWebSocketTaskはsend(_:completionHandler:)で、async/await版はないため、withCheckedThrowingContinuationでラップ
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ws.send(.string(jsonString)) { error in
                if let error = error {
                    cont.resume(throwing: error)
                } else {
                    cont.resume()
                }
            }
        }
    }

    private func sendBinary(type: UInt8, payload: Data) async throws {
        var buf = Data([type])
        buf.append(payload)
        guard let ws = wsTask else { return }
        try await ws.send(.data(buf))
    }
}
