import Foundation
import AVFoundation
import Services
import Domain
import Support
import DataStores

extension ConversationController {
    // MARK: - Realtime（次の段階：会話）
    public func startRealtimeSession() {
        // 既に接続中または接続済みの場合は何もしない
        guard !isRealtimeActive && !isRealtimeConnecting else {
            print("⚠️ ConversationController: 既に音声プレビューセッションがアクティブまたは接続中です")
            return
        }
        // 既存のセッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        startRealtimeSessionInternal()
    }

    private func startRealtimeSessionInternal() {
        // 接続中フラグを設定
        isRealtimeConnecting = true
        nudgeCount = 0  // セッション開始時に促し回数をリセット
        logNetworkEnvironment()

        // オーディオセッションを構成
        do {
            try audioSessionManager.configure()

            // ✅ 共通エンジンを開始（AudioSession設定後）
            // ⚠️ 重要な順序：AudioSessionを設定してからエンジンを開始
            // ✅ 共通エンジンを開始することで、VoiceProcessingIO（AEC）が入出力の両方に効く
            try sharedAudioEngine.start()
            print("✅ ConversationController: 共通AudioEngine開始成功（AEC有効化）")

            // AudioSession設定後にPlayerNodeStreamerのエンジンを開始
            try player.start()

            // 音量確認（デバッグ用）
            let audioSession = AVAudioSession.sharedInstance()
            print("📊 ConversationController: オーディオ設定確認")
            print("   - OutputVolume: \(audioSession.outputVolume) (1.0が最大)")
            print("   - OutputChannels: \(audioSession.outputNumberOfChannels)")
            print("   - SampleRate: \(audioSession.sampleRate)Hz")

            if audioSession.outputVolume < 0.1 {
                print("⚠️ ConversationController: 音量が非常に低いです（\(audioSession.outputVolume)）。デバイスの音量設定を確認してください。")
            }

            print("✅ ConversationController: AudioSession設定とPlayerNodeStreamer開始成功")
        } catch {
            self.errorMessage = "AudioSession構成に失敗: \(error.localizedDescription)"
            print("❌ ConversationController: AudioSession構成失敗 - \(error.localizedDescription)")

            // 詳細なエラー情報をログに出力
            if let nsError = error as NSError? {
                print("   - Error Domain: \(nsError.domain)")
                print("   - Error Code: \(nsError.code)")
                print("   - Error Info: \(nsError.userInfo)")
            }
        }

        let key = AppConfig.openAIKey
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            self.errorMessage = "OPENAI_API_KEY が未設定です（Secrets.xcconfig を確認）"
            return
        }

        audioPreviewClient = AudioPreviewStreamingClient(
            apiKey: key,
            apiBase: URL(string: AppConfig.apiBase) ?? URL(string: "https://api.openai.com")!
        )

