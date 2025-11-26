// MARK: - Firebase Conversations Repository
// Firebase Firestoreに会話セッションとターンを保存するリポジトリ
import Foundation
import FirebaseFirestore
import Domain

public final class FirebaseConversationsRepository {
    private let db = Firestore.firestore()
    
    public init() {}
    
    // MARK: - セッション管理
    
    /// セッションの作成（会話開始時）
    /// - Parameters:
    ///   - userId: 親ユーザーID（Firebase Auth UID）
    ///   - childId: 子供ID
    ///   - session: セッション情報
    public func createSession(userId: String, childId: String, session: FirebaseConversationSession) async throws {
        let sessionId = session.id ?? UUID().uuidString
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
        
        // Codableを使って手動でエンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(session)
        guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FirebaseConversationsRepository", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode session"])
        }
        
        // idはドキュメントIDとして使用するため、フィールドには保存しない
        dict.removeValue(forKey: "id")
        
        // DateをTimestampに変換
        dict["startedAt"] = Timestamp(date: session.startedAt)
        if let endedAt = session.endedAt {
            dict["endedAt"] = Timestamp(date: endedAt)
        }
        
        try await ref.setData(dict)
        print("✅ FirebaseConversationsRepository: セッション作成 - userId: \(userId), childId: \(childId), sessionId: \(sessionId)")
    }
    
    /// セッションの終了更新（会話終了時）
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - sessionId: セッションID
    ///   - endedAt: 終了時刻
    public func finishSession(userId: String, childId: String, sessionId: String, endedAt: Date) async throws {
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
        
        try await ref.updateData([
            "endedAt": Timestamp(date: endedAt)
        ])
        print("✅ FirebaseConversationsRepository: セッション終了更新 - sessionId: \(sessionId), endedAt: \(endedAt)")
    }
    
    /// セッションのターン数を更新
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - sessionId: セッションID
    ///   - turnCount: ターン数
    public func updateTurnCount(userId: String, childId: String, sessionId: String, turnCount: Int) async throws {
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
        
        try await ref.updateData([
            "turnCount": turnCount
        ])
    }
    
    // MARK: - ターン管理
    
    /// ターンの追加（会話中）
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - sessionId: セッションID
    ///   - turn: ターン情報
    public func addTurn(userId: String, childId: String, sessionId: String, turn: FirebaseTurn) async throws {
        let turnId = turn.id ?? UUID().uuidString
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
            .collection("turns").document(turnId) // サブコレクション
        
        // Codableを使って手動でエンコード
        let encoder = JSONEncoder()
        let data = try encoder.encode(turn)
        guard var dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "FirebaseConversationsRepository", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode turn"])
        }
        
        // idはドキュメントIDとして使用するため、フィールドには保存しない
        dict.removeValue(forKey: "id")
        
        // DateをTimestampに変換
        dict["timestamp"] = Timestamp(date: turn.timestamp)
        
        try await ref.setData(dict)
        print("✅ FirebaseConversationsRepository: ターン追加 - sessionId: \(sessionId), turnId: \(turnId), role: \(turn.role.rawValue)")
    }
    
    // MARK: - セッション取得
    
    /// セッション一覧の取得（降順・新しい順）
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - limit: 取得件数の上限（デフォルト: 20）
    /// - Returns: 開始時刻の降順でソートされたセッションの配列
    public func fetchSessions(userId: String, childId: String, limit: Int = 20) async throws -> [FirebaseConversationSession] {
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions")
            .order(by: "startedAt", descending: true)
            .limit(to: limit)
        
        print("🔍 FirebaseConversationsRepository: セッション取得クエリ - path: users/\(userId)/children/\(childId)/sessions")
        
        let snapshot = try await ref.getDocuments()
        
        print("🔍 FirebaseConversationsRepository: クエリ結果 - ドキュメント数: \(snapshot.documents.count)")
        
        // 手動でデコード（既存のfetchTurnsと同じ方式）
        let decoder = JSONDecoder()
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var decodedSessions: [FirebaseConversationSession] = []
        var decodeErrors: [String] = []
        
        for doc in snapshot.documents {
            do {
                var data = doc.data()
                print("🔍 FirebaseConversationsRepository: ドキュメントID: \(doc.documentID), フィールド数: \(data.count)")
                print("🔍 FirebaseConversationsRepository: データ構造 - \(data.keys.joined(separator: ", "))")
                
                // idを追加
                data["id"] = doc.documentID
                // TimestampをISO8601文字列に変換（JSONSerializationでDateを処理できないため）
                if let startedAt = data["startedAt"] as? Timestamp {
                    data["startedAt"] = dateFormatter.string(from: startedAt.dateValue())
                }
                if let endedAt = data["endedAt"] as? Timestamp {
                    data["endedAt"] = dateFormatter.string(from: endedAt.dateValue())
                }
                
                // interestContextがString配列の場合はそのまま、enum配列の場合は変換が必要
                if let interestContext = data["interestContext"] as? [String] {
                    // String配列のまま（デコード時にenumに変換される）
                    print("🔍 FirebaseConversationsRepository: interestContext (String配列): \(interestContext)")
                } else if let interestContext = data["interestContext"] as? [Any] {
                    // 何か別の形式の場合
                    print("🔍 FirebaseConversationsRepository: interestContext (その他): \(interestContext)")
                } else {
                    // interestContextが存在しない場合は空配列を設定
                    print("🔍 FirebaseConversationsRepository: interestContext が存在しないため空配列を設定")
                    data["interestContext"] = []
                }
                
                // modeがStringの場合はそのまま
                if let mode = data["mode"] as? String {
                    print("🔍 FirebaseConversationsRepository: mode: \(mode)")
                } else {
                    // modeが存在しない場合はデフォルト値を設定
                    print("🔍 FirebaseConversationsRepository: mode が存在しないため freeTalk を設定")
                    data["mode"] = "freeTalk"
                }
                
                // summariesが存在しない場合は空配列を設定
                if data["summaries"] == nil {
                    data["summaries"] = []
                }
                
                // newVocabularyが存在しない場合は空配列を設定
                if data["newVocabulary"] == nil {
                    data["newVocabulary"] = []
                }
                
                // turnCountが存在しない場合は0を設定
                if data["turnCount"] == nil {
                    data["turnCount"] = 0
                }
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
                    decodeErrors.append("ドキュメント \(doc.documentID): JSONSerialization失敗")
                    continue
                }
                
                // Dateのデコード戦略をカスタムISO8601フォーマッターに設定
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    
                    // ISO8601DateFormatterでパース（fractional seconds対応）
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    
                    // フォールバック: fractional secondsなしで再試行
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                }
                
                // デコードを試みる
                do {
                    let session = try decoder.decode(FirebaseConversationSession.self, from: jsonData)
                    decodedSessions.append(session)
                } catch let decodeError {
                    let errorDescription = String(describing: decodeError)
                    print("❌ FirebaseConversationsRepository: デコードエラー詳細 - \(errorDescription)")
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        print("🔍 FirebaseConversationsRepository: JSONデータ（最初の500文字）: \(String(jsonString.prefix(500)))")
                    }
                    decodeErrors.append("ドキュメント \(doc.documentID): デコード失敗 - \(errorDescription)")
                }
            } catch {
                decodeErrors.append("ドキュメント \(doc.documentID): エラー - \(error.localizedDescription)")
            }
        }
        
        if !decodeErrors.isEmpty {
            print("⚠️ FirebaseConversationsRepository: デコードエラー - \(decodeErrors.joined(separator: ", "))")
        }
        
        print("✅ FirebaseConversationsRepository: セッション一覧取得 - count: \(decodedSessions.count)")
        return decodedSessions
    }
    
    // MARK: - ターン管理
    
    /// セッションの全ターンを取得（分析用）
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - sessionId: セッションID
    /// - Returns: タイムスタンプ順にソートされたターンの配列
    public func fetchTurns(userId: String, childId: String, sessionId: String) async throws -> [FirebaseTurn] {
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
            .collection("turns")
            .order(by: "timestamp")
        
        print("🔍 FirebaseConversationsRepository: ターン取得クエリ - path: users/\(userId)/children/\(childId)/sessions/\(sessionId)/turns")
        
        let snapshot = try await ref.getDocuments()
        
        print("🔍 FirebaseConversationsRepository: クエリ結果 - ドキュメント数: \(snapshot.documents.count)")
        
        // 手動でデコード
        let decoder = JSONDecoder()
        
        let dateFormatter = ISO8601DateFormatter()
        dateFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        
        var decodedTurns: [FirebaseTurn] = []
        var decodeErrors: [String] = []
        
        for doc in snapshot.documents {
            do {
                var data = doc.data()
                print("🔍 FirebaseConversationsRepository: ターンドキュメントID: \(doc.documentID), フィールド数: \(data.count)")
                print("🔍 FirebaseConversationsRepository: ターンデータ構造 - \(data.keys.joined(separator: ", "))")
                
                // idを追加
                data["id"] = doc.documentID
                // TimestampをISO8601文字列に変換（JSONSerializationでDateを処理できないため）
                if let timestamp = data["timestamp"] as? Timestamp {
                    data["timestamp"] = dateFormatter.string(from: timestamp.dateValue())
                }
                
                // roleがStringの場合はそのまま
                if let role = data["role"] as? String {
                    print("🔍 FirebaseConversationsRepository: role: \(role)")
                }
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
                    decodeErrors.append("ターン \(doc.documentID): JSONSerialization失敗")
                    continue
                }
                
                // Dateのデコード戦略をカスタムISO8601フォーマッターに設定
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    
                    // ISO8601DateFormatterでパース（fractional seconds対応）
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    
                    // フォールバック: fractional secondsなしで再試行
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                }
                
                // デコードを試みる
                do {
                    let turn = try decoder.decode(FirebaseTurn.self, from: jsonData)
                    decodedTurns.append(turn)
                } catch let decodeError {
                    let errorDescription = String(describing: decodeError)
                    print("❌ FirebaseConversationsRepository: ターンデコードエラー詳細 - \(errorDescription)")
                    if let jsonString = String(data: jsonData, encoding: .utf8) {
                        print("🔍 FirebaseConversationsRepository: ターンJSONデータ（最初の500文字）: \(String(jsonString.prefix(500)))")
                    }
                    decodeErrors.append("ターン \(doc.documentID): デコード失敗 - \(errorDescription)")
                }
            } catch {
                decodeErrors.append("ターン \(doc.documentID): エラー - \(error.localizedDescription)")
            }
        }
        
        if !decodeErrors.isEmpty {
            print("⚠️ FirebaseConversationsRepository: デコードエラー - \(decodeErrors.joined(separator: ", "))")
        }
        
        print("✅ FirebaseConversationsRepository: ターン取得 - sessionId: \(sessionId), count: \(decodedTurns.count)")
        return decodedTurns
    }
    
    // MARK: - 分析結果の更新
    
    /// 分析結果の更新（要約・興味など）
    /// - Parameters:
    ///   - userId: 親ユーザーID
    ///   - childId: 子供ID
    ///   - sessionId: セッションID
    ///   - summaries: 要約の配列
    ///   - interests: 興味タグの配列
    ///   - newVocabulary: 新出語彙の配列
    public func updateAnalysis(
        userId: String,
        childId: String,
        sessionId: String,
        summaries: [String],
        interests: [FirebaseInterestTag],
        newVocabulary: [String]
    ) async throws {
        let ref = db.collection("users").document(userId)
            .collection("children").document(childId)
            .collection("sessions").document(sessionId)
        
        // InterestTagをString配列に変換して保存
        let interestRawValues = interests.map { $0.rawValue }
        
        try await ref.updateData([
            "summaries": summaries,
            "interestContext": interestRawValues,
            "newVocabulary": newVocabulary
        ])
        print("✅ FirebaseConversationsRepository: 分析結果更新 - sessionId: \(sessionId), summaries: \(summaries.count), interests: \(interests.count), vocabulary: \(newVocabulary.count)")
    }
}

