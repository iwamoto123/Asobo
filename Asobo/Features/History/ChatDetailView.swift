// MARK: - Chat Detail View
// 会話の詳細を表示するView（吹き出し形式）
import SwiftUI
import Domain
import DataStores

struct ChatDetailView: View {
    let session: FirebaseConversationSession
    @EnvironmentObject var authVM: AuthViewModel
    @State private var turns: [FirebaseTurn] = []
    @State private var isLoading = false
    @State private var errorMessage: String?
    
    private let repository = FirebaseConversationsRepository()
    
    private var childPhotoURL: URL? {
        guard let urlString = authVM.selectedChild?.photoURL else { return nil }
        return URL(string: urlString)
    }
    
    var body: some View {
        ZStack {
            // 背景色（LINE風の薄いグレー）
            Color(uiColor: .systemGroupedBackground)
                .ignoresSafeArea()
            
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(spacing: 0) {
                        // セッション情報ヘッダー（簡潔版）
                        // 要約、興味タグ、新出語彙のいずれかがあれば表示
                        if !session.summaries.isEmpty || !session.interestContext.isEmpty || !session.newVocabulary.isEmpty {
                            SessionHeaderView(session: session)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 12)
                                .background(Color(uiColor: .secondarySystemGroupedBackground))
                        }
                        
                        // 会話内容
                        if isLoading {
                            ProgressView("読み込み中...")
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else if let errorMessage = errorMessage {
                            VStack(spacing: 8) {
                                Image(systemName: "exclamationmark.triangle")
                                    .font(.title)
                                    .foregroundColor(.orange)
                                Text(errorMessage)
                                    .foregroundColor(.secondary)
                                    .multilineTextAlignment(.center)
                                Button("再試行") {
                                    Task {
                                        await loadTurns()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        } else if turns.isEmpty {
                            Text("会話内容がありません")
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity)
                                .padding(.top, 40)
                        } else {
                            LazyVStack(spacing: 8) {
                                ForEach(turns) { turn in
                                    ChatBubbleView(turn: turn, childPhotoURL: childPhotoURL)
                                        .id(turn.id ?? UUID().uuidString)
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 16)
                            .onAppear {
                                // 最後のメッセージにスクロール
                                if let lastTurn = turns.last, let lastId = lastTurn.id {
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        withAnimation {
                                            proxy.scrollTo(lastId, anchor: .bottom)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("会話詳細")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await loadTurns()
        }
        .onChange(of: authVM.selectedChild?.id) { _ in
            Task { await loadTurns() }
        }
    }
    
    private func loadTurns() async {
        guard let sessionId = session.id else { return }
        guard let userId = authVM.currentUser?.uid, let childId = authVM.selectedChild?.id else {
            errorMessage = "ユーザー情報が見つかりません。再ログインしてください。"
            return
        }
        
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        
        do {
            self.turns = try await repository.fetchTurns(
                userId: userId,
                childId: childId,
                sessionId: sessionId
            )
            print("✅ ChatDetailView: ターン取得完了 - count: \(turns.count)")
        } catch {
            let errorString = String(describing: error)
            errorMessage = "会話内容の取得に失敗しました: \(errorString)"
            print("❌ ChatDetailView: ターン取得失敗 - \(error)")
        }
    }
}

// MARK: - Session Header View
// セッション情報のヘッダー（簡潔版）
struct SessionHeaderView: View {
    let session: FirebaseConversationSession
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 要約（目立つように表示）
            if !session.summaries.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("要約")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .textCase(.uppercase)
                    
                    ForEach(session.summaries, id: \.self) { summary in
                        if !summary.isEmpty {
                            Text(summary)
                                .font(.body)
                                .foregroundColor(.primary)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(Color.blue.opacity(0.1))
                                .cornerRadius(8)
                        }
                    }
                }
            }
            
            // 興味タグと新出語彙を横並び
            HStack(alignment: .top, spacing: 12) {
                // 興味タグ
                if !session.interestContext.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("興味")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(session.interestContext.prefix(3), id: \.self) { tag in
                                Text(tagDisplayName(tag))
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.blue.opacity(0.15))
                                    .foregroundColor(.blue)
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
                
                // 新出語彙
                if !session.newVocabulary.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("新語")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        FlowLayout(spacing: 6) {
                            ForEach(session.newVocabulary.prefix(3), id: \.self) { word in
                                Text(word)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(Color.green.opacity(0.15))
                                    .foregroundColor(.green)
                                    .cornerRadius(6)
                            }
                        }
                    }
                }
            }
        }
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

// MARK: - Chat Bubble View
// 会話の吹き出し（LINE風デザイン）
struct ChatBubbleView: View {
    let turn: FirebaseTurn
    let childPhotoURL: URL?
    
    private var isChild: Bool {
        turn.role == .child
    }
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter
    }
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if isChild {
                // 子どもの発言（右側・緑色）
                Spacer(minLength: 16)
                
                // ✅ alignment: .bottom にして時刻を下に揃える
                HStack(alignment: .bottom, spacing: 6) {
                    // タイムスタンプ
                    Text(timeFormatter.string(from: turn.timestamp))
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    
                    // 吹き出し
                    Text(turn.text ?? "")
                        .font(.system(size: 16))
                        .foregroundColor(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 18)
                                .fill(Color(red: 0.18, green: 0.80, blue: 0.44)) // LINEの緑色
                        )
                        .frame(maxWidth: 240, alignment: .trailing)
                    
                    // 右側アイコン（子の写真があれば表示）
                    childAvatar
                }
            } else {
                // AIの発言（左側・グレー）
                // アイコンと吹き出し群はTop揃え
                HStack(alignment: .top, spacing: 8) {
                    // 左側アイコン（子の写真があれば表示）
                    if let url = childPhotoURL {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .empty:
                                ProgressView()
                                    .frame(width: 36, height: 36)
                            case .success(let image):
                                image
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: 36, height: 36)
                                    .clipShape(Circle())
                            case .failure:
                                Circle()
                                    .fill(Color.gray.opacity(0.3))
                                    .frame(width: 36, height: 36)
                                    .overlay(
                                        Image(systemName: "sparkles")
                                            .font(.system(size: 16))
                                            .foregroundColor(.gray)
                                    )
                            @unknown default:
                                EmptyView()
                            }
                        }
                    } else {
                        Circle()
                            .fill(Color.gray.opacity(0.3))
                            .frame(width: 36, height: 36)
                            .overlay(
                                Image(systemName: "sparkles")
                                    .font(.system(size: 16))
                                    .foregroundColor(.gray)
                            )
                    }
                    
                    // ✅ 吹き出しと時刻はBottom揃え
                    HStack(alignment: .bottom, spacing: 4) {
                        // 吹き出し
                        Text(turn.text ?? "")
                            .font(.system(size: 16))
                            .foregroundColor(.primary)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                            .background(
                                RoundedRectangle(cornerRadius: 18)
                                    .fill(Color(uiColor: .systemGray5))
                            )
                            .frame(maxWidth: 280, alignment: .leading)
                        
                        // タイムスタンプ
                        Text(timeFormatter.string(from: turn.timestamp))
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer(minLength: 60)
            }
        }
    }
    
    @ViewBuilder
    private var childAvatar: some View {
        if let url = childPhotoURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .empty:
                    ProgressView()
                        .frame(width: 36, height: 36)
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: 36, height: 36)
                        .clipShape(Circle())
                case .failure:
                    Circle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(width: 36, height: 36)
                        .overlay(
                            Image(systemName: "person.fill")
                                .font(.system(size: 16))
                                .foregroundColor(.gray)
                        )
                @unknown default:
                    EmptyView()
                }
            }
        } else {
            Circle()
                .fill(Color.gray.opacity(0.3))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "person.fill")
                        .font(.system(size: 16))
                        .foregroundColor(.gray)
                )
        }
    }
}

// MARK: - Flow Layout
// タグなどを横に流すレイアウト
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.width ?? 0,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                      y: bounds.minY + result.frames[index].minY),
                          proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if currentX + size.width > maxWidth && currentX > 0 {
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                lineHeight = max(lineHeight, size.height)
                currentX += size.width + spacing
            }
            
            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}
