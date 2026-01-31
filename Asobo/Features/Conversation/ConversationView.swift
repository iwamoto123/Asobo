import SwiftUI
import Domain

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
                        Text("🎤 あなたの音声入力（Realtime並走STT / 状態モニター）")
                            .font(.caption)
                            .foregroundColor(.green)
                    }

                    if vm.mode == .realtime && vm.isRecording && vm.handsFreeMonitorTranscript.isEmpty {
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
                        let t = (vm.mode == .realtime) ? vm.handsFreeMonitorTranscript : vm.transcript
                        Text(t.isEmpty ? "（音声を話すとここに文字が流れます）" : t)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .background(Color.green.opacity(0.1))
                            .cornerRadius(8)
                            .font(.caption)
                            .frame(minHeight: 60, maxHeight: 80)
                    }

                    if vm.mode == .realtime {
                        Text("STT monitor: \(vm.handsFreeMonitorStatus)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }

                // AI応答テキスト表示
                VStack(alignment: .leading, spacing: 2) {
                    Text("🤖 AI応答")
                        .font(.caption)
                        .foregroundColor(.blue)

                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            let displayText = vm.aiResponseText.isEmpty
                            ? (vm.isThinking ? "かんがえちゅう..." : "（AIの応答がここに表示されます）")
                            : vm.aiResponseText

                            Text(displayText)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(8)
                                .id("aiResponseText")
                                .onChange(of: vm.aiResponseText) { newValue in
                                    // ✅ テキストが更新されるたびに自動スクロール（最新のテキストを見せる）
                                    if !newValue.isEmpty {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                            withAnimation(.easeOut(duration: 0.2)) {
                                                proxy.scrollTo("aiResponseText", anchor: .bottom)
                                            }
                                        }
                                    }
                                }
                        }
                        .frame(minHeight: 60, maxHeight: 200)  // ✅ 最大高さを増やして長いテキストも表示
                        .background(Color.blue.opacity(0.1))
                        .cornerRadius(8)
                        .font(.caption)
                    }
                }

                // ライブ要約と興味/新語のハイライト
                if !vm.liveSummary.isEmpty || !vm.liveInterests.isEmpty || !vm.liveNewVocabulary.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        if !vm.liveSummary.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("📝 いまのまとめ")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(vm.liveSummary)
                                    .font(.caption)
                                    .foregroundColor(.primary)
                                    .padding(8)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .background(Color.blue.opacity(0.08))
                                    .cornerRadius(8)
                            }
                        }

                        if !vm.liveInterests.isEmpty || !vm.liveNewVocabulary.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                if !vm.liveInterests.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("興味タグ")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        FlowLayout(spacing: 6) {
                                            ForEach(vm.liveInterests, id: \.self) { tag in
                                                HStack(spacing: 4) {
                                                    Image(systemName: iconName(for: tag))
                                                        .font(.system(size: 10))
                                                    Text(tagDisplayName(tag))
                                                        .font(.caption2)
                                                        .bold()
                                                }
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 4)
                                                .background(Color.blue.opacity(0.12))
                                                .cornerRadius(10)
                                            }
                                        }
                                    }
                                }

                                if !vm.liveNewVocabulary.isEmpty {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("新しく覚えたことば")
                                            .font(.caption2)
                                            .foregroundColor(.secondary)
                                        FlowLayout(spacing: 6) {
                                            ForEach(vm.liveNewVocabulary, id: \.self) { word in
                                                Text(word)
                                                    .font(.caption2)
                                                    .padding(.horizontal, 8)
                                                    .padding(.vertical, 4)
                                                    .background(Color.green.opacity(0.12))
                                                    .cornerRadius(10)
                                            }
                                        }
                                    }
                                }
                            }
                        }
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
                            if vm.isHandsFreeMode {
                                vm.stopHandsFreeConversation()
                            } else if vm.isRecording {
                                vm.stopPTTRealtime()
                            } else {
                                vm.startHandsFreeConversation()
                            }
                        } label: {
                            Image(systemName: vm.isHandsFreeMode ? "stop.circle.fill" : (vm.isRecording ? "stop.circle.fill" : "mic.circle.fill"))
                                .font(.system(size: 60))
                                .foregroundStyle(vm.isHandsFreeMode ? .red : (vm.isRecording ? .red : .blue))
                        }
                        .padding(.top, 4)

                        Text(vm.isHandsFreeMode
                             ? "ハンズフリー会話中（沈黙で自動送信）"
                             : (vm.isRecording ? "録音中（Realtime送信）" : (vm.isRealtimeConnecting ? "接続中..." : (vm.isRealtimeActive ? "タップでハンズフリー開始" : "まずはセッション開始を押してください"))))
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

// MARK: - Helpers
private func tagDisplayName(_ tag: FirebaseInterestTag) -> String {
    switch tag {
    case .dinosaurs: return "恐竜"
    case .space: return "宇宙"
    case .cooking: return "料理"
    case .animals: return "動物"
    case .vehicles: return "乗り物"
    case .music: return "音楽"
    case .sports: return "スポーツ"
    case .crafts: return "工作"
    case .stories: return "お話"
    case .insects: return "昆虫"
    case .princess: return "プリンセス"
    case .heroes: return "ヒーロー"
    case .robots: return "ロボット"
    case .nature: return "自然"
    case .others: return "その他"
    }
}

private func iconName(for tag: FirebaseInterestTag) -> String {
    switch tag {
    case .dinosaurs: return "lizard.fill"
    case .space: return "star.fill"
    case .cooking: return "fork.knife"
    case .animals: return "pawprint.fill"
    case .vehicles: return "car.fill"
    case .music: return "music.note"
    case .sports: return "sportscourt.fill"
    case .stories: return "book.fill"
    case .insects: return "ant.fill"
    case .princess: return "crown.fill"
    default: return "tag.fill"
    }
}
