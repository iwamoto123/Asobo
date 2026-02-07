import SwiftUI
import AVFoundation
import Domain

private let analytics = AnalyticsService.shared

// MARK: - Color Palette
extension Color {
    // 変更点: より暖かみのあるオレンジ・ベージュ系の薄いグラデーションに変更
    static let anoneBgTop = Color(red: 1.0, green: 0.96, blue: 0.91) // Warm Milk
    static let anoneBgBottom = Color(red: 1.0, green: 0.88, blue: 0.80) // Soft Peach Orange
    static let anoneButton = Color(red: 1.0, green: 0.6, blue: 0.5) // Living Coral
    static let anoneHeartLight = Color(red: 1.0, green: 0.75, blue: 0.7) // Light Pink
    static let anoneHeartDark = Color(red: 0.95, green: 0.5, blue: 0.45) // Deep Coral
    static let anoneShadowLight = Color.white.opacity(0.6)
    static let anoneShadowDark = Color(red: 0.8, green: 0.6, blue: 0.5).opacity(0.3)
}

public struct ChildHomeView: View {
    @EnvironmentObject var authVM: AuthViewModel
    @StateObject private var controller = ConversationController()
    @State private var isBreathing = false
    @State private var isPressed = false
    /// Home表示用に「最後に確定したユーザーテキスト」を保持する。
    /// Controller側がセッション切替などで値をクリアしても、次の更新まで表示を維持する。
    @State private var stableUserText: String = ""
    /// lastCommittedUserText の反映をデバウンスして、ホーム表示のブレ/チカチカを防ぐ
    @State private var stableUserTextUpdateTask: Task<Void, Never>?
    /// 録音中のライブ表示は更新頻度が高いので、Home側で軽く間引いて“ブレ”を抑える
    @State private var stableLiveText: String = ""
    @State private var stableLiveTextUpdateTask: Task<Void, Never>?
    @State private var hasStartedSession = false
    @State private var initialGreetingText: String = ""
    @State private var lastAIDisplayText: String = ""
    @State private var isBlinking = false
    @State private var isSquinting = false
    @State private var isNodding = false
    /// Homeの名前ボタンで「いま呼んでほしい子」を指定（きょうだいがいる場合のみ）
    @State private var preferredChildId: String?

    // 最初の質問パターン
    private let greetingPatterns = [
        "ねえねえ、\nきょうは なにが たのしかった？",
        "こんにちは！\nきょうは なにして あそんだ？",
        "おはよう！\nいま どんな きもち？",
        "やあ！\nきょうは なにが おもしろかった？",
        "こんにちは！\nきょうは どこに いったの？",
        "やあ！\nきょうは だれと あそんだ？",
        "こんにちは！\nきょうは なにを たべた？",
        "こんにちは！\nなにか すきなものある？",
        "やあ！\nきょうは どんな ことした？",
        "こんにちは！\nいま 気になることある？"
    ]

    public init() {}

    public var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width
            let h = geometry.size.height
            // ✅ 画面に対して均等に見えるように、縦を3ブロックに分けて相対配置する
            // - 上: 吹き出し
            // - 中: くま
            // - 下: ユーザー台詞ボックス（タブバー分だけ余白を確保）
            // 全体が上に寄りすぎる場合があるので、ほんの少しだけ全体を下げる
            let globalDownShift = max(10, h * 0.015)
            // タブバー/ホームインジケータの逃げ（大きすぎると全体が上に寄るので少しだけ控えめに）
            let bottomPad = max(56, h * 0.06)
            let topRegion = max(140, h * 0.23)
            let bottomRegion = max(120, h * 0.22)
            let middleRegion = max(0, h - topRegion - bottomRegion - bottomPad)
            let interGap = max(8, h * 0.012) // くまとユーザー台詞ボックスの間（ほんの少し）

            // くまは「中ブロック」に収まる範囲でサイズ決定（上に行きすぎない）
            let desiredBear = w * 0.80
            let bearSize = max(220, min(desiredBear, middleRegion * 0.95))
            let bubbleWidth = min(w * 0.88, 560)

