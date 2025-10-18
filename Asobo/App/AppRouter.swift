import SwiftUI

public enum AppRoute {
    case home
    case conversation
    case story
    case parentDashboard
    case devices
}

public final class AppRouter: ObservableObject {
    @Published public var route: AppRoute = .home
    public init() {}
}
