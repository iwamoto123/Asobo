import Foundation
import AVFoundation
import Services
import Support

extension ConversationController {
    func playFallbackTTS(text: String, turnId: Int) async {
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
            let format: String
        }
        // PCM16 で受け取ればデコード不要で確実に再生できる
        let ttsInput = fallbackTTSInput(from: trimmed)
        let payload = SpeechPayload(model: "gpt-4o-mini-tts", voice: "nova", input: ttsInput, format: "pcm16")

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        // サーバがWAV/MP3等で返してきても受けられるようにする（実データは必ず24k/mono/PCM16へ正規化してから再生する）
        request.addValue("audio/pcm, audio/wav, audio/mpeg", forHTTPHeaderField: "Accept")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(payload)
        print("🎺 ConversationController: fallback TTS request - len=\(ttsInput.count), model=\(payload.model), voice=\(payload.voice), format=\(payload.format)")

        var startedPlayback = false
        do {
            var (data, response) = try await URLSession.shared.data(for: request)
            guard var http = response as? HTTPURLResponse else {
                print("⚠️ ConversationController: fallback TTS invalid response")
                return
            }
            if !(200..<300).contains(http.statusCode) {
                let body = String(data: data, encoding: .utf8) ?? "(binary)"
                print("❌ ConversationController: fallback TTS HTTP \(http.statusCode) - body: \(body)")
                return
            }
            let contentType = http.value(forHTTPHeaderField: "Content-Type")
            let ctText = contentType ?? "unknown"
            print("🎺 ConversationController: fallback TTS response - status=\(http.statusCode), bytes=\(data.count), contentType=\(ctText)")

            guard let pcmData = Self.fallbackPCM16_24kMonoData(from: data, contentType: contentType) else {
                let head = data.prefix(16).map { String(format: "%02X", $0) }.joined(separator: " ")
                print("⚠️ ConversationController: fallback TTS decode failed; head[16]=[\(head)] ct=\(ctText)")
                return
            }
            playbackTurnId = turnId
            turnState = .speaking
            if isFillerPlaying { isFillerPlaying = false }

            // ✅ フォールバックTTSは声が落ち着きがちなので、再生側でピッチを上げてマスコット寄りにする
            if fallbackTTSVoiceFXRestore == nil {
                fallbackTTSVoiceFXRestore = player.snapshotVoiceFXState()
            }
            isFallbackTTSPlaybackActive = true
            player.applyMascotBoostPreset()

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

    /// fallback TTS の応答データを「24kHz / mono / PCM16(インターリーブ)」へ正規化して返す。
    /// - Note: 生PCMとWAV/MP3を混在で扱えるように、Content-Type と先頭マジックで判定する。
    private static func fallbackPCM16_24kMonoData(from data: Data, contentType: String?) -> Data? {
        let lowerCT = contentType?.lowercased()

        func looksLikeWav(_ d: Data) -> Bool {
            guard d.count >= 12 else { return false }
            return String(data: d[0..<4], encoding: .ascii) == "RIFF"
                && String(data: d[8..<12], encoding: .ascii) == "WAVE"
        }
        func looksLikeMP3(_ d: Data) -> Bool {
            guard d.count >= 3 else { return false }
            if String(data: d[0..<3], encoding: .ascii) == "ID3" { return true }
            // frame sync 0xFFEx
            return d[0] == 0xFF && (d[1] & 0xE0) == 0xE0
        }

        let isWav = (lowerCT?.contains("wav") == true) || looksLikeWav(data)
        let isMP3 = (lowerCT?.contains("mpeg") == true) || (lowerCT?.contains("mp3") == true) || looksLikeMP3(data)
        let isPCM =
            (lowerCT?.contains("pcm") == true) ||
            (lowerCT?.contains("audio/raw") == true) ||
            (lowerCT?.contains("octet-stream") == true) ||
            (lowerCT == nil) // 不明な場合はPCMの可能性もある

        if isWav {
            return decodeByAVAudioFile(data: data, fileExtension: "wav")
        }
        if isMP3 {
            return decodeByAVAudioFile(data: data, fileExtension: "mp3")
        }
        if isPCM {
            // 生PCMは「すでに24kHz/mono/PCM16」の前提で受け取る（違う場合はWAVで返してもらう/decoderで対応）
            guard data.count % 2 == 0 else { return nil }
            return data
        }
        // それ以外（不明）はWAVとして一度試す（成功すればOK）
        return decodeByAVAudioFile(data: data, fileExtension: "wav")
    }

    private static func decodeByAVAudioFile(data: Data, fileExtension: String) -> Data? {
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        let url = tmpDir.appendingPathComponent("asobo_fallback_tts_\(UUID().uuidString).\(fileExtension)")
        do {
            try data.write(to: url, options: [.atomic])
            defer { try? FileManager.default.removeItem(at: url) }
            return convertToPCM16_24kMono(fileURL: url)
        } catch {
            print("⚠️ ConversationController: fallback TTS temp write/decode failed - \(error.localizedDescription)")
            return nil
        }
    }

    private static func convertToPCM16_24kMono(fileURL: URL) -> Data? {
        do {
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

            // 出力は概算（サンプルレート変換があるので余裕を持たせる）
            let ratio = outFormat.sampleRate / inFormat.sampleRate
            let outCapacity = AVAudioFrameCount(Double(inBuffer.frameLength) * ratio + 1024)
            guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else { return nil }

            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error) { _, outStatus in
                outStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error {
                if let error { print("⚠️ ConversationController: fallback TTS convert error - \(error.localizedDescription)") }
                return nil
            }

            // interleaved Int16: AudioBufferListのmBuffers[0]にまとまっている
            let abl = outBuffer.audioBufferList
            let m0 = abl.pointee.mBuffers
            guard let ptr = m0.mData else { return nil }
            let byteCount = Int(m0.mDataByteSize)
            return Data(bytes: ptr, count: byteCount)
        } catch {
            print("⚠️ ConversationController: fallback TTS file decode failed - \(error.localizedDescription)")
            return nil
        }
    }
}
