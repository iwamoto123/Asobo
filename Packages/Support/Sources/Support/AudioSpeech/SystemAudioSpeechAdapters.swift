import AVFoundation
import Speech

public final class SystemAudioSessionManager: AudioSessionManaging {
    public init() {}
    public func configure() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.record, mode: .measurement, options: .duckOthers)
        try s.setActive(true, options: .notifyOthersOnDeactivation)
    }
}

final class _SystemSpeechTask: SpeechRecognitionTasking {
    private let task: SFSpeechRecognitionTask
    init(_ task: SFSpeechRecognitionTask) { self.task = task }
    func cancel() { task.cancel() }
}

public final class SystemSpeechRecognizer: SpeechRecognizing {
    private let recognizer: SFSpeechRecognizer?

    public init(locale: String = "ja-JP") {
        self.recognizer = SFSpeechRecognizer(locale: Locale(identifier: locale))
    }

    public var isAvailable: Bool { recognizer?.isAvailable == true }

    public func startTask(
        request: SFSpeechAudioBufferRecognitionRequest,
        onResult: @escaping (String, Bool) -> Void,
        onError: @escaping (Error) -> Void
    ) -> SpeechRecognitionTasking {
        request.shouldReportPartialResults = true
        let task = recognizer!.recognitionTask(with: request) { result, error in
            if let r = result { onResult(r.bestTranscription.formattedString, r.isFinal) }
            if let e = error { onError(e) }
        }
        return _SystemSpeechTask(task)
    }
}
