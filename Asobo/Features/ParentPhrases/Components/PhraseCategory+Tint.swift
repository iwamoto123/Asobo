import SwiftUI
import Domain

extension PhraseCategory {
    var tintColor: Color {
        switch color {
        case "orange": return .orange
        case "green": return .green
        case "purple": return .purple
        case "blue": return .blue
        case "pink": return .pink
        case "yellow": return .yellow
        case "teal": return .teal
        case "indigo": return .indigo
        case "brown": return .brown
        default: return .gray
        }
    }
}


