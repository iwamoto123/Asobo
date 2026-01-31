import Foundation

/// TTS エンジンの共通インターフェース
@MainActor
public protocol TTSEngineProtocol {
    /// テキストを音声に変換して再生
    /// - Parameters:
    ///   - text: 読み上げるテキスト
    ///   - requestId: リクエストID（ログ用）
    func speak(text: String, requestId: String) async throws

    /// 進行中の再生をキャンセル
    /// - Parameter reason: キャンセル理由（ログ用）
    func cancelCurrentPlayback(reason: String)

    /// 再生ターンを開始（古いTaskが開始しても上書きできないようにする）
    /// - Parameter requestId: リクエストID
    func beginRequest(_ requestId: String)
}