            ZStack {
                // 1. Background
                LinearGradient(
                    gradient: Gradient(colors: [.anoneBgTop, .anoneBgBottom]),
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                // 背景の浮遊物
                AmbientCircles()

                // 2. Main Character & Interface
                VStack(spacing: 0) {
                    // 上: 吹き出し（上ブロックの中で下寄せ）
                    VStack {
                        // 画面上端にほんの少し余白（長文で伸びた時にも“余裕”が見える）
                        Spacer(minLength: max(10, h * 0.015))
                        Spacer(minLength: 0)
                        SpeechBubbleView(
                            text: currentDisplayText,
                            isThinking: controller.isThinking,
                            isConnecting: controller.isRealtimeConnecting
                        )
                        .frame(width: bubbleWidth)
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: currentDisplayText)
                    }
                    .frame(height: topRegion)
                    .frame(maxWidth: .infinity)

                    // 中: くま（中ブロックの中央〜やや下寄せ）
                    VStack {
                        Spacer(minLength: 0)
                        MocchyBearView(
                            size: bearSize,
                            isRecording: controller.isRecording,
                            isPressed: isPressed,
                            isBreathing: isBreathing,
                            isBlinking: isBlinking,
                            isSquinting: isSquinting,
                            isNodding: isNodding,
                            onTap: handleMicButtonTap,
                            onPressChanged: { pressed in
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) { // バウンスを強めに
                                    isPressed = pressed
                                }
                            }
                        )
                        .opacity((controller.isRealtimeActive || controller.isRealtimeConnecting) ? 1.0 : 0.6)
                        .disabled(!controller.isRealtimeActive && !controller.isRealtimeConnecting)
                        Spacer(minLength: max(bearSize * 0.08, interGap))
                    }
                    .frame(height: middleRegion)
                    .frame(maxWidth: .infinity)

                    // 下: ユーザー台詞ボックス（下ブロックの上寄せ）
                    VStack {
                        VStack(spacing: 10) {
                            userSpeechCardView

                            // きょうだいがいる場合のみ：名前ボタン
                            if authVM.children.count > 1 {
                                preferredNameButtonsView
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, interGap)
                        Spacer(minLength: 0)
                    }
                    .frame(height: bottomRegion)
                    .frame(maxWidth: .infinity)

                    // タブバー/ホームインジケータの逃げ
                    Spacer(minLength: bottomPad)
                }
                .padding(.top, globalDownShift)

                // エラー表示
                if let errorMessage = controller.errorMessage {
                    VStack {
                        Spacer()
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundColor(.white)
                            .padding()
                            .background(Color.red.opacity(0.8))
                            .cornerRadius(10)
                            .padding(.bottom, 100)
                    }
                }
            }
        }
        .onAppear {
            analytics.logScreenView(.home)

            // ✅ AuthViewModelからユーザー情報を取得してConversationControllerに設定
            if let userId = authVM.currentUser?.uid, let child = authVM.selectedChild, let childId = child.id {
                controller.setupUser(
                    userId: userId,
                    childId: childId,
                    childName: child.displayName,
                    childNickname: child.nickName
                )
            }
            // 初期はオーバーライドなし
            controller.setPreferredCallNameOverride(nil)
            controller.setSpeakerAttributionOverride(childId: nil, childName: nil)
            preferredChildId = nil

            withAnimation(.easeInOut(duration: 3.0).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
            if initialGreetingText.isEmpty {
                initialGreetingText = greetingPatterns.randomElement() ?? greetingPatterns[0]
            }

            // ✅ セッションが停止している場合は再開する（タブ切り替え後の復帰対応）
            if !controller.isRealtimeActive && !controller.isRealtimeConnecting {
                if !hasStartedSession {
                    hasStartedSession = true
                    controller.mode = .realtime
                    controller.requestPermissions()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    controller.startRealtimeSession()
                }
            }

            startEyeAnimation()
            startNoddingAnimation()
        }
        .onChange(of: authVM.selectedChild?.id) { _ in
            // 選択中の子が変わったら、Homeの「呼び名優先」もリセット
            preferredChildId = nil
            controller.setPreferredCallNameOverride(nil)
            controller.setSpeakerAttributionOverride(childId: nil, childName: nil)
        }
        .onDisappear {
            // ✅ タブを離れた時にセッションを停止（オプション：必要に応じてコメントアウト）
            // 注意: これを有効にすると、タブを切り替えるたびにセッションが停止・再開される
            // controller.stopRealtimeSession()
        }
        .onChange(of: controller.isRecording) { _ in
            // 録音中の頻度調整は、startEyeAnimation内で管理
        }
        .onChange(of: controller.isRecording) { isRecording in
            if isRecording {
                // 新規録音開始：前回のライブ表示を一旦クリア
                stableLiveTextUpdateTask?.cancel()
                stableLiveTextUpdateTask = nil
                stableLiveText = ""
                scheduleLiveTextUpdate()
            } else {
                // 録音停止：確定文が来るまで直前のライブを保持したいので、ここでは消さない
                stableLiveTextUpdateTask?.cancel()
                stableLiveTextUpdateTask = nil
            }
        }
        .onChange(of: controller.handsFreeMonitorTranscript) { _ in
            scheduleLiveTextUpdate()
        }
        .onChange(of: controller.transcript) { _ in
            scheduleLiveTextUpdate()
        }
        .onChange(of: controller.lastCommittedUserText) { newValue in
            // ✅ 確定したテキストは「少し待ってから」固定表示する（更新のブレ/チカチカ回避）
            stableUserTextUpdateTask?.cancel()
            let raw = newValue
            stableUserTextUpdateTask = Task { @MainActor in
                // 軽いラグを入れて、コミット直後の揺れを吸収
                try? await Task.sleep(nanoseconds: 260_000_000) // 0.26s
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                // 技術的プレースホルダはUIに出さない
                guard trimmed != "(voice)" else { return }
                // 同じ文を再設定しない
                if stableUserText != trimmed {
                    stableUserText = trimmed
                    // ✅ 確定文が更新されたら、次のユーザー発話が来るまでライブ表示は空に戻す
                    // （送信/再起動でライブが一瞬空になったときに前回確定文へ戻る“チラ見え”を防ぐ）
                    stableLiveText = ""
                }
            }
        }
        .onChange(of: controller.aiResponseText) { newValue in
            // AIテキストが更新されたら常に保持（録音中の表示は固定で最後の値を使う）
            if !newValue.isEmpty {
                lastAIDisplayText = newValue
            }
        }
        .onAppear {
            lastAIDisplayText = controller.aiResponseText
        }
    }

    private var currentDisplayText: String {
        if controller.isRealtimeConnecting {
            return "つながっています..."
        }

        // 返答テキストが届いたら思考中でも即表示する
        if controller.isThinking && controller.aiResponseText.isEmpty {
            return "かんがえちゅう..."
        }

        if !controller.aiResponseText.isEmpty {
            return controller.aiResponseText
        } else if controller.isRecording {
            // ユーザー発話中は前ターンのAIテキストをそのまま表示
            if !lastAIDisplayText.isEmpty {
                return lastAIDisplayText
            } else if !initialGreetingText.isEmpty {
                return initialGreetingText
            }
        }

        if !lastAIDisplayText.isEmpty {
            return lastAIDisplayText
        }
        return initialGreetingText
    }

    private var liveUserTranscriptText: String {
        let t = !controller.handsFreeMonitorTranscript.isEmpty
        ? controller.handsFreeMonitorTranscript
        : controller.transcript
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var monitorUserText: String {
        // ✅ 録音中：
        // - 次のユーザー発話（ライブ文字）が来るまでは「前回の確定文」を表示したままにする
        // - ライブ文字が入ったらライブ表示へ切り替える
        if controller.isRecording {
            if !stableLiveText.isEmpty {
                return stableLiveText
            }
            return stableUserText
        }
        // ✅ 録音後：確定文があればそれを表示。確定が来るまでの間は直前のライブを保持。
        return !stableUserText.isEmpty ? stableUserText : stableLiveText
    }

    private var userSpeechCardView: some View {
        // 恋愛ゲーム風：ラベル類は出さず、台詞ウィンドウだけに寄せる
        let t = monitorUserText
        let placeholder = "話してみてね"
        let displayText = t.isEmpty ? placeholder : t

        return VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical, showsIndicators: false) {
                Text(displayText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .foregroundColor(t.isEmpty ? .secondary : .primary)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
                .lineSpacing(4)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
            }
            .frame(minHeight: 54, maxHeight: 110)
        }
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.black.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.white.opacity(0.45), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.10), radius: 12, x: 0, y: 6)
    }

    private var preferredNameButtonsView: some View {
        // childrenは「メイン + きょうだい」同列。ボタンは“呼び名（ニックネーム優先）”を表示する。
        let items: [(id: String, label: String)] = authVM.children.compactMap { child in
            guard let id = child.id else { return nil }
            let nick = (child.nickName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let name = child.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = !nick.isEmpty ? nick : name
            guard !label.isEmpty else { return nil }
            return (id: id, label: label)
        }

        return HStack(spacing: 10) {
            Text("今話しているのは")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Color(hex: "5A4A42"))
                .lineLimit(1)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        let isSelected = (preferredChildId == item.id)
                        Button {
                            // ✅ 仕様: タップで選択（=ずっとその子）、もう一度タップで解除
                            if preferredChildId == item.id {
                                preferredChildId = nil
                                controller.setPreferredCallNameOverride(nil)
                                controller.setSpeakerAttributionOverride(childId: nil, childName: nil)
                            } else {
                                preferredChildId = item.id
                                controller.setPreferredCallNameOverride(item.label)
                                controller.setSpeakerAttributionOverride(childId: item.id, childName: item.label)
                            }
                        } label: {
                            Text(item.label)
                                .font(.system(size: 14, weight: .semibold))
                                .padding(.vertical, 8)
                                .padding(.horizontal, 12)
                                .background(isSelected ? Color.anoneButton : Color.white.opacity(0.9))
                                .foregroundColor(isSelected ? .white : Color.anoneButton)
                                .clipShape(Capsule())
                                .overlay(
                                    Capsule()
                                        .stroke(Color.anoneButton.opacity(isSelected ? 0 : 0.35), lineWidth: 1)
                                )
                        }
                    }
                }
                .padding(.horizontal, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("今話しているのは、呼んでほしい名前を選ぶ")
    }

    private func handleMicButtonTap() {
        guard controller.isRealtimeActive else { return }
        if controller.isHandsFreeMode {
            controller.stopHandsFreeConversation()
            // ✅ ハート停止時：ユーザーの表示を初期状態に戻す
            stableUserTextUpdateTask?.cancel()
            stableUserTextUpdateTask = nil
            stableLiveTextUpdateTask?.cancel()
            stableLiveTextUpdateTask = nil
            stableUserText = ""
            stableLiveText = ""
            controller.lastCommittedUserText = ""
            controller.handsFreeMonitorTranscript = ""
            controller.transcript = ""
        } else {
            controller.startHandsFreeConversation()
            // ✅ 再開時も前の表示が残らないように初期化
            stableUserTextUpdateTask?.cancel()
            stableUserTextUpdateTask = nil
            stableLiveTextUpdateTask?.cancel()
            stableLiveTextUpdateTask = nil
            stableUserText = ""
            stableLiveText = ""
            controller.lastCommittedUserText = ""
            controller.handsFreeMonitorTranscript = ""
            controller.transcript = ""
        }
    }

    private func scheduleLiveTextUpdate() {
        guard controller.isRecording else { return }
        stableLiveTextUpdateTask?.cancel()
        let raw = liveUserTranscriptText
        stableLiveTextUpdateTask = Task { @MainActor in
            // ライブ表示は少し間引いて読みやすさ優先（それでも十分リアルタイム）
            try? await Task.sleep(nanoseconds: 120_000_000) // 0.12s
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            // ✅ ライブ側は「空文字への更新」をしない（STTの瞬間的な空で表示がブレるのを防ぐ）
            guard !trimmed.isEmpty else { return }
            if stableLiveText != trimmed {
                stableLiveText = trimmed
            }
        }
    }

    // アニメーションロジック（既存のゆっくりしたアニメーションを維持）
    // まばたきとsquintingを1つのタスクで管理し、同時に起こらないようにする
    private func startEyeAnimation() {
        Task {
            while true {
                // まばたきかsquintingかをランダムに選ぶ
                let isBlink = Bool.random()

                if isBlink {
                    // まばたき（頻度を減らす）
                    let baseInterval: TimeInterval = controller.isRecording ? 3.0 : 6.0
                    let randomInterval = baseInterval + Double.random(in: 0...6.0)
                    try? await Task.sleep(nanoseconds: UInt64(randomInterval * 1_000_000_000))

                    await MainActor.run {
                        // squintingが有効な場合は待機
                        if isSquinting {
                            return
                        }
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.2)) {
                            isBlinking = true
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(0.5 * 1_000_000_000))
                    try? await Task.sleep(nanoseconds: UInt64(0.2 * 1_000_000_000))
                    await MainActor.run {
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.75, blendDuration: 0.2)) {
                            isBlinking = false
                        }
                    }
                } else {
                    // squinting
                    let randomInterval = Double.random(in: 6.0...15.0)
                    try? await Task.sleep(nanoseconds: UInt64(randomInterval * 1_000_000_000))

                    await MainActor.run {
                        // まばたきが有効な場合は待機
                        if isBlinking {
                            return
                        }
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0.1)) {
                            isSquinting = true
                        }
                    }
                    let squintDuration = Double.random(in: 0.5...1.5)
                    try? await Task.sleep(nanoseconds: UInt64(squintDuration * 1_000_000_000))
                    await MainActor.run {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.7, blendDuration: 0.1)) {
                            isSquinting = false
                        }
                    }
                }
            }
        }
    }

    private func startNoddingAnimation() {
        Task {
            while true {
                let randomInterval = Double.random(in: 8.0...15.0)
                try? await Task.sleep(nanoseconds: UInt64(randomInterval * 1_000_000_000))
                for _ in 0..<2 {
                    await MainActor.run {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.2)) {
                            isNodding = true
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                    await MainActor.run {
                        withAnimation(.spring(response: 0.6, dampingFraction: 0.8, blendDuration: 0.2)) {
                            isNodding = false
                        }
                    }
                    try? await Task.sleep(nanoseconds: UInt64(0.3 * 1_000_000_000))
                }
            }
        }
    }
}

