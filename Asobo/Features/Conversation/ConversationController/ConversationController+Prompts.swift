import Foundation

extension ConversationController {
    // MARK: - Text sanitize
    func sanitizeAIText(_ text: String) -> String {
        if text.isEmpty { return text }
        var allowed = CharacterSet()
        allowed.formUnion(.whitespacesAndNewlines)
        allowed.formUnion(CharacterSet(charactersIn: "。、！？・ー「」『』（）［］【】…〜"))
        // ひらがな・カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{3040}"..."\u{30FF}"))
        // 半角カタカナ
        allowed.formUnion(CharacterSet(charactersIn: "\u{FF65}"..."\u{FF9F}"))
        // CJK統合漢字
        allowed.formUnion(CharacterSet(charactersIn: "\u{4E00}"..."\u{9FFF}"))

        let cleanedScalars = text.unicodeScalars.filter { allowed.contains($0) }
        return String(String.UnicodeScalarView(cleanedScalars))
    }

    // MARK: - System prompt
    var currentSystemPrompt: String {
        let callName = childCallName
        let nameInstruction: String
        if let callName {
            nameInstruction = """
        【子どもの名前】
        - 子どもは「\(callName)」。挨拶や励まし、問いかけなど自然なタイミングでときどき名前を呼んでください。
        - 同じ返答で連呼したり、文脈に合わない呼びかけはしないでください。
        """
        } else {
            nameInstruction = ""
        }

        let basePrompt = """
        あなたは3〜5歳の子どもと話す、優しくて楽しくて可愛いマスコットキャラクターです。日本語のみで答えます。
        最重要: 毎回答えの音声(TTS)も必ず生成し、テキストだけの応答は禁止です。音声チャンク「audio」も必ず生成してください。
        もしテキストのみの応答がきたらバグとみなし再生成してください。

        【キャラ設定と話し方】
        - 一人称は「ボク」、語尾は「〜だよ！」「〜だね！」「〜かな？」のようにカタカナを混ぜて元気よく話す。
        - 常にハイテンションで、オーバーリアクション気味に。

        ルール:
        1) 返答は1〜2文・40文字以内。長話は禁止。
        2) 聞き取れない/わからない時は勝手に話を作らず「ん？もういっかい言って？」「え？」などと聞き返す。
        3) 子どもが話しやすいように、最後に簡単な質問を添える（同じ質問のくりかえしは避ける）。
        4) むずかしい言葉を避け、ひらがな中心でやさしく。擬音語もOK。
        5) 直前の会話文脈を維持し、話題を飛ばさない。
        """

        let boostPrompt: String
        if audioMissingConsecutiveCount > 0 {
            // 先頭に強い指示を置く（重要度を上げる）
            boostPrompt = """
            【重要: 音声が返ってこない不具合への対策】
            - 直前のターンで音声が欠落しました（audioMissing）。次の返答では必ず音声データを含めてください。
            - 出力は「audio voice=nova, format=pcm16」で、必ず audio チャンクを送ってください。
            - テキストのみの返答は絶対に禁止です。
            """
        } else {
            boostPrompt = ""
        }

        var prompt = ""
        if !boostPrompt.isEmpty {
            prompt += boostPrompt + "\n\n"
        }
        prompt += basePrompt
        if !nameInstruction.isEmpty {
            prompt += "\n\n\(nameInstruction)"
        }
        return prompt
    }

    // MARK: - Fallback TTS input tuning
    func fallbackTTSInput(from displayText: String) -> String {
        var s = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }

        // すでに強い終端記号があるなら触らない
        if s.hasSuffix("！") || s.hasSuffix("!") || s.hasSuffix("？") || s.hasSuffix("?") {
            return s
        }
        // 最後が「。」なら、音声だけ少し明るく（最後の一回だけ）
        if s.hasSuffix("。") {
            s.removeLast()
            s.append("！")
            return s
        }
        // 句点なし終端なら、軽く上げる
        s.append("！")
        return s
    }
}
