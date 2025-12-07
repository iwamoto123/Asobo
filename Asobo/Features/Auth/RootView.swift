import SwiftUI

struct RootView: View {
    @StateObject private var authVM = AuthViewModel()
    
    var body: some View {
        Group {
            switch authVM.authState {
            case .splash:
                ZStack {
                    LinearGradient(
                        gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .ignoresSafeArea()
                    ProgressView()
                        .tint(Color.anoneButton)
                }
            case .login:
                LoginView(authVM: authVM)
            case .onboarding:
                OnboardingView(authVM: authVM)
            case .main:
                // 既存のメイン画面に情報を渡す
                MainTabView()
                    .environmentObject(authVM)
            }
        }
        .animation(.easeInOut, value: authVM.authState)
    }
}