// MARK: - Subviews

/// ハートを抱えたくまちゃんキャラクター
struct MocchyBearView: View {
    let size: CGFloat
    let isRecording: Bool
    let isPressed: Bool
    let isBreathing: Bool
    let isBlinking: Bool
    let isSquinting: Bool
    let isNodding: Bool
    let onTap: () -> Void
    let onPressChanged: (Bool) -> Void

    var body: some View {
        ZStack {
            // 1. 耳
            HStack(spacing: size * 0.45) { // 少し離す
                BearEar(size: size)
                BearEar(size: size)
            }
            .offset(y: -size * 0.32)
            .scaleEffect(isBreathing ? 1.02 : 0.98)
            .offset(y: isNodding ? size * 0.03 : 0)

            // 2. 体 (顔と胴体の一体型)
            // 押されたときに「むにゅっ」と潰れるアニメーション
            Circle()
                .fill(.white)
                .frame(width: size * 0.85, height: size * 0.82)
                .shadow(color: .anoneShadowDark, radius: 20, x: 0, y: 10)
                .shadow(color: .white, radius: 10, x: -5, y: -5)
                .scaleEffect(isBreathing ? 1.02 : 0.98)
                .scaleEffect(x: isPressed ? 1.05 : 1.0, y: isPressed ? 0.92 : 1.0) // 潰れる
                .offset(y: isPressed ? size * 0.02 : 0) // 少し下がる

            // 3. 顔パーツ (中心より下に配置してベビーフェイス化)
            VStack(spacing: size * 0.015) {
                // 目
                HStack(spacing: size * 0.15) { // もっと中央に配置
                    EyeView(size: size, isBlinking: isBlinking, isSquinting: isSquinting)
                    EyeView(size: size, isBlinking: isBlinking, isSquinting: isSquinting)
                }

                // 鼻
                Ellipse()
                    .fill(Color(hex: "4A3A32"))
                    .frame(width: size * 0.07, height: size * 0.045)
            }
            .offset(y: size * 0.05) // もっと下に下げる
            .scaleEffect(isBreathing ? 1.02 : 0.98)
            .offset(y: isNodding ? size * 0.03 : 0)
            .scaleEffect(x: isPressed ? 1.02 : 1.0, y: isPressed ? 0.98 : 1.0) // 顔も一緒に潰れる

            // ほっぺ (チーク) - 鼻と同じ高さに配置
            HStack(spacing: size * 0.32) {
                CheekView(size: size)
                CheekView(size: size)
            }
            .offset(y: size * 0.0875) // 鼻の中心と同じ高さ（size * 0.05 + size * 0.015 + size * 0.0225）
            .scaleEffect(isBreathing ? 1.02 : 0.98)
            .offset(y: isNodding ? size * 0.03 : 0)
            .scaleEffect(x: isPressed ? 1.02 : 1.0, y: isPressed ? 0.98 : 1.0) // 顔も一緒に潰れる

            // 4. ハートのボタン
            HeartButtonBody(size: size, isRecording: isRecording, isPressed: isPressed)
            .offset(y: size * 0.32) // 少し上に配置
            .scaleEffect(x: isPressed ? 0.95 : 1.0, y: isPressed ? 0.95 : 1.0) // ボタン自体も縮む
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in onPressChanged(true) }
                    .onEnded { _ in
                        onPressChanged(false)
                        onTap()
                    }
            )
            .zIndex(1000)

