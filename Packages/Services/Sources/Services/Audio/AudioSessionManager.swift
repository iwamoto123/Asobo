import Foundation
import AVFoundation

public final class AudioSessionManager {
    public init() {}
    
    public func configure() throws {
        let s = AVAudioSession.sharedInstance()
        try s.setCategory(.playAndRecord,
                          options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try s.setMode(.voiceChat)

        // 20ms 目安の I/O バッファ
        try? s.setPreferredIOBufferDuration(0.02)

        #if targetEnvironment(simulator)
        // シミュレータは 48kHz に寄せて CoreAudio ログを抑制
        try? s.setPreferredSampleRate(48_000)
        #else
        // 実機は 24kHz（RealtimeのPCMに合わせやすい）
        try? s.setPreferredSampleRate(24_000)
        #endif

        try s.setActive(true, options: .notifyOthersOnDeactivation)
    }
    
    public func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false)
    }
}
