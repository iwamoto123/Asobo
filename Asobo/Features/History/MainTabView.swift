// MARK: - Main Tab View
// アプリのメインタブビュー（ホーム、履歴、声かけ、プロフィールを切り替え）
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

            // 声かけタブ（新機能 - iOS 17以降のみ）
            if #available(iOS 17.0, *) {
                ParentPhrasesView()
                    .tabItem {
                        Label("声かけ", systemImage: "bubble.left.and.text.bubble.right.fill")
                    }
                    .tag(2)
            }

            // プロフィールタブ
            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("プロフィール", systemImage: "person.crop.circle")
            }
            .tag(3)
        }
    }
}