            // 5. 手 (ハートを抱っこ)
            HStack(spacing: size * 0.52) {
                BearHand(size: size)
                    .rotationEffect(.degrees(-10))
                BearHand(size: size)
                    .rotationEffect(.degrees(10))
            }
            .offset(y: size * 0.32) // ハートと同じ高さ
            .scaleEffect(isBreathing ? 1.02 : 0.98)
            .offset(y: isPressed ? size * 0.01 : 0) // 手も一緒に動く
        }
    }
}

// MARK: - Parts Components

struct BearEar: View {
    let size: CGFloat
    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: size * 0.24, height: size * 0.24)
                .shadow(color: .anoneShadowDark.opacity(0.2), radius: 4, x: 0, y: 2)
            // 内耳（うっすらピンク）
            Circle()
                .fill(Color.anoneHeartLight.opacity(0.3))
                .frame(width: size * 0.14, height: size * 0.14)
        }
    }
}

struct BearHand: View {
    let size: CGFloat
    var body: some View {
        Circle()
            .fill(.white)
            .frame(width: size * 0.18, height: size * 0.18)
            .shadow(color: .anoneShadowDark.opacity(0.2), radius: 3, x: 0, y: 2)
    }
}

struct CheekView: View {
    let size: CGFloat
    var body: some View {
        Ellipse()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 1.0, green: 0.6, blue: 0.6).opacity(0.4),
                        Color(red: 1.0, green: 0.6, blue: 0.6).opacity(0.0)
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: size * 0.12
                )
            )
            .frame(width: size * 0.18, height: size * 0.12)
    }
}

