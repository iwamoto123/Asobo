import AVFoundation
import Speech

public final class SystemAudioSessionManager: AudioSessionManaging {
    public init() {}
    public func configure() throws {
        let s = AVAudioSession.sharedInstance()
        // ✅ Local STT中でも「再生（TTS/効果音）」が完全に死なないようにする
        // - .record のままだと、その後に再生系（声かけカード等）へ戻す処理がない限り音が極小/無音になりやすい
        // - .defaultToSpeaker で受話口ルートを避け、iPhoneの音量ボタン（メディア音量）に自然に追従させる
        // - Speech用途なので mode は .measurement のまま維持（音声処理を抑えて認識を安定）
        try s.setCategory(
            .playAndRecord,
            mode: .measurement,
            options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP]
        )
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
