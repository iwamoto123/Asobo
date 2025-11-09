import Foundation
import AVFoundation

/// ✅ 音声入力が正常に動作するためのAudioSession設定
/// 
/// ## 重要な設定ポイント（AEC有効化）
/// 1. **カテゴリ**: `.playAndRecord` - 録音と再生を同時に行う
/// 2. **モード**: `.voiceChat` - AEC（エコーキャンセレーション）を有効化するために必須
///    - Voice Processing I/Oが有効になり、AIのTTSがマイクに拾われないようにする
///    - 48kHzで動作し、AGC/AECが適切に機能する
/// 3. **サンプルレート**: 48kHz - iOSのVoiceProcessingは48kHzが安定
/// 4. **IOバッファ**: 10ms - 低レイテンシーでAECの精度向上
/// 
/// ## 音声フォーマットの変換フロー
/// - 入力: 48kHz/mono/Float32（デバイス依存、AEC適用後）
/// - 変換: MicrophoneCaptureで24kHz/mono/PCM16に変換
/// - 送信: OpenAI Realtime APIの要求仕様（24kHz/mono/PCM16）に合わせる
/// 
/// ## AEC（エコーキャンセレーション）について
/// - `.voiceChat`モードでAECが有効化され、AIのTTSがマイクに拾われないようになる
/// - マイクとプレイヤーを同じAVAudioEngineに統合することで、AECの効果が安定する
public final class AudioSessionManager {
    public init() {}
    
    public func configure() throws {
        let s = AVAudioSession.sharedInstance()
        
        // 既存のセッションを非アクティブにする（競合を防ぐ）
        try? s.setActive(false)
        
        // ✅ AEC（エコーキャンセレーション）を有効化するための設定
        // .defaultToSpeaker: スピーカーに強制出力（重要！）
        // .allowBluetooth: Bluetoothデバイスを許可
        // .allowBluetoothA2DP: Bluetooth A2DPプロファイルを許可
        try s.setCategory(.playAndRecord,
                          options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
        // ✅ .voiceChatモードに変更（AEC/NS/AGCを有効化するために必須）
        // ✅ Voice Processing I/Oが有効になり、AIのTTSがマイクに拾われないようになる
        // ✅ 48kHzで動作し、AGC/AECが適切に機能する
        try s.setMode(.voiceChat)
        
        // ✅ 48kHz/10msに設定（iOSのVoiceProcessingは48kHzが安定）
        // ✅ 48kHzに上げると入力振幅とVADの反応が良くなる
        try s.setPreferredSampleRate(48_000)
        // ✅ IOBufferDurationを10msに設定（AECの精度向上のため）
        try s.setPreferredIOBufferDuration(0.01)  // 10ms

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
