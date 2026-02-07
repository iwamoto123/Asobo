import Foundation
import FirebaseAnalytics

// MARK: - Analytics Event Definitions
public enum AnalyticsEvent {

    // MARK: - 認証系イベント
    case loginStart(provider: AuthProvider)
    case loginSuccess(provider: AuthProvider)
    case loginFailure(provider: AuthProvider, error: String)
    case logout
    case onboardingStart
    case onboardingStep(step: Int)
    case onboardingComplete

    // MARK: - 会話系イベント
    case conversationSessionStart(mode: ConversationMode)
    case conversationSessionEnd(durationSeconds: Double, turnCount: Int)
    case conversationTurn(role: TurnRole)
    case handsFreeStart
    case handsFreeStop
    case speechRecognitionStart
    case speechRecognitionEnd(textLength: Int)
    case aiResponseReceived(textLength: Int)

    // MARK: - 画面表示イベント
    case screenView(screenName: ScreenName)
    case tabSwitch(fromTab: TabName, toTab: TabName)

    // MARK: - 親向け機能イベント
    case phraseCardPlay(category: String)
    case phraseCardSave(category: String, isNew: Bool)
    case phraseCardDelete(category: String)
    case voiceInputStart
    case voiceInputComplete(textLength: Int)
    case categoryCreated(name: String)
    case weeklyReportView
    case historySessionView(sessionId: String)

    // MARK: - プロフィール系イベント
    case profileUpdate
    case avatarUpload
    case childSwitch(childId: String)
    case siblingAdded
    case speakerSelected(childId: String)

    // MARK: - エラー系イベント
    case errorOccurred(type: ErrorType, message: String)

    // MARK: - Supporting Types
    public enum AuthProvider: String {
        case google, apple
    }

    public enum ConversationMode: String {
        case freeTalk, story
    }

    public enum TurnRole: String {
        case user, ai, parent
    }

    public enum ScreenName: String {
        case home, history, parentPhrases, profile
        case login, onboarding, chatDetail
        case devices, story
    }

    public enum TabName: String {
        case home, history, parentPhrases, profile
    }

    public enum ErrorType: String {
        case network, auth, speechRecognition, api, firebase, audio
    }
}

// MARK: - Analytics Service
public final class AnalyticsService {
    public static let shared = AnalyticsService()

    private init() {}

    /// イベントをFirebase Analyticsに送信
    public func log(_ event: AnalyticsEvent) {
        let (name, parameters) = eventNameAndParameters(for: event)
        Analytics.logEvent(name, parameters: parameters)

        #if DEBUG
        print("📊 Analytics: \(name) - \(parameters ?? [:])")
        #endif
    }

    /// 画面表示をログ（自動画面トラッキングを補完）
    public func logScreenView(_ screenName: AnalyticsEvent.ScreenName, screenClass: String? = nil) {
        Analytics.logEvent(AnalyticsEventScreenView, parameters: [
            AnalyticsParameterScreenName: screenName.rawValue,
            AnalyticsParameterScreenClass: screenClass ?? screenName.rawValue
        ])

        #if DEBUG
        print("📊 Analytics: screen_view - \(screenName.rawValue)")
        #endif
    }

    /// ユーザープロパティを設定
    public func setUserProperty(_ value: String?, forName name: String) {
        Analytics.setUserProperty(value, forName: name)

        #if DEBUG
        print("📊 Analytics: setUserProperty \(name) = \(value ?? "nil")")
        #endif
    }

    /// ユーザーIDを設定
    public func setUserId(_ userId: String?) {
        Analytics.setUserID(userId)

        #if DEBUG
        print("📊 Analytics: setUserID = \(userId ?? "nil")")
        #endif
    }

    // MARK: - Private
    private func eventNameAndParameters(for event: AnalyticsEvent) -> (String, [String: Any]?) {
        switch event {

        // MARK: 認証系
        case .loginStart(let provider):
            return ("login_start", ["provider": provider.rawValue])
        case .loginSuccess(let provider):
            return (AnalyticsEventLogin, [
                AnalyticsParameterMethod: provider.rawValue
            ])
        case .loginFailure(let provider, let error):
            return ("login_failure", [
                "provider": provider.rawValue,
                "error": error.prefix(100).description
            ])
        case .logout:
            return ("logout", nil)
        case .onboardingStart:
            return ("onboarding_start", nil)
        case .onboardingStep(let step):
            return ("onboarding_step", ["step": step])
        case .onboardingComplete:
            return (AnalyticsEventTutorialComplete, nil)

        // MARK: 会話系
        case .conversationSessionStart(let mode):
            return ("conversation_session_start", ["mode": mode.rawValue])
        case .conversationSessionEnd(let duration, let turnCount):
            return ("conversation_session_end", [
                "duration_seconds": Int(duration),
                "turn_count": turnCount
            ])
        case .conversationTurn(let role):
            return ("conversation_turn", ["role": role.rawValue])
        case .handsFreeStart:
            return ("handsfree_start", nil)
        case .handsFreeStop:
            return ("handsfree_stop", nil)
        case .speechRecognitionStart:
            return ("speech_recognition_start", nil)
        case .speechRecognitionEnd(let textLength):
            return ("speech_recognition_end", ["text_length": textLength])
        case .aiResponseReceived(let textLength):
            return ("ai_response_received", ["text_length": textLength])

        // MARK: 画面表示
        case .screenView(let screenName):
            return (AnalyticsEventScreenView, [
                AnalyticsParameterScreenName: screenName.rawValue
            ])
        case .tabSwitch(let fromTab, let toTab):
            return ("tab_switch", [
                "from_tab": fromTab.rawValue,
                "to_tab": toTab.rawValue
            ])

        // MARK: 親向け機能
        case .phraseCardPlay(let category):
            return ("phrase_card_play", ["category": category])
        case .phraseCardSave(let category, let isNew):
            return ("phrase_card_save", [
                "category": category,
                "is_new": isNew
            ])
        case .phraseCardDelete(let category):
            return ("phrase_card_delete", ["category": category])
        case .voiceInputStart:
            return ("voice_input_start", nil)
        case .voiceInputComplete(let textLength):
            return ("voice_input_complete", ["text_length": textLength])
        case .categoryCreated(let name):
            return ("category_created", ["name": name])
        case .weeklyReportView:
            return ("weekly_report_view", nil)
        case .historySessionView(let sessionId):
            return ("history_session_view", ["session_id": sessionId])

        // MARK: プロフィール
        case .profileUpdate:
            return ("profile_update", nil)
        case .avatarUpload:
            return ("avatar_upload", nil)
        case .childSwitch(let childId):
            return ("child_switch", ["child_id": childId])
        case .siblingAdded:
            return ("sibling_added", nil)
        case .speakerSelected(let childId):
            return ("speaker_selected", ["child_id": childId])

        // MARK: エラー
        case .errorOccurred(let type, let message):
            return ("error_occurred", [
                "error_type": type.rawValue,
                "error_message": message.prefix(100).description
            ])
        }
    }
}

// MARK: - Convenience Extensions
public extension AnalyticsService {
    /// 会話セッション開始時のヘルパー
    func logConversationStart(isStoryMode: Bool = false) {
        log(.conversationSessionStart(mode: isStoryMode ? .story : .freeTalk))
    }

    /// エラーログのヘルパー
    func logError(_ type: AnalyticsEvent.ErrorType, message: String) {
        log(.errorOccurred(type: type, message: message))
    }
}
