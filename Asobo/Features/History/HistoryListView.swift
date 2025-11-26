// MARK: - History List View
// 会話履歴一覧を表示するView
import SwiftUI
import Domain

struct HistoryListView: View {
    @StateObject private var viewModel = HistoryViewModel()
    @State private var selectedSession: FirebaseConversationSession?
    
    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    ProgressView("読み込み中...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = viewModel.errorMessage {
                    VStack(spacing: 16) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 48))
                            .foregroundColor(.orange)
                        Text(errorMessage)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("再試行") {
                            Task {
                                await viewModel.loadSessions()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if viewModel.sessions.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "bubble.left.and.bubble.right")
                            .font(.system(size: 48))
                            .foregroundColor(.secondary)
                        Text("会話履歴がありません")
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List {
                        ForEach(viewModel.sessions) { session in
                            NavigationLink(destination: ChatDetailView(session: session)) {
                                SessionRowView(session: session, viewModel: viewModel)
                            }
                            .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        }
                    }
                    .listStyle(.plain)
                    .refreshable {
                        await viewModel.loadSessions()
                    }
                }
            }
            .navigationTitle("会話履歴")
            .navigationBarTitleDisplayMode(.large)
            .task {
                print("📱 HistoryListView: タスク開始 - データ読み込み開始")
                await viewModel.loadSessions()
            }
            .onAppear {
                print("📱 HistoryListView: ビュー表示 - タブが選択されました")
            }
        }
    }
}

// MARK: - Session Row View
// セッション一覧の各行（LINE風デザイン）
struct SessionRowView: View {
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
        HStack(alignment: .top, spacing: 12) {
            // アイコン（会話アイコン）
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.1))
                    .frame(width: 50, height: 50)
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 20))
                    .foregroundColor(.blue)
            }
            
            // コンテンツ
            VStack(alignment: .leading, spacing: 6) {
                // 日付と時間
                HStack {
                    Text(viewModel.sessionDateString(for: session))
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    Text(timeFormatter.string(from: session.startedAt))
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                
                // 要約またはプレビュー
                if let summary = session.summaries.first, !summary.isEmpty {
                    Text(summary)
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                } else {
                    Text("\(session.turnCount)回のやり取り")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                        .italic()
                }
                
                // メタ情報（タグ）
                if !session.interestContext.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(session.interestContext.prefix(2), id: \.self) { tag in
                            Text(tagDisplayName(tag))
                                .font(.system(size: 11))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.blue.opacity(0.1))
                                .foregroundColor(.blue)
                                .cornerRadius(4)
                        }
                        if session.interestContext.count > 2 {
                            Text("+\(session.interestContext.count - 2)")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding(.vertical, 8)
    }
    
    private func tagDisplayName(_ tag: FirebaseInterestTag) -> String {
        switch tag {
        case .dinosaurs: return "恐竜"
        case .space: return "宇宙"
        case .cooking: return "料理"
        case .animals: return "動物"
        case .vehicles: return "乗り物"
        case .music: return "音楽"
        case .sports: return "スポーツ"
        case .crafts: return "工作"
        case .stories: return "お話"
        case .insects: return "昆虫"
        case .princess: return "プリンセス"
        case .heroes: return "ヒーロー"
        case .robots: return "ロボット"
        case .nature: return "自然"
        case .others: return "その他"
        }
    }
}

