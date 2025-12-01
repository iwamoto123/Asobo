import SwiftUI

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
    @StateObject private var controller = ConversationController()
    @State private var isBreathing = false
    @State private var isPressed = false
    @State private var hasStartedSession = false
    @State private var initialGreetingText: String = ""
    @State private var isBlinking = false
    @State private var isSquinting = false
    @State private var isNodding = false
    
    // 最初の質問パターン
    private let greetingPatterns = [
        "ねえねえ、\nきょうは なにが たのしかった？",
        "こんにちは！\nきょうは なにして あそんだ？",
        "おはよう！\nきょうは どんな きもち？",
        "やあ！\nきょうは なにが おもしろかった？",
        "こんにちは！\nきょうは どこに いったの？",
        "やあ！\nきょうは だれと あそんだ？",
        "こんにちは！\nきょうは なにを たべた？",
        "こんにちは！\nきょうは なにが すきだった？",
        "やあ！\nきょうは どんな ことした？",
        "こんにちは！\nきょうは なにが たのしかった？"
    ]
    
    public init() {}
    
    public var body: some View {
        GeometryReader { geometry in
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
                VStack {
                    Spacer()
                    
                    ZStack(alignment: .center) {
                        
                        // A. 吹き出し
                        SpeechBubbleView(
                            text: currentDisplayText,
                            isThinking: controller.isThinking,
                            isConnecting: controller.isRealtimeConnecting
                        )
                        .frame(width: geometry.size.width * 0.85)
                        .offset(y: -geometry.size.width * 0.68) // 少し上に調整
                        .animation(.spring(response: 0.5, dampingFraction: 0.7), value: currentDisplayText)
                        
                        // B. キャラクター with ハートボタン
                        MocchyBearView(
                            size: geometry.size.width * 0.8,
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
                    }
                    .frame(maxHeight: .infinity)
                    
                    Spacer()
                }
                
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
        .onDisappear {
            // ✅ タブを離れた時にセッションを停止（オプション：必要に応じてコメントアウト）
            // 注意: これを有効にすると、タブを切り替えるたびにセッションが停止・再開される
            // controller.stopRealtimeSession()
        }
        .onChange(of: controller.isRecording) { isRecording in
            // 録音中の頻度調整は、startEyeAnimation内で管理
        }
    }
    
    private var currentDisplayText: String {
        if controller.isRealtimeConnecting {
            return "つながっています..."
        } else if controller.isThinking {
            return "かんがえちゅう..."
        } else if !controller.aiResponseText.isEmpty {
            return controller.aiResponseText
        } else {
            return initialGreetingText
        }
    }
    
    private func handleMicButtonTap() {
        guard controller.isRealtimeActive else { return }
        if controller.isRecording {
            controller.stopPTTRealtime()
        } else {
            controller.startPTTRealtime()
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
        ZStack {
            // 吹き出し本体
            RoundedRectangle(cornerRadius: 30)
                .fill(Color.white.opacity(0.95))
                .shadow(color: .anoneShadowDark.opacity(0.15), radius: 10, x: 0, y: 5)
            
            // しっぽ (逆三角形)
            Image(systemName: "arrowtriangle.down.fill")
                .font(.system(size: 24))
                .foregroundColor(.white.opacity(0.95))
                .offset(y: 50) // 下へ
                .shadow(color: .anoneShadowDark.opacity(0.1), radius: 2, x: 0, y: 2)
            
            // テキスト表示エリア
            VStack {
                if isConnecting || isThinking {
                    HStack(spacing: 10) {
                        ProgressView()
                            .tint(Color.anoneButton)
                        Text(text)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "5A4A42"))
                    }
                } else if !text.isEmpty {
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
        .frame(minHeight: 100)
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
            blue:  Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
