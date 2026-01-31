import Foundation
import AVFoundation
import Speech

extension ConversationController {
    // MARK: - Hands-free realtime STT monitor helpers
    func normalizeRealtimeTranscript(_ text: String) -> String {
        // 日本語想定：余計な改行/空白を潰す（文字数ベースではなく「内容変化」を見る）
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // 連続空白/改行を1つに
        let collapsed = trimmed.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
        return collapsed
    }

    func startHandsFreeRealtimeSTTMonitorIfNeeded() {
        guard isHandsFreeMode else { return }
        // 既に開始済みなら何もしない
        if handsFreeSTTRequest != nil || handsFreeSTTTask != nil { return }

        // 権限が無い/利用不可ならフォールバックしない（既存VAD/RMSに任せる）
        guard handsFreeSpeech.isAvailable else {
            handsFreeMonitorStatus = "unavailable"
            print("⚠️ HandsFreeRealtimeSTTMonitor: unavailable (handsFreeSpeech.isAvailable=false)")
            return
        }
        guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
            handsFreeMonitorStatus = "unauthorized"
            print("⚠️ HandsFreeRealtimeSTTMonitor: unauthorized (status=\(SFSpeechRecognizer.authorizationStatus().rawValue))")
            return
        }

        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        handsFreeSTTRequest = req
        handsFreeSTTLastNormalized = ""
        handsFreeSTTLastChangeAt = nil
        handsFreeBargeInLastNormalized = ""
        handsFreeMonitorFinalCandidate = ""
        handsFreeMonitorStatus = "running"
        handsFreeMonitorTranscript = ""
        handsFreeMonitorLastUIUpdateAt = nil

