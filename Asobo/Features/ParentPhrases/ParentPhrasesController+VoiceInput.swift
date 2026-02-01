import AVFoundation
import Speech
import Support

@available(iOS 17.0, *)
extension ParentPhrasesController {
    func startNewVoiceInput() {
        startVoiceInput(clearExistingText: true)
    }

    func resumeVoiceInput() {
        startVoiceInput(clearExistingText: false)
    }

    func dismissVoiceInputPanel() {
        stopVoiceInput(keepPanel: false)
    }

    func toggleVoiceInput() {
        if isRecording {
            stopVoiceInput(keepPanel: true)
        } else {
            resumeVoiceInput()
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
        voiceInputFallbackTask?.cancel()
        voiceInputFallbackTask = nil
        voiceInputLastBufferAt = nil
        micCapture?.stop()
        micCapture = nil
        micBufferObserver.map(NotificationCenter.default.removeObserver)
        micBufferObserver = nil
        micRMSObserver.map(NotificationCenter.default.removeObserver)
        micRMSObserver = nil
        isVoiceInputPresented = keepPanel
    }
}


