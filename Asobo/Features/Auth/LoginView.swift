import SwiftUI
import AuthenticationServices
import CryptoKit
import GoogleSignIn

struct LoginView: View {
    @ObservedObject var authVM: AuthViewModel
    @State private var currentNonce: String?
    
    var body: some View {
        ZStack {
            // 背景
            LinearGradient(
                gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            .overlay(AmbientCircles()) // 既存のふわふわ背景
            
            VStack(spacing: 40) {
                Spacer()
                
                // アプリアイコンやタイトル
                VStack(spacing: 20) {
                    // アプリアイコン
                    Image(systemName: "bubble.left.and.bubble.right.fill")
                        .font(.system(size: 80))
                        .foregroundColor(.anoneButton)
                    
                    Text("Asobo")
                        .font(.system(size: 48, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "5A4A42"))
                    
                    Text("こどものおしゃべりパートナー")
                        .font(.system(size: 18, design: .rounded))
                        .foregroundColor(Color(hex: "8A7A72"))
                }
                
                Spacer()
                
                // Sign in with Apple Button
                ZStack {
                    // タップ処理を担う純正ボタン（ラベルは非表示）
                    SignInWithAppleButton(.signIn,
                        onRequest: { request in
                            let nonce = randomNonceString()
                            currentNonce = nonce
                            request.requestedScopes = [.fullName, .email]
                            request.nonce = sha256(nonce)
                        },
                        onCompletion: { result in
                            switch result {
                            case .success(let authResults):
                                if let credential = authResults.credential as? ASAuthorizationAppleIDCredential {
                                    guard let nonce = currentNonce else { return }
                                    authVM.handleSignInWithApple(credential: credential, nonce: nonce)
                                }
                            case .failure(let error):
                                print("❌ LoginView: Apple Sign In 失敗 - \(error.localizedDescription)")
                                authVM.errorMessage = "ログインに失敗しました: \(error.localizedDescription)"
                                authVM.isSigningIn = false
                            }
                        }
                    )
                    .signInWithAppleButtonStyle(.white)
                    .labelsHidden()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .cornerRadius(25)
                    
                    // カスタム表示（タップは純正ボタンに通す）
                    HStack(spacing: 8) {
                        Image(systemName: "applelogo")
                            .font(.system(size: 18, weight: .semibold))
                        Text("AppleIDでログイン")
                            .font(.system(size: 16, weight: .semibold))
                    }
                    .foregroundColor(.black)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.white)
                    .cornerRadius(25)
                    .allowsHitTesting(false)
                }
                .frame(height: 50)
                .padding(.horizontal, 40)
                
                if let errorMessage = authVM.errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                        .padding(.top, 8)
                }
                
                // Google ログインボタン
                Button(action: startGoogleSignIn) {
                    HStack {
                        Image(systemName: "g.circle.fill")
                        Text("Googleでログイン")
                            .fontWeight(.semibold)
                    }
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color(red: 66/255, green: 133/255, blue: 244/255))
                    .cornerRadius(25)
                }
                .padding(.horizontal, 40)
                .padding(.top, 8)
                
                Text("利用規約 と プライバシーポリシー")
                    .font(.caption)
                    .foregroundColor(.gray)
                    .padding(.bottom, 40)
            }
            
            if authVM.isSigningIn {
                Color.black.opacity(0.25)
                    .ignoresSafeArea()
                VStack(spacing: 16) {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.3)
                    Text("ログイン中です")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("少しお待ちください…")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                }
                .padding(32)
                .frame(maxWidth: 300)
                .background(Color.black.opacity(0.45))
                .cornerRadius(24)
                .shadow(radius: 20)
                .transition(.opacity)
            }
        }
    }
    
    // --- Apple Sign In Helpers (Nonce生成用) ---
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess { fatalError("Unable to generate nonce") }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        let nonce = randomBytes.map { charset[Int($0) % charset.count] }
        return String(nonce)
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        let hashString = hashedData.compactMap { String(format: "%02x", $0) }.joined()
        return hashString
    }
    
    /// Google Sign In開始
    private func startGoogleSignIn() {
        authVM.isSigningIn = true
        guard let rootViewController = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .flatMap({ $0.windows })
            .first(where: { $0.isKeyWindow })?.rootViewController else {
            authVM.errorMessage = "画面を取得できませんでした"
            authVM.isSigningIn = false
            return
        }
        
        GIDSignIn.sharedInstance.signIn(withPresenting: rootViewController) { result, error in
            if let error = error {
                print("❌ LoginView: Google Sign In 失敗 - \(error.localizedDescription)")
                authVM.errorMessage = "Googleログインに失敗しました: \(error.localizedDescription)"
                return
            }
            guard
                let user = result?.user,
                let idToken = user.idToken?.tokenString
            else {
                authVM.errorMessage = "Googleの認証情報が取得できませんでした"
                return
            }
            let accessToken = user.accessToken.tokenString
            authVM.handleGoogleSignIn(idToken: idToken, accessToken: accessToken)
        }
    }
}

