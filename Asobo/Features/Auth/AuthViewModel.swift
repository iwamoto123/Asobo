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
                    await self.fetchUserProfile(userId: user.uid)
                } else {
                    self.authState = .login
                    self.isLoading = false
                    self.isSigningIn = false
                }
            }
        }
    }
    
    // Google Sign In 処理 (IDトークンとアクセストークンを受け取ってFirebase認証)
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
            // ログイン成功時は addStateDidChangeListener が fetchUserProfile を呼ぶ
        }
    }
    
    // プロフィール情報の取得
    func fetchUserProfile(userId: String) async {
        self.isLoading = true
        defer {
            self.isLoading = false
            self.isSigningIn = false
        }
        do {
            let doc = try await db.collection("users").document(userId).getDocument()
            if doc.exists {
                // 手動デコード（FirebaseFirestoreSwiftを使わない方式）
                var data = doc.data() ?? [:]
                
                let isoFormatter = ISO8601DateFormatter()
                isoFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                
                // Date/TimestampをISO8601文字列に変換（JSONSerializationはDateを扱えないため）
                if let createdAt = data["createdAt"] as? Timestamp {
                    data["createdAt"] = isoFormatter.string(from: createdAt.dateValue())
                }
                
                guard let jsonData = try? JSONSerialization.data(withJSONObject: data) else {
                    self.authState = .onboarding
                    self.isLoading = false
                    return
                }
                
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .custom { decoder in
                    let container = try decoder.singleValueContainer()
                    let dateString = try container.decode(String.self)
                    let formatter = ISO8601DateFormatter()
                    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    formatter.formatOptions = [.withInternetDateTime]
                    if let date = formatter.date(from: dateString) {
                        return date
                    }
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid date format: \(dateString)")
                }
                self.userProfile = try decoder.decode(FirebaseParentProfile.self, from: jsonData)
                self.userProfile?.id = userId
                
                // 子供情報も取得（currentChildIdがあればその子を、なければ最初の1人を取得）
                let childId = self.userProfile?.currentChildId
                let childrenSnap: QuerySnapshot
                
                if let childId = childId {
                    // 指定された子供を取得
                    let childDoc = try await db.collection("users").document(userId).collection("children").document(childId).getDocument()
                    if childDoc.exists {
                        var childData = childDoc.data() ?? [:]
                        if let createdAt = childData["createdAt"] as? Timestamp {
                            childData["createdAt"] = isoFormatter.string(from: createdAt.dateValue())
                        }
                        if let birthDate = childData["birthDate"] as? Timestamp {
                            childData["birthDate"] = isoFormatter.string(from: birthDate.dateValue())
                        }
                        if let photoURL = childData["photoURL"] as? String {
                            childData["photoURL"] = photoURL
                        }
                        if let interests = childData["interestContext"] as? [String] {
                            childData["interests"] = interests
                        }
                        // interestContextが存在しない場合は空配列を入れておく
                        if childData["interests"] == nil, childData["interestContext"] == nil {
                            childData["interests"] = []
                        }
                        
                        guard let childJsonData = try? JSONSerialization.data(withJSONObject: childData) else {
                            self.authState = .onboarding
                            self.isLoading = false
                            return
                        }
                        
                        self.selectedChild = try decoder.decode(FirebaseChildProfile.self, from: childJsonData)
                        self.selectedChild?.id = childId
                        self.authState = .main // 準備完了！
                        self.isLoading = false
                        return
                    }
                }
                
                // 指定がない、または見つからない場合は最初の1人を取得
                childrenSnap = try await db.collection("users").document(userId).collection("children").getDocuments()
                
                if let firstChild = childrenSnap.documents.first {
                    var childData = firstChild.data()
                    if let createdAt = childData["createdAt"] as? Timestamp {
                        childData["createdAt"] = isoFormatter.string(from: createdAt.dateValue())
                    }
                    if let birthDate = childData["birthDate"] as? Timestamp {
                        childData["birthDate"] = isoFormatter.string(from: birthDate.dateValue())
                    }
                    if let photoURL = childData["photoURL"] as? String {
                        childData["photoURL"] = photoURL
                    }
                    if let interests = childData["interestContext"] as? [String] {
                        childData["interests"] = interests
                    }
                    if childData["interests"] == nil, childData["interestContext"] == nil {
                        childData["interests"] = []
                    }
                    
                    guard let childJsonData = try? JSONSerialization.data(withJSONObject: childData) else {
                        self.authState = .onboarding
                        self.isLoading = false
                        return
                    }
                    
                    self.selectedChild = try decoder.decode(FirebaseChildProfile.self, from: childJsonData)
                    self.selectedChild?.id = firstChild.documentID
                    self.authState = .main // 準備完了！
                } else {
                    self.authState = .onboarding // 親情報はあっても子供情報がない
                }
            } else {
                // AuthはあるがFirestoreにデータがない（初回）
                self.authState = .onboarding
            }
        } catch {
            self.errorMessage = "データの読み込みに失敗しました: \(error.localizedDescription)"
            print("❌ AuthViewModel: プロフィール取得エラー - \(error)")
            self.authState = .onboarding
        }
    }
    
    // Apple Sign In 処理 (UI側からCredentialを受け取る)
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
        
        // ✅ ここを修正：appleCredential を使う
        let firebaseCredential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: nonce,
            fullName: credential.fullName   // 名前が不要なら nil でもOK
        )
        
        Auth.auth().signIn(with: firebaseCredential) { [weak self] result, error in
            guard let self = self else { return }
            if let error = error {
                self.errorMessage = error.localizedDescription
                print("❌ AuthViewModel: Apple Sign In エラー - \(error)")
                self.isSigningIn = false
                return
            }
            // ログイン成功 -> initのリスナーが検知して fetchUserProfile が走る
            print("✅ AuthViewModel: Apple Sign In 成功")
        }
    }
    
    // ログアウト
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
}
