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

        // 20ms 目安の I/O バッファ（低レイテンシ）
        try? s.setPreferredIOBufferDuration(0.02)

        #if targetEnvironment(simulator)
        // シミュレータは 48kHz に寄せて CoreAudio ログを抑制
        try? s.setPreferredSampleRate(48_000)
        #else
        // 実機も48kHzに統一（デバイスの標準サンプリングレートに合わせる）
        // 24kHzだと一部のデバイスで問題が発生する可能性があるため
        try? s.setPreferredSampleRate(48_000)
        #endif

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
