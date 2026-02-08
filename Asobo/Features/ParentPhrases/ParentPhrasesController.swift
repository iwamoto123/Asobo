import Foundation
import SwiftUI
import AVFoundation
import Domain
import DataStores
import Services
import Support
import Speech

private let analytics = AnalyticsService.shared

@available(iOS 17.0, *)
@MainActor
public final class ParentPhrasesController: ObservableObject {
    @Published var cards: [PhraseCard] = []
    @Published var hasLoadedCards: Bool = false
    @Published var customCategories: [PhraseCategory] = []
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
    private let customCategoriesKey: String
    private let removedCategoriesMigrationKey: String
    // extension（別ファイル）から音声入力タップに使うため internal にしている
    // ✅ 再生系（TTS/PlayerNodeStreamer）専用
    let audioEngine: AVAudioEngine
    // ✅ 音声入力（STT）専用：再生系と分離してハンズフリーへの影響をゼロに寄せる
    private let sttEngine: AVAudioEngine
    private let player: PlayerNodeStreamer
    private let ttsEngine: TTSEngineProtocol  // ✅ プロトコルで宣言（切り替え可能）
    private var playQueueTask: Task<Void, Never>?
    private var currentPlayRequestId: String?
    private let speech: SpeechRecognizing
    var speechTask: SpeechRecognitionTasking?
    var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    // extension（別ファイル）から停止処理に使うため internal にしている
    var micCapture: MicrophoneCapture?
    // extension（別ファイル）から停止処理に使うため internal にしている
    var micBufferObserver: NSObjectProtocol?
    var micRMSObserver: NSObjectProtocol?
    var voiceInputFallbackTask: Task<Void, Never>?
    var voiceInputLastBufferAt: Date?
    private var voiceInputPrefixText: String = ""

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
        self.sttEngine = AVAudioEngine()
        self.player = PlayerNodeStreamer(sharedEngine: audioEngine)
        self.speech = SystemSpeechRecognizer(locale: "ja-JP")
        self.customCategoriesKey = "ParentPhrases.customCategories.\(userId ?? "local")"
        self.removedCategoriesMigrationKey = "ParentPhrases.migration.removedOutingReturnHome.\(userId ?? "local")"

        // TTS エンジンの選択（どちらかをコメントアウト）
        // 1. OpenAI TTS（高品質、ネットワーク必須、有料）
        self.ttsEngine = TTSEngine(player: player)

        // 2. AVSpeechSynthesizer（iOS標準、オフライン、無料、マスコット的な声）
        // self.ttsEngine = AVSpeechTTSEngine()

