import Foundation
import AVFoundation
import Support
import Services

/// OpenAI TTS APIを使用した音声合成エンジン
@MainActor
public final class TTSEngine: TTSEngineProtocol {
    private let player: PlayerNodeStreamer
    private let apiKey: String
    private let apiBase: URL
    private var currentRequestId: String?

    public init(player: PlayerNodeStreamer) {
        self.player = player
        self.apiKey = AppConfig.openAIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = URL(string: AppConfig.apiBase) ?? URL(string: "https://api.openai.com")!
        if base.path.contains("/v1") {
            self.apiBase = base.appendingPathComponent("audio/speech")
        } else {
            self.apiBase = base.appendingPathComponent("v1").appendingPathComponent("audio/speech")
        }
    }

    /// テキストを音声に変換して再生
    public func speak(text: String, requestId: String = "unknown") async throws {
        print("🎙️ TTSEngine[\(requestId)]: speak() 開始 - text=\"\(text)\"")

        guard currentRequestId == requestId else {
            print("⚠️ TTSEngine[\(requestId)]: 非アクティブなリクエストのため無視")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("⚠️ TTSEngine[\(requestId)]: テキストが空です")
            return
        }

        guard !apiKey.isEmpty else {
            print("⚠️ TTSEngine[\(requestId)]: APIキー未設定")
            throw TTSError.apiKeyMissing
        }

        // トークン数チェック（簡易）
        if trimmed.count > 200 {
            print("⚠️ TTSEngine[\(requestId)]: テキストが長すぎます (\(trimmed.count)文字)")
            throw TTSError.textTooLong
        }

        // OpenAI TTS API リクエスト
        struct SpeechPayload: Encodable {
            let model: String
            let voice: String
            let input: String
            let response_format: String
        }

        let payload = SpeechPayload(
            model: "tts-1-hd",
            voice: "nova",
            input: trimmed,
            response_format: "pcm"  // 24kHz/mono/PCM16
        )

        var request = URLRequest(url: apiBase)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("audio/pcm, audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(payload)

        print("📡 TTSEngine[\(requestId)]: TTS API呼び出し開始 - model=\(payload.model), voice=\(payload.voice), text=\"\(trimmed.prefix(30))...\"")

        // API呼び出し
        let (data, response) = try await URLSession.shared.data(for: request)

        guard currentRequestId == requestId else {
            print("⚠️ TTSEngine[\(requestId)]: 再生キャンセル済み（API完了後）")
            return
        }

        guard let http = response as? HTTPURLResponse else {
            print("⚠️ TTSEngine[\(requestId)]: 無効なレスポンス")
            throw TTSError.invalidResponse
        }

        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? "(binary)"
            print("❌ TTSEngine[\(requestId)]: HTTP \(http.statusCode) - body: \(body)")
            throw TTSError.httpError(http.statusCode)
        }

        let contentType = http.value(forHTTPHeaderField: "Content-Type")
        print("✅ TTSEngine[\(requestId)]: TTS API成功 - status=\(http.statusCode), bytes=\(data.count), contentType=\(contentType ?? "unknown")")

        // PCM16データに正規化
        guard let pcmData = try normalizeToPCM16_24kMono(data: data, contentType: contentType) else {
            let head = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
            print("⚠️ TTSEngine: 音声データのデコード失敗 - head[16]=[\(head)]")
            throw TTSError.decodeError
        }

        print("✅ TTSEngine[\(requestId)]: 音声データ準備完了 - size=\(pcmData.count) bytes")

        // ✅ 末尾の音切れ対策：短い無音を足す（24kHz/mono/PCM16）
        let tailSilenceSec: Double = 0.12
        let tailBytes = Int(24_000 * tailSilenceSec) * 2
        var pcmWithTail = pcmData
        pcmWithTail.append(Data(repeating: 0, count: tailBytes))

        // PlayerNodeStreamerで再生
        print("🔧 TTSEngine[\(requestId)]: prepareForNextStream()呼び出し")
        player.prepareForNextStream()  // ✅ 前の再生を停止してバッファをクリア

        guard currentRequestId == requestId else {
            print("⚠️ TTSEngine[\(requestId)]: 再生キャンセル済み（再生前）")
            return
        }

        print("🎛️ TTSEngine[\(requestId)]: applyParentPhrasePreset()呼び出し")
        player.applyParentPhrasePreset()  // 保護者フレーズ用：早口で高い声

        print("▶️ TTSEngine[\(requestId)]: playChunk()呼び出し - dataSize=\(pcmWithTail.count)")
        // ✅ 単発TTSは必ず即時再生（プリバッファで止まるのを防ぐ）
        player.playChunk(pcmWithTail, forceStart: true)

        print("🎺 TTSEngine[\(requestId)]: 再生開始 - 再生終了待機")
        await player.waitForPlaybackToEnd()
        print("✅ TTSEngine[\(requestId)]: 再生完了 - 終了通知")
    }

