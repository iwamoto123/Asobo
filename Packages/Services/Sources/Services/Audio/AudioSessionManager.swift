import Foundation
import AVFoundation

public final class AudioSessionManager {
    public init() {}
    
    public func configure() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try session.setMode(.voiceChat)
        
        #if targetEnvironment(simulator)
        // シミュレータでは48kHzに寄せてオーディオログを抑制
        try session.setPreferredSampleRate(48_000)
        #else
        // 実機では24kHzを維持
        try session.setPreferredSampleRate(24_000)
        #endif
        
        try session.setActive(true)
    }
    
    public func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false)
    }
}
