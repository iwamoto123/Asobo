import Foundation
import Domain
import Support
import DataStores

extension ConversationController {
    // MARK: - ライブ要約生成
    /// 現在までの会話ログから要約/興味タグ/新語を生成し、即時Firestoreに反映する
    func generateLiveAnalysisAndPersist() async {
        guard !inMemoryTurns.isEmpty else { return }
        print("📝 generateLiveAnalysis: start, inMemoryTurns=\(inMemoryTurns.count)")

        // プロンプトが大きくなりすぎないように直近12ターンを使用
        let recentTurns = Array(inMemoryTurns.suffix(12))
        let conversationLog = recentTurns.compactMap { turn -> String? in
            guard let text = turn.text, !text.isEmpty else { return nil }
            let roleLabel = turn.role == .child ? "子ども" : "AI"
            return "\(roleLabel): \(text)"
        }.joined(separator: "\n")
        let childOnlyLog = recentTurns.compactMap { turn -> String? in
            guard turn.role == .child, let text = turn.text, !text.isEmpty else { return nil }
            return text
        }.joined(separator: "\n")

        guard !conversationLog.isEmpty else { return }

        struct Payload: Encodable {
            let model: String
            let messages: [[String: String]]
            let response_format: [String: String]
            let max_tokens: Int
            let temperature: Double
        }

        let prompt = """
        以下のAIと子どもの会話を分析し、JSON形式で出力してください。
        - summary: 親向けに1行で要約（50文字以内）。AIの返答も加味して状況をまとめてください。
        - interests: 子どもが興味を示したトピック（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others の英語enum値配列）。子どもの発話を主に見てください。
        - newWords: 子どもが使った特徴的な言葉（3つまで）。必ず子どもの発話からのみ選んでください。

        会話ログ（子ども/AI両方）:
        \(conversationLog)

        子ども発話のみ:
        \(childOnlyLog.isEmpty ? "(なし)" : childOnlyLog)
        """

        let payload = Payload(
            model: "gpt-4o-mini",
            messages: [
                ["role": "system", "content": "あなたは会話を短く要約し、興味タグと新出語を抽出するアシスタントです。JSONのみで返してください。"],
                ["role": "user", "content": prompt]
            ],
            response_format: ["type": "json_object"],
            max_tokens: 200,
            temperature: 0.3
        )

        let apiKey = AppConfig.openAIKey
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            print("⚠️ generateLiveAnalysis: APIキー未設定のためスキップ")
            return
        }

        let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
            .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!

        var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.addValue("application/json", forHTTPHeaderField: "Content-Type")
        req.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try? JSONEncoder().encode(payload)

        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                print("⚠️ generateLiveAnalysis: HTTPエラー - \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
                return
            }

            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            struct Resp: Decodable { let choices: [Choice] }
            let decoded = try JSONDecoder().decode(Resp.self, from: data)
            guard let content = decoded.choices.first?.message.content.data(using: .utf8) else {
                print("⚠️ generateLiveAnalysis: contentなし")
                return
            }
            struct Result: Decodable {
                let summary: String?
                let interests: [String]?
                let newWords: [String]?
            }
            let result = try JSONDecoder().decode(Result.self, from: content)

            if Task.isCancelled { return }

            let summaryText = result.summary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let interests = (result.interests ?? []).compactMap { FirebaseInterestTag(rawValue: $0) }
            let newWords = result.newWords ?? []

            await MainActor.run {
                if !summaryText.isEmpty { self.liveSummary = summaryText }
                self.liveInterests = interests
                self.liveNewVocabulary = newWords
            }

