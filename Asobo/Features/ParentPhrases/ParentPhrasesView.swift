import SwiftUI
import Domain
import Combine

@available(iOS 17.0, *)
struct ParentPhrasesView: View {
    @EnvironmentObject private var authViewModel: AuthViewModel
    @State private var controller: ParentPhrasesController?
    @State private var controllerUserId: String?

    init() {
        ParentPhrasesNavigationAppearance.apply()
    }

    var body: some View {
        NavigationStack {
            Group {
                if let controller = controller {
                    ParentPhrasesContentView(controller: controller)
                } else {
                    ZStack {
                        ParentPhrasesBackgroundView()
                        ProgressView("読み込み中...")
                            .tint(Color.anoneButton)
                            .foregroundColor(Color(hex: "5A4A42"))
                    }
                }
            }
            .navigationTitle("声かけ")
            .navigationBarTitleDisplayMode(.large)
            .task {
                if controller == nil {
                    let uid = authViewModel.currentUser?.uid
                    controller = ParentPhrasesController(userId: uid)
                    controllerUserId = uid
                }
            }
            .onChange(of: authViewModel.currentUser?.uid) { _, newUid in
                guard controllerUserId != newUid else { return }
                controller = ParentPhrasesController(userId: newUid)
                controllerUserId = newUid
            }
        }
    }
}

@available(iOS 17.0, *)
#Preview {
    ParentPhrasesView()
        .environmentObject(AuthViewModel())
}
