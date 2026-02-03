import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

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
/// 
/// ## スピーカー出力の強制
/// - `overrideOutputAudioPort(.speaker)`でスピーカー出力を強制
/// - これにより「電話みたいな音（細い・小さい）」現象を防ぐ
/// - 近接センサを無効化して、受話口への自動切り替えを防ぐ
public final class AudioSessionManager {
    public init() {}
    
    private var routeChangeObserver: NSObjectProtocol?

    public func configure(reset: Bool = true) throws {
        let s = AVAudioSession.sharedInstance()

        // 既存のセッションを非アクティブにする（競合を防ぐ）
        if reset {
            try? s.setActive(false)
        }

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

        // ✅ Bluetoothデバイスが接続されているかチェック
        let hasBluetoothOutput = s.currentRoute.outputs.contains(where: { output in
            let portType = output.portType
            return portType == .bluetoothHFP ||
                   portType == .bluetoothA2DP ||
                   portType == .bluetoothLE
        })

        // ✅ Bluetoothデバイスが接続されていない時だけスピーカー固定
        // Bluetooth接続時は`overrideOutputAudioPort`を呼ばない（イヤホンに出力される）
        if !hasBluetoothOutput {
            // 念押しでスピーカー固定（UI操作でレシーバに落ちた時の保険）
            // これにより「電話みたいな音（細い・小さい）」現象を防ぐ
            try? s.overrideOutputAudioPort(.speaker)
            print("📢 AudioSessionManager: スピーカー出力を強制（Bluetooth未接続）")
        } else {
            // Bluetooth接続時はオーバーライドを解除（イヤホンに出力）
            try? s.overrideOutputAudioPort(.none)
            print("🎧 AudioSessionManager: Bluetoothデバイス検出 - イヤホン出力")
        }

        // ✅ ルート変更通知を監視（Bluetooth接続/切断時に適切に対応）
        // - Note: configure() が複数回呼ばれてもオブザーバが増殖しないように token を保持する
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleRouteChange(notification)
            }
        }

        // ✅ 近接センサが勝手にONになるのを避ける
        // VoIP通話アプリで"受話口"運用したい時だけ有効にする
        #if canImport(UIKit)
        UIDevice.current.isProximityMonitoringEnabled = false
        #endif

        // 設定確認のログ出力（デバッグ用）
        print("✅ AudioSessionManager: 設定完了")
        print("   - Category: \(s.category.rawValue)")
        print("   - Mode: \(s.mode.rawValue)")
        print("   - SampleRate: \(s.sampleRate)Hz")
        print("   - OutputVolume: \(s.outputVolume)")
        print("   - OutputChannels: \(s.outputNumberOfChannels)")
        print("   - CurrentRoute: \(s.currentRoute.outputs.map { "\($0.portName ?? "unknown")(\($0.portType.rawValue))" }.joined(separator: ", "))")
        print("   - HasBluetooth: \(hasBluetoothOutput)")
        #if canImport(UIKit)
        print("   - ProximityMonitoring: \(UIDevice.current.isProximityMonitoringEnabled ? "enabled" : "disabled")")
        #endif
    }

    /// ✅ ルート変更時の処理（Bluetooth接続/切断時に呼ばれる）
    private func handleRouteChange(_ notification: Notification) {
        guard let userInfo = notification.userInfo,
              let reasonValue = userInfo[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: reasonValue) else {
            return
        }

        let session = AVAudioSession.sharedInstance()
        let hasBluetoothOutput = session.currentRoute.outputs.contains(where: { output in
            let portType = output.portType
            return portType == .bluetoothHFP ||
                   portType == .bluetoothA2DP ||
                   portType == .bluetoothLE
        })

        print("🔄 AudioSessionManager: ルート変更検出 - reason: \(reason), hasBluetooth: \(hasBluetoothOutput)")

        // ✅ categoryChange(=3) はアプリ内の設定変更（mode切替など）でも発生し、
        // BT接続中はこの瞬間だけ「BT未接続」に見えることがある。
        // ただし非BTでは categoryChange でも Receiver に落ちることがあるため、非BTは補正する。
        if reason == .categoryChange, hasBluetoothOutput {
            print("ℹ️ AudioSessionManager: route override skipped (categoryChange, bluetooth=true)")
            return
        }

        // それ以外は常に出力先を補正する（受話口落ち・BT切替対策）
        if !hasBluetoothOutput {
            try? session.overrideOutputAudioPort(.speaker)
            print("📢 AudioSessionManager: スピーカー出力を強制（Bluetooth未接続、reason=\(reason.rawValue)）")
        } else {
            try? session.overrideOutputAudioPort(.none)
            print("🎧 AudioSessionManager: オーバーライド解除（Bluetooth接続、reason=\(reason.rawValue)）")
        }
    }

    public func deactivate() throws {
        // ルート変更通知の監視を解除
        if let token = routeChangeObserver {
            NotificationCenter.default.removeObserver(token)
            routeChangeObserver = nil
        }
        try AVAudioSession.sharedInstance().setActive(false)
    }
}
