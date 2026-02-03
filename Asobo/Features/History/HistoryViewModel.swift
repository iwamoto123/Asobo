// MARK: - History ViewModel
// 会話履歴を管理するViewModel
import Foundation
import Domain
import DataStores
import Support

@MainActor
class HistoryViewModel: ObservableObject {
    @Published var sessions: [FirebaseConversationSession] = []
    @Published var isLoading = false
    @Published var errorMessage: String?

    // MARK: - Weekly Summary (Parent)
    @Published var weeklyReport: FirebaseWeeklyReport?
    @Published var isWeeklyReportLoading: Bool = false
    @Published var weeklyReportErrorMessage: String?

    private let repository = FirebaseConversationsRepository()
    // ✅ 認証情報（AuthViewModelから設定される）
    private var userId: String?
    private var childId: String?

    // ✅ ユーザー情報を設定するメソッド
    public func setupUser(userId: String, childId: String) {
        self.userId = userId
        self.childId = childId
        print("✅ HistoryViewModel: ユーザー情報を設定 - Parent=\(userId), Child=\(childId)")
    }

    /// セッション一覧を読み込む
    func loadSessions() async {
        guard let userId = userId, let childId = childId else {
            print("⚠️ HistoryViewModel: ユーザー情報が設定されていないため、セッションを読み込めません")
            errorMessage = "ユーザー情報が設定されていません。ログインしてください。"
            return
        }
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
            await loadWeeklyReportIfNeeded(userId: userId, childId: childId)
        } catch {
            let errorString = String(describing: error)
            errorMessage = "履歴の取得に失敗しました: \(errorString)"
            print("❌ HistoryViewModel: 履歴取得失敗 - \(error)")
            print("❌ HistoryViewModel: エラー詳細 - \(errorString)")
        }
    }

    // MARK: - Weekly Report Logic

    private func isoWeekId(for date: Date) -> String {
        let cal = Calendar(identifier: .iso8601)
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: date)
        let year = comps.yearForWeekOfYear ?? Calendar.current.component(.year, from: date)
        let week = comps.weekOfYear ?? Calendar.current.component(.weekOfYear, from: date)
        return String(format: "%04d-W%02d", year, week)
    }

    private func isoWeekInterval(for date: Date) -> DateInterval? {
        let cal = Calendar(identifier: .iso8601)
        return cal.dateInterval(of: .weekOfYear, for: date)
    }

    private func formatMonthDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M/d"
        formatter.locale = Locale(identifier: "ja_JP")
        return formatter.string(from: date)
    }

    private func buildWeeklyPrompt(weekStart: Date, weekEndInclusive: Date, sessions: [FirebaseConversationSession]) -> String {
        // LLMに渡すログを短くまとめる（Firestoreのturnsは読まず、sessionメタのみ）
        let lines: [String] = sessions
            .sorted { $0.startedAt < $1.startedAt }
            .map { s in
                let when = formatMonthDay(s.startedAt) + " " + {
                    let tf = DateFormatter()
                    tf.dateStyle = .none
                    tf.timeStyle = .short
                    tf.locale = Locale(identifier: "ja_JP")
                    return tf.string(from: s.startedAt)
                }()
                let who = (s.speakerChildName?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "(未指定)"
                let summary = (s.summaries.first?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 } ?? "(要約なし)"
                let tags = s.interestContext.map { $0.rawValue }.joined(separator: ", ")
                let words = s.newVocabulary.joined(separator: ", ")
                return "- \(when) / \(who) / 要約: \(summary) / 興味: [\(tags)] / 新語: [\(words)] / turnCount: \(s.turnCount)"
            }
        let log = lines.isEmpty ? "(この週の会話はまだありません)" : lines.joined(separator: "\n")

        return """
        あなたは保護者向けの週次レポート作成AIです。以下の会話セッション（メタ情報）を読み、子どもの成長や興味が伝わるように、日本語で簡潔にまとめてください。

        制約:
        - 事実に基づく（誇張しない／ない情報は作らない）
        - 毎回の表現ゆらぎを減らすため、落ち着いたトーンで“同じ入力なら似た出力”になるようにする
        - きょうだいが混在する場合は、話者名ごとにセクションを分ける（名前が未指定のものは「(未指定)」）
        - 1セクションは2〜4文。全体まとめは3〜5文。
        - 興味タグは Domain enum の英語値で返す（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others）
        - newWords は日本語の単語/フレーズを最大8個（重複除去）

        期間: \(formatMonthDay(weekStart))〜\(formatMonthDay(weekEndInclusive))

        入力セッション:
        \(log)

        返すJSON（json_object）:
        {
          "sections": [
            { "name": "（子の表示名 or (未指定)）", "summary": "..." }
          ],
          "interestTags": ["dinosaurs"],
          "newWords": ["..."],
          "overallSummary": "..."
        }
        """
    }

    private func generateWeeklyReportWithOpenAI(prompt: String) async throws -> (sections: [FirebaseWeeklyReport.SpeakerSection], interests: [FirebaseInterestTag], newWords: [String], overall: String) {
        struct Payload: Encodable {
            let model: String
            let messages: [[String: String]]
            let response_format: [String: String]
            let max_tokens: Int
            let temperature: Double
        }
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        struct Result: Decodable {
            struct Section: Decodable {
                let name: String?
                let summary: String?
            }
            let sections: [Section]?
            let interestTags: [String]?
            let newWords: [String]?
            let overallSummary: String?
        }

        let apiKey = AppConfig.openAIKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw NSError(domain: "WeeklyReport", code: -10, userInfo: [NSLocalizedDescriptionKey: "OPENAI_API_KEY が未設定です"])
        }

        let payload = Payload(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": "あなたは保護者向けの週次レポート作成アシスタントです。JSONのみで返してください。"],
                ["role": "user", "content": prompt]
            ],
            response_format: ["type": "json_object"],
            max_tokens: 600,
            temperature: 0.2
        )

        let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
            .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!

        var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "WeeklyReport", code: http.statusCode, userInfo: [NSLocalizedDescriptionKey: "週次要約の生成に失敗しました: \(http.statusCode) \(body)"])
        }

        let decoded = try JSONDecoder().decode(Response.self, from: data)
        guard let content = decoded.choices.first?.message.content else {
            throw NSError(domain: "WeeklyReport", code: -2, userInfo: [NSLocalizedDescriptionKey: "OpenAIの返答が空です"])
        }
        guard let jsonData = content.data(using: .utf8) else {
            throw NSError(domain: "WeeklyReport", code: -3, userInfo: [NSLocalizedDescriptionKey: "OpenAI返答のJSON変換に失敗しました"])
        }
        let result = try JSONDecoder().decode(Result.self, from: jsonData)

        let sections: [FirebaseWeeklyReport.SpeakerSection] = (result.sections ?? []).compactMap { s in
            let name = s.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = s.summary?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let summary, !summary.isEmpty else { return nil }
            return FirebaseWeeklyReport.SpeakerSection(
                speakerChildId: nil,
                speakerChildName: (name?.isEmpty == true) ? nil : name,
                summary: summary
            )
        }
        let interests = (result.interestTags ?? []).compactMap { FirebaseInterestTag(rawValue: $0) }
        let newWords = Array(Set((result.newWords ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let overall = (result.overallSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return (sections, interests, newWords, overall.isEmpty ? "今週の会話の要約はまだ十分にありませんでした。" : overall)
    }

    private func loadWeeklyReportIfNeeded(userId: String, childId: String) async {
        isWeeklyReportLoading = true
        weeklyReportErrorMessage = nil
        defer { isWeeklyReportLoading = false }

        guard let interval = isoWeekInterval(for: Date()) else { return }
        let weekISO = isoWeekId(for: interval.start)
        let weekStart = interval.start
        // 表示用：週の“終わりの日”として扱う（日付だけ見せたいので end-1秒）
        let weekEndInclusive = interval.end.addingTimeInterval(-1)

        do {
            let existing = try await repository.fetchWeeklyReport(userId: userId, childId: childId, weekISO: weekISO)
            // 再生成判定のため、現在の総セッション数（上限付き）
            let totalCount = try await repository.fetchSessions(userId: userId, childId: childId, limit: 500).count
            let lastCount = existing?.sessionCountAtGeneration ?? 0
            let shouldRegenerate = (existing == nil) || (totalCount - lastCount >= 10)

            if !shouldRegenerate {
                self.weeklyReport = existing
                return
            }

            // 週内のセッションを取得して生成
            let weekSessions = try await repository.fetchSessionsInRange(
                userId: userId,
                childId: childId,
                start: weekStart,
                end: interval.end,
                limit: 200
            ).filter { $0.turnCount >= 3 }

            let prompt = buildWeeklyPrompt(weekStart: weekStart, weekEndInclusive: weekEndInclusive, sessions: weekSessions)
            let gen = try await generateWeeklyReportWithOpenAI(prompt: prompt)

            let report = FirebaseWeeklyReport(
                id: weekISO,
                periodStart: weekStart,
                periodEnd: weekEndInclusive,
                sessionCountAtGeneration: totalCount,
                sections: gen.sections.isEmpty ? nil : gen.sections,
                summary: gen.overall,
                topInterests: Array(gen.interests.prefix(3)),
                newVocabulary: Array(gen.newWords.prefix(12)),
                adviceForParent: nil,
                createdAt: Date()
            )
            try await repository.upsertWeeklyReport(userId: userId, childId: childId, report: report)
            self.weeklyReport = report
        } catch {
            weeklyReportErrorMessage = "1週間のまとめの取得に失敗しました: \(error.localizedDescription)"
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