            // Firestoreにも即時反映
            if let userId = currentUserId, let childId = currentChildId, let sessionId = currentSessionId {
                try await firebaseRepository.updateAnalysis(
                    userId: userId,
                    childId: childId,
                    sessionId: sessionId,
                    summaries: summaryText.isEmpty ? [] : [summaryText],
                    interests: interests,
                    newVocabulary: newWords
                )
                print("🟢 generateLiveAnalysis: Firestore更新 success - summary:'\(summaryText)', interests:\(interests.map { $0.rawValue }), newWords:\(newWords)")
            }
        } catch {
            if Task.isCancelled { return }
            print("⚠️ generateLiveAnalysis: 生成失敗 - \(error)")
        }
    }

    // MARK: - 会話分析機能
    /// 会話終了後の分析処理（要約・興味タグ・新出語彙の抽出）
    /// - Parameter sessionId: 分析対象のセッションID
    func analyzeSession(sessionId: String) async {
        print("📊 ConversationController: 会話分析開始 - sessionId: \(sessionId)")

        guard let userId = currentUserId, let childId = currentChildId else {
            print("⚠️ ConversationController: analyzeSession - ユーザー情報が設定されていないため、分析をスキップ")
            return
        }

        do {
            print("📊 ConversationController: analyzeSession - エラーキャッチブロック開始")
            // 1. Firestoreからこのセッションの全ターンを取得
            let turns = try await firebaseRepository.fetchTurns(
                userId: userId,
                childId: childId,
                sessionId: sessionId
            )

            guard !turns.isEmpty else {
                print("⚠️ ConversationController: ターンが存在しないため分析をスキップ - sessionId: \(sessionId)")
                return
            }

            print("📊 ConversationController: 取得したターン数 - \(turns.count)")

            // 2. テキストを連結してプロンプト作成
            let conversationLog = turns.compactMap { turn -> String? in
                guard let text = turn.text, !text.isEmpty else { return nil }
                let roleLabel = turn.role == .child ? "子ども" : "AI"
                return "\(roleLabel): \(text)"
            }.joined(separator: "\n")

            print("📊 ConversationController: 会話テキストの長さ - \(conversationLog.count)文字, テキストありのターン数: \(turns.filter { $0.text != nil && !$0.text!.isEmpty }.count)")
            print("📒 ConversationController: 会話ログサンプル（先頭150文字）: \(conversationLog.prefix(150))")

            guard !conversationLog.isEmpty else {
                print("⚠️ ConversationController: 会話テキストが存在しないため分析をスキップ - sessionId: \(sessionId), ターン数: \(turns.count)")
                return
            }

            print("📝 ConversationController: 会話ログ（\(turns.count)ターン）\n\(conversationLog)")

            // 3. OpenAI Chat Completion (gpt-4o-mini) に投げる
            let prompt = """
            以下の親子の会話ログを分析し、JSON形式で出力してください。

            出力項目:
            - summary: 子どもの発話を中心に、親向けに1〜2行で簡潔にまとめる。返答が短い/雑談が少ない場合は状況だけ短く触れる（長い飾り付けはしない）。
            - interests: 子どもが興味を示したトピック（dinosaurs, space, cooking, animals, vehicles, music, sports, crafts, stories, insects, princess, heroes, robots, nature, others から選択。英語のenum値で配列で出力）
            - newWords: 子どもが使った特徴的な単語や成長を感じる言葉（3つまで、配列で出力）

            会話ログ:
            \(conversationLog)

            JSON形式で出力してください。例:
            {
              "summary": "子どもが恐竜の種類について詳しく話していました。ティラノサウルスとトリケラトプスの違いを説明したり、草食と肉食の違いについて興味深そうに質問していました。",
              "interests": ["dinosaurs", "animals"],
              "newWords": ["ティラノサウルス", "草食", "肉食"]
            }
            """

            struct Payload: Encodable {
                let model: String
                let messages: [[String: String]]
                let response_format: [String: String]
                let temperature: Double
            }

            let payload = Payload(
                model: "gpt-4o-mini",
                messages: [
                    ["role": "system", "content": "あなたは会話分析の専門家です。JSON形式のみで回答してください。"],
                    ["role": "user", "content": prompt]
                ],
                response_format: ["type": "json_object"],
                temperature: 0.3
            )

            let endpoint = (Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String)
                .flatMap(URL.init(string:)) ?? URL(string: "https://api.openai.com/v1")!

            var req = URLRequest(url: endpoint.appendingPathComponent("chat/completions"))
            req.httpMethod = "POST"
            req.addValue("application/json", forHTTPHeaderField: "Content-Type")
            req.addValue("Bearer \(AppConfig.openAIKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONEncoder().encode(payload)

            let (data, response) = try await URLSession.shared.data(for: req)

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                print("❌ ConversationController: 分析API呼び出し失敗 - Status: \(httpResponse.statusCode)")
                if let errorData = String(data: data, encoding: .utf8) {
                    print("   Error: \(errorData)")
                }
                return
            }

            // 4. JSONレスポンスをパース
            struct AnalysisResponse: Decodable {
                struct Choice: Decodable {
                    struct Message: Decodable {
                        let content: String
                    }
                    let message: Message
                }
                let choices: [Choice]
            }

            struct AnalysisResult: Decodable {
                let summary: String?
                let interests: [String]?
                let newWords: [String]?
            }

            let decoded = try JSONDecoder().decode(AnalysisResponse.self, from: data)
            guard let content = decoded.choices.first?.message.content else {
                print("❌ ConversationController: 分析結果が空です")
                return
            }

            // JSON文字列をパース
            print("🔍 ConversationController: 分析結果のJSON文字列 - content: \(content)")
            guard let jsonData = content.data(using: .utf8) else {
                print("❌ ConversationController: JSON文字列のdata変換失敗")
                return
            }

            let result: AnalysisResult
            do {
                result = try JSONDecoder().decode(AnalysisResult.self, from: jsonData)
                print("✅ ConversationController: 分析結果のJSONパース成功 - summary: \(result.summary ?? "nil"), interests: \(result.interests ?? []), newWords: \(result.newWords ?? [])")
            } catch {
                print("❌ ConversationController: 分析結果のJSONパース失敗 - error: \(error), content: \(content)")
                return
            }

            // 5. 結果をFirestoreに保存
            let summaries = result.summary.map { [$0] } ?? []
            let interests = (result.interests ?? []).compactMap { FirebaseInterestTag(rawValue: $0) }
            let newVocabulary = result.newWords ?? []

            print("🔍 ConversationController: 保存前のデータ - summaries: \(summaries), interests: \(interests.map { $0.rawValue }), newVocabulary: \(newVocabulary)")

            try await firebaseRepository.updateAnalysis(
                userId: userId,
                childId: childId,
                sessionId: sessionId,
                summaries: summaries,
                interests: interests,
                newVocabulary: newVocabulary
            )
            print("✅ ConversationController: 分析結果をFirebaseに保存完了")
            await MainActor.run {
                if let firstSummary = summaries.first, !firstSummary.isEmpty {
                    self.liveSummary = firstSummary
                }
                self.liveInterests = interests
                self.liveNewVocabulary = newVocabulary
                print("🟢 ConversationController: live fields updated - summary:'\(self.liveSummary)', interests:\(self.liveInterests.map { $0.rawValue }), newVocabulary:\(self.liveNewVocabulary)")
            }
            print("✅ ConversationController: 会話分析完了 - summary: \(summaries.first ?? "なし"), interests: \(interests.map { $0.rawValue }), vocabulary: \(newVocabulary)")

        } catch {
            print("❌ ConversationController: analyzeSession - エラー発生: \(error)")
            print("❌ ConversationController: analyzeSession - エラーの詳細: \(String(describing: error))")
            if let nsError = error as NSError? {
                print("❌ ConversationController: analyzeSession - NSError詳細 - domain: \(nsError.domain), code: \(nsError.code), userInfo: \(nsError.userInfo)")
            }
            logFirebaseError(error, operation: "会話分析")
        }
    }
}


