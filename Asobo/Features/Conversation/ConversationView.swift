import SwiftUI

public struct ConversationView: View {
    @StateObject private var vm = ConversationController()

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // モード切替
                Picker("モード", selection: $vm.mode) {
                    Text("テキスト化(ローカル)").tag(ConversationController.Mode.localSTT)
                    Text("会話(Realtime)").tag(ConversationController.Mode.realtime)
                }
                .pickerStyle(.segmented)
            .onChange(of: vm.mode) { newValue in
                switch newValue {
                case .localSTT:
                    vm.stopRealtimeSession()
                case .realtime:
                    vm.stopLocalTranscription()
                    // 少し遅延してから開始（重複を防ぐ）
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        vm.startRealtimeSession()
                    }
                }
            }

                // デバッグ情報表示（コンパクト版）
                VStack(alignment: .leading, spacing: 2) {
                    Text("🔍 デバッグ情報")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    LazyVGrid(columns: [
                        GridItem(.flexible()),
                        GridItem(.flexible())
                    ], spacing: 4) {
                        Text("📱 \(vm.isRecording ? "録音中" : "停止中")")
                        Text("🎤 \(vm.hasMicrophonePermission ? "✅許可" : "❌未許可")")
                        Text("🔗 \(vm.isRealtimeConnecting ? "🔄接続中" : (vm.isRealtimeActive ? "✅接続済み" : "❌未接続"))")
                        Text("🔊 \(vm.isPlayingAudio ? "再生中" : "停止中")")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    
                    if let error = vm.errorMessage {
                        Text("❌ \(error)")
                            .foregroundColor(.red)
                            .font(.caption2)
                    }
                }
                .padding(6)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(6)
                
                // 音声入力テキスト表示
                VStack(alignment: .leading, spacing: 2) {
                    if vm.mode == .localSTT {
                        Text("🎤 あなたの音声入力（ローカル認識）")
                            .font(.caption)
                            .foregroundColor(.green)
                    } else {
                        Text("🎤 あなたの音声入力（Realtime認識）")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                    
                    if vm.mode == .realtime && vm.isRecording && vm.transcript.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .scaleEffect(0.8)
                            Text("音声を認識中...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.green.opacity(0.1))
                        .cornerRadius(8)
                        .frame(minHeight: 60, maxHeight: 80)
                    } else {
                        Text(vm.transcript.isEmpty ? "（音声を話すとここに文字が流れます）" : vm.transcript)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            .font(.caption)
                            .frame(minHeight: 60, maxHeight: 80)
                    }
                }
                
                // AI応答テキスト表示
                VStack(alignment: .leading, spacing: 2) {
                    Text("🤖 AI応答")
                        .font(.caption)
                        .foregroundColor(.blue)
                    
                    if vm.isThinking {
                        HStack(spacing: 6) {
                            ProgressView()
                            Text("かんがえちゅう…").font(.caption)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .background(Color.blue.opacity(0.06))
                        .cornerRadius(8)
                    } else {
                        Text(vm.aiResponseText.isEmpty ? "（AIの応答がここに表示されます）" : vm.aiResponseText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.blue.opacity(0.1))
                            .cornerRadius(8)
                            .font(.caption)
                            .frame(minHeight: 60, maxHeight: 80)
                    }
                }

                // コントロール
                Group {
                    if vm.mode == .localSTT {
                        // ローカルSTT：ワンタップで開始/停止
                        Button {
                            vm.isRecording ? vm.stopLocalTranscription() : vm.startLocalTranscription()
                        } label: {
                            Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(vm.isRecording ? .red : .blue)
                        }
                        Text(vm.isRecording ? "録音中（ローカル文字起こし）" : "タップして録音開始")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    } else {
                        // Realtime：セッション開始/終了 + PTT録音
                        HStack(spacing: 8) {
                            Button {
                                vm.startRealtimeSession()
                            } label: {
                                Label("開始", systemImage: "bolt.horizontal.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(vm.isRealtimeActive || vm.isRealtimeConnecting)

                            Button(role: .destructive) {
                                vm.stopRealtimeSession()
                            } label: {
                                Label("終了", systemImage: "xmark.circle")
                                    .font(.caption)
                            }
                            .buttonStyle(.bordered)
                            .disabled(!vm.isRealtimeActive || vm.isRealtimeConnecting)
                        }

                        Button {
                            vm.isRecording ? vm.stopPTTRealtime() : vm.startPTTRealtime()
                        } label: {
                            Image(systemName: vm.isRecording ? "stop.circle.fill" : "mic.circle.fill")
                                .font(.system(size: 60))
                                .foregroundStyle(vm.isRecording ? .red : .blue)
                        }
                        .padding(.top, 4)

                        Text(vm.isRecording ? "録音中（Realtime送信）" : (vm.isRealtimeConnecting ? "接続中..." : (vm.isRealtimeActive ? "タップで話す（PTT）" : "まずはセッション開始を押してください")))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }

                // エラーバナー
                if let msg = vm.errorMessage, !msg.isEmpty {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.white)
                        .padding(6)
                        .frame(maxWidth: .infinity)
                        .background(Color.red.opacity(0.9))
                        .cornerRadius(6)
                }
            }
            .padding()
        }
        .navigationTitle("会話")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { vm.requestPermissions() }
    }
}
