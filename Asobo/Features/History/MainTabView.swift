// MARK: - Main Tab View
// アプリのメインタブビュー（ホーム、履歴、声かけ、プロフィールを切り替え）
import SwiftUI
import Domain

private let analytics = AnalyticsService.shared

struct MainTabView: View {
    @State private var selectedTab = 0
    @State private var previousTab = 0

    private func tabName(for index: Int) -> AnalyticsEvent.TabName {
        switch index {
        case 0: return .home
        case 1: return .history
        case 2: return .parentPhrases
        case 3: return .profile
        default: return .home
        }
    }

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
        .onChange(of: selectedTab) { newTab in
            if previousTab != newTab {
                analytics.log(.tabSwitch(fromTab: tabName(for: previousTab), toTab: tabName(for: newTab)))
                previousTab = newTab
            }
        }
    }
}
