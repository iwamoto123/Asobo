import SwiftUI
import Domain

// MARK: - History List View
struct HistoryListView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var viewModel = HistoryViewModel()
    
    // 3回以上のターンのセッションのみをフィルタリング
    private var filteredSessions: [FirebaseConversationSession] {
        viewModel.sessions.filter { $0.turnCount >= 3 }
    }
    
    init() {
        // ナビゲーションバーの背景を透明にして、アプリの背景色を活かす設定
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(Color(hex: "5A4A42")),
            .font: UIFont.systemFont(ofSize: 34, weight: .bold) // ほんとは丸ゴシックにしたい
        ]
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor(Color(hex: "5A4A42")),
            .font: UIFont.systemFont(ofSize: 17, weight: .bold)
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                // 1. 背景 (ホーム画面と共通)
                LinearGradient(
                    gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
                
                // 背景の浮遊物
                AmbientCircles()
                
                // 2. コンテンツ
                Group {
                    if viewModel.isLoading {
                        ProgressView("読み込み中...")
                            .tint(Color.anoneButton)
                            .foregroundColor(Color(hex: "5A4A42"))
                    } else if let errorMessage = viewModel.errorMessage {
                        ErrorStateView(message: errorMessage) {
                            Task { await viewModel.loadSessions() }
                        }
                    } else if filteredSessions.isEmpty {
                        EmptyStateView()
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 16) {
                                ForEach(filteredSessions) { session in
                                    NavigationLink(destination: ChatDetailView(session: session)) {
                                        SessionCardView(session: session, viewModel: viewModel)
                                    }
                                    .buttonStyle(ScaleButtonStyle()) // 押した時のアニメーション
                                }
                            }
                            .padding(20)
                            // 下部のタブバーとかぶらないように余白
                            .padding(.bottom, 80)
                        }
                    }
                }
            }
            .navigationTitle("おもいで")
            .navigationBarTitleDisplayMode(.large)
            .task {
                // ✅ AuthViewModelからユーザー情報を取得してHistoryViewModelに設定
                if let userId = authVM.currentUser?.uid, let childId = authVM.selectedChild?.id {
                    viewModel.setupUser(userId: userId, childId: childId)
                }
                await viewModel.loadSessions()
            }
            .onChange(of: authVM.selectedChild?.id) { newChildId in
                // ✅ 子供が変更された場合も更新
                if let userId = authVM.currentUser?.uid, let childId = newChildId {
                    viewModel.setupUser(userId: userId, childId: childId)
                    Task { await viewModel.loadSessions() }
                }
            }
            .refreshable {
                await viewModel.loadSessions()
            }
        }
    }
}

// MARK: - Subviews

/// 会話セッションのカード（おもいでカード）
struct SessionCardView: View {
    let session: FirebaseConversationSession
    let viewModel: HistoryViewModel
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }
    
    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            // 左側: 日付バッジ
            VStack(spacing: 4) {
                // 日付から「日」を取得する簡易ロジック
                let month = Calendar.current.component(.month, from: session.startedAt)
                let day = Calendar.current.component(.day, from: session.startedAt)
                let weekday = Calendar.current.component(.weekday, from: session.startedAt)
                let weekdaySymbol = Calendar.current.shortWeekdaySymbols[weekday - 1]
                
                Text("\(month)月")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Color.gray.opacity(0.6))
                Text("\(day)")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(Color.anoneButton)
                Text(weekdaySymbol)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundColor(Color.gray.opacity(0.6))
            }
            .frame(width: 50)
            
            // 右側: 内容
            VStack(alignment: .leading, spacing: 8) {
                // 時間と要約
                HStack {
                    Text(timeFormatter.string(from: session.startedAt))
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.gray)
                    
                    Spacer()
                    
                    if session.mode == .story {
                        Label("おはなし", systemImage: "book.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.purple)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(Color.purple.opacity(0.1))
                            .cornerRadius(4)
                    }
                }
                
                // メインテキスト（要約）
                Text(session.summaries.first ?? "たのしい おしゃべり")
                    .font(.system(size: 16, weight: .medium, design: .rounded))
                    .foregroundColor(Color(hex: "5A4A42"))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                
                // 興味タグ
                if !session.interestContext.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(session.interestContext, id: \.self) { tag in
                                InterestTagView(tag: tag)
                            }
                        }
                    }
                    .padding(.top, 4)
                    
                    // タグがある場合もやり取りの回数を表示
                    Text("\(session.turnCount)回のやり取り")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.top, 2)
                } else {
                    // タグがない場合はターン数のみ表示
                    Text("\(session.turnCount)回のやり取り")
                        .font(.system(size: 12, design: .rounded))
                        .foregroundColor(.gray.opacity(0.7))
                        .padding(.top, 4)
                }
            }
        }
        .padding(16)
        .background(Color.white)
        .cornerRadius(20)
        // クレイモーフィズム風の影
        .shadow(color: .anoneShadowDark.opacity(0.15), radius: 10, x: 5, y: 5)
        .shadow(color: .white, radius: 10, x: -5, y: -5)
    }
}

