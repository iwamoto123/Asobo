import SwiftUI

@available(iOS 17.0, *)
struct ParentPhrasesEmptyStateView: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: 110, height: 110)
                Image(systemName: "bubble.left.and.text.bubble.right.fill")
                    .font(.system(size: 44))
                    .foregroundColor(.anoneButton)
            }

            Text(title)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(Color(hex: "5A4A42"))

            Text(message)
                .font(.system(size: 14, design: .rounded))
                .foregroundColor(.gray)
                .multilineTextAlignment(.center)

            Button(action: action) {
                Text(actionTitle)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
                    .padding(.horizontal, 22)
                    .padding(.vertical, 12)
                    .background(Color.anoneButton)
                    .cornerRadius(18)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 24)
    }
}