        // ✅ 重要: Playerの状態変化を監視して、正確なタイミングでマイクのゲートを開閉する
        player.onPlaybackStateChange = { [weak self] isPlaying in
            Task { @MainActor in
                guard let self = self else { return }
                guard let playbackId = self.playbackTurnId, playbackId == self.currentTurnId else {
                    if let playbackId = self.playbackTurnId {
                        print("⏭️ ConversationController: playback state change ignored for stale turn \(playbackId)")
                    }
                    if !isPlaying { self.playbackTurnId = nil }
                    return
                }
                self.isAIPlayingAudio = isPlaying
                self.isPlayingAudio = isPlaying
                self.mic?.setAIPlayingAudio(isPlaying)

                if isPlaying {
                    self.aiPlaybackStartedAt = Date()
                    // ✅ AI再生開始時にバージイン検知のベースをリセット（同一フレーズの繰り返しでも取りこぼしにくくする）
                    self.handsFreeBargeInLastNormalized = ""
                    // ✅ AI再生中のバージイン検知のため、監視STTが止まっていたら復帰させる
                    Task { @MainActor [weak self] in
                        self?.startHandsFreeRealtimeSTTMonitorIfNeeded()
                    }
                    print("🔊 ConversationController: 再生開始 - マイクゲート閉 (AEC/BargeInモード)")
                    if self.turnMetrics.firstAudio == nil {
                        self.turnMetrics.firstAudio = Date()
                        self.logTurnStageTiming(event: "firstAudio", at: self.turnMetrics.firstAudio!)
                    }
                } else {
                    self.aiPlaybackStartedAt = nil
                    print("🔇 ConversationController: 再生完全終了 - マイクゲート開")
                    // ✅ フォールバックTTSのボイス加工を元に戻す
                    if self.isFallbackTTSPlaybackActive, let restore = self.fallbackTTSVoiceFXRestore {
                        self.player.applyVoiceFXState(restore)
                        self.fallbackTTSVoiceFXRestore = nil
                        self.isFallbackTTSPlaybackActive = false
                        print("🎛️ ConversationController: fallback TTS voice FX restored")
                    }
                    // ✅ AIが完全に話し終わったら、ユーザーの入力を待つ状態にしてタイマーを開始（ハンズフリー時は即再開）
                    if self.isHandsFreeMode && self.isRecording {
                        self.resumeListening()
                    } else if self.turnState == .speaking {
                        self.turnState = .waitingUser
                        print("⏰ ConversationController: AIの音声再生完全終了 -> 促しタイマーを開始")
                        self.startWaitingForResponse()
                    }
                    self.turnMetrics.playbackEnd = Date()
                    // firstAudio が未設定で playbackEnd が先に来た場合のフォールバック
                    if self.turnMetrics.firstAudio == nil {
                        self.turnMetrics.firstAudio = self.turnMetrics.requestStart ?? self.turnMetrics.playbackEnd
                    }
                    if let end = self.turnMetrics.playbackEnd {
                        self.logTurnStageTiming(event: "playbackEnd", at: end)
                    }
                    self.logTurnLatencySummary(context: "playback complete")
                    self.playbackTurnId = nil
                }
            }
        }

