import SwiftUI
import Domain

@available(iOS 17.0, *)
struct ParentPhrasesVoiceInputOverlayView: View {
    let isRecording: Bool
    let text: String
    let errorText: String?
    let rms: Double
    @Binding var selectedCategory: PhraseCategory
    let onStop: () -> Void
    let onClose: () -> Void
    let onDiscard: () -> Void
    let onAdd: () -> Void

    var body: some View {
        let level = max(0.0, min(1.0, (rms + 60.0) / 60.0)) // -60...0 dBFS -> 0...1
        ZStack {
            Color.black.opacity(0.22)
                .ignoresSafeArea()
                .onTapGesture { onClose() }

            VStack(spacing: 12) {
                HStack {
                    HStack(spacing: 10) {
                        ZStack {
                            Circle()
                                .fill(Color.anoneButton.opacity(0.18))
                                .frame(width: 18, height: 18)
                                .scaleEffect(0.9 + level * 0.9)
                                .animation(.linear(duration: 0.08), value: level)
                            Circle()
                                .fill(Color.anoneButton)
                                .frame(width: 8, height: 8)
                        }
                        Text(isRecording ? "聞いてるよ…" : "音声入力")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "5A4A42"))
                    }
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundColor(Color(hex: "5A4A42"))
                    Spacer()
                    Button("閉じる") { onClose() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.gray)
                }
                .overlay(alignment: .trailing) {
                    Button("破棄") { onDiscard() }
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(.red)
                        .padding(.trailing, 72)
                        .opacity((isRecording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ? 0.0 : 1.0)
                        .disabled(isRecording || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let err = errorText, !err.isEmpty {
                            Text(err)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(.red)
                        }
                        Text(text.isEmpty ? "（ここに文字が表示されます）" : text)
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                            .foregroundColor(Color(hex: "5A4A42"))
                    }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(Color.white.opacity(0.95))
                        .cornerRadius(16)
                }
                .frame(maxHeight: 160)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(PhraseCategory.builtinAllCases) { cat in
                            Button {
                                selectedCategory = cat
                            } label: {
                                Label(cat.rawValue, systemImage: cat.icon)
                                    .font(.system(size: 12, weight: .bold, design: .rounded))
                                    .padding(.vertical, 8)
                                    .padding(.horizontal, 10)
                                    .background(selectedCategory == cat ? Color.anoneButton : Color.white.opacity(0.85))
                                    .foregroundColor(selectedCategory == cat ? .white : Color(hex: "5A4A42"))
                                    .cornerRadius(14)
                            }
                        }
                    }
                }

                HStack(spacing: 12) {
                    Button(action: onStop) {
                        Label(isRecording ? "停止" : "再開", systemImage: isRecording ? "stop.fill" : "mic.fill")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.white.opacity(0.85))
                            .foregroundColor(Color(hex: "5A4A42"))
                            .cornerRadius(16)
                    }

                    Button(action: onAdd) {
                        Label(isRecording ? "停止して追加" : "カードに追加", systemImage: "plus")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Color.anoneButton)
                            .foregroundColor(.white)
                            .cornerRadius(16)
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.55 : 1.0)
                }
            }
            .padding(16)
            .background(.ultraThinMaterial)
            .cornerRadius(22)
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }
}