struct EyeView: View {
    let size: CGFloat
    let isBlinking: Bool
    let isSquinting: Bool

    var body: some View {
        Group {
            if isBlinking {
                // つぶった目（線）
                Capsule()
                    .fill(Color(hex: "4A3A32"))
                    .frame(width: size * 0.06, height: size * 0.008)
            } else if isSquinting {
                // 笑った目（アーチ）
                Circle()
                    .trim(from: 0.5, to: 1.0)
                    .stroke(Color(hex: "4A3A32"), style: StrokeStyle(lineWidth: size * 0.008, lineCap: .round))
                    .frame(width: size * 0.06, height: size * 0.06)
                    .rotationEffect(.degrees(180))
            } else {
                // 通常の目（まんまる）
                Circle()
                    .fill(Color(hex: "4A3A32"))
                    .frame(width: size * 0.06, height: size * 0.06)
                    // 目のハイライト（キラキラ感）
                    .overlay(
                        Circle()
                            .fill(.white)
                            .frame(width: size * 0.02, height: size * 0.02)
                            .offset(x: size * 0.015, y: -size * 0.015)
                    )
            }
        }
    }
}

struct HeartButtonBody: View {
    let size: CGFloat
    let isRecording: Bool
    let isPressed: Bool

    var body: some View {
        ZStack {
            // 影
            PuffyHeartShape()
                .fill(.black.opacity(0.15))
                .frame(width: size * 0.55, height: size * 0.50)
                .blur(radius: 10)
                .offset(y: 8)

            // 本体
            PuffyHeartShape()
                .fill(
                    LinearGradient(
                        colors: isRecording
                        ? [Color(hex: "FF6B6B"), Color(hex: "FF8E8E")]
                        : [.anoneHeartDark, .anoneHeartLight],
                        startPoint: .bottomTrailing,
                        endPoint: .topLeading
                    )
                )
                .frame(width: size * 0.55, height: size * 0.50)
                .overlay(
                    PuffyHeartShape()
                        .stroke(Color.white.opacity(0.4), lineWidth: 4)
                        .blur(radius: 4)
                        .offset(x: -2, y: -2)
                        .mask(PuffyHeartShape().frame(width: size * 0.55, height: size * 0.50))
                )
                .overlay(
                    // ハイライト
                    Circle()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: size * 0.12, height: size * 0.08)
                        .rotationEffect(.degrees(-20))
                        .blur(radius: 6)
                        .offset(x: size * 0.14, y: -size * 0.12)
                )
                .shadow(color: .anoneButton.opacity(0.3), radius: 10, x: 0, y: 5)

            // アイコン
            Image(systemName: isRecording ? "stop.fill" : "mic.fill")
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundColor(.white.opacity(0.95))
                .shadow(color: .black.opacity(0.1), radius: 1, x: 1, y: 1)
        }
    }
}

