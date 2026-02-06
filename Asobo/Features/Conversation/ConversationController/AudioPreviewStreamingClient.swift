import Foundation

// MARK: - gpt-4o-audio-preview クライアント
final class AudioPreviewStreamingClient {
    private let apiKey: String
    private let apiBase: URL
    private let decoder = JSONDecoder()

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
        userMessagePrefix: String? = nil,
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
        var userParts: [AudioPreviewPayload.MessageContent] = []
        if let userMessagePrefix, !userMessagePrefix.isEmpty {
            userParts.append(.text(userMessagePrefix))
        }
        userParts.append(.inputAudio(.init(data: audioData.base64EncodedString(), format: "wav")))
        messages.append(.init(role: "user", content: userParts))

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
        userMessagePrefix: String? = nil,
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
        var userParts: [AudioPreviewPayload.MessageContent] = []
        if let userMessagePrefix, !userMessagePrefix.isEmpty {
            userParts.append(.text(userMessagePrefix))
        }
        userParts.append(.text(userText))
        messages.append(.init(role: "user", content: userParts))

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

                    // ⚠️ message.audio はストリーム終盤で累積データとして返されることがある。
                    // delta.audio と両方処理すると出だしが二重再生されるため、
                    // ストリーミング再生では delta.audio のみを使用する。
                    if let messageAudio = choice.message?.audio {
                        if messageAudio.data != nil {
                            // delta.audio で既に再生済みなので、ここでは再生しない
                            print("ℹ️ AudioPreviewStreamingClient: message.audio present (skipped for streaming, delta.audio preferred)")
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
