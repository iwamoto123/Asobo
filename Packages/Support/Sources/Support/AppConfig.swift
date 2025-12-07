import Foundation

public struct AppConfig {
    public static var apiBase: String {
        Bundle.main.object(forInfoDictionaryKey: "API_BASE") as? String ?? "https://api.openai.com"
    }
    
    public static var openAIKey: String {
        Bundle.main.object(forInfoDictionaryKey: "OPENAI_API_KEY") as? String ?? ""
    }
    
    public static var realtimeModel: String {
        // ✅ gpt-realtime に固定（フォールバックを完全排除）
        Bundle.main.object(forInfoDictionaryKey: "REALTIME_MODEL") as? String ?? "gpt-realtime"
    }
    
    public static var realtimeEndpoint: String {
        // 直接URLが設定されている場合はそれを使用
        if let directUrl = Bundle.main.object(forInfoDictionaryKey: "REALTIME_WSS_URL") as? String {
            return directUrl
        }
        // そうでなければAPI_BASEとREALTIME_MODELから構築
        return "\(apiBase)/v1/realtime?model=\(realtimeModel)"
    }
    
    public static var nudgeMaxCount: Int {
        Bundle.main.object(forInfoDictionaryKey: "NUDGE_MAX_COUNT") as? Int ?? 2
    }
}