// MARK: - Typewriter

/// タイプライター風の表示（確定文向け）。
/// - Note: ライブ更新（STTのdelta）に追従させると読みづらいので、Homeでは「確定文」のみ想定。
struct TypewriterText: View {
    let text: String
    let isActive: Bool
    let showsCursorWhenActive: Bool
    var interval: TimeInterval = 0.018

    @State private var rendered: String = ""
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text(rendered + (showsCursorWhenActive && isActive && rendered != text ? "▍" : ""))
            .onAppear { startIfNeeded() }
            .onChange(of: text) { _ in startIfNeeded() }
            .onChange(of: isActive) { _ in startIfNeeded() }
            .onDisappear {
                task?.cancel()
                task = nil
            }
    }

    private func startIfNeeded() {
        task?.cancel()
        task = nil

        guard isActive else {
            rendered = text
            return
        }

        // 先頭から打ち直す（恋愛ゲームっぽい挙動）
        rendered = ""
        let target = text
        task = Task {
            for ch in target {
                if Task.isCancelled { return }
                await MainActor.run {
                    rendered.append(ch)
                }
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            }
        }
    }
}

/// 録音中のキラキラエフェクト
struct ParticleEffectView: View {
    let size: CGFloat
    @State private var animate = false

    var body: some View {
        ZStack {
            ForEach(0..<6, id: \.self) { i in
                ParticleHeart(
                    size: size,
                    index: i,
                    targetAngle: Double(i) * 60.0,
                    animate: animate
                )
            }
        }
        .onAppear { animate = true }
    }
}

