import Foundation
import SwiftUI
import AVFoundation
import Domain
import DataStores
import Services
import Support
import Speech

@available(iOS 17.0, *)
@MainActor
public final class ParentPhrasesController: ObservableObject {
    @Published var cards: [PhraseCard] = []
    @Published var isRecording: Bool = false
    @Published var isVoiceInputPresented: Bool = false
    @Published var voiceInputText: String = ""
    @Published var voiceInputError: String?
    @Published var voiceInputRMS: Double = -60.0
    @Published var isPlaying: Bool = false
    @Published var preparingCardId: UUID?
    @Published var editCard: PhraseCard?
    @Published var playingCardId: UUID?  // 再生中のカードID
    @Published var playbackProgress: Double = 0.0  // 再生進捗 (0.0〜1.0)

    private let repository: ParentPhrasesRepository
    // extension（別ファイル）から音声入力タップに使うため internal にしている
    let audioEngine: AVAudioEngine
    private let player: PlayerNodeStreamer
    private let ttsEngine: TTSEngineProtocol  // ✅ プロトコルで宣言（切り替え可能）
    private var playQueueTask: Task<Void, Never>?
    private var currentPlayRequestId: String?
    private let speech: SpeechRecognizing
    var speechTask: SpeechRecognitionTasking?
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    // extension（別ファイル）から停止処理に使うため internal にしている
    var micCapture: MicrophoneCapture?

    public init(userId: String?) {
        // リポジトリの選択
        if let userId = userId {
            // Firebase保存（本番用）
            self.repository = FirebaseParentPhrasesRepository(userId: userId)
            print("🔥 ParentPhrasesController: Firebaseリポジトリを使用 - userId=\(userId)")
        } else {
            // ローカル保存（SwiftData）- ログインしていない場合のフォールバック
            self.repository = try! SwiftDataParentPhrasesRepository()
            print("💾 ParentPhrasesController: SwiftDataリポジトリを使用（ローカル）")
        }

        // AudioEngine と PlayerNodeStreamer の初期化
        self.audioEngine = AVAudioEngine()
        self.player = PlayerNodeStreamer(sharedEngine: audioEngine)
        self.speech = SystemSpeechRecognizer(locale: "ja-JP")

        // TTS エンジンの選択（どちらかをコメントアウト）
        // 1. OpenAI TTS（高品質、ネットワーク必須、有料）
        self.ttsEngine = TTSEngine(player: player)

        // 2. AVSpeechSynthesizer（iOS標準、オフライン、無料、マスコット的な声）
        // self.ttsEngine = AVSpeechTTSEngine()

        Task {
            await loadCards()
            await startAudioEngine()
        }
    }

    private func ensureVoiceInputPermissions() async -> Bool {
        let micOK: Bool = await withCheckedContinuation { cont in
            AVAudioSession.sharedInstance().requestRecordPermission { granted in
                cont.resume(returning: granted)
            }
        }
        if !micOK {
            voiceInputError = "マイクの許可が必要です（設定 > Asobo > マイク）"
            return false
        }

        let speechOK: Bool = await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
        if !speechOK {
            voiceInputError = "音声認識の許可が必要です（設定 > Asobo > 音声認識）"
            return false
        }
        return true
    }

    private func startAudioEngine() async {
        do {
            // ❌ AudioSessionは設定しない（ConversationControllerが既に設定済み）
            // ConversationControllerと同じAudioSessionを共有するため、ここでは設定しない
            try audioEngine.start()
            print("✅ ParentPhrasesController: AudioEngine started")
        } catch {
            print("❌ ParentPhrasesController: AudioEngine start failed - \(error.localizedDescription)")
        }
    }

    func loadCards() async {
        do {
            self.cards = try await repository.fetchAll()
            print("✅ カード読み込み完了: \(cards.count)件")
        } catch {
            print("❌ カード読み込みエラー: \(error)")
        }
    }

    func filteredCards(for category: PhraseCategory) -> [PhraseCard] {
        cards
            .filter { $0.category == category }
            .sorted { card1, card2 in
                // 優先順位 → 使用回数 → 作成日の順
                if card1.priority != card2.priority {
                    return card1.priority < card2.priority
                }
                if card1.usageCount != card2.usageCount {
                    return card1.usageCount > card2.usageCount
                }
                return card1.createdAt > card2.createdAt
            }
    }

