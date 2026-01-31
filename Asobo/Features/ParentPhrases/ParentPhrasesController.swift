import Foundation
import SwiftUI
import AVFoundation
import Domain
import DataStores
import Services

@available(iOS 17.0, *)
@MainActor
public final class ParentPhrasesController: ObservableObject {
    @Published var cards: [PhraseCard] = []
    @Published var isRecording: Bool = false
    @Published var isPlaying: Bool = false
    @Published var preparingCardId: UUID?
    @Published var editCard: PhraseCard?
    @Published var playingCardId: UUID?  // 再生中のカードID
    @Published var playbackProgress: Double = 0.0  // 再生進捗 (0.0〜1.0)

    private let repository: ParentPhrasesRepository
    private let audioEngine: AVAudioEngine
    private let player: PlayerNodeStreamer
    private let ttsEngine: TTSEngineProtocol  // ✅ プロトコルで宣言（切り替え可能）
    private var playQueueTask: Task<Void, Never>?
    private var currentPlayRequestId: String?

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
        // 推定はズレやすいので少し長めに見積もる（止まって見えにくくする）
        let baseSpeed = 4.3  // 文字/秒（少し遅め）
        let adjustedSpeed = baseSpeed * 1.25
        let duration = Double(text.count) / adjustedSpeed
        return max(duration + 0.9, 1.2)
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

        defer {
            if self.currentPlayRequestId == requestId {
                self.isPlaying = false
                self.playingCardId = nil
                self.preparingCardId = nil
                self.playbackProgress = 0.0
                self.currentPlayRequestId = nil
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
                        self.playbackProgress = min(elapsed / estimatedDuration, 0.985)
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                }

                _ = try await speakTask.value
                progressTask.cancel()
                playbackProgress = 1.0
            } else {
                _ = try await speakTask.value
            }
        } catch {
            print("❌ playPhrase[\(requestId)]: 再生エラー - text=\"\(card.text)\", error=\(error.localizedDescription)")
        }
    }

    // 音声入力（Phase 5で実装）
    func startVoiceInput() {
        Task {
            isRecording = true
            // TODO: Phase 5で STT実装
            print("🎤 音声入力開始")
            // ダミーの録音
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            isRecording = false
            print("🎤 音声入力終了")
        }
    }

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