private struct ParticleHeart: View {
    let size: CGFloat
    let index: Int
    let targetAngle: Double
    let animate: Bool

    private var radians: Double {
        targetAngle * .pi / 180
    }

    var body: some View {
        PuffyHeartShape()
            .fill(
                LinearGradient(
                    colors: [Color.anoneHeartLight, Color.anoneHeartDark],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size * 0.05, height: size * 0.05)
            .offset(
                x: animate ? cos(radians) * size * 1.5 : 0,
                y: animate ? sin(radians) * size * 1.5 : 0
            )
            .opacity(animate ? 0 : 1)
            .rotationEffect(.degrees(targetAngle))
            .animation(
                .easeOut(duration: 1.5)
                .repeatForever(autoreverses: false)
                .delay(Double(index) * 0.2),
                value: animate
            )
    }
}

/// ふっくらしたハートの形状
struct PuffyHeartShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let width = rect.width
        let height = rect.height

        // より丸みを帯びたハートを描く
        path.move(to: CGPoint(x: width / 2, y: height * 0.85))

        // 左下のカーブ
        path.addCurve(
            to: CGPoint(x: 0, y: height * 0.35),
            control1: CGPoint(x: width * 0.1, y: height * 0.75),
            control2: CGPoint(x: -width * 0.1, y: height * 0.5)
        )