    // フレーズ読み上げ
    func playPhrase(_ card: PhraseCard) {
        // ✅ UX: 新しいカードが押されたら、前の再生（待機中のAPI含む）を即キャンセルして差し替える
        if isPlaying || playQueueTask != nil || preparingCardId != nil {
            currentPlayRequestId = nil
            playQueueTask?.cancel()
            playQueueTask = nil
            ttsEngine.cancelCurrentPlayback(reason: "user_tapped_new_card")
            isPlaying = false
            playingCardId = nil
            preparingCardId = nil
            playbackProgress = 0.0
        }

        let requestId = String(UUID().uuidString.prefix(8))
        playQueueTask = Task { @MainActor [weak self] in
            await self?.playCard(card, requestId: requestId)
            self?.playQueueTask = nil
        }
    }

    // 再生時間を推定（文字数ベース）
    private func estimatePlaybackDuration(text: String) async -> Double {
        // ✅ 体感に合わせて「短め」に寄せる（遅すぎる問題の改善）
        // 親フレーズは早口プリセットなので、文字/秒を高めに設定する
        // まだ「後半で加速」して見える場合は、この値が低すぎて音声より進捗が遅いのが原因なので上げる
        let charsPerSecond = 10.5
        let base = Double(text.count) / charsPerSecond
        // 先頭/末尾の余白 + 末尾無音(0.12s)を加味
        return max(base + 0.20 + 0.12, 0.65)
    }