        handsFreeSTTTask = handsFreeSpeech.startTask(
            request: req,
            onResult: { [weak self] text, isFinal in
                Task { @MainActor in
                    guard let self else { return }
                    guard self.isHandsFreeMode else { return }
                    let normalized = self.normalizeRealtimeTranscript(text)

                    // ① VAD/フォールバック用（通常の前回比較）
                    let previous = self.handsFreeSTTLastNormalized
                    let didChange = (!normalized.isEmpty && normalized != previous)
                    if didChange {
                        self.handsFreeSTTLastNormalized = normalized
                        self.handsFreeSTTLastChangeAt = Date()
                    }

                    // ② バージイン用（AI再生開始時にリセットされる前回比較）
                    let bargePrev = self.handsFreeBargeInLastNormalized
                    let didChangeForBargeIn = (!normalized.isEmpty && normalized != bargePrev)
                    if didChangeForBargeIn {
                        self.handsFreeBargeInLastNormalized = normalized
                    }

                    // ✅ バージイン: AI応答中でもマイクは動かし、ライブSTTの変化で割り込みを検知する
                    self.handleSTTBargeInIfNeeded(normalized: normalized, didChange: didChangeForBargeIn)

                    // ✅ 新方針: 発話開始/終了判定はSTTで行う
                    self.handleSTTVADUpdate(normalized: normalized, didChange: didChange, isFinal: isFinal)

                    // ✅ UI表示（更新頻度を抑えて警告を避ける）
                    let now = Date()
                    let shouldUIUpdate: Bool = {
                        if normalized == self.handsFreeMonitorTranscript { return false }
                        if let last = self.handsFreeMonitorLastUIUpdateAt,
                           now.timeIntervalSince(last) < self.handsFreeMonitorUIUpdateMinInterval {
                            return false
                        }
                        return true
                    }()
                    if shouldUIUpdate {
                        self.handsFreeMonitorTranscript = normalized
                        self.handsFreeMonitorLastUIUpdateAt = now
                        // ログ（必要ならここで見る）
                        if !normalized.isEmpty {
                            print("📝 HandsFreeMonitor STT:", normalized)
                        }
                    }
                    if isFinal {
                        // 監視目的なので、finalでも即停止しない（VAD側が終了を決める）
                    }
                }
            },
            onError: { [weak self] err in
                Task { @MainActor in
                    guard let self else { return }
                    let benign = Self.isBenignSpeechError(err)
                    let ns = err as NSError
                    let msg = ns.localizedDescription
                    if benign {
                        print("ℹ️ HandsFreeRealtimeSTTMonitor benign error -> restart (domain=\(ns.domain), code=\(ns.code))")
                    } else {
                        self.handsFreeMonitorStatus = "error"
                        print("⚠️ HandsFreeRealtimeSTTMonitor error: \(msg) (domain=\(ns.domain), code=\(ns.code))")
                    }
                    self.stopHandsFreeRealtimeSTTMonitor(setStatusOff: false)
                    self.scheduleHandsFreeRealtimeSTTMonitorRestart(delay: benign ? 0.2 : 0.8)
                }
            }
        )
    }

    func stopHandsFreeRealtimeSTTMonitor(setStatusOff: Bool = true) {
        handsFreeSTTRestartTask?.cancel()
        handsFreeSTTRestartTask = nil
        cancelSTTVADEndTimer()
        handsFreeSTTRequest?.endAudio()
        handsFreeSTTTask?.cancel()
        handsFreeSTTRequest = nil
        handsFreeSTTTask = nil
        handsFreeSTTLastNormalized = ""
        handsFreeSTTLastChangeAt = nil
        if setStatusOff {
            handsFreeMonitorStatus = "off"
        }
    }

    func scheduleHandsFreeRealtimeSTTMonitorRestart(delay: TimeInterval) {
        guard isHandsFreeMode else { return }
        // listen/AI再生中どちらでも監視STTは必要（バージイン用）
        handsFreeSTTRestartTask?.cancel()
        handsFreeMonitorStatus = "restarting"
        handsFreeSTTRestartTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return
            }
            guard self.isHandsFreeMode else { return }
            self.startHandsFreeRealtimeSTTMonitorIfNeeded()
        }
    }

    // MARK: - STT-based VAD logic
    func cancelSTTVADEndTimer() {
        sttVADEndTimer?.invalidate()
        sttVADEndTimer = nil
    }

    func handleSTTBargeInIfNeeded(normalized: String, didChange: Bool) {
        guard isHandsFreeMode else { return }
        // NOTE:
        // PlayerNodeStreamerの状態は「再生開始→一瞬で終了→再開」のように揺れることがあり、
        // isAIPlayingAudio だけに依存するとバージインを取りこぼす。
        // 「AIターン中（speaking）」または「AI再生中フラグ」であれば割り込みOKとする。
        // - PlayerNodeStreamerの状態が揺れて turnState が waitingUser になっても、AI音声が出ている間は割り込み検知を続ける。
        guard turnState == .speaking || isAIPlayingAudio else { return }
        guard didChange else { return }
        guard normalized.count >= sttBargeInMinChars else { return }

        let now = Date()
        if let last = lastSTTBargeInAt, now.timeIntervalSince(last) < sttBargeInMinInterval {
            return
        }
        if let started = aiPlaybackStartedAt, now.timeIntervalSince(started) < sttBargeInIgnoreWindowAfterPlaybackStart {
            return
        }

        // AIの自分の音声を拾っただけの可能性を少しだけ下げる（完全には防げない）
        if normalized.count >= 4, !aiResponseText.isEmpty, aiResponseText.contains(normalized) {
            return
        }

        lastSTTBargeInAt = now
        let head = String(normalized.prefix(40))
        let sinceStart: String = {
            guard let started = aiPlaybackStartedAt else { return "nil" }
            return String(format: "%.2fs", now.timeIntervalSince(started))
        }()
        print("⚡️ STT barge-in detected -> interruptAI (textHead='\(head)', isAIPlayingAudio=\(isAIPlayingAudio), playbackTurnId=\(String(describing: playbackTurnId)), sincePlaybackStart=\(sinceStart))")
        interruptAI()
    }

    func scheduleSTTVADEndTimer(turnId: Int) {
        cancelSTTVADEndTimer()
        let token = handsFreeSTTLastNormalized
        let tokenHead = String(token.prefix(40))
        sttVADEndTimer = Timer.scheduledTimer(withTimeInterval: sttVADEndSilenceDuration, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard self.isHandsFreeMode else { return }
                guard self.turnState == .listening else { return }
                guard turnId == self.currentTurnId, turnId == self.listeningTurnId else { return }
                guard self.vadState == .speaking, self.isUserSpeaking else { return }
                // STTが更新されていない（=最後の文字列と同じ）ことを確認して終了
                guard self.handsFreeSTTLastNormalized == token else { return }
                print("🟧 STT-VAD end by silence (turnId=\(turnId), tokenHead='\(tokenHead)')")
                self.handleSilenceTimeout(for: turnId, reason: "sttSilence")
            }
        }
    }

    func handleSTTVADUpdate(normalized: String, didChange: Bool, isFinal: Bool) {
        guard isHandsFreeMode else { return }
        guard turnState == .listening else { return }

        let now = Date()
        let turnId = listeningTurnId
        guard turnId == currentTurnId else { return }

        // 1) STTで文字が出たら「発話開始」
        if vadState == .idle {
            let hasText = !normalized.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if hasText, normalized.count >= sttVADSpeechStartMinChars {
                vadState = .speaking
                isUserSpeaking = true
                speechStartTime = speechStartTime ?? now
                // 旧VAD由来のフラグは使わない（STT起点）
                speechStartTriggeredByProb = false
                // 旧VADタイマーは無効化
                silenceTimer?.invalidate()
                silenceTimer = nil
                let head = String(normalized.prefix(40))
                print("🟩 STT-VAD start (turnId=\(turnId), textHead='\(head)')")
            }
        }

        // 2) 発話中は「STT更新が止まったら終了」タイマーを延長
        if vadState == .speaking, isUserSpeaking {
            // SFSpeechのisFinalは endAudio しないと来づらいので、基本は sttSilence で終了する
            if isFinal {
                handleSilenceTimeout(for: turnId, reason: "sttFinal")
                return
            }
            // STTが空のまま続く場合は sttNoText で打ち切り（ハング防止）
            if handsFreeSTTLastNormalized.isEmpty,
               let start = speechStartTime,
               now.timeIntervalSince(start) >= sttNoTextDuration {
                print("🟧 STT-VAD end by noText (turnId=\(turnId))")
                handleSilenceTimeout(for: turnId, reason: "sttNoText")
                return
            }
            // 「最後にテキストが変化した時刻」基準で終了を判定したいので、変更があった時だけタイマーを延長する
            if didChange || sttVADEndTimer == nil {
                scheduleSTTVADEndTimer(turnId: turnId)
            }
        }
    }

    func appendHandsFreeSTTInputBuffer(_ buffer: AVAudioPCMBuffer) {
        // ハンズフリー中のみ、監視用STTへ流す
        guard isHandsFreeMode else { return }
        handsFreeSTTAppendCount &+= 1
        let now = Date()

        // ✅ 監視STTが何らかの理由で落ちている場合、入力が来たタイミングで“メインスレッドで”自動復帰させる
        if handsFreeSTTRequest == nil || handsFreeSTTTask == nil {
            if let last = handsFreeSTTLastAutoStartAt, now.timeIntervalSince(last) < 0.5 {
                // throttle
            } else {
                handsFreeSTTLastAutoStartAt = now
                Task { @MainActor [weak self] in
                    self?.startHandsFreeRealtimeSTTMonitorIfNeeded()
                }
            }
        }

        // 🔎 AI再生中に「監視STTへ入力が流れているか」だけを低頻度でログ
        if isAIPlayingAudio {
            if let last = handsFreeSTTLastAppendLogAt, now.timeIntervalSince(last) < 1.0 {
                // throttle
            } else {
                handsFreeSTTLastAppendLogAt = now
                let active = (handsFreeSTTRequest != nil && handsFreeSTTTask != nil)
                print("🎙️ HandsFreeMonitor input while AI (active=\(active), status=\(handsFreeMonitorStatus), appendCount=\(handsFreeSTTAppendCount))")
            }
        }

        handsFreeSTTRequest?.append(buffer)
    }

    func sttFallbackEndReason(now: Date) -> String? {
        guard isHandsFreeMode else { return nil }
        guard vadState == .speaking, isUserSpeaking else { return nil }
        // 既存の無音タイマーが動いているなら、そちらが先に終了させるので二重判定しない
        guard silenceTimer == nil else { return nil }

        // 「音はしている」の確認（RMSが閾値以上の更新が直近にあること）
        let activityDelta = now.timeIntervalSince(lastUserVoiceActivityTime)
        guard activityDelta <= 0.4 else { return nil }

        // 1) 「テキスト化を検知後、更新が止まった」→ 発話終了
        let current = handsFreeSTTLastNormalized
        if current.count >= sttStagnationMinChars,
           let lastChange = handsFreeSTTLastChangeAt,
           now.timeIntervalSince(lastChange) >= sttStagnationDuration {
            return "sttStagnation"
        }

        // 2) 「テキストが一切出ないまま、音だけが続く」→ 発話（誤検知）を打ち切る
        if current.isEmpty, handsFreeSTTLastChangeAt == nil,
           let speechStartTime,
           now.timeIntervalSince(speechStartTime) >= sttNoTextDuration {
            return "sttNoText"
        }

        return nil
    }
}
