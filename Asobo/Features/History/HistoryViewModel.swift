// MARK: - History ViewModel
// 会話履歴を管理するViewModel
import Foundation
import Domain
import DataStores

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var sessions: [FirebaseConversationSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    
    private let repository = FirebaseConversationsRepository()
    // TODO: 本来はFirebase Authから取得する必要がある
    private let userId = "dummy_parent_uid"
    // TODO: 選択中の子供IDを設定する必要がある
    private let childId = "dummy_child_uid"
    
    /// セッション一覧を読み込む
    func loadSessions() async {
        print("📱 HistoryViewModel: loadSessions開始 - userId: \(userId), childId: \(childId)")
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            self.sessions = try await repository.fetchSessions(userId: userId, childId: childId)
            print("✅ HistoryViewModel: セッション一覧読み込み完了 - count: \(sessions.count)")
            if sessions.isEmpty {
                print("⚠️ HistoryViewModel: セッションが0件です。Firebaseコンソールでデータが存在するか確認してください。")
            }
        } catch {
            let errorString = String(describing: error)
            errorMessage = "履歴の取得に失敗しました: \(errorString)"
            print("❌ HistoryViewModel: 履歴取得失敗 - \(error)")
            print("❌ HistoryViewModel: エラー詳細 - \(errorString)")
        }
    }
    
    /// セッションの要約を取得（最初の要約、または日付）
    func sessionSummary(for session: FirebaseConversationSession) -> String {
        if let firstSummary = session.summaries.first, !firstSummary.isEmpty {
            return firstSummary
        }
        // 要約がない場合は日付を表示
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: session.startedAt)
    }
    
    /// セッションの日付文字列を取得
    func sessionDateString(for session: FirebaseConversationSession) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: session.startedAt)
    }
}

