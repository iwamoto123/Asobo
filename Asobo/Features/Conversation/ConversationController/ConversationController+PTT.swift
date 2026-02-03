import Foundation
import AVFoundation
import Services

extension ConversationController {
    // MARK: - PTT (Push-to-talk)
    public func startPTTRealtime() {
        // ハンズフリー中にPTTを開始したらハンズフリーを明示的に無効化
        if isHandsFreeMode {
            stopHandsFreeConversation()
        }
        guard audioPreviewClient != nil else {
            self.errorMessage = "音声プレビュークライアントが初期化されていません"; return
        }
        // 促しと既存の録音をリセット
        cancelNudge()
        recordedPCMData.removeAll()
        recordedSampleRate = 24_000

        // バージイン前提でAI音声を止める
        stopPlayer(reason: "startPTTRealtime (barge-in before PTT)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)

        // 共有エンジンが止まっていたら再開
        if !sharedAudioEngine.isRunning {
            do { try sharedAudioEngine.start() } catch {
                print("⚠️ ConversationController: エンジン再開失敗 - \(error.localizedDescription)")
            }
        }

        startPTTRealtimeInternal()
    }

    private func startPTTRealtimeInternal() {
        cancelNudge()             // ✅ ユーザーが話し始めるので促しを止める
        // 🔇 いま流れているAI音声を止める（barge-in 前提）
        stopPlayer(reason: "startPTTRealtimeInternal (barge-in before reconfigure)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        ignoreIncomingAIChunks = false

        mic?.stop()

        // ✅ Task内で実行
        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // 1. エンジンがいったん動いているなら停止（再構成のため）
            // VoiceProcessingIOは構成変更時に停止しているのが最も安全
            if self.sharedAudioEngine.isRunning {
                self.sharedAudioEngine.stop()
            }

            // 2. マイクを初期化 & Start (ここで Tap をインストール)
            // エンジンは停止状態だが、Tapインストールは可能
            self.mic = MicrophoneCapture(sharedEngine: self.sharedAudioEngine, onPCM: { [weak self] buf in
                self?.appendPCMBuffer(buf)
            }, outputMonitor: self.player.outputMonitor)

            // -------------------------------------------------------
            // ✅ 追加: マイクの音量を監視して、音がしていれば時刻を更新
            // -------------------------------------------------------
            self.mic?.onVolume = { [weak self] rms in
                // バックグラウンドスレッドから呼ばれるためMainActorへ
                Task { @MainActor [weak self] in
                    guard let self = self else { return }
                    self.lastInputRMS = rms

                    // 閾値(-50dB)より大きければ「音がしている」とみなして時刻更新
                    if rms > self.silenceThresholdDb {
                        self.lastUserVoiceActivityTime = Date()
                    }
                }
            }
            self.lastInputRMS = nil

            // マイク開始時に時刻をリセット
            self.lastUserVoiceActivityTime = Date()

            do {
                // ここで Tap がインストールされる (フォーマット補正込み)
                try self.mic?.start()
            } catch {
                self.errorMessage = "マイク設定失敗: \(error.localizedDescription)"
                self.isRecording = false
                return
            }

            // 3. その後で、エンジンを Prepare & Start
            self.sharedAudioEngine.prepare()
            do {
                try self.sharedAudioEngine.start()
                print("✅ ConversationController: エンジン再開成功")
            } catch {
                print("❌ ConversationController: エンジン開始失敗: \(error)")
                self.errorMessage = "オーディオエンジンの開始に失敗しました"
                self.isRecording = false
                return
            }

            // 4. 状態更新
            self.isRecording = true
            // ✅ 録音開始時点の「話者（子）」押下状態をロック（録音中に離されても、このターンの保存に反映する）
            if let id = self.speakerChildIdOverride, let name = self.speakerChildNameOverride {
                self.lockedSpeakerChildIdForTurn = id
                self.lockedSpeakerChildNameForTurn = name
            }
            self.transcript = ""
            self.turnState = .listening
            self.markListeningTurn()
            self.turnMetrics = TurnMetrics()
            self.turnMetrics.listenStart = Date()
            print("⏱️ Latency: listen start (PTT) at \(self.turnMetrics.listenStart!)")

            // 注意: 促しタイマーは onResponseDone でのみセットする（AI応答完了時のみ）
            // ユーザーが話し始めた直後はタイマーをセットしない
            print("✅ ConversationController: PTT開始シーケンス完了")
        }
    }

    public func stopPTTRealtime() {
        isRecording = false
        isHandsFreeMode = false
        mic?.stop()
        if turnMetrics.speechEnd == nil {
            turnMetrics.speechEnd = Date()
        }
        turnState = .thinking
        Task { [weak self] in
            await self?.sendAudioPreviewRequest()
        }
    }
}