        Task {
            self.loadCustomCategories()
            await loadCards()
        }
    }

    func availableCategories() -> [PhraseCategory] {
        var list: [PhraseCategory] = []
        let other = PhraseCategory.other

        // 1) 内蔵カテゴリ（「その他」は最後に回す）
        for c in PhraseCategory.builtinAllCases where !c.name.isEmpty && c != other {
            if !list.contains(c) { list.append(c) }
        }

        // 2) ユーザー追加カテゴリ（常に「その他」より前）
        for c in customCategories where !c.name.isEmpty && c != other {
            if !list.contains(c) { list.append(c) }
        }

        // 3) 既存カードから検出された未登録カテゴリ（ユーザーカテゴリ扱いで「その他」より前）
        for card in cards {
            let c = card.category
            if !c.name.isEmpty && c != other && !PhraseCategory.builtinAllCases.contains(c) {
                if !list.contains(c) { list.append(c) }
            }
        }

        // 4) 「その他」は常に最後
        if !list.contains(other) { list.append(other) }
        return list
    }

    func addCustomCategory(_ name: String) {
        let c = PhraseCategory(name)
        guard !c.name.isEmpty else { return }
        if !customCategories.contains(c) {
            customCategories.append(c)
            persistCustomCategories()
            analytics.log(.categoryCreated(name: name))
        }
    }

    private func loadCustomCategories() {
        let arr = UserDefaults.standard.array(forKey: customCategoriesKey) as? [String] ?? []
        self.customCategories = arr.map { PhraseCategory($0) }.filter { !$0.name.isEmpty }
    }

    private func persistCustomCategories() {
        let arr = customCategories.map(\.name)
        UserDefaults.standard.set(arr, forKey: customCategoriesKey)
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

    private func ensureAudioEngineRunning(reason: String) -> Bool {
        do {
            audioEngine.prepare()
            if !audioEngine.isRunning {
                try audioEngine.start()
                print("✅ ParentPhrasesController: AudioEngine started (\(reason))")
            }
            return true
        } catch {
            print("❌ ParentPhrasesController: AudioEngine start failed (\(reason)) - \(error.localizedDescription)")
            return false
        }
    }

    /// ✅ 非Bluetooth時に Receiver（受話口）へ落ちた場合だけ、スピーカーへ戻す
    /// - Note: 声かけ再生で .playback へ切り替えると「メディア音量(0になりがち)」へ切り替わり無音になり得るため、
    ///         カテゴリ/モードは触らず、ルーティングだけを最低限補強する。
    private func ensureSpeakerOutputIfNoBluetooth(reason: String) {
        let s = AVAudioSession.sharedInstance()
        let hasBluetoothOutput = s.currentRoute.outputs.contains(where: { out in
            out.portType == .bluetoothHFP || out.portType == .bluetoothA2DP || out.portType == .bluetoothLE
        })
        guard !hasBluetoothOutput else { return }

        // ✅ AudioSessionを常に再設定する（Bluetooth切断後の音量低下対策）
        // - Bluetooth(HFP)切断後、サンプルレートが8kHz/16kHzのまま残る問題を解消
        // - .playAndRecord + .defaultToSpeaker でスピーカー出力を確保
        // - .voiceChat モードでAEC有効化（マイク入力との干渉を防ぐ）
        // - 48kHz/10msバッファで高品質再生を確保
        do {
            // ✅ AudioEngine を常に停止（BT切断後の不整合状態をリセット）
            audioEngine.stop()
            // ✅ PlayerNodeStreamer の状態もリセット（内部バッファや接続をクリア）
            player.prepareForNextStream()
            print("🔧 ParentPhrasesController: AudioEngine & Player reset (\(reason))")

            try s.setCategory(.playAndRecord, options: [.defaultToSpeaker, .allowBluetooth, .allowBluetoothA2DP])
            try s.setMode(.voiceChat)
            // ✅ サンプルレートとバッファを明示的に設定（BT切断後の復旧）
            try s.setPreferredSampleRate(48_000)
            try s.setPreferredIOBufferDuration(0.01)  // 10ms
            try s.setActive(true)
            print("🔧 ParentPhrasesController: AudioSession configured - sampleRate=\(s.sampleRate)Hz (\(reason))")
        } catch {
            print("⚠️ ParentPhrasesController: AudioSession configuration failed - \(error.localizedDescription)")
        }

        // ✅ 非Bluetooth時は常にスピーカー出力を強制（受話口落ち対策）
        try? s.overrideOutputAudioPort(.speaker)
        #if canImport(UIKit)
        UIDevice.current.isProximityMonitoringEnabled = false
        #endif
        print("📢 ParentPhrasesController: speaker override applied (no BT) (\(reason))")
    }

    private func startStandaloneVoiceCapture() throws {
        // STT専用エンジンでマイクを掴む（再生系とは分離）
        micCapture?.stop()
        micCapture = nil

        guard let cap = MicrophoneCapture(
            sharedEngine: sttEngine,
            onPCM: { _ in },
            outputMonitor: nil,
            ownsEngine: true
        ) else {
            throw NSError(domain: "ParentPhrasesController", code: -1, userInfo: [
                NSLocalizedDescriptionKey: "MicrophoneCaptureの生成に失敗しました"
            ])
        }
        micCapture = cap
        cap.onInputBuffer = { [weak self] buffer in
            guard let self else { return }
            self.voiceInputLastBufferAt = Date()
            self.speechRequest?.append(buffer)
        }
        cap.onVolume = { [weak self] rms in
            guard let self else { return }
            self.voiceInputLastBufferAt = Date()
            Task { @MainActor in
                self.voiceInputRMS = rms
            }
        }
        try cap.start()
    }

    func loadCards() async {
        // 初回ロード完了までは空状態UIを出さない（チラつき防止）
        do {
            self.cards = try await repository.fetchAll()
            await migrateRemovedCategoriesIfNeeded()
            print("✅ カード読み込み完了: \(cards.count)件")
        } catch {
            print("❌ カード読み込みエラー: \(error)")
        }
        if !hasLoadedCards { hasLoadedCards = true }
    }

    /// 一回限りの移行: 「おでかけ」「帰宅後」を削除したので、既存カード/カスタムカテゴリがあれば「その他」へ寄せる
    private func migrateRemovedCategoriesIfNeeded() async {
        if UserDefaults.standard.bool(forKey: removedCategoriesMigrationKey) { return }

        let removed = Set(["おでかけ", "帰宅後"])
        var updated = false

        // カスタムカテゴリから除去
        let filteredCustom = customCategories.filter { !removed.contains($0.name) }
        if filteredCustom.count != customCategories.count {
            customCategories = filteredCustom
            persistCustomCategories()
            updated = true
        }

        // 既存カードのカテゴリ移行
        let targets = cards.filter { removed.contains($0.category.name) }
        if !targets.isEmpty {
            for card in targets {
                var c = card
                c.category = .other
                try? await repository.upsert(c)
            }
            updated = true
            self.cards = (try? await repository.fetchAll()) ?? self.cards
        }

        if updated {
            print("🔁 ParentPhrasesController: migrated removed categories -> その他")
        }
        UserDefaults.standard.set(true, forKey: removedCategoriesMigrationKey)
    }

    func filteredCards(for category: PhraseCategory) -> [PhraseCard] {
        cards
            .filter { $0.category == category }
            .sorted { card1, card2 in
                // ✅ 起動時は「使用回数が多い順」
                if card1.usageCount != card2.usageCount { return card1.usageCount > card2.usageCount }
                // タイブレーク: 最終使用 → 優先順位 → 作成日
                if let a = card1.lastUsedAt, let b = card2.lastUsedAt, a != b { return a > b }
                if card1.priority != card2.priority { return card1.priority < card2.priority }
                return card1.createdAt > card2.createdAt
            }
    }

    // テキストを直接読み上げ（保存前のプレビュー用）
    func playText(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // 再生中なら止める
        if isPlaying || playQueueTask != nil || preparingCardId != nil {
            currentPlayRequestId = nil
            playQueueTask?.cancel()
            playQueueTask = nil
            ttsEngine.cancelCurrentPlayback(reason: "user_tapped_preview")
            isPlaying = false
            playingCardId = nil
            preparingCardId = nil
            playbackProgress = 0.0
        }

        let requestId = String(UUID().uuidString.prefix(8))
        playQueueTask = Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentPlayRequestId = requestId
            self.ttsEngine.beginRequest(requestId)
            self.ensureSpeakerOutputIfNoBluetooth(reason: "playText")
            self.audioEngine.mainMixerNode.outputVolume = 1.0
            guard self.ensureAudioEngineRunning(reason: "playText") else { return }

            self.isPlaying = true
            defer {
                if self.currentPlayRequestId == requestId {
                    self.isPlaying = false
                    self.currentPlayRequestId = nil
                }
            }

            do {
                try await self.ttsEngine.speak(text: trimmed, requestId: requestId)
            } catch {
                print("❌ playText[\(requestId)]: 再生エラー - text=\"\(trimmed)\", error=\(error.localizedDescription)")
            }
            self.playQueueTask = nil
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

        analytics.log(.phraseCardPlay(category: card.category.name))

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

        // ✅ 非Bluetooth時の受話口落ち対策（カテゴリ切替はしない）
        ensureSpeakerOutputIfNoBluetooth(reason: "playCard")
        audioEngine.mainMixerNode.outputVolume = 1.0

        guard ensureAudioEngineRunning(reason: "playCard") else { return }

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
    func startVoiceInput(clearExistingText: Bool) {
        if isRecording { return }
        analytics.log(.voiceInputStart)
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

            self.isVoiceInputPresented = true
            self.voiceInputLastBufferAt = nil
            if clearExistingText {
                self.voiceInputText = ""
                self.voiceInputPrefixText = ""
            } else {
                self.voiceInputPrefixText = self.voiceInputText.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            // requestは使い回ししない（タスク跨ぎで壊れやすい）
            self.speechRequest?.endAudio()
            self.speechRequest = nil
            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            self.speechRequest = request

            // ✅ ハンズフリーに影響を出さないため、tapを増やさず “既存のMicrophoneCapture” の入力を購読する
            self.voiceInputRMS = -60.0
            self.micBufferObserver.map(NotificationCenter.default.removeObserver)
            self.micRMSObserver.map(NotificationCenter.default.removeObserver)
            self.micCapture?.stop()
            self.micCapture = nil
            self.voiceInputFallbackTask?.cancel()
            self.voiceInputFallbackTask = nil
            self.micBufferObserver = NotificationCenter.default.addObserver(
                forName: MicrophoneCapture.Notifications.inputBuffer,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let buffer = note.object as? AVAudioPCMBuffer else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isVoiceInputPresented else { return }
                    self.voiceInputLastBufferAt = Date()
                    self.speechRequest?.append(buffer)
                }
            }
            self.micRMSObserver = NotificationCenter.default.addObserver(
                forName: MicrophoneCapture.Notifications.rms,
                object: nil,
                queue: nil
            ) { [weak self] note in
                guard let rms = note.object as? Double else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    guard self.isVoiceInputPresented else { return }
                    self.voiceInputLastBufferAt = Date()
                    self.voiceInputRMS = rms
                }
            }

            // ✅ 0.6s待っても入力が来ない場合は「単独録音」にフォールバック
            // - ハンズフリーが動いている場合は通知経路が来るはずなので、影響ゼロのまま動く
            // - ハンズフリーが動いていない場合は単独エンジンで録音開始してテキスト化する
            self.voiceInputFallbackTask = Task { @MainActor [weak self] in
                guard let self else { return }
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard self.isVoiceInputPresented else { return }
                guard self.voiceInputLastBufferAt == nil else { return }

                // 通知購読を止め、単独キャプチャに切り替える（二重append防止）
                self.micBufferObserver.map(NotificationCenter.default.removeObserver)
                self.micBufferObserver = nil
                self.micRMSObserver.map(NotificationCenter.default.removeObserver)
                self.micRMSObserver = nil

                do {
                    try self.startStandaloneVoiceCapture()
                } catch {
                    self.voiceInputError = "音声入力を開始できませんでした。ハンズフリー/会話を停止してから、もう一度お試しください。"
                    print("⚠️ ParentPhrasesController: standalone mic start failed - \(error.localizedDescription)")
                }
            }

            self.speechTask?.cancel()
            self.speechTask = self.speech.startTask(
                request: request,
                onResult: { [weak self] text, isFinal in
                    Task { @MainActor in
                        guard let self else { return }
                        guard self.isVoiceInputPresented else { return }
                        let base = self.voiceInputPrefixText
                        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
                        if base.isEmpty {
                            self.voiceInputText = t
                        } else if t.isEmpty {
                            self.voiceInputText = base
                        } else {
                            self.voiceInputText = base + " " + t
                        }
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
        let isNew = !cards.contains(where: { $0.id == card.id })
        Task {
            try? await repository.upsert(card)
            await loadCards()
            editCard = nil
            if !card.category.isBuiltin {
                addCustomCategory(card.category.name)
            }
            analytics.log(.phraseCardSave(category: card.category.name, isNew: isNew))
            print("✅ カード保存完了: \(card.text)")
        }
    }

    func deleteCard(_ card: PhraseCard) {
        Task {
            try? await repository.delete(id: card.id)
            await loadCards()
            analytics.log(.phraseCardDelete(category: card.category.name))
            print("🗑️ カード削除完了: \(card.text)")
        }
    }
}
