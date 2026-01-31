import Foundation
import AVFoundation

/// AVSpeechSynthesizerを使用した音声合成エンジン（iOS標準TTS）
/// - 完全無料・オフライン動作
/// - ピッチとレートを調整してマスコット的な声を実現
@MainActor
public final class AVSpeechTTSEngine: NSObject, TTSEngineProtocol {
    private let synthesizer: AVSpeechSynthesizer
    private var currentRequestId: String?
    private var continuation: CheckedContinuation<Void, Error>?

    // マスコット的な声の設定
    private let pitchMultiplier: Float = 1.4  // 高い声（1.0が標準、1.3〜1.5が推奨）
    private let speechRate: Float = 0.6       // やや早口（0.5が標準、0.6〜0.7が推奨）

    public override init() {
        self.synthesizer = AVSpeechSynthesizer()
        super.init()
        self.synthesizer.delegate = self
        print("✅ AVSpeechTTSEngine: 初期化完了 - pitch=\(pitchMultiplier), rate=\(speechRate)")
    }

    /// テキストを音声に変換して再生
    public func speak(text: String, requestId: String) async throws {
        print("🎙️ AVSpeechTTSEngine[\(requestId)]: speak() 開始 - text=\"\(text)\"")

        guard currentRequestId == requestId else {
            print("⚠️ AVSpeechTTSEngine[\(requestId)]: 非アクティブなリクエストのため無視")
            return
        }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            print("⚠️ AVSpeechTTSEngine[\(requestId)]: テキストが空です")
            return
        }

        // AVSpeechUtterance作成
        let utterance = AVSpeechUtterance(string: trimmed)

        // 日本語音声を使用
        utterance.voice = AVSpeechSynthesisVoice(language: "ja-JP")

        // マスコット的な声に調整
        utterance.pitchMultiplier = pitchMultiplier  // 高い声
        utterance.rate = speechRate                  // やや早口
        utterance.volume = 1.0                       // 最大音量

        print("🎛️ AVSpeechTTSEngine[\(requestId)]: 音声設定 - pitch=\(pitchMultiplier), rate=\(speechRate), voice=\(utterance.voice?.language ?? "unknown")")

        // 再生完了を待つ（CheckedContinuationで async/await に変換）
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.continuation = continuation

            // 既存の再生を停止
            if synthesizer.isSpeaking {
                print("🛑 AVSpeechTTSEngine[\(requestId)]: 既存の再生を停止")
                synthesizer.stopSpeaking(at: .immediate)
            }

            print("▶️ AVSpeechTTSEngine[\(requestId)]: 再生開始")
            synthesizer.speak(utterance)
        }

        print("✅ AVSpeechTTSEngine[\(requestId)]: 再生完了")
    }

    /// 進行中の再生をキャンセル（次の再生を優先）
    public func cancelCurrentPlayback(reason: String) {
        if let activeId = currentRequestId {
            print("🛑 AVSpeechTTSEngine[\(activeId)]: 再生キャンセル - reason=\(reason)")
        }
        currentRequestId = nil

        if synthesizer.isSpeaking {
            synthesizer.stopSpeaking(at: .immediate)
        }

        // 待機中のcontinuationがあればキャンセル
        if let continuation = continuation {
            continuation.resume(returning: ())
            self.continuation = nil
        }
    }

    /// 再生ターンを開始（古いTaskが開始しても上書きできないようにする）
    public func beginRequest(_ requestId: String) {
        currentRequestId = requestId
        print("🎬 AVSpeechTTSEngine[\(requestId)]: リクエスト開始")
    }
}

// MARK: - AVSpeechSynthesizerDelegate
extension AVSpeechTTSEngine: AVSpeechSynthesizerDelegate {
    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        print("✅ AVSpeechTTSEngine: didFinish - 再生完了")
        continuation?.resume(returning: ())
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        print("🛑 AVSpeechTTSEngine: didCancel - 再生キャンセル")
        continuation?.resume(returning: ())
        continuation = nil
    }

    public func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        print("🎺 AVSpeechTTSEngine: didStart - 再生開始")
    }
}

// MARK: - Errors
public enum AVSpeechTTSError: Error, LocalizedError {
    case textTooLong

    public var errorDescription: String? {
        switch self {
        case .textTooLong:
            return "テキストが長すぎます（最大1000文字）"
        }
    }
}
