import Foundation
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

extension ConversationController {
    /// アプリがバックグラウンドに移行しても、ハンズフリー会話（録音/再生 + Bluetooth HFPルート）を
    /// 可能な限り継続できるように、通知ベースで復帰処理を仕込む。
    ///
    /// - Note: 「バックグラウンドで長時間」動かす正攻法は `UIBackgroundModes = audio`。
    ///         その上で、割り込み/メディアサービスリセット等からの復帰を担保する。
    func setupAppLifecycleObservers() {
        guard lifecycleObserverTokens.isEmpty else { return }
        let nc = NotificationCenter.default

        #if canImport(UIKit)
        lifecycleObserverTokens.append(
            nc.addObserver(
                forName: UIApplication.didEnterBackgroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] (_: Notification) in
                Task { @MainActor [weak self] in
                    self?.handleDidEnterBackground()
                }
            }
        )

        lifecycleObserverTokens.append(
            nc.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil,
                queue: .main
            ) { [weak self] (_: Notification) in
                Task { @MainActor [weak self] in
                    self?.handleWillEnterForeground()
                }
            }
        )
        #endif

        // Audio interruption / media reset は UIKit が無くても起き得るので、常に監視
        lifecycleObserverTokens.append(
            nc.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                Task { @MainActor [weak self] in
                    self?.handleAudioSessionInterruption(note)
                }
            }
        )

        lifecycleObserverTokens.append(
            nc.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: nil,
                queue: .main
            ) { [weak self] (_: Notification) in
                Task { @MainActor [weak self] in
                    self?.handleMediaServicesReset()
                }
            }
        )
    }

    @MainActor
    private func handleDidEnterBackground() {
        // 会話中だけ keep-alive 対象（無駄にバックグラウンド維持しない）
        guard isRealtimeActive else { return }
        guard isHandsFreeMode && isRecording else { return }

        #if canImport(UIKit)
        // UIBackgroundModes=audio があるため「長時間の backgroundTask 保持」は不要で、むしろ終了リスクになる。
        // ここでは遷移直後の短時間だけ保険として開始し、すぐ自動終了する。
        beginBackgroundTaskIfNeeded(timeout: 10)
        #endif

        // 重要: バックグラウンド遷移のたびに AudioSession を再configure すると、
        // 稼働中の AVAudioEngine が途切れて「止まった」ように見えることがある。
        // ここでは"再設定しない"（復帰が必要なケースは interruption / media reset ハンドラで行う）。
    }

    @MainActor
    private func handleWillEnterForeground() {
        #if canImport(UIKit)
        endBackgroundTaskIfNeeded()
        #endif

        // YouTube等で `shouldResume=false` になった場合は、フォアグラウンド復帰時に復旧を試みる。
        guard needsHandsFreeRecoveryOnForeground else { return }
        needsHandsFreeRecoveryOnForeground = false
        guard isRealtimeActive else { return }

        reactivateAudioIfNeeded(reason: "willEnterForeground.recover")

        // ハンズフリー継続意思がある場合のみ復旧（ユーザーが止めたなら isHandsFreeMode=false のはず）
        guard isHandsFreeMode else { return }
        if mic == nil || !isRecording {
            if audioPreviewClient != nil {
                startHandsFreeConversation()
            }
        } else {
            resumeListening()
        }
    }

    @MainActor
    private func handleAudioSessionInterruption(_ note: Notification) {
        guard let userInfo = note.userInfo,
              let typeValue = userInfo[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: typeValue) else {
            return
        }

        switch type {
        case .began:
            print("⛔️ ConversationController: audio interruption began")
            // YouTube等でオーディオを奪われた場合、戻ってきたときに自動復旧できるようフラグを立てる
            if isHandsFreeMode {
                needsHandsFreeRecoveryOnForeground = true
            }
            // 状態フラグを安全側に寄せる（実際の停止はOSが行う）
            isAIPlayingAudio = false
            isPlayingAudio = false
            mic?.setAIPlayingAudio(false)
            playbackTurnId = nil

        case .ended:
            let optionsValue = (userInfo[AVAudioSessionInterruptionOptionKey] as? UInt) ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsValue)
            let shouldResume = options.contains(.shouldResume)
            print("✅ ConversationController: audio interruption ended (shouldResume=\(shouldResume))")

            // shouldResume=false は iOS が「ここでは自動再開しない」判断。
            // アプリへ戻ったタイミング（willEnterForeground）で復旧を試みる。
            guard shouldResume else {
                if isHandsFreeMode {
                    needsHandsFreeRecoveryOnForeground = true
                }
                return
            }
            guard isRealtimeActive else { return }
            reactivateAudioIfNeeded(reason: "interruptionEnded")
            needsHandsFreeRecoveryOnForeground = false

            // ハンズフリー会話中なら listening を復帰（マイク/エンジンを再起動）
            if isHandsFreeMode {
                if mic == nil {
                    // startHandsFreeConversation は audioPreviewClient を要求するので、存在チェックだけして呼ぶ
                    if audioPreviewClient != nil {
                        startHandsFreeConversation()
                    }
                } else {
                    resumeListening()
                }
            }
        @unknown default:
            break
        }
    }

    @MainActor
    private func handleMediaServicesReset() {
        // 稀に iOS が audio services をリセットする（長時間/BT切替/通話後など）
        print("🔄 ConversationController: media services were reset")
        guard isRealtimeActive else { return }
        reactivateAudioIfNeeded(reason: "mediaServicesWereReset")
        if isHandsFreeMode {
            resumeListening()
        }
    }

    @MainActor
    private func reactivateAudioIfNeeded(reason: String) {
        // ここで「reset=true」で毎回setActive(false)すると途切れやすいので、復帰系はreset=false
        do {
            try audioSessionManager.configure(reset: false)
        } catch {
            print("⚠️ ConversationController: audioSessionManager.configure failed (\(reason)) - \(error.localizedDescription)")
        }

        if !sharedAudioEngine.isRunning {
            do {
                try sharedAudioEngine.start()
                print("✅ ConversationController: sharedAudioEngine restarted (\(reason))")
            } catch {
                print("⚠️ ConversationController: sharedAudioEngine restart failed (\(reason)) - \(error.localizedDescription)")
            }
        }

        do {
            try player.start()
        } catch {
            print("⚠️ ConversationController: player.start failed (\(reason)) - \(error.localizedDescription)")
        }

        // すでに録音中のはずなのに mic が止まっていたら再開を試す（失敗しても致命ではない）
        if isHandsFreeMode && isRecording {
            do {
                try mic?.start()
            } catch {
                // resumeListening() / startHandsFreeConversation() 側で再構築されるのでログだけ
                print("ℹ️ ConversationController: mic.start retry failed (\(reason)) - \(error.localizedDescription)")
            }
        }
    }

    #if canImport(UIKit)
    @MainActor
    private func beginBackgroundTaskIfNeeded(timeout: TimeInterval) {
        guard backgroundTaskId == .invalid else { return }
        backgroundTaskId = UIApplication.shared.beginBackgroundTask(withName: "com.asobo.handsfree.conversation") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.backgroundTaskId != .invalid {
                    UIApplication.shared.endBackgroundTask(self.backgroundTaskId)
                    self.backgroundTaskId = .invalid
                }
            }
        }
        if backgroundTaskId != .invalid {
            print("🧩 ConversationController: began backgroundTask id=\(backgroundTaskId.rawValue)")
            // ✅ 重要: backgroundTask を持ちっぱなしにすると警告→終了リスク。
            // audio background mode が本筋なので、保険タスクは短時間で必ず閉じる。
            Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(1.0, timeout) * 1_000_000_000))
                self.endBackgroundTaskIfNeeded()
            }
        }
    }

    @MainActor
    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTaskId)
        print("🧩 ConversationController: ended backgroundTask id=\(backgroundTaskId.rawValue)")
        backgroundTaskId = .invalid
    }
    #endif
}