        // 左上の山
        path.addCurve(
            to: CGPoint(x: width / 2, y: height * 0.25),
            control1: CGPoint(x: width * 0.05, y: 0),
            control2: CGPoint(x: width * 0.45, y: 0)
        )

        // 右上の山
        path.addCurve(
            to: CGPoint(x: width, y: height * 0.35),
            control1: CGPoint(x: width * 0.55, y: 0),
            control2: CGPoint(x: width * 0.95, y: 0)
        )

        // 右下のカーブ
        path.addCurve(
            to: CGPoint(x: width / 2, y: height * 0.85),
            control1: CGPoint(x: width * 1.1, y: height * 0.5),
            control2: CGPoint(x: width * 0.9, y: height * 0.75)
        )

        path.closeSubpath()
        return path
    }
}

/// 吹き出しView
struct SpeechBubbleView: View {
    let text: String
    let isThinking: Bool
    let isConnecting: Bool

    var body: some View {
        // しっぽを「レイアウトの一部」にして、吹き出しの下部に常にくっつくようにする
        VStack(spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 30)
                    .fill(Color.white.opacity(0.95))

                // テキスト表示エリア
                VStack {
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "5A4A42"))
                            .multilineTextAlignment(.center)
                            .lineSpacing(6)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                    }
                }
                .padding(20)
            }
            .shadow(color: .anoneShadowDark.opacity(0.15), radius: 10, x: 0, y: 5)
            .frame(minHeight: 100)

            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.95))
                // ちょっとだけ重ねて「くっつき感」を出す
                .padding(.top, -4)
                .shadow(color: .anoneShadowDark.opacity(0.1), radius: 2, x: 0, y: 2)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

// 背景のふわふわ
struct AmbientCircles: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(Color.blue.opacity(0.05))
                .frame(width: 300, height: 300)
                .offset(x: -100, y: -300)

            Circle()
                .fill(Color.yellow.opacity(0.1))
                .frame(width: 200, height: 200)
                .offset(x: 150, y: 100)

            Circle()
                .fill(Color.green.opacity(0.05))
                .frame(width: 150, height: 150)
                .offset(x: -120, y: 350)
        }
    }
}

// Helper for Hex Color
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
