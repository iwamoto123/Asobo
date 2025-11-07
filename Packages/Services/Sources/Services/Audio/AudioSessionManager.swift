import Foundation
import AVFoundation

public final class AudioSessionManager {
    public init() {}
    
    public func configure() throws {
        let s = AVAudioSession.sharedInstance()
        
        // 既存のセッションを非アクティブにする（競合を防ぐ）
        try? s.setActive(false)
        
        // ✅ 実機で確実に音を出すための設定
        // .defaultToSpeaker: スピーカーに強制出力（重要！）
        // .allowBluetooth: Bluetoothデバイスを許可
        // .duckOthers: 他のオーディオを一時的に下げる
        try s.setCategory(.playAndRecord,
                          options: [.defaultToSpeaker, .allowBluetooth, .duckOthers])
        try s.setMode(.voiceChat)

        // ✅ 24kHz/10msに設定（OpenAI Realtime APIの要求仕様に合わせる）
        // ✅ AEC/AGCを確実に有効化するため、preferredIOBufferDuration = 0.01 前後に固定して無音パケット乱発を抑制
        try? s.setPreferredSampleRate(24_000)
        try? s.setPreferredIOBufferDuration(0.01)  // 10ms（無音パケット乱発を抑制）

        // AudioSessionをアクティブにする
        try s.setActive(true, options: .notifyOthersOnDeactivation)
        
        // 設定確認のログ出力（デバッグ用）
        print("✅ AudioSessionManager: 設定完了")
        print("   - Category: \(s.category.rawValue)")
        print("   - Mode: \(s.mode.rawValue)")
        print("   - SampleRate: \(s.sampleRate)Hz")
        print("   - OutputVolume: \(s.outputVolume)")
        print("   - OutputChannels: \(s.outputNumberOfChannels)")
    }
    
    public func deactivate() throws {
        try AVAudioSession.sharedInstance().setActive(false)
    }
}
