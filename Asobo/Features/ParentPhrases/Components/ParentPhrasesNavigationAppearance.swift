import SwiftUI

enum ParentPhrasesNavigationAppearance {
    static func apply() {
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.largeTitleTextAttributes = [
            .foregroundColor: UIColor(Color(hex: "5A4A42")),
            .font: UIFont.systemFont(ofSize: 34, weight: .bold),
        ]
        appearance.titleTextAttributes = [
            .foregroundColor: UIColor(Color(hex: "5A4A42")),
            .font: UIFont.systemFont(ofSize: 17, weight: .bold),
        ]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
    }
}


