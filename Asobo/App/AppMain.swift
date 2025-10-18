// App/AppMain.swift
import SwiftUI

@main
struct AsoboApp: App {
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                ConversationView()   // 引数なしの今の View を表示
            }
        }
    }
}

