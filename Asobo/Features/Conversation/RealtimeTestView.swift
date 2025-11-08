import SwiftUI
import AVFoundation
import Support

/// テスト用のRealtime API直接接続View
/// 他の開発者の実装を参考にしたシンプルな実装
public struct RealtimeTestView: View {
    @State private var isRecording = false
    @State private var transcription = ""
    @State private var isConnected = false
    @State private var accumulatedAudioData = Data()
    @State private var webSocketTask: URLSessionWebSocketTask?
    @State private var errorMessage: String?
    @State private var isSendingAudioData = false

    private let audioEngine = AVAudioEngine()
    private var playerNode = AVAudioPlayerNode()

    private let audioSendThresholdBytes = 1024 * 20

    public init() {}

    public var body: some View {
        VStack {
            Text("マジで何でも食べる料理評論家Agent")
                .font(.largeTitle)
                .padding(.bottom, 20)
            
            Button(action: toggleRecording) {
                HStack {
                    Image(systemName: isRecording ? "mic.fill" : "mic")
                    Text(isRecording ? "Stop" : "Start")
                }
                .padding()
                .background(isRecording ? Color.red : Color.blue)
                .foregroundColor(.white)
                .cornerRadius(10)
            }
            Text(transcription)
                .padding()
            
            if let errorMessage = errorMessage {
                Text(errorMessage)
                    .foregroundColor(.red)
                    .padding()
            }
        }
        .padding()
        .onAppear {
            connectWebSocket()
            setupAudioSession()
        }
        .onDisappear {
            stopRecording()
            disconnectWebSocket()
        }
    }
    
    private func connectWebSocket() {
        if isConnected {
            return
        }
        
        // ✅ AppConfigからAPIキーを取得
        let apiKey = AppConfig.openAIKey
        guard !apiKey.isEmpty else {
            errorMessage = "Error: OPENAI_API_KEY not found"
            return
        }
        
        guard let url = URL(string: "wss://api.openai.com/v1/realtime?model=gpt-4o-realtime-preview-2024-10-01") else {
            errorMessage = "Error: Invalid WebSocket URL"
            return
        }
        
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("realtime=v1", forHTTPHeaderField: "OpenAI-Beta")
        
        webSocketTask = URLSession.shared.webSocketTask(with: request)
        receiveMessage()
        webSocketTask?.resume()
        isConnected = true
    }

    private func disconnectWebSocket() {
        webSocketTask?.cancel(with: .goingAway, reason: nil)
        webSocketTask = nil
        isConnected = false
    }

    private func receiveMessage() {
        webSocketTask?.receive { result in
            switch result {
            case .success(let message):
                if case .string(let text) = message, 
                   let data = text.data(using: .utf8),
                   let json = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
                   let type = json["type"] as? String {
                    
                    switch type {
                    case "session.created":
                        sendSessionUpdate()
                    case "response.audio.delta":
                        if let delta = json["delta"] as? String {
                            handleAudioDelta(delta)
                        }
                    case "response.audio_transcript.delta":
                        if let delta = json["delta"] as? String {
                            DispatchQueue.main.async {
                                self.transcription += delta
                            }
                        }
                    case "response.audio_transcript.done":
                        if let ts = json["transcript"] as? String {
                            DispatchQueue.main.async {
                                self.transcription = ts
                            }
                        }
                    case "response.done":
                        if let response = json["response"] as? [String: Any],
                           let status = response["status"] as? String,
                           status == "failed",
                           let statusDetails = response["status_details"] as? [String: Any],
                           let error = statusDetails["error"] as? [String: Any],
                           let errorMessage = error["message"] as? String {
                            DispatchQueue.main.async {
                                self.stopRecording()
                                self.errorMessage = errorMessage
                            }
                        }
                    default:
                        print("handleReceivedText:others:type=\(type)")
                        if let jsonData = try? JSONSerialization.data(withJSONObject: json, options: .prettyPrinted),
                           let jsonString = String(data: jsonData, encoding: .utf8) {
                            print("Received JSON: \(jsonString)")
                        }
                    }
                }
                self.receiveMessage() // Continue receiving messages
            case .failure(let error):
                print("WebSocket error: \(error)")
                DispatchQueue.main.async {
                    self.errorMessage = "WebSocket error: \(error.localizedDescription)"
                }
            }
        }
    }

