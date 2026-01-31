import SwiftUI
import Domain

struct CategorySelectorView: View {
    @Binding var selectedCategory: PhraseCategory
    let categories: [PhraseCategory]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(categories) { category in
                    CategoryChip(
                        category: category,
                        isSelected: selectedCategory == category
                    ) {
                        withAnimation {
                            selectedCategory = category
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 4)
        }
        .scrollClipDisabled()
    }
}

struct CategoryChip: View {
    let category: PhraseCategory
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: category.icon)
                    .font(.system(size: 14, weight: .semibold))
                Text(category.rawValue)
                    .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(isSelected ? Color.anoneButton : Color.white.opacity(0.80))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(isSelected ? Color.white.opacity(0.35) : category.tintColor.opacity(0.25), lineWidth: 1)
            )
            .foregroundStyle(isSelected ? .white : Color(hex: "5A4A42"))
            .shadow(color: .anoneShadowDark.opacity(isSelected ? 0.18 : 0.10), radius: 10, x: 2, y: 6)
            .shadow(color: .white.opacity(0.7), radius: 10, x: -3, y: -3)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    @Previewable @State var selected = PhraseCategory.morning
    return CategorySelectorView(
        selectedCategory: $selected,
        categories: PhraseCategory.allCases
    )
}
