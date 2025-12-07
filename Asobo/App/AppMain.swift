// App/AppMain.swift

import SwiftUI
import FirebaseCore
import FirebaseAuth
import GoogleSignIn


class AppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication,
                   didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey : Any]? = nil) -> Bool {
    FirebaseApp.configure()
    
    // Google Sign-In 用のクライアントID設定（Info.plistのGIDClientIDが無い場合の保険）
    if let clientID = FirebaseApp.app()?.options.clientID {
      GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
    } else {
      print("⚠️ Google Sign-In clientID が取得できませんでした。GoogleService-Info.plist を確認してください。")
    }
#if DEBUG
    do {
      try Auth.auth().signOut()
      print("DEBUG: signed out on launch")
    } catch {
      print("DEBUG: signOut failed - \(error)")
    }
#endif

    return true
  }
  
  func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {
    // Google Sign-In のコールバック処理
    return GIDSignIn.sharedInstance.handle(url)
  }
}

@main
struct AsoboApp: App {
  // register app delegate for Firebase setup
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate

  var body: some Scene {
    WindowGroup {
      RootView()
    }
  }
}
