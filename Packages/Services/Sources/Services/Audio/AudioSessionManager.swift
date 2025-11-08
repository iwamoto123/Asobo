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
        // .mixWithOthers: 他のオーディオと混在可能
        try s.setCategory(.playAndRecord,
                          options: [.defaultToSpeaker, .allowBluetooth, .mixWithOthers])
        // ✅ .measurementモードに変更（.voiceChatは端末や経路次第で16kHzに落ちたりAGC/AECが強くかかって振幅が潰れる）
        // ✅ 入力は48kHz/mono/Float32で取り、アプリ内で24kHz/mono/PCM16に確実に変換するのが安定
        try s.setMode(.measurement)
        
        // ✅ 48kHz/20msに設定（入力は48kHzで取り、アプリ内で24kHzに変換）
        // ✅ 48kHzに上げると入力振幅とVADの反応が良くなる
        try s.setPreferredSampleRate(48_000)
        // ✅ IOBufferDurationを20msに設定
        try s.setPreferredIOBufferDuration(0.02)  // 20ms

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
