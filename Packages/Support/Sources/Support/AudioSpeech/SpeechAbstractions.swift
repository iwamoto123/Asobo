import Foundation
import Speech

public protocol AudioSessionManaging {
    func configure() throws
}

public protocol SpeechRecognitionTasking {
    func cancel()
}

public protocol SpeechRecognizing {
    var isAvailable: Bool { get }
    func startTask(
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping (_ text: String, _ isFinal: Bool) -> Void,
        onError: @escaping (_ error: Error) -> Void
    ) -> SpeechRecognitionTasking
}
