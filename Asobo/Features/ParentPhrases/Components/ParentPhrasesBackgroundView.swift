import SwiftUI

@available(iOS 17.0, *)
struct ParentPhrasesBackgroundView: View {
    var body: some View {
        ZStack {
            LinearGradient(
                gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            AmbientCircles()
        }
    }
}


