import AVFoundation
import Speech
import Support

@available(iOS 17.0, *)
extension ParentPhrasesController {
    func toggleVoiceInput() {
        if isRecording {
            stopVoiceInput(keepPanel: true)
        } else {
            cancelVoiceInput()
            startVoiceInput()
        }
    }

    func cancelVoiceInput() {
        stopVoiceInput(keepPanel: false)
        voiceInputText = ""
    }

    func stopVoiceInput(keepPanel: Bool) {
        isRecording = false
        speechRequest?.endAudio()
        speechRequest = nil
        speechTask?.cancel()
        speechTask = nil
        micCapture?.stop()
        micCapture = nil
        isVoiceInputPresented = keepPanel
    }
}


