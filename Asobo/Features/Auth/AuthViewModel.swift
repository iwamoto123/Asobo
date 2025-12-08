import SwiftUI
import FirebaseAuth
import FirebaseFirestore
import FirebaseStorage
import AuthenticationServices
import Domain
import GoogleSignIn

@MainActor
class AuthViewModel: ObservableObject {
    @Published var currentUser: User?
    @Published var userProfile: FirebaseParentProfile?
    @Published var selectedChild: FirebaseChildProfile?
    @Published var isLoading = true
    @Published var isSigningIn = false
    @Published var errorMessage: String?
    
    // 画面遷移の制御用
    enum AuthState {
        case splash      // 起動確認中
        case login       // 未ログイン
        case onboarding  // ログイン済みだが子供情報未登録
        case main        // 準備完了
    }
    @Published var authState: AuthState = .splash
    
    private let db = Firestore.firestore()
    
    init() {
        // 起動時にログイン状態を監視
        Auth.auth().addStateDidChangeListener { [weak self] _, user in
            guard let self = self else { return }
            Task { @MainActor in
                self.currentUser = user
                
                if let user = user {
                    // ログイン済みならプロフィールを取得しに行く
                    print("✅ AuthViewModel: ユーザー検知 (uid: \(user.uid)) -> プロフィール取得開始")
                    await self.fetchUserProfile(userId: user.uid)
                } else {
                    print("ℹ️ AuthViewModel: 未ログイン状態")
                    self.authState = .login
                    self.isLoading = false
                    self.isSigningIn = false
                }
            }
        }
    }
    
    // MARK: - Google Sign In
    func handleGoogleSignIn(idToken: String, accessToken: String) {
        isSigningIn = true
        let credential = GoogleAuthProvider.credential(withIDToken: idToken, accessToken: accessToken)
        Auth.auth().signIn(with: credential) { [weak self] result, error in
            guard let self else { return }
            if let error = error {
                self.errorMessage = "Googleログインに失敗しました: \(error.localizedDescription)"
                print("❌ AuthViewModel: Google Sign In エラー - \(error)")
                self.isSigningIn = false
                return
            }
            print("✅ AuthViewModel: Google Sign In 成功")
            // fetchUserProfileはリスナー経由で呼ばれるためここでは呼ばない
        }
    }
    
    // MARK: - Apple Sign In
    func handleSignInWithApple(credential: ASAuthorizationAppleIDCredential, nonce: String) {
        isSigningIn = true
        guard let appleIDToken = credential.identityToken else {
            self.errorMessage = "認証トークンの取得に失敗しました"
            self.isSigningIn = false
            return
        }
        guard let idTokenString = String(data: appleIDToken, encoding: .utf8) else {
            self.errorMessage = "トークンの変換に失敗しました"
            self.isSigningIn = false
            return
        }
        
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: credential.fullName
        )
        
