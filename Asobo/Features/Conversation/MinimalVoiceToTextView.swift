import SwiftUI
import AVFoundation
import Speech

/// ConversationController をそのまま使って、
/// 「音声入力 → リアルタイムでテキスト表示」だけに特化した最小ビュー
public struct MinimalVoiceToTextView: View {
    @StateObject private var vm: ConversationController

    public init(controller: ConversationController? = nil) {
        _vm = StateObject(wrappedValue: controller ?? ConversationController())
    }

    public var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                // タイトル
                Text("音声を文字に変換")
                    .font(.largeTitle).bold()

                // デバッグ情報（軽量）
                VStack(alignment: .leading, spacing: 4) {
                    Text("🔍 デバッグ")
                        .font(.caption)
                        .foregroundColor(.blue)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        Text("📱 \(vm.isRecording ? "録音中" : "停止中")")
                        Text("🎤 \(vm.hasMicrophonePermission ? "✅マイク許可" : "❌未許可")")
                        Text("🗣️ STT")
                        Text(vm.mode == .localSTT ? "✅ローカル" : "—")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    if let err = vm.errorMessage, !err.isEmpty {
                        Text("❌ \(err)")
                            .font(.caption2)
                            .foregroundColor(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(8)
                .background(Color.gray.opacity(0.12))
                .cornerRadius(8)

                // あなたの音声入力（部分認識→確定を随時反映）
                VStack(alignment: .leading, spacing: 6) {
                    Text("🎤 あなたの音声入力")
                        .font(.caption)
                        .foregroundColor(.green)

                    ScrollView {
                        Text(vm.transcript.isEmpty ? "（ボタンを押して話すと、ここに文字が流れます）" : vm.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(10)
                    }
                    .frame(minHeight: 80, maxHeight: 180)

                    HStack(spacing: 8) {
                        Button("コピー") {
                            UIPasteboard.general.string = vm.transcript
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.transcript.isEmpty)

                        Button("クリア") {
                            // 録音を止めずに画面だけクリア
                            vm.transcript = ""
                        }
                        .buttonStyle(.bordered)
                        .disabled(vm.transcript.isEmpty)
                    }
                }

                // 録音ボタン（ConversationController の Local STT を開始/停止）
                Button {
                    if vm.isRecording {
                        vm.stopLocalTranscription()
                    } else {
                        // 念のため Realtime を停止してからローカル STT を開始
                        vm.stopRealtimeSession()
                        vm.startLocalTranscription()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(vm.isRecording ? Color.red : Color.blue)
                            .frame(width: 120, height: 120)
                            .scaleEffect(vm.isRecording ? 1.06 : 1.0)
                            .animation(.easeInOut(duration: 0.12), value: vm.isRecording)
                        Image(systemName: vm.isRecording ? "stop.fill" : "mic.fill")
                            .font(.system(size: 40))
                            .foregroundColor(.white)
                    }
                }

                Text(vm.isRecording ? "録音中（ローカル文字起こし）" : "タップして録音開始")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()
            }
            .padding()
            .onAppear {
                // この画面はローカルSTT専用
                vm.mode = .localSTT
                vm.stopRealtimeSession()
                vm.requestPermissions()
            }
            .onDisappear {
                vm.stopLocalTranscription()
            }
        }
    }
}
