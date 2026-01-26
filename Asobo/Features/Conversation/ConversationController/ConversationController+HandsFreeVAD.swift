import Foundation
import AVFoundation
import Services

extension ConversationController {
    // MARK: - Hands-free Conversation (VAD)
    /// 1回のタップで「聞く→送る→AI応答→再開」を繰り返すモード
    public func startHandsFreeConversation() {
        guard audioPreviewClient != nil else {
            self.errorMessage = "まず「開始」を押してセッションを開いてください"
            return
        }
        // PTT録音中に切り替えられないようガード
        if isRecording && !isHandsFreeMode {
            self.errorMessage = "現在の録音を停止してからハンズフリーを開始してください"
            return
        }

        cancelNudge()
        recordedPCMData.removeAll()
        recordedSampleRate = 24_000
        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil

        // バージイン前提でAI音声を止める
        stopPlayer(reason: "startHandsFreeConversation (barge-in before HF start)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)

        if !sharedAudioEngine.isRunning {
            do { try sharedAudioEngine.start() } catch {
                print("⚠️ ConversationController: エンジン再開失敗 - \(error.localizedDescription)")
            }
        }

        isHandsFreeMode = true
        vadState = .idle
        speechStartTime = nil
        silenceTimer?.invalidate()
        silenceTimer = nil
        startHandsFreeInternal()
    }

    public func stopHandsFreeConversation() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        handsFreeSTTRestartTask?.cancel()
        handsFreeSTTRestartTask = nil
        cancelSTTVADEndTimer()
        isHandsFreeMode = false
        isRecording = false
        isUserSpeaking = false
        vadState = .idle
        speechStartTime = nil
        recordedPCMData.removeAll()
        stopHandsFreeRealtimeSTTMonitor()
        mic?.stop()
        turnState = .waitingUser
    }

    private func startHandsFreeInternal() {
        cancelNudge()
        stopPlayer(reason: "startHandsFreeInternal (reset before VAD start)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        mic?.stop()
        ignoreIncomingAIChunks = false

        Task { @MainActor [weak self] in
            guard let self = self else { return }

            // 1. エンジンを一度止めてから再構成
            if self.sharedAudioEngine.isRunning {
                self.sharedAudioEngine.stop()
            }

            self.mic = MicrophoneCapture(sharedEngine: self.sharedAudioEngine, onPCM: { [weak self] buf in
                self?.appendPCMBuffer(buf)
            }, outputMonitor: self.player.outputMonitor)

            // ✅ 監視用リアルタイムSTTに「変換前の入力バッファ」を流す
            self.mic?.onInputBuffer = { [weak self] buffer in
                self?.appendHandsFreeSTTInputBuffer(buffer)
            }

            // NOTE: Silero VAD は使用しない方針（バージインは STT ベースのみで行う）

            // ✅ Bluetooth/非Bluetooth問わず、マイク開始と同時にライブSTTが立ち上がるよう
            // mic生成・入力バッファ経路の設定直後に監視STTを起動しておく
            self.startHandsFreeRealtimeSTTMonitorIfNeeded()
            self.mic?.onVolume = { [weak self] rms in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.lastInputRMS = rms

                    if rms > self.silenceThresholdDb {
                        self.lastUserVoiceActivityTime = Date()
                    }
                }
            }
            self.lastInputRMS = nil

            recordedPCMData.removeAll()
            recordedSampleRate = 24_000

            do {
                try self.mic?.start()
            } catch {
                self.errorMessage = "マイク設定失敗: \(error.localizedDescription)"
                self.isRecording = false
                self.isHandsFreeMode = false
                return
            }

            self.sharedAudioEngine.prepare()
            do {
                try self.sharedAudioEngine.start()
                print("✅ ConversationController: ハンズフリー用エンジン開始")
            } catch {
                print("❌ ConversationController: エンジン開始失敗: \(error)")
                self.errorMessage = "オーディオエンジンの開始に失敗しました"
                self.isRecording = false
                self.isHandsFreeMode = false
                return
            }

            self.isRecording = true
            self.turnState = .listening
            self.markListeningTurn()
            self.vadState = .idle
            self.speechStartTime = nil
            self.turnMetrics = TurnMetrics()
            self.turnMetrics.listenStart = Date()
            print("⏱️ Latency: listen start (handsfree) at \(self.turnMetrics.listenStart!)")
            print("🟢 ハンズフリー会話開始: Listening...")

            // ✅ ライブSTTは「speech start検知後」だと立ち上がりが遅れることがあるため、
            // listen開始と同時に起動してバッファを流し続ける（必要ならspeech start側で再起動される）
            self.startHandsFreeRealtimeSTTMonitorIfNeeded()
        }
    }

