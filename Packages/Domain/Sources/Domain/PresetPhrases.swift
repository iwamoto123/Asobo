import Foundation

// MARK: - 初期データ定義
public struct PresetPhrases {
    public static let data: [PhraseCategory: [String]] = [
        .morning: [
            "おはよう！今日も元気に行こうね！",
            "早くお着替えしようね！",
            "朝ごはんの時間だよ！",
            "歯磨きしようね！",
            "準備できたかな！"
        ],
        .meals: [
            "ごはんの時間だよ！",
            "手を洗おうね！",
            "いただきますしようね！",
            "よく噛んで食べようね！",
            "ごちそうさまでした！"
        ],
        .bedtime: [
            "そろそろ寝る時間だよ！",
            "歯磨きしようね！",
            "パジャマに着替えようね！",
            "おやすみなさい、いい夢見てね！",
            "明日も楽しい日になるよ！"
        ],
        .hygiene: [
            "お風呂の時間だよ！",
            "トイレに行こうね！",
            "手を洗おうね！",
            "靴を揃えようね！",
            "お片付けしようね！"
        ],
        .play: [
            "外で遊ぼうか！",
            "おもちゃで遊ぼう！",
            "一緒に遊ぼうね！",
            "もう少しで終わりにしようね！",
            "次は何して遊ぶ！"
        ],
        .praise: [
            "すごいね！",
            "よくできたね！",
            "がんばったね！",
            "えらいね！",
            "ありがとう！"
        ]
    ]

    /// 初期データを PhraseCard 配列として生成
    public static func createCards() -> [PhraseCard] {
        var cards: [PhraseCard] = []
        var priority = 0

        for (category, phrases) in data {
            for text in phrases {
                cards.append(PhraseCard(
                    text: text,
                    category: category,
                    isPreset: true,
                    priority: priority,
                    createdAt: Date()
                ))
                priority += 1
            }
        }
        return cards
    }
}
