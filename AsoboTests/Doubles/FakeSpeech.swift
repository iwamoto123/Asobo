import Foundation
import Speech
import Support
@testable import Asobo

final class FakeSpeechTask: SpeechRecognitionTasking {
    func cancel() {}
}

final class FakeSpeechRecognizer: SpeechRecognizing {
    var isAvailable: Bool = true
    var emissions: [(String, Bool)] = [] // (text, isFinal)

    func startTask(
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) -> SpeechRecognitionTasking {
        Task {
            for (t, f) in emissions {
                try? await Task.sleep(nanoseconds: 50_000_000)
                onResult(t, f)
            }
        }
        return FakeSpeechTask()
    }
}

final class DummyAudioSession: AudioSessionManaging {
    func configure() throws {}
}
