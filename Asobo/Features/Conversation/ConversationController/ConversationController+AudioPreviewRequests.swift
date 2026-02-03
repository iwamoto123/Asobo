import Foundation
import AVFoundation
import Speech
import Services
import Domain
import DataStores

extension ConversationController {
    // MARK: - Turn helpers (shared across extensions)
    func advanceTurnId() -> Int {
        currentTurnId += 1
        playbackTurnId = nil
        return currentTurnId
    }

    func markListeningTurn() {
        listeningTurnId = currentTurnId
        silenceTimer?.invalidate()
        silenceTimer = nil
    }

    func isCurrentTurn(_ turnId: Int) -> Bool {
        turnId == currentTurnId
    }

    // MARK: - Local transcription helper (for history)
    /// ユーザー音声をローカルで文字起こし（会話履歴用）。失敗時は nil を返す。
    nonisolated static func transcribeUserAudio(wavData: Data) async -> String? {
        // ✅ オフラインSTTが不安定な環境では早期に諦めてエラーを抑制
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        guard authStatus == .authorized,
              let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ja-JP")),
              recognizer.isAvailable else { return nil }

        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent("user_audio_\(UUID().uuidString).wav")
        do {
            try wavData.write(to: tmpURL)
        } catch {
            print("⚠️ UserAudioTranscribe: write failed - \(error)")
            return nil
        }

        return await withCheckedContinuation { continuation in
            var didFinish = false
            func finish(_ text: String?) {
                if didFinish { return }
                didFinish = true
                continuation.resume(returning: text)
                try? FileManager.default.removeItem(at: tmpURL)
            }

            let request = SFSpeechURLRecognitionRequest(url: tmpURL)
            var task: SFSpeechRecognitionTask?
            task = recognizer.recognitionTask(with: request) { result, error in
                if let result = result, result.isFinal {
                    finish(result.bestTranscription.formattedString)
                    task?.cancel()
                } else if let error = error {
                    // kAFAssistantErrorDomain 1101 は「ローカル認識不可」で頻発するため静かに無視
                    let nsError = error as NSError
                    if !(nsError.domain == "kAFAssistantErrorDomain" && nsError.code == 1101) {
                        print("⚠️ UserAudioTranscribe: recognition error - \(error)")
                    }
                    finish(nil)
                }
            }
        }
    }