/// 興味タグのチップ
struct InterestTagView: View {
    let tag: FirebaseInterestTag
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName(for: tag))
                .font(.system(size: 10))
            Text(tagDisplayName(tag))
                .font(.system(size: 11, weight: .bold, design: .rounded))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(tagColor(for: tag).opacity(0.15))
        .foregroundColor(tagColor(for: tag))
        .cornerRadius(12)
    }
    
    // タグごとの色定義
    private func tagColor(for tag: FirebaseInterestTag) -> Color {
        switch tag {
        case .dinosaurs: return .green
        case .space: return .blue
        case .cooking: return .orange
        case .animals: return .brown
        case .vehicles: return .red
        case .music: return .purple
        case .princess: return .pink
        default: return .gray
        }
    }
    
    // タグごとのアイコン定義
    private func iconName(for tag: FirebaseInterestTag) -> String {
        switch tag {
        case .dinosaurs: return "lizard.fill"
        case .space: return "star.fill"
        case .cooking: return "fork.knife"
        case .animals: return "pawprint.fill"
        case .vehicles: return "car.fill"
        case .music: return "music.note"
        case .sports: return "sportscourt.fill"
        case .stories: return "book.fill"
        case .insects: return "ant.fill"
        case .princess: return "crown.fill"
        default: return "tag.fill"
        }
    }
    
    private func tagDisplayName(_ tag: FirebaseInterestTag) -> String {
        switch tag {
        case .dinosaurs: return "きょうりゅう"
        case .space: return "うちゅう"
        case .cooking: return "りょうり"
        case .animals: return "どうぶつ"
        case .vehicles: return "のりもの"
        case .music: return "おんがく"
        case .sports: return "スポーツ"
        case .crafts: return "こうさく"
        case .stories: return "おはなし"
        case .insects: return "むし"
        case .princess: return "プリンセス"
        case .heroes: return "ヒーロー"
        case .robots: return "ロボット"
        case .nature: return "しぜん"
        case .others: return "そのほか"
        }
    }
}

/// 空の状態の表示
struct EmptyStateView: View {
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.5))
                    .frame(width: 120, height: 120)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 50))
                    .foregroundColor(.anoneButton)
            }
            
            Text("まだ おもいでが ないよ")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "5A4A42"))
            
            Text("たくさん おはなしして\nおもいでを つくろう！")
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// エラー状態の表示
struct ErrorStateView: View {
    let message: String
    let retryAction: () -> Void
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundColor(.orange)
            Text("あれれ？")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "5A4A42"))
            Text(message)
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            
            Button(action: retryAction) {
                Text("もういちど")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 12)
                    .background(Color.anoneButton)
                    .cornerRadius(20)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// ボタンを押した時の縮小アニメーション
struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.spring(response: 0.3, dampingFraction: 0.6), value: configuration.isPressed)
    }
}
