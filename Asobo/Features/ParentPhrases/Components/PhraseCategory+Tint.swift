import SwiftUI
import Domain

extension PhraseCategory {
    var tintColor: Color {
        switch self {
        case .morning: return .orange
        case .meals: return .green
        case .bedtime: return .purple
        case .hygiene: return .blue
        case .play: return .pink
        case .praise: return .yellow
        case .outing: return .teal
        case .returnHome: return .indigo
        case .cleanup: return .brown
        case .custom: return .gray
        }
    }
}


