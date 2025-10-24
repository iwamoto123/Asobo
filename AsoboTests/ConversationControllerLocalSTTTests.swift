import XCTest
@testable import Asobo

final class ConversationControllerLocalSTTTests: XCTestCase {
    func test_LocalSTT_PartialAndFinal() async throws {
        let fakeSpeech = FakeSpeechRecognizer()
        fakeSpeech.emissions = [("こん", false), ("こんにちは", true)]
        let sut = ConversationController(
            audioSession: DummyAudioSession(),
            speech: fakeSpeech
        )

        sut.startLocalTranscription()
        try await Task.sleep(nanoseconds: 150_000_000)

        XCTAssertEqual(sut.transcript, "こんにちは")
        XCTAssertFalse(sut.isRecording)
        XCTAssertNil(sut.errorMessage)
    }
}