    // MARK: - Audio-preview requests
    func sendTextPreviewRequest(userText: String) async {
        guard let client = audioPreviewClient else {
            await MainActor.run { self.errorMessage = "音声プレビュークライアントが初期化されていません" }
            return
        }

        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // ✅ このターンの「話者（子）」メタ情報は、リクエスト開始時点でスナップショットする
        // （レスポンス待ちの間にUIの“押下”が離れても、会話としては押下中に話していたことがあるため）
        let speakerChildIdForThisTurn = self.speakerChildIdOverride
        let speakerChildNameForThisTurn = self.speakerChildNameOverride

        await MainActor.run {
            // ✅ 履歴に積むのと同じ確定テキストをUIへ公開（Homeのモニター表示用）
            self.lastCommittedUserText = trimmed
            // 新しい返答を開始するので前の表示テキストをクリア
            self.aiResponseText = ""
            self.turnMetrics.requestStart = Date()
            self.logTurnStageTiming(event: "request", at: self.turnMetrics.requestStart!)
        }

        let turnId = advanceTurnId()
        ignoreIncomingAIChunks = false

        // AIが考え始めるタイミングで相槌を打つ
        await MainActor.run {
            self.isThinking = true
            self.playRandomFiller()
            self.player.prepareForNextStream()
        }

        let tStart = Date()
        print("⏱️ ConversationController: sendTextPreviewRequest start - textLen=\(trimmed.count)")
        print("🧩 ConversationController: systemPrompt audioMissingBoost=\(audioMissingConsecutiveCount > 0) (consecutive=\(audioMissingConsecutiveCount))")
        let promptHead = String(currentSystemPrompt.prefix(140)).replacingOccurrences(of: "\n", with: "\\n")
        print("🧩 ConversationController: systemPrompt head(140)=\(promptHead)")

        do {
            let result = try await client.streamResponseText(
                userText: trimmed,
                systemPrompt: currentSystemPrompt,
                history: conversationHistory,
                userMessagePrefix: audioPreviewUserMessagePrefix,
                onText: { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        if self.turnMetrics.firstText == nil {
                            self.turnMetrics.firstText = Date()
                            self.logTurnStageTiming(event: "firstText", at: self.turnMetrics.firstText!)
                        }
                        let clean = self.sanitizeAIText(delta)
                        if clean.isEmpty { return }
                        print("🟦 onText delta (clean):", clean)
                        self.aiResponseText += clean
                    }
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        print("🔊 onAudioChunk bytes:", chunk.count)
                        self.playbackTurnId = turnId
                        self.turnState = .speaking
                        // 相槌が鳴っていても強制停止せず自然に終わらせる
                        if self.isFillerPlaying {
                            self.isFillerPlaying = false
                        }
                        self.handleFirstAudioChunk(for: turnId)
                        self.player.resumeIfNeeded()
                        // 出力はpcm16指定なのでそのまま再生
                        self.player.playChunk(chunk)
                    }
                },
                onFirstByte: { [weak self] firstByte in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        self.turnMetrics.firstByte = firstByte
                        self.logTurnStageTiming(event: "firstByte", at: firstByte)
                    }
                }
            )
            let tEnd = Date()
            print("⏱️ ConversationController: sendTextPreviewRequest completed in \(String(format: "%.2f", tEnd.timeIntervalSince(tStart)))s, finalText.count=\(result.text.count), finalText=\"\(result.text)\", audioMissing=\(result.audioMissing)")
            audioMissingConsecutiveCount = result.audioMissing ? min(audioMissingConsecutiveCount + 1, 3) : 0
            let cleanFinal = self.sanitizeAIText(result.text)
            guard self.isCurrentTurn(turnId) else { return }
            turnMetrics.streamComplete = tEnd
            logTurnStageTiming(event: "streamComplete", at: tEnd)
            logTurnLatencySummary(context: "stream complete (text)")

            await MainActor.run {
                // 吹き出し用に最終テキストをUIへ反映
                self.aiResponseText = cleanFinal
                if !result.audioMissing {
                    if self.isHandsFreeMode && self.isRecording && self.turnState != .speaking {
                        self.resumeListening()
                    } else if self.turnState != .speaking {
                        self.turnState = .waitingUser
                        self.startWaitingForResponse()
                    }
                } else {
                    print("🎺 ConversationController: text-only response -> fallback TTS will run")
                }
            }

            if result.audioMissing {
                await self.playFallbackTTS(text: cleanFinal, turnId: turnId)
            }

            // Firebase保存
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                let speakerChildId = speakerChildIdForThisTurn
                let speakerChildName = speakerChildNameForThisTurn
                let userTurn = FirebaseTurn(role: .child, text: trimmed, timestamp: Date())
                let aiTurn = FirebaseTurn(role: .ai, text: cleanFinal, timestamp: Date())
                print("🗂️ ConversationController: append inMemoryTurns (user:'\(userTurn.text ?? "nil")', ai:'\(aiTurn.text ?? "nil")')")
                inMemoryTurns.append(contentsOf: [userTurn, aiTurn])
                // ✅ 履歴にテキストを積む（直近の文脈としてステートレスAPIへ渡す）
                conversationHistory.append(HistoryItem(role: "user", text: trimmed))
                conversationHistory.append(HistoryItem(role: "assistant", text: cleanFinal))
                // 履歴が長くなりすぎないように6ターン分（12エントリ）に抑える
                if conversationHistory.count > 12 {
                    conversationHistory.removeFirst(conversationHistory.count - 12)
                }
                turnCount += 2
                let updatedTurnCount = turnCount
                Task.detached { [weak self, userId, childId, sessionId, userTurn, aiTurn, updatedTurnCount, speakerChildId, speakerChildName] in
                    let repo = FirebaseConversationsRepository()
                    do {
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: aiTurn)
                        try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
                        if speakerChildId != nil || speakerChildName != nil {
                            try? await repo.updateSpeakerAttribution(
                                userId: userId,
                                childId: childId,
                                sessionId: sessionId,
                                speakerChildId: speakerChildId,
                                speakerChildName: speakerChildName
                            )
                        }
                    } catch {
                        await MainActor.run {
                            self?.logFirebaseError(error, operation: "テキスト会話の保存")
                        }
                    }
                }

                // 各ターンの終了時にライブ要約/タグ/新語を生成して即時保存
                liveSummaryTask?.cancel()
                liveSummaryTask = Task { [weak self] in
                    print("📝 ConversationController: live analysis task start (turnCount=\(self?.inMemoryTurns.count ?? 0))")
                    await self?.generateLiveAnalysisAndPersist()
                    print("📝 ConversationController: live analysis task end (summary='\(self?.liveSummary ?? "")', interests=\(self?.liveInterests.map { $0.rawValue } ?? []), newWords=\(self?.liveNewVocabulary ?? []))")
                }
            }
        } catch {
            print("❌ ConversationController: sendTextPreviewRequest failed - \(error)")
            await MainActor.run {
                guard self.isCurrentTurn(turnId) else { return }
                self.errorMessage = error.localizedDescription
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
        }

        await MainActor.run {
            if self.isCurrentTurn(turnId) {
                self.isThinking = false
            }
        }
    }

    func sendAudioPreviewRequest() async {
        guard let client = audioPreviewClient else {
            await MainActor.run { self.errorMessage = "音声プレビュークライアントが初期化されていません" }
            return
        }

        // ✅ このターンの「話者（子）」メタ情報は、リクエスト開始時点でスナップショットする
        // - Note: 録音中に押されていた名前を優先したいので、locked -> override の順で解決する
        let speakerChildIdForThisTurn = self.lockedSpeakerChildIdForTurn ?? self.speakerChildIdOverride
        let speakerChildNameForThisTurn = self.lockedSpeakerChildNameForTurn ?? self.speakerChildNameOverride
        // 次ターンへ持ち越さない
        self.lockedSpeakerChildIdForTurn = nil
        self.lockedSpeakerChildNameForTurn = nil

        await MainActor.run {
            // 新しい返答を開始するので前の表示テキストをクリア
            self.aiResponseText = ""
            self.turnMetrics.requestStart = Date()
            self.logTurnStageTiming(event: "request", at: self.turnMetrics.requestStart!)
        }

        let captured = recordedPCMData
        recordedPCMData.removeAll()
        guard !captured.isEmpty else {
            await MainActor.run {
                self.errorMessage = "音声が録音されていません"
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
            return
        }

        let turnId = advanceTurnId()
        ignoreIncomingAIChunks = false

        // AIが考え始めるタイミングで相槌を打つ
        await MainActor.run {
            self.isThinking = true
            self.playRandomFiller()
        }

        let wav = pcm16ToWav(pcmData: captured, sampleRate: recordedSampleRate)

        // ユーザー音声も会話履歴にテキストで残すため、ローカルで並行して文字起こしを試みる
        let userTranscriptionTask: Task<String?, Never>? = enableLocalUserTranscription
            ? Task.detached { [wavData = wav] in
                await ConversationController.transcribeUserAudio(wavData: wavData)
            }
            : nil

        let tStart = Date()
        print("🧩 ConversationController: systemPrompt audioMissingBoost=\(audioMissingConsecutiveCount > 0) (consecutive=\(audioMissingConsecutiveCount))")
        let promptHead = String(currentSystemPrompt.prefix(140)).replacingOccurrences(of: "\n", with: "\\n")
        print("🧩 ConversationController: systemPrompt head(140)=\(promptHead)")
        print("⏱️ ConversationController: sendAudioPreviewRequest start - pcmBytes=\(captured.count), sampleRate=\(recordedSampleRate)")
        await MainActor.run {
            self.player.prepareForNextStream()
        }

        do {
            let result = try await client.streamResponse(
                audioData: wav,
                systemPrompt: currentSystemPrompt,
                history: conversationHistory,
                userMessagePrefix: audioPreviewUserMessagePrefix,
                onText: { [weak self] delta in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        if self.turnMetrics.firstText == nil {
                            self.turnMetrics.firstText = Date()
                            self.logTurnStageTiming(event: "firstText", at: self.turnMetrics.firstText!)
                        }
                        let clean = self.sanitizeAIText(delta)
                        if clean.isEmpty { return }
                        print("🟦 onText delta (clean):", clean)
                        self.aiResponseText += clean
                    }
                },
                onAudioChunk: { [weak self] chunk in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        print("🔊 onAudioChunk bytes:", chunk.count)
                        self.playbackTurnId = turnId
                        self.turnState = .speaking
                        // 相槌が鳴っていても強制停止せず自然に終わらせる
                        if self.isFillerPlaying {
                            self.isFillerPlaying = false
                        }
                        self.handleFirstAudioChunk(for: turnId)
                        self.player.resumeIfNeeded()
                        // 出力はpcm16指定なのでそのまま再生
                        self.player.playChunk(chunk)
                    }
                },
                onFirstByte: { [weak self] firstByte in
                    guard let self else { return }
                    Task { @MainActor in
                        guard !self.ignoreIncomingAIChunks, self.isCurrentTurn(turnId) else { return }
                        self.turnMetrics.firstByte = firstByte
                        self.logTurnStageTiming(event: "firstByte", at: firstByte)
                    }
                }
            )
            let tEnd = Date()
            print("⏱️ ConversationController: streamResponse completed in \(String(format: "%.2f", tEnd.timeIntervalSince(tStart)))s, finalText.count=\(result.text.count), finalText=\"\(result.text)\", audioMissing=\(result.audioMissing)")
            audioMissingConsecutiveCount = result.audioMissing ? min(audioMissingConsecutiveCount + 1, 3) : 0
            let cleanFinal = self.sanitizeAIText(result.text)
            guard self.isCurrentTurn(turnId) else { return }
            turnMetrics.streamComplete = tEnd
            logTurnStageTiming(event: "streamComplete", at: tEnd)
            logTurnLatencySummary(context: "stream complete")

            await MainActor.run {
                // 吹き出し用に最終テキストをUIへ反映（音声のみの場合でもテキストを入れる）
                self.aiResponseText = cleanFinal
                print("🟩 set aiResponseText final:", cleanFinal)
                if !result.audioMissing {
                    if self.isHandsFreeMode && self.isRecording && self.turnState != .speaking {
                        self.resumeListening()
                    } else if self.turnState != .speaking {
                        self.turnState = .waitingUser
                        self.startWaitingForResponse()
                    }
                } else {
                    print("🎺 ConversationController: audio missing from stream -> fallback TTS will run")
                }
            }

            if result.audioMissing {
                await self.playFallbackTTS(text: cleanFinal, turnId: turnId)
            }

            // Firebase保存（ユーザー音声もローカル文字起こししたテキストを保存）
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                let speakerChildId = speakerChildIdForThisTurn
                let speakerChildName = speakerChildNameForThisTurn
                let userText = await userTranscriptionTask?.value?.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines)
                let userTurn = FirebaseTurn(role: .child, text: userText?.isEmpty == false ? userText! : "(voice)", timestamp: Date())
                let aiTurn = FirebaseTurn(role: .ai, text: cleanFinal, timestamp: Date())
                print("🗂️ ConversationController: append inMemoryTurns (user:'\(userTurn.text ?? "nil")', ai:'\(aiTurn.text ?? "nil")')")
                inMemoryTurns.append(contentsOf: [userTurn, aiTurn])
                // ✅ 履歴にテキストを積む（直近の文脈としてステートレスAPIへ渡す）
                let historyUserText = userText?.isEmpty == false ? userText! : "(不明瞭な音声)"
                self.lastCommittedUserText = historyUserText
                conversationHistory.append(HistoryItem(role: "user", text: historyUserText))
                conversationHistory.append(HistoryItem(role: "assistant", text: cleanFinal))
                // 履歴が長くなりすぎないように6ターン分（12エントリ）に抑える
                if conversationHistory.count > 12 {
                    conversationHistory.removeFirst(conversationHistory.count - 12)
                }
                turnCount += 2
                let updatedTurnCount = turnCount
                Task.detached { [weak self, userId, childId, sessionId, userTurn, aiTurn, updatedTurnCount, speakerChildId, speakerChildName] in
                    let repo = FirebaseConversationsRepository()
                    do {
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                        try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: aiTurn)
                        try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
                        if speakerChildId != nil || speakerChildName != nil {
                            try? await repo.updateSpeakerAttribution(
                                userId: userId,
                                childId: childId,
                                sessionId: sessionId,
                                speakerChildId: speakerChildId,
                                speakerChildName: speakerChildName
                            )
                        }
                    } catch {
                        await MainActor.run {
                            self?.logFirebaseError(error, operation: "音声会話の保存")
                        }
                    }
                }

                // 各ターンの終了時にライブ要約/タグ/新語を生成して即時保存
                liveSummaryTask?.cancel()
                liveSummaryTask = Task { [weak self] in
                    print("📝 ConversationController: live analysis task start (turnCount=\(self?.inMemoryTurns.count ?? 0))")
                    await self?.generateLiveAnalysisAndPersist()
                    print("📝 ConversationController: live analysis task end (summary='\(self?.liveSummary ?? "")', interests=\(self?.liveInterests.map { $0.rawValue } ?? []), newWords=\(self?.liveNewVocabulary ?? []))")
                }
            }
        } catch {
            print("❌ ConversationController: streamResponse failed - \(error)")
            await MainActor.run {
                guard self.isCurrentTurn(turnId) else { return }
                self.errorMessage = error.localizedDescription
                if self.isHandsFreeMode && self.isRecording {
                    self.resumeListening()
                } else {
                    self.turnState = .waitingUser
                }
            }
        }

        await MainActor.run {
            if self.isCurrentTurn(turnId) {
                self.isThinking = false
            }
        }
    }

    func persistVoiceOnlyTurn() async {
        let placeholder = "(voice)"
        print("🟨 persistVoiceOnlyTurn: saving placeholder '\(placeholder)'")
        lastCommittedUserText = placeholder
        inMemoryTurns.append(FirebaseTurn(role: .child, text: placeholder, timestamp: Date()))
        conversationHistory.append(HistoryItem(role: "user", text: placeholder))
        if conversationHistory.count > 12 {
            conversationHistory.removeFirst(conversationHistory.count - 12)
        }
        turnCount += 1
        let updatedTurnCount = turnCount

        guard let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId else { return }
        // できるだけ録音中の押下を優先してスナップショット
        let speakerChildId = self.lockedSpeakerChildIdForTurn ?? self.speakerChildIdOverride
        let speakerChildName = self.lockedSpeakerChildNameForTurn ?? self.speakerChildNameOverride
        Task.detached { [weak self, userId, childId, sessionId, updatedTurnCount, speakerChildId, speakerChildName] in
            let repo = FirebaseConversationsRepository()
            do {
                let userTurn = FirebaseTurn(role: .child, text: placeholder, timestamp: Date())
                try await repo.addTurn(userId: userId, childId: childId, sessionId: sessionId, turn: userTurn)
                try? await repo.updateTurnCount(userId: userId, childId: childId, sessionId: sessionId, turnCount: updatedTurnCount)
                if speakerChildId != nil || speakerChildName != nil {
                    try? await repo.updateSpeakerAttribution(
                        userId: userId,
                        childId: childId,
                        sessionId: sessionId,
                        speakerChildId: speakerChildId,
                        speakerChildName: speakerChildName
                    )
                }
            } catch {
                await MainActor.run {
                    self?.logFirebaseError(error, operation: "音声のみターンの保存")
                }
            }
        }
    }
}
