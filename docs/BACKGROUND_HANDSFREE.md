# バックグラウンドでのハンズフリー会話（Asobo）

## 目的

ハートボタンで「ハンズフリー会話」を開始したあと、親が別アプリを操作しても、**バックグラウンドで可能な限り長く** Bluetooth（HFP）機器を使った会話を継続する。

このアプリの現状は CoreBluetooth で機器接続を管理するのではなく、**AVAudioSession のオーディオルート（Bluetooth HFP）として入出力**する方式。

そのため「長時間バックグラウンド継続」の本筋は **iOSのBackground Audio（録音/再生）**。

## iOSの前提（重要）

- iOSで「長時間バックグラウンド動作」を行う正攻法は、Background Modes のうち **audio**（録音/再生）が必要。
- `beginBackgroundTask` は **短時間の猶予**（遷移直後の後片付け等）向けで、長時間保持すると警告が出て終了リスクが上がる。

## 実施したこと（設定/実装）

### 1) Info.plist: UIBackgroundModes に audio を追加

ファイル: `Asobo/App/Resources/Info.plist`

- `UIBackgroundModes` に `audio` を追加
- これにより、ハンズフリー会話中（録音/再生が稼働中）はバックグラウンドでも動作継続しやすくなる

### 2) AudioSessionManager の安定化

ファイル: `Packages/Services/Sources/Services/Audio/AudioSessionManager.swift`

- `AVAudioSession` を以下で構成
  - category: `.playAndRecord`
  - mode: `.voiceChat`（AEC/NS/AGCを期待）
  - options: `.defaultToSpeaker`, `.allowBluetooth`, `.allowBluetoothA2DP`
- ルート変更通知の監視が `configure()` 多重呼び出しで増殖しないように、observer token を保持して **1回だけ登録**
- 追加: `configure(reset:)`
  - 復帰パス（割り込み後など）では `reset=false` を使い、`setActive(false)` を毎回挟んで途切れやすくなるのを避ける

### 3) アプリのライフサイクル/割り込み復帰（バックグラウンド継続の要）

ファイル: `Asobo/Features/Conversation/ConversationController/ConversationController+AppLifecycle.swift`

追加した監視/処理:

- `UIApplication.didEnterBackgroundNotification`
  - 会話中（`isRealtimeActive && isHandsFreeMode && isRecording`）なら、AudioSession/AudioEngine を念のため再活性化
  - `beginBackgroundTask` は **短時間のみ**（移行直後の保険）。保持しっぱなしにしない

- `UIApplication.willEnterForegroundNotification`
  - フォアグラウンド復帰時に AudioSession/Engine の再活性化

- `AVAudioSession.interruptionNotification`
  - `.began`: 状態フラグを安全側へ（OSがオーディオ権を奪う）
  - `.ended` + `.shouldResume`: AudioSession/Engine を復帰し、ハンズフリーなら `resumeListening()` / 必要なら `startHandsFreeConversation()` で復帰

- `AVAudioSession.mediaServicesWereResetNotification`
  - 長時間運用やルート切替などで稀に起きる “media services reset” から復帰

フック:

- `ConversationController.init` で `setupAppLifecycleObservers()` を呼ぶ
- `deinit` で observer を解除

## ログの見方（今回のログは概ねOK）

### ✅ 正常に見えるポイント

- `🔇 ConversationController: 再生完全終了 - マイクゲート開` → `👂 聞き取り再開`
  - 1ターンのAI再生が終わって、次の聞き取りに戻れている

- `🟩 STT-VAD start ...` → `🟧 STT-VAD end by silence ...`
  - ハンズフリーの発話検知（開始/終了）が動いている

- `audioMissing=false`
  - AI応答がテキストだけにならず、音声チャンクも返ってきている

- `✅ FirebaseConversationsRepository: 分析結果更新成功`
  - ライブ要約/興味/新語の分析更新が成功している

### ⚠️ 注意（ただし致命ではない）

- `kAFAssistantErrorDomain Code=1101` / `kLSRErrorDomain code=301`
  - ローカル音声認識（Speech.framework）がバックグラウンド/端末状況で不安定なときに出やすい
  - 実装上は **benign error として restart** する設計なので、ログ上は許容

- `UserAudioTranscribe ... Code=1110 "No speech detected"`
  - ローカルSTT確定が空になったケース
  - その場合 `Fallback to HandsFreeMonitor transcript` により、並走STTのテキストでAIへ送れているのでOK

- `Background Task ... was created over 30 seconds ago...`
  - **これはNG寄り**。backgroundTask を長く保持しすぎると終了リスクが上がる
  - 対応: backgroundTask は短時間で自動終了するように修正済み（長時間継続は audio background mode が本筋）

## 検証手順（推奨）

- 実機で、ハートでハンズフリー開始
- ホームに戻る/他アプリへ切り替える
- Bluetooth（HFP）機器で会話できること
- 割り込み（通話/通知音など）後に復帰すること（可能なら）

注意:

- Xcodeデバッグ起動だとバックグラウンド動作の挙動が変わることがあるため、実利用に近い形で検証するのが安全


