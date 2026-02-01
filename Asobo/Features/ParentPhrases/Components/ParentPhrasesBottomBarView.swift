import SwiftUI

@available(iOS 17.0, *)
struct ParentPhrasesBottomBarView: View {
    let onAdd: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onAdd) {
                Label("追加", systemImage: "plus")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.anoneButton)
                    .foregroundColor(.white)
                    .cornerRadius(16)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(
            Rectangle()
                .fill(Color.black.opacity(0.06))
                .frame(height: 1),
            alignment: .top
        )
    }
}