    /// 進行中の再生をキャンセル（次の再生を優先）
    public func cancelCurrentPlayback(reason: String = "interrupted") {
        if let activeId = currentRequestId {
            print("🛑 TTSEngine[\(activeId)]: 再生キャンセル - reason=\(reason)")
        }
        currentRequestId = nil
        player.prepareForNextStream()
    }

    /// 再生ターンを開始（古いTaskが開始しても上書きできないようにする）
    public func beginRequest(_ requestId: String) {
        currentRequestId = requestId
    }

    /// 音声データを 24kHz/mono/PCM16 に正規化
    private func normalizeToPCM16_24kMono(data: Data, contentType: String?) throws -> Data? {
        let lowerCT = contentType?.lowercased()
        let isPCM = (lowerCT?.contains("audio/pcm") == true) || (lowerCT?.contains("audio/raw") == true)

        // WAVかMP3の場合、AVAudioFileでデコード
        let isWav = (lowerCT?.contains("wav") == true) || (!isPCM && looksLikeWav(data))
        let isMP3 = (lowerCT?.contains("mpeg") == true) || (lowerCT?.contains("mp3") == true) || (!isPCM && looksLikeMP3(data))

        if isWav {
            return try decodeByAVAudioFile(data: data, fileExtension: "wav")
        }
        if isMP3 {
            return try decodeByAVAudioFile(data: data, fileExtension: "mp3")
        }

        // 生PCMの場合、そのまま返す（24kHz/mono/PCM16の前提）
        guard data.count % 2 == 0 else { return nil }
        return data
    }

    private func looksLikeWav(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        return String(data: data[0..<4], encoding: .ascii) == "RIFF"
            && String(data: data[8..<12], encoding: .ascii) == "WAVE"
    }

    private func looksLikeMP3(_ data: Data) -> Bool {
        guard data.count >= 3 else { return false }
        if String(data: data[0..<3], encoding: .ascii) == "ID3" { return true }
        return data[0] == 0xFF && (data[1] & 0xE0) == 0xE0
    }

    private func decodeByAVAudioFile(data: Data, fileExtension: String) throws -> Data? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = tmpDir.appendingPathComponent("asobo_tts_\(UUID().uuidString).\(fileExtension)")

        try data.write(to: url, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: url) }

        return try convertToPCM16_24kMono(fileURL: url)
    }

    private func convertToPCM16_24kMono(fileURL: URL) throws -> Data? {
        let inputFile = try AVAudioFile(forReading: fileURL)
        let inFormat = inputFile.processingFormat

        guard let outFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: 24_000,
            channels: 1,
            interleaved: true
        ) else { return nil }

        guard let converter = AVAudioConverter(from: inFormat, to: outFormat) else { return nil }

        let frameCount = AVAudioFrameCount(inputFile.length)
        guard let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: frameCount) else { return nil }
        try inputFile.read(into: inBuffer)

        let ratio = outFormat.sampleRate / inFormat.sampleRate
        let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }

        var error: NSError?
        let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
            outStatus.pointee = .haveData
            return inBuffer
        }

        if status == .error {
            print("⚠️ TTSEngine: 音声変換エラー - \(error?.localizedDescription ?? "unknown")")
            return nil
        }

        // interleaved Int16データを取得
        let abl = outBuffer.audioBufferList
        let m0 = abl.pointee.mBuffers
        guard let ptr = m0.mData else { return nil }
        let byteCount = Int(m0.mDataByteSize)
        return Data(bytes: ptr, count: byteCount)
    }
}

// MARK: - Errors
public enum TTSError: Error, LocalizedError {
    case apiKeyMissing
    case textTooLong
    case invalidResponse
    case httpError(Int)
    case decodeError

    public var errorDescription: String? {
        switch self {
        case .apiKeyMissing:
            return "APIキーが設定されていません"
        case .textTooLong:
            return "テキストが長すぎます（最大200文字）"
        case .invalidResponse:
            return "無効なレスポンス"
        case .httpError(let code):
            return "HTTPエラー: \(code)"
        case .decodeError:
            return "音声データのデコードに失敗しました"
        }
    }
}
