// MARK: - Main Tab View
// アプリのメインタブビュー（会話と履歴を切り替え）
import SwiftUI

struct MainTabView: View {
    var body: some View {
        TabView {
            // 会話タブ
            ConversationView()
                .tabItem {
                    Label("会話", systemImage: "bubble.left.and.bubble.right.fill")
                }
            
            // 履歴タブ
            HistoryListView()
                .tabItem {
                    Label("履歴", systemImage: "clock.fill")
                }
        }
    }
}