        Auth.auth().signIn(with: firebaseCredential) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                self.errorMessage = error.localizedDescription
                print("❌ AuthViewModel: Apple Sign In エラー - \(error)")
                self.isSigningIn = false
                return
            }
            print("✅ AuthViewModel: Apple Sign In 成功")
        }
    }
    
    // MARK: - Sign Out
    func signOut() {
        do {
            try Auth.auth().signOut()
            self.userProfile = nil
            self.selectedChild = nil
            self.authState = .login
            self.isSigningIn = false
            print("✅ AuthViewModel: ログアウト成功")
        } catch {
            self.errorMessage = "ログアウトに失敗しました: \(error.localizedDescription)"
            print("❌ AuthViewModel: ログアウトエラー - \(error)")
        }
    }
    
    // MARK: - Fetch Data
    func fetchUserProfile(userId: String) async {
        self.isLoading = true
        // 処理終了時に必ずローディングを解除する
        defer {
            self.isLoading = false
            self.isSigningIn = false
        }
        
        do {
            // 1. 親プロフィールの取得
            let doc = try await db.collection("users").document(userId).getDocument()
            
            guard doc.exists, let data = doc.data() else {
                print("⚠️ AuthViewModel: 親ドキュメントが存在しません -> Onboardingへ")
                self.authState = .onboarding
                return
            }
            
            // 親データのデコード
            self.userProfile = try decodeParent(from: data, id: userId)
            
            // 2. 子供プロフィールの取得
            // currentChildIdがあれば優先的に取得、なければサブコレクション全体を取得して先頭を使う
            var targetChildDoc: DocumentSnapshot?
            
            if let currentChildId = self.userProfile?.currentChildId {
                let childDoc = try await db.collection("users").document(userId).collection("children").document(currentChildId).getDocument()
                if childDoc.exists {
                    targetChildDoc = childDoc
                }
            }
            
            // ID指定で見つからなかった場合、一覧から取得
            if targetChildDoc == nil {
                let childrenSnap = try await db.collection("users").document(userId).collection("children").getDocuments()
                targetChildDoc = childrenSnap.documents.first
            }
            
            // 最終判定
            if let childDoc = targetChildDoc, let childData = childDoc.data() {
                // 子データのデコード
                print("📸 AuthViewModel: 子データを取得中... photoURL確認 -> \(childData["photoURL"] as? String ?? "nil")")
                self.selectedChild = try decodeChild(from: childData, id: childDoc.documentID)
                self.authState = .main
                print("✅ AuthViewModel: 準備完了 (Child: \(self.selectedChild?.displayName ?? "unknown"))")
            } else {
                print("⚠️ AuthViewModel: 子どもデータが見つかりません -> Onboardingへ")
                self.authState = .onboarding
            }
            
        } catch {
            self.errorMessage = "データの読み込みに失敗しました: \(error.localizedDescription)"
            print("❌ AuthViewModel: プロフィール取得エラー - \(error)")
            // エラー時はログイン画面に戻すか、Onboardingにするかは仕様次第だが、ここではOnboardingとして扱う
            self.authState = .onboarding
        }
    }
    
    // MARK: - Private Helpers (Decoding Logic)
    
    /// 親データのデコード（手動マッピング補助）
    private func decodeParent(from data: [String: Any], id: String) throws -> FirebaseParentProfile {
        var data = data
        let isoFormatter = getISOFormatter()
        
        // Date変換
        if let createdAt = data["createdAt"] as? Timestamp {
            data["createdAt"] = isoFormatter.string(from: createdAt.dateValue())
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let decoder = getJSONDecoder()
        var profile = try decoder.decode(FirebaseParentProfile.self, from: jsonData)
        profile.id = id
        return profile
    }
    
    /// 子データのデコード（手動マッピング補助）
    private func decodeChild(from data: [String: Any], id: String) throws -> FirebaseChildProfile {
        var data = data
        let isoFormatter = getISOFormatter()
        
        // Date/Timestamp変換
        if let createdAt = data["createdAt"] as? Timestamp {
            data["createdAt"] = isoFormatter.string(from: createdAt.dateValue())
        }
        if let birthDate = data["birthDate"] as? Timestamp {
            data["birthDate"] = isoFormatter.string(from: birthDate.dateValue())
        }
        
        // 配列やOptional値の安全策
        if let interests = data["interestContext"] as? [String] {
            data["interests"] = interests
        }
        if data["interests"] == nil && data["interestContext"] == nil {
            data["interests"] = []
        }
        
        // photoURLはStringとしてそのまま渡す（モデル側でURL変換される想定、もしくはモデルがStringで持っている想定）
        // キーが存在しない場合はnilのままでOK
        if let photoURL = data["photoURL"] as? String {
            print("📸 AuthViewModel: decodeChild - photoURL取得: \(photoURL)")
        } else {
            print("⚠️ AuthViewModel: decodeChild - photoURLが見つかりません")
        }
        
        let jsonData = try JSONSerialization.data(withJSONObject: data)
        let decoder = getJSONDecoder()
        var child = try decoder.decode(FirebaseChildProfile.self, from: jsonData)
        child.id = id
        print("📸 AuthViewModel: decodeChild完了 - photoURL: \(child.photoURL ?? "nil")")
        return child
    }
    
    private func getISOFormatter() -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }
    
    private func getJSONDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let dateString = try container.decode(String.self)
            
            // ミリ秒あり
            let formatterFull = ISO8601DateFormatter()
            formatterFull.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatterFull.date(from: dateString) {
                return date
            }
            
            // ミリ秒なし（フォールバック）
            let formatterSimple = ISO8601DateFormatter()
            formatterSimple.formatOptions = [.withInternetDateTime]
            if let date = formatterSimple.date(from: dateString) {
                return date
            }
            
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
        }
        return decoder
    }
}