    private func sendSessionUpdate() {
        let event: [String: Any] = [
            "type": "session.update",
            "session": [
                "modalities": ["text", "audio"],
                "instructions": """
あなたは「マジで何でも食べる料理評論家」です。どんな架空の食材や料理でも、実際に食べたかのように詳細にレビューしてださい。食感、味、見た目、そして食べた後の感想をユーモアを交えて表現してください。物理的に不可能な食材や料理でも、あたかも現実のものであるかのように描写してください。
ユーザーが話した言葉がレビューの対象です。依頼されていない料理についてはレビューしないでください。ではどうぞ。
""",
                "voice": "echo"
            ]
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: event),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("Error sending session update: \(error)")
                    DispatchQueue.main.async {
                        self.errorMessage = "Error sending session update: \(error.localizedDescription)"
                    }
                }
            }
        }
    }
    
    private func setupAudioSession() {
        #if os(iOS)
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .default, options: [.defaultToSpeaker, .mixWithOthers])
            try audioSession.setActive(true)
        } catch {
            print("Audio session error: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Audio session error: \(error.localizedDescription)"
            }
        }
        #endif
    }
    
    private func toggleRecording() {
        if isRecording {
            stopRecording()
        } else {
            startRecording()
        }
    }
    
    private func startRecording() {
        connectWebSocket()
        
        let inputNode = audioEngine.inputNode
        let inputFormat = inputNode.outputFormat(forBus: 0)
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { buffer, _ in
            self.sendAudioData(buffer)
        }

        audioEngine.attach(playerNode)
        playerNode.stop()
        
        let mainMixerNode = audioEngine.mainMixerNode
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24000, channels: 1, interleaved: false)
        audioEngine.connect(playerNode, to: mainMixerNode, format: outputFormat)
        
        audioEngine.prepare()
        do {
            try audioEngine.start()
            DispatchQueue.main.async {
                self.isRecording = true
            }
        } catch {
            print("Failed to start audio engine: \(error)")
            DispatchQueue.main.async {
                self.errorMessage = "Failed to start audio engine: \(error.localizedDescription)"
            }
        }
        
        DispatchQueue.main.async {
            self.transcription = ""
        }
    }
    
    private func stopRecording() {
        audioEngine.inputNode.removeTap(onBus: 0)
        DispatchQueue.main.async {
            self.isRecording = false
            self.transcription = ""
        }
    }
    
    private func sendAudioData(_ buffer: AVAudioPCMBuffer) {
        guard isConnected else {
            print("WebSocket is not connected. Cannot send audio data.")
            return
        }
        
        guard !isSendingAudioData else {
            print("Audio data is already being sent. Skipping this buffer.")
            return
        }
        
        guard !playerNode.isPlaying else {
            return
        }
        
        guard let base64Audio = self.pcmBufferToBase64(pcmBuffer: buffer) else {
            print("Failed to convert PCM buffer to Base64 string.")
            return
        }
        
        isSendingAudioData = true
        let event: [String: Any] = [
            "type": "input_audio_buffer.append",
            "audio": base64Audio,
        ]
        
        if let jsonData = try? JSONSerialization.data(withJSONObject: event),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            webSocketTask?.send(.string(jsonString)) { error in
                if let error = error {
                    print("Error sending message: \(error)")
                }
                self.isSendingAudioData = false // Reset the flag after sending
            }
        } else {
            isSendingAudioData = false
        }
    }
    
    private func handleAudioDelta(_ base64Audio: String) {
        if let buffer = base64ToPCMBuffer(base64String: base64Audio) {
            playerNode.scheduleBuffer(buffer, at: nil)
        }
        if !playerNode.isPlaying {
            playerNode.play()
            DispatchQueue.main.async {
                self.stopRecording()
            }
        }
    }
    
    private func base64ToPCMBuffer(base64String: String) -> AVAudioPCMBuffer? {
        let sampleRate = 24000.0
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false)!
        
        guard let audioData = Data(base64Encoded: base64String) else {
            print("Failed to decode Base64 audio data")
            return nil
        }
        
        let frameCount = audioData.count / MemoryLayout<Int16>.size
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(frameCount)
        
        audioData.withUnsafeBytes { rawBufferPointer in
            let int16BufferPointer = rawBufferPointer.bindMemory(to: Int16.self)
            for i in 0..<frameCount {
                let int16Value = int16BufferPointer[i]
                buffer.floatChannelData?[0][i] = Float(int16Value) / Float(Int16.max)
            }
        }
        
        return buffer
    }
    
    private func pcmBufferToBase64(pcmBuffer: AVAudioPCMBuffer) -> String? {
        guard let floatChannelData = pcmBuffer.floatChannelData else {
            return nil
        }
        
        let originalSampleRate = pcmBuffer.format.sampleRate
        let targetSampleRate: Float64 = 24000.0
        let frameLength = Int(pcmBuffer.frameLength)
        
        // ✅ リサンプル（Float32 → Float32 @ 24kHz）
        let resampledData = resampleAudio(floatChannelData: floatChannelData.pointee, frameLength: frameLength, originalSampleRate: originalSampleRate, targetSampleRate: targetSampleRate)
        
        // ✅ 量子化：Float32 → Int16（クリッピング処理付き）
        // ✅ Float32は[-1.0, 1.0]の範囲を想定し、Int16は[-32768, 32767]に変換
        var int16Data = [Int16](repeating: 0, count: resampledData.count)
        for i in 0..<resampledData.count {
            // ✅ クリッピング：[-1.0, 1.0]の範囲に制限
            let clamped = max(-1.0, min(1.0, resampledData[i]))
            // ✅ Float32 → Int16変換（リトルエンディアン）
            int16Data[i] = Int16(clamped * Float(Int16.max))
        }
        
        // ✅ リトルエンディアンでDataを作成（iOSはリトルエンディアン）
        let audioData = Data(bytes: int16Data, count: int16Data.count * MemoryLayout<Int16>.size)
        
        return audioData.base64EncodedString()
    }
    
    private func resampleAudio(floatChannelData: UnsafePointer<Float>, frameLength: Int, originalSampleRate: Float64, targetSampleRate: Float64) -> [Float] {
        let resampleRatio = targetSampleRate / originalSampleRate
        let resampledFrameLength = Int(Double(frameLength) * resampleRatio)
        var resampledData = [Float](repeating: 0, count: resampledFrameLength)
        
        for i in 0..<resampledFrameLength {
            let originalIndex = Int(Double(i) / resampleRatio)
            resampledData[i] = floatChannelData[originalIndex]
        }
        
        return resampledData
    }
}

#Preview {
    RealtimeTestView()
}