    private func playCard(_ card: PhraseCard, requestId: String) async {
        currentPlayRequestId = requestId
        ttsEngine.beginRequest(requestId)

        // 使用回数をインクリメント
        try? await repository.incrementUsage(id: card.id)
        await loadCards()

        // TTSで読み上げ（開始までは準備中扱い）
        preparingCardId = card.id
        isPlaying = false
        playingCardId = nil
        playbackProgress = 0.0

        var shouldDelayFinalizeUI = false

        defer {
            if self.currentPlayRequestId == requestId {
                if shouldDelayFinalizeUI {
                    // ✅ 1.0が描画される前にバーが消える問題を防ぐ（体感で「99%で止まる」原因）
                    Task { @MainActor [weak self] in
                        guard let self else { return }
                        try? await Task.sleep(nanoseconds: 250_000_000) // 0.25s
                        // ✅ playingCardId は途中で変化しうるので、requestId一致だけで確実に解放する（固まり防止）
                        guard self.currentPlayRequestId == requestId else { return }
                        self.isPlaying = false
                        self.playingCardId = nil
                        self.preparingCardId = nil
                        self.playbackProgress = 0.0
                        self.currentPlayRequestId = nil
                    }
                } else {
                    self.isPlaying = false
                    self.playingCardId = nil
                    self.preparingCardId = nil
                    self.playbackProgress = 0.0
                    self.currentPlayRequestId = nil
                }
            }
        }

        do {
            // 再生時間を推定（TTSEngine内の計算と同じロジック）
            let estimatedDuration = await estimatePlaybackDuration(text: card.text)

            let speakTask = Task { @MainActor [weak self] in
                try await self?.ttsEngine.speak(text: card.text, requestId: requestId)
            }

            // ✅ 実再生開始を待つ（開始前のAPI待ちで進捗が動かないように）
            let didStart = await player.waitForPlaybackToStart(timeout: 10.0)
            if didStart, self.currentPlayRequestId == requestId {
                preparingCardId = nil
                isPlaying = true
                playingCardId = card.id

                let progressTask = Task { @MainActor in
                    let startTime = Date()
                    while !Task.isCancelled && self.playingCardId == card.id {
                        let elapsed = Date().timeIntervalSince(startTime)
                        // 再生中は「ほぼ最後」まで進め、完了時に1.0へ到達させる
                        self.playbackProgress = min(elapsed / estimatedDuration, 0.999)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }

                _ = try await speakTask.value
                progressTask.cancel()
                // ✅ ここが一気に飛ぶと「後半で加速」に見えるので、線形で1.0へ到達させる
                withAnimation(.linear(duration: 0.12)) {
                    playbackProgress = 1.0
                }
                shouldDelayFinalizeUI = true
            } else {
                _ = try await speakTask.value
            }
        } catch {
            print("❌ playPhrase[\(requestId)]: 再生エラー - text=\"\(card.text)\", error=\(error.localizedDescription)")
        }
    }

    // 音声入力（即時テキスト表示 → 追加へ）
    func startVoiceInput() {
        if isVoiceInputPresented { return }
        Task { @MainActor in
            self.voiceInputError = nil
            print("🎤 ParentPhrasesController: startVoiceInput()")

            guard await self.ensureVoiceInputPermissions() else {
                self.isVoiceInputPresented = true
                self.isRecording = false
                return
            }
            guard self.speech.isAvailable else {
                self.voiceInputError = "音声認識が現在利用できません。"
                print("⚠️ ParentPhrasesController: SpeechRecognizer not available")
                self.isVoiceInputPresented = true
                self.isRecording = false
                return
            }

            // 再生中なら止める（マイク入力と干渉しやすい）
            if self.isPlaying || self.preparingCardId != nil {
                self.currentPlayRequestId = nil
                self.playQueueTask?.cancel()
                self.playQueueTask = nil
                self.ttsEngine.cancelCurrentPlayback(reason: "voice_input_started")
                self.isPlaying = false
                self.playingCardId = nil
                self.preparingCardId = nil
                self.playbackProgress = 0.0
            }

            self.voiceInputText = ""
            self.isVoiceInputPresented = true

            // requestは使い回ししない（タスク跨ぎで壊れやすい）
            self.speechRequest?.endAudio()
            self.speechRequest = nil
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.speechRequest = request

            // ✅ 重要：AudioSession/Engineが止まっていると tap が一切流れず、RMSもSTTも更新されない
            // - category/mode は既存（Conversation側）を尊重し、ここでは「有効化」だけ行う
            let s = AVAudioSession.sharedInstance()
            do {
                try s.setActive(true)
            } catch {
                // ルート切替直後に失敗することがあるため1回だけリトライ
                try? await Task.sleep(nanoseconds: 250_000_000)
                do {
                    try s.setActive(true)
                } catch {
                    self.voiceInputError = "音声の準備に失敗しました（オーディオセッション）: \(error.localizedDescription)"
                    print("⚠️ ParentPhrasesController: AudioSession setActive failed - \(error.localizedDescription)")
                    self.isRecording = false
                    return
                }
            }

            do {
                self.audioEngine.prepare()
                if !self.audioEngine.isRunning {
                    try self.audioEngine.start()
                    print("✅ ParentPhrasesController: AudioEngine started (voice input)")
                }
            } catch {
                self.voiceInputError = "音声の準備に失敗しました（AudioEngine）: \(error.localizedDescription)"
                print("⚠️ ParentPhrasesController: AudioEngine start failed (voice input) - \(error.localizedDescription)")
                self.isRecording = false
                return
            }

            // ✅ ハンズフリーと同じ：MicrophoneCapture 経由で入力バッファ＋RMSを受け取る
            self.voiceInputRMS = -60.0
            self.micCapture?.stop()
            self.micCapture = MicrophoneCapture(
                sharedEngine: self.audioEngine,
                onPCM: { _ in },
                outputMonitor: self.player.outputMonitor
            )
            self.micCapture?.onInputBuffer = { [weak self] buffer in
                // Speech.frameworkへ入力を流す
                self?.speechRequest?.append(buffer)
            }
            self.micCapture?.onVolume = { [weak self] rms in
                Task { @MainActor in
                    self?.voiceInputRMS = rms
                }
            }
            do {
                try self.micCapture?.start()
            } catch {
                self.voiceInputError = "マイク開始に失敗: \(error.localizedDescription)"
                print("⚠️ ParentPhrasesController: mic start failed - \(error.localizedDescription)")
                self.isRecording = false
                return
            }

            self.speechTask?.cancel()
            self.speechTask = self.speech.startTask(
                request: request,
                onResult: { [weak self] text, isFinal in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.isVoiceInputPresented else { return }
                        self.voiceInputText = text
                        if isFinal {
                            self.stopVoiceInput(keepPanel: true)
                        }
                    }
                },
                onError: { [weak self] error in
                    Task { @MainActor in
                        guard let self else { return }
                        // キャンセル/無音系は黙って止める
                        let ns = error as NSError
                        let msg = ns.localizedDescription.lowercased()
                        let benign = msg.contains("canceled") || msg.contains("no speech")
                        if !benign {
                            self.voiceInputError = error.localizedDescription
                            print("⚠️ ParentPhrasesController: voice input error - \(error.localizedDescription)")
                        }
                        self.stopVoiceInput(keepPanel: true)
                    }
                }
            )

            self.isRecording = true
            print("🎤 ParentPhrasesController: voice input running")
        }
    }

    // toggle/cancel/stop/tap helpers are implemented in ParentPhrasesController+VoiceInput.swift

    func saveCard(_ card: PhraseCard) {
        Task {
            try? await repository.upsert(card)
            await loadCards()
            editCard = nil
            print("✅ カード保存完了: \(card.text)")
        }
    }

    func deleteCard(_ card: PhraseCard) {
        Task {
            try? await repository.delete(id: card.id)
            await loadCards()
            print("🗑️ カード削除完了: \(card.text)")
        }
    }
}