    // MARK: - VAD core
    func handleVAD(probability: Float) {
        // AI再生中の割り込み判定：Silero VAD を一定時間連続検出した場合のみ停止
        if isAIPlayingAudio && turnState == .speaking {
            if probability >= bargeInVADThreshold {
                if vadInterruptSpeechStart == nil {
                    vadInterruptSpeechStart = Date()
                } else if let start = vadInterruptSpeechStart,
                          Date().timeIntervalSince(start) >= bargeInHoldDuration {
                    vadInterruptSpeechStart = nil
                    interruptAI()
                    return
                }
            } else {
                vadInterruptSpeechStart = nil
            }
        } else {
            vadInterruptSpeechStart = nil
        }

        if turnState == .thinking { return }
        guard listeningTurnId == currentTurnId else { return }

        switch vadState {
        case .idle:
            let now = Date()
            let rmsDb = lastInputRMS ?? -120.0
            let probTriggered = probability > speechStartThreshold
            let rmsTriggered = rmsDb > activeRmsStartThresholdDb
            if probTriggered || rmsTriggered {
                if speechStartCandidateTime == nil {
                    speechStartCandidateTime = now
                }
                let elapsed = now.timeIntervalSince(speechStartCandidateTime ?? now)
                if elapsed < speechStartHoldDuration {
                    return
                }
                speechStartCandidateTime = nil

                vadState = .speaking
                isUserSpeaking = true
                speechStartTime = Date()
                speechStartTriggeredByProb = probTriggered
                silenceTimer?.invalidate()
                silenceTimer = nil
                startHandsFreeRealtimeSTTMonitorIfNeeded()
                turnMetrics.listenStart = turnMetrics.listenStart ?? speechStartTime
                let probText = String(format: "%.4f", probability)
                let rmsText = String(format: "%.2f", rmsDb)
                let rmsStartText = String(format: "%.1f", activeRmsStartThresholdDb)
                let session = AVAudioSession.sharedInstance()
                let input = session.currentRoute.inputs.first
                let inputName = input?.portName ?? input?.portType.rawValue ?? "none"
                let preferredInput = session.preferredInput?.portName ?? session.preferredInput?.portType.rawValue ?? "none"
                print("⏱️ Latency: speech start detected at \(speechStartTime!) | prob=\(probText), rms=\(rmsText)dB, input=\(inputName), preferredInput=\(preferredInput), trigProb=\(probTriggered), trigRMS=\(rmsTriggered), rmsStartThresh=\(rmsStartText)")
            } else {
                speechStartCandidateTime = nil
            }
        case .speaking:
            let rmsDb = lastInputRMS ?? -120.0
            // ✅ 発話終了判定:
            //    - probが正常に動いているなら、(probが静か) または (RMSが静か) で無音タイマー開始
            //    - ただし prob が機能していない/常に低い場合、ORにすると常時 isSilent=true になり即終了するため、
            //      「開始がprobでトリガされていない」ターンでは終了判定でprobを無視して RMSのみで判定する。
            let probSaysSilent = (probability < speechEndThreshold)
            let rmsSaysSilent = (rmsDb < activeSpeechEndRmsThresholdDb)
            let isSilent = speechStartTriggeredByProb ? (probSaysSilent || rmsSaysSilent) : rmsSaysSilent
            if isSilent {
                if silenceTimer == nil {
                    let turnId = listeningTurnId
                    silenceTimer = Timer.scheduledTimer(withTimeInterval: activeMinSilenceDuration, repeats: false) { [weak self] _ in
                        Task { @MainActor [weak self] in
                            self?.handleSilenceTimeout(for: turnId, reason: "silence")
                        }
                    }
                }
            } else {
                silenceTimer?.invalidate()
                silenceTimer = nil
            }

            // ✅ 追加: 「STTが更新されない + 音はしている」状態が2秒続いたら発話終了
            // - 既存の無音判定が効かない（ノイズフロア張り付き等）場合のフォールバック
            if let reason = sttFallbackEndReason(now: Date()) {
                let turnId = listeningTurnId
                print("🛑 STT fallback detected -> end speech (turnId=\(turnId), reason=\(reason))")
                handleSilenceTimeout(for: turnId, reason: reason)
                return
            }
        }
    }

