import Foundation
import AVFoundation

extension ConversationController {
    // MARK: - Audio capture helpers
    func appendPCMBuffer(_ buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.int16ChannelData else { return }
        let frameLength = Int(buffer.frameLength)
        let channels = Int(buffer.format.channelCount)
        let bytesPerFrame = channels * MemoryLayout<Int16>.size
        let byteCount = frameLength * bytesPerFrame
        let data = Data(bytes: channelData[0], count: byteCount)
        recordedPCMData.append(data)
        recordedSampleRate = buffer.format.sampleRate
    }

    func stopPlayer(reason: String, function: String = #function) {
        let playbackIdText = playbackTurnId.map(String.init) ?? "nil"
        print("🛑 PlayerNodeStreamer.stop() call - caller=\(function), reason=\(reason), playbackTurnId=\(playbackIdText), currentTurnId=\(currentTurnId), turnState=\(turnState)")
        player.stop()
    }

    // MARK: - Fillers
    func playRandomFiller() {
        guard enableFillers else {
            isFillerPlaying = false
            return
        }
        guard let fileName = fillerFiles.randomElement(),
              let url = Bundle.main.url(forResource: fileName, withExtension: "wav") else {
            print("⚠️ 相槌ファイルが見つかりません: \(fillerFiles)")
            return
        }
        print("🗣️ 相槌再生: \(fileName)")
        player.playLocalFile(url)
        isFillerPlaying = true
    }

    // MARK: - PCM/WAV
    func pcm16ToWav(pcmData: Data, sampleRate: Double) -> Data {
        // シンプルなPCM16(LE)/モノラル -> WAVヘッダー付与
        var wav = Data()
        let numChannels: UInt16 = 1
        let bitsPerSample: UInt16 = 16
        let byteRate = UInt32(sampleRate) * UInt32(numChannels) * UInt32(bitsPerSample / 8)
        let blockAlign = UInt16(numChannels * bitsPerSample / 8)
        let dataSize = UInt32(pcmData.count)

        func appendLE<T: FixedWidthInteger>(_ value: T) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { wav.append(contentsOf: $0) }
        }

        wav.append("RIFF".data(using: .ascii)!)
        appendLE(UInt32(36 + dataSize))
        wav.append("WAVE".data(using: .ascii)!)
        wav.append("fmt ".data(using: .ascii)!)
        appendLE(UInt32(16))           // PCM fmt chunk size
        appendLE(UInt16(1))            // PCM format
        appendLE(numChannels)
        appendLE(UInt32(sampleRate))
        appendLE(byteRate)
        appendLE(blockAlign)
        appendLE(bitsPerSample)
        wav.append("data".data(using: .ascii)!)
        appendLE(dataSize)
        wav.append(pcmData)
        return wav
    }
}