        transcript = ""
        print("🟥 aiResponseText cleared at:", #function)
        aiResponseText = ""
        liveSummary = ""
        liveInterests = []
        liveNewVocabulary = []
        inMemoryTurns.removeAll()
        errorMessage = nil
        turnState = .waitingUser  // セッション開始時はユーザーが話すのを待つ

        // ✅ Firebaseにセッションを作成
        guard let userId = self.currentUserId, let childId = self.currentChildId else {
            print("⚠️ ConversationController: ユーザー情報が設定されていないため、セッションを作成できません")
            self.errorMessage = "ユーザー情報が設定されていません。ログインしてください。"
            return
        }

        let newSessionId = UUID().uuidString
        self.currentSessionId = newSessionId
        self.turnCount = 0
        conversationHistory.removeAll()
        lastCommittedUserText = ""

        // オーディオルート変更時にグラフを立て直す
        if routeChangeObserver == nil {
            routeChangeObserver = NotificationCenter.default.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] note in
                self?.handleAudioRouteChange(note)
            }
        }

        let session = FirebaseConversationSession(
            id: newSessionId,
            mode: .freeTalk,
            startedAt: Date(),
            interestContext: [],
            summaries: [],
            newVocabulary: [],
            turnCount: 0
        )

        Task.detached { [weak self, userId, childId, session] in
            let repo = FirebaseConversationsRepository()
            do {
                try await repo.createSession(
                    userId: userId,
                    childId: childId,
                    session: session
                )
                print("✅ ConversationController: Firebaseセッション作成完了 - sessionId: \(session.id ?? "nil")")
            } catch {
                await MainActor.run {
                    self?.logFirebaseError(error, operation: "Firebaseセッション作成")
                }
            }
        }

        sessionStartTask = Task { [weak self] in
            guard let self else { return }
            do {
                print("🚀 ConversationController: gpt-4o-audio-previewセッション開始")

                // 状態を更新
                await MainActor.run {
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = true
                    self.mode = .realtime
                    self.startWaitingForResponse()
                }
            } catch {
                print("❌ ConversationController: セッション開始失敗 - \(error.localizedDescription)")
                await MainActor.run {
                    self.errorMessage = "音声プレビュー接続失敗: \(error.localizedDescription)"
                    self.isRealtimeConnecting = false
                    self.isRealtimeActive = false
                }
            }
        }
    }

    public func stopRealtimeSession() {
        print("🛑 ConversationController: Realtimeセッション終了")
        ignoreIncomingAIChunks = true
        currentTurnId = 0
        listeningTurnId = 0
        playbackTurnId = nil

        // セッション開始タスクをキャンセル
        sessionStartTask?.cancel()
        sessionStartTask = nil

        // 受信タスクをキャンセル
        receiveTextTask?.cancel(); receiveTextTask = nil
        receiveAudioTask?.cancel(); receiveAudioTask = nil
        receiveInputTextTask?.cancel(); receiveInputTextTask = nil

        // マイクとプレイヤーを停止
        mic?.stop(); mic = nil
        stopPlayer(reason: "stopRealtimeSession")
        isAIPlayingAudio = false
        isPlayingAudio = false

        // ★ 重要：先にセッションを非アクティブ化（他アプリへも通知）
        let s = AVAudioSession.sharedInstance()
        try? s.setActive(false, options: [.notifyOthersOnDeactivation])

        // ★ エンジンを完全に解体
        sharedAudioEngine.inputNode.removeTap(onBus: 0)   // 冪等
        if sharedAudioEngine.isRunning {
            sharedAudioEngine.stop()
        }
        sharedAudioEngine.reset()                          // ← これが2回目クラッシュの予防線

        // ✅ 促しタイマーを停止
        cancelNudge()
        silenceTimer?.invalidate()
        silenceTimer = nil

        // 状態をリセット
        isRecording = false
        isHandsFreeMode = false
        isRealtimeActive = false
        isRealtimeConnecting = false
        turnState = .idle
        nudgeCount = 0
        liveSummaryTask?.cancel()
        liveSummaryTask = nil
        inMemoryTurns.removeAll()
        conversationHistory.removeAll()
        lastCommittedUserText = ""

        // テキストをクリア
        transcript = ""
        print("🟥 aiResponseText cleared at:", #function)
        aiResponseText = ""

        // エラーメッセージをクリア
        errorMessage = nil

        Task { [weak self] in
            guard let self else {
                print("⚠️ ConversationController: stopRealtimeSession - selfがnilのため処理をスキップ")
                return
            }

            // ✅ Firebaseにセッション終了を記録
            guard let userId = self.currentUserId, let childId = self.currentChildId, let sessionId = self.currentSessionId else {
                print("⚠️ ConversationController: stopRealtimeSession - ユーザー情報またはセッションIDがnilのため、セッション終了処理をスキップ")
                return
            }
            print("🔄 ConversationController: stopRealtimeSession - セッション終了処理開始 - sessionId: \(sessionId)")
            let endedAt = Date()
            do {
                try await self.firebaseRepository.finishSession(
                    userId: userId,
                    childId: childId,
                    sessionId: sessionId,
                    endedAt: endedAt
                )
                print("✅ ConversationController: Firebaseセッション終了更新完了 - sessionId: \(sessionId)")

                // ✅ 会話終了後の分析処理を実行
                print("🔄 ConversationController: stopRealtimeSession - 分析処理を開始します - sessionId: \(sessionId), turnCount=\(self.inMemoryTurns.count)")
                await self.analyzeSession(sessionId: sessionId)
                print("✅ ConversationController: stopRealtimeSession - 分析処理完了 - sessionId: \(sessionId)")
            } catch {
                print("❌ ConversationController: stopRealtimeSession - エラー発生: \(error)")
                self.logFirebaseError(error, operation: "Firebaseセッション終了更新")
            }

            await MainActor.run {
                self.currentSessionId = nil
                self.turnCount = 0
                print("✅ ConversationController: リソースクリーンアップ完了")
            }
        }
    }
}