    func handleSilenceTimeout(for turnId: Int, reason: String) {
        guard turnId == currentTurnId, turnId == listeningTurnId else { return }
        guard vadState == .speaking else { return }
        cancelSTTVADEndTimer()
        silenceTimer?.invalidate()
        silenceTimer = nil
        // commit前に候補を退避（stopで消えるため）
        handsFreeMonitorFinalCandidate = handsFreeSTTLastNormalized

        // ✅ ここから先は「ターン確定処理」なので、VAD側の新規開始を止める
        turnState = .thinking

        let now = Date()
        let speechBegan = speechStartTime ?? now
        let duration = now.timeIntervalSince(speechBegan)
        speechStartTime = nil
        turnMetrics.speechEnd = now
        if let listenStart = turnMetrics.listenStart {
            let totalListen = now.timeIntervalSince(listenStart)
            print("⏱️ Latency: speech end [\(reason)] (listen->speechEnd=\(String(format: "%.2f", totalListen))s, speechDuration=\(String(format: "%.2f", duration))s)")
        } else {
            print("⏱️ Latency: speech end [\(reason)] (duration=\(String(format: "%.2f", duration))s)")
        }

        if duration < minSpeechDuration {
            vadState = .idle
            isUserSpeaking = false
            speechStartTriggeredByProb = false
            recordedPCMData.removeAll()
            let formattedDuration = String(format: "%.2f", duration)
            print("🪫 短すぎる発話を破棄 (duration=\(formattedDuration)s)")
            return
        }

        vadState = .idle
        speechStartTriggeredByProb = false
        commitUserSpeech()
    }

    func interruptAI() {
        guard turnState == .speaking else { return }
        print("⚡️ 割り込み検知: AI停止 -> 聞き取りへ")
        vadInterruptSpeechStart = nil
        ignoreIncomingAIChunks = true

        // 再生を即時停止し、マイクゲートを開く
        stopPlayer(reason: "interruptAI (barge-in)")
        playbackTurnId = nil
        isAIPlayingAudio = false
        isPlayingAudio = false
        mic?.setAIPlayingAudio(false)
        aiPlaybackStartedAt = nil

        // ✅ 重要：割り込み時に「ターン世代」を進めて、進行中のAIストリーム（旧ターン）を確実に無効化する。
        // - 旧ターンの完了処理が turnState を上書きすると、STT-VADの終了タイマーが guard で落ちて固まりやすい。
        // - onText/onAudioChunk だけでなく、stream完了側も isCurrentTurn ガードに乗るようにする。
        _ = advanceTurnId()

        // ステートをListeningへ戻し、バッファを新規発話用にする
        turnState = .listening
        markListeningTurn()
        recordedPCMData.removeAll()
        // STT-VADで開始判定を行うため、ここでは speaking には入れない
        vadState = .idle
        isUserSpeaking = false
        speechStartTime = nil
        cancelSTTVADEndTimer()
        handsFreeBargeInLastNormalized = ""
        turnMetrics = TurnMetrics()
        turnMetrics.listenStart = Date()
        print("⏱️ Latency: listen start (barge-in) at \(turnMetrics.listenStart!)")
        silenceTimer?.invalidate()
        silenceTimer = nil

        // ✅ バージイン直後も監視STTを先に起動
        startHandsFreeRealtimeSTTMonitorIfNeeded()

        // マイクが止まっていれば再開
        if !sharedAudioEngine.isRunning {
            try? sharedAudioEngine.start()
        }
        do {
            try mic?.start()
        } catch {
            errorMessage = "マイク再開に失敗しました: \(error.localizedDescription)"
            isRecording = false
            isHandsFreeMode = false
        }
    }

