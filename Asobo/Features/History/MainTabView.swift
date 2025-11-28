// MARK: - Main Tab View
// アプリのメインタブビュー（ホームと履歴を切り替え）
import SwiftUI

struct MainTabView: View {
    @State private var selectedTab = 0
    
    var body: some View {
        TabView(selection: $selectedTab) {
            // ホームタブ（最初の画面 - 会話機能を含む）
            ChildHomeView()
                .tabItem {
                    Label("ホーム", systemImage: "house.fill")
                }
                .tag(0)
            
            // 履歴タブ
            HistoryListView()
                .tabItem {
                    Label("履歴", systemImage: "clock.fill")
                }
                .tag(1)
        }
    }
}