    func resumeListening() {
        guard isHandsFreeMode else { return }
        print("👂 聞き取り再開")
        turnState = .listening
        markListeningTurn()
        recordedPCMData.removeAll()
        isUserSpeaking = false
        turnMetrics = TurnMetrics()
        turnMetrics.listenStart = Date()
        print("⏱️ Latency: listen start (resume) at \(turnMetrics.listenStart!)")
        silenceTimer?.invalidate()
        silenceTimer = nil
        ignoreIncomingAIChunks = false

        // ✅ 再開時も先に監視STTを立ち上げておく（HFP等での遅延対策）
        startHandsFreeRealtimeSTTMonitorIfNeeded()

        if !sharedAudioEngine.isRunning {
            try? sharedAudioEngine.start()
        }

        do {
            try mic?.start()
        } catch {
            errorMessage = "マイク再開に失敗しました: \(error.localizedDescription)"
            isRecording = false
            isHandsFreeMode = false
        }
    }

    private func commitUserSpeech() {
        guard isHandsFreeMode else { return }
        guard isUserSpeaking else { return }
        print("🚀 発話終了判定 -> ゲート通過チェック")

        isUserSpeaking = false
        silenceTimer?.invalidate()
        silenceTimer = nil

        // ✅ フォールバック候補はここでローカルに退避しておく（次ターン開始等で上書きされ得るため）
        let monitorCandidateAtCommit = handsFreeMonitorFinalCandidate.trimmingCharacters(in: .whitespacesAndNewlines)
        handsFreeMonitorFinalCandidate = ""

        let audioData = recordedPCMData
        recordedPCMData.removeAll()
        let sampleRate = recordedSampleRate > 0 ? recordedSampleRate : 16_000
        let durationSec = Double(audioData.count) / 2.0 / sampleRate
        guard durationSec >= 0.2 else {
            let formatted = String(format: "%.2f", durationSec)
            print("🎧 User speech too short, discarding (\(formatted)s)")
            return
        }

        let wavData = pcm16ToWav(pcmData: audioData, sampleRate: sampleRate)

        Task { [weak self] in
            guard let self else { return }

            let transcript = await ConversationController.transcribeUserAudio(wavData: wavData)
            let cleaned = transcript?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let formattedDuration = String(format: "%.2f", durationSec)
            if cleaned.isEmpty || cleaned == "(voice)" {
                print("🔎 Local STT returned empty, skip AI request (duration=\(formattedDuration)s, bytes=\(audioData.count))")
            } else {
                print("📝 Local STT succeeded: '\(cleaned)' (duration=\(formattedDuration)s)")
            }

            await MainActor.run {
                // handleSilenceTimeout() 側で turnState を thinking にしているが、念のためここでも整合させる
                // ✅ AI応答中もバージイン検知のためマイクは動かし続ける（サーバ送信はMicrophoneCapture側でブロック済み）
                // self.mic?.stop() // <- 削除：マイクを停止するとバージインが機能しない
                self.turnState = .thinking
                if self.turnMetrics.speechEnd == nil { self.turnMetrics.speechEnd = Date() }
                if let listenStart = self.turnMetrics.listenStart, let speechEnd = self.turnMetrics.speechEnd {
                    print("⏱️ Latency: capture done (listen->speechEnd=\(String(format: "%.2f", speechEnd.timeIntervalSince(listenStart)))s)")
                }
            }

            // ✅ Local STT が空なら、並走STTの候補でフォールバック（デバッグにも有用）
            let userTextToSend: String = (!cleaned.isEmpty && cleaned != "(voice)") ? cleaned : monitorCandidateAtCommit

            if !userTextToSend.isEmpty, userTextToSend != "(voice)" {
                if cleaned.isEmpty || cleaned == "(voice)" {
                    print("🟨 Fallback to HandsFreeMonitor transcript: '\(userTextToSend)'")
                }
                await self.sendTextPreviewRequest(userText: userTextToSend)
            } else {
                await self.persistVoiceOnlyTurn()
                await MainActor.run {
                    self.isThinking = false
                    self.turnState = .waitingUser
                    if self.isHandsFreeMode && self.isRecording {
                        self.resumeListening()
                    }
                }
            }
        }
    }
}


