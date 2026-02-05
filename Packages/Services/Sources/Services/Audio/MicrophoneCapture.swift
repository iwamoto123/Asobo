import AVFoundation

/// ✅ マイク入力キャプチャとフォーマット変換
/// 
/// ## 重要な設定ポイント
/// 1. **出力フォーマット**: 24kHz/mono/PCM16LE（OpenAI Realtime APIの要求仕様）
/// 2. **バッチ送信**: 60msごとにまとめて送信（反応速度重視、AECが効いているため短縮可能）
/// 3. **フォーマット変換**: AVAudioConverterで確実に24kHz/mono/PCM16に変換
/// 
/// ## 変換フロー
/// - 入力: デバイス依存（通常48kHz/mono/Float32、AEC適用後）
/// - エンジン内: 48kHz/monoで処理（AEC最適化のため）
/// - 送信時変換: AVAudioConverterで24kHz/mono/PCM16LEに変換（サーバ送信の直前）
/// - バッファリング: 60ms分をまとめて送信（反応速度重視）
/// - 出力: 24kHz/mono/PCM16LE形式のAVAudioPCMBuffer
/// 
/// ## AEC対策
/// - **エンジン内は48kHz/monoで統一**: AECは48kHz/モノのパスで最も安定
/// - **再生中のマイク送信ゲート**: AI再生中はマイク入力をサーバに送信しない（ハーフデュプレックス）
/// - **バージイン検出**: バージイン検出時のみ送信を再開
public final class MicrophoneCapture {
  public enum Notifications {
    public static let inputBuffer = Notification.Name("com.asobo.microphone.inputBuffer")
    public static let rms = Notification.Name("com.asobo.microphone.rms")
  }
  private let engine: AVAudioEngine
  private var ownsEngine: Bool  // エンジンの所有権を持つかどうか
  private let outFormat: AVAudioFormat
  private var converter: AVAudioConverter?  // ✅ エンジン開始後に再作成する可能性があるため、varに変更
  private let onPCM: (AVAudioPCMBuffer) -> Void
  /// ✅ 追加: 変換前の入力生バッファ（主にSpeech.framework等のリアルタイムSTT用）
  /// - note: installTapで受け取った `buffer` をそのまま渡す（通常 Float32 / 48kHz 前後）
  public var onInputBuffer: ((AVAudioPCMBuffer) -> Void)?
  // ✅ 追加: 音量レベル（dB）を通知するコールバック
  public var onVolume: ((Double) -> Void)?
  private var running = false
  private var pendingVoiceProcessingEnabled: Bool?

  // ✅ バッチ送信用：60msごとにまとめて送信（反応速度重視）
  // 変更前: 200ms (安定重視)
  // 変更後: 60ms (反応速度重視、AECが効いているため短縮可能)
  private var audioBuffer: Data = Data()
  private let batchDurationMs: Double = 60.0  // 60msバッチ
  private var lastFlushTime: Date = Date()
  private let flushQueue = DispatchQueue(label: "com.asobo.audio.flush")

  // ✅ AEC対策：再生中ゲート制御
  private var isAIPlayingAudio: Bool = false
  private var outputMonitor: OutputMonitor?
  private var isFirstBuffer: Bool = true  // ✅ 初回バッファ受信フラグ（converter作成のため）
  // ✅ 再生中はVoiceProcessing（コンフォートノイズ含む）をオフにしてノイズ源を減らす
  //    再生中は送信ゲートでマイクデータをサーバに出さないため、AECを一時停止してもエコーのリスクは低い想定
  // ⚠️ playback中の切替で-10849が頻発しAVAudioEngineが不安定になるため一時的に無効化
  private let disableVoiceProcessingDuringPlayback: Bool = false

  // ✅ 初回接続時の音声認識問題対策：マイク開始直後の初期フレームをスキップ
  private var startTime: Date?  // マイク開始時刻
  private let initialSkipDurationMs: Double = 200.0  // 開始後200msは音声データを送信しない（初期ノイズ対策）

  /// ✅ 共通エンジンを使用する場合（AEC有効化のため推奨）
  public init?(sharedEngine: AVAudioEngine, onPCM: @escaping (AVAudioPCMBuffer) -> Void, outputMonitor: OutputMonitor? = nil, ownsEngine: Bool = false) {
    self.engine = sharedEngine
    self.ownsEngine = ownsEngine
    self.onPCM = onPCM
    self.outputMonitor = outputMonitor
    // ✅ 出力フォーマットは固定（24kHz/mono/PCM16）
    guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                  sampleRate: 24_000,  // ✅ 24kHzに変更（OpenAI Realtime APIの要求仕様に合わせる）
                                  channels: 1,
                                  interleaved: true) else {
      return nil
    }
    self.outFormat = out
    // ✅ converterはstart()で作成（エンジン開始後のフォーマットを使用）
    self.converter = nil
  }

  /// ✅ 独自エンジンを使用する場合（後方互換性のため）
  public convenience init?(onPCM: @escaping (AVAudioPCMBuffer) -> Void, outputMonitor: OutputMonitor? = nil) {
    let engine = AVAudioEngine()
    self.init(sharedEngine: engine, onPCM: onPCM, outputMonitor: outputMonitor, ownsEngine: true)
  }

  /// ✅ AI再生状態を設定
  public func setAIPlayingAudio(_ isPlaying: Bool) {
    isAIPlayingAudio = isPlaying

    // ✅ 再生中はVoiceProcessing（コンフォートノイズ生成源）を一時停止
    if disableVoiceProcessingDuringPlayback {
      setVoiceProcessingEnabled(!isPlaying)
    }
  }

  /// ✅ RMS計算（dBFS）
  private func calculateRMS(from buffer: AVAudioPCMBuffer) -> Double {
    guard let channelData = buffer.floatChannelData else { return -60.0 }
    let channelCount = Int(buffer.format.channelCount)
    let frameLength = Int(buffer.frameLength)

    var sum: Float = 0.0
    for ch in 0..<channelCount {
      let channel = channelData[ch]
      for i in 0..<frameLength {
        let sample = channel[i]
        sum += sample * sample
      }
    }

    let mean = sum / Float(frameLength * channelCount)
    let rms = sqrt(mean)

    // dBFSに変換
    if rms < 1e-10 {
      return -60.0
    }
    return 20.0 * log10(Double(rms))
  }

  public func start() throws {
    guard !running else { return }
    let inputNode = engine.inputNode

    // ✅ 既にタップがインストールされている場合は先に削除（エラー回避）
    inputNode.removeTap(onBus: 0)

    // ✅ 追加: 強力なAEC有効化設定 (iOS 13+)
    // 共有エンジンでは切替を行わない（クラッシュ報告あり）
    if #available(iOS 13.0, *), ownsEngine {
      setVoiceProcessingEnabled(true)
    }

    // ✅ エンジンの所有権ロジック
    if ownsEngine && !engine.isRunning {
        try engine.start()
        print("✅ MicrophoneCapture: エンジンを開始（start()呼び出し時、ownsEngine=true）")
    } else if !ownsEngine && !engine.isRunning {
        // 共通エンジンの場合、ここでstartできないが、ConversationController側でstart済みのはず
        print("⚠️ MicrophoneCapture: エンジンが停止状態です")
    }

    // ------------------------------------------------------------
    // ✅ 修正ポイント: フォーマット決定ロジック (ファイナル)
    // ------------------------------------------------------------

    // Tapのフォーマットは「有効なものが取れるならそれを使う」。
    // Bluetooth HFP + VoiceChat 等で 0Hz/不正フォーマットになるケースがあり、その場合に
    // こちらで無理にフォーマットを指定すると `Input HW format is invalid` でNSExceptionクラッシュしうる。
    // そのため、無効時は format=nil で installTap し、実際に来た buffer.format から converter を作る。
    let inputFormat = inputNode.outputFormat(forBus: 0)
    let tapFormat: AVAudioFormat?
    if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
        print("✅ MicrophoneCapture: 既存フォーマット使用: \(inputFormat.sampleRate)Hz")
        tapFormat = inputFormat
    } else {
        print("⚠️ MicrophoneCapture: 0Hz検出 -> format=nilでinstallTap（クラッシュ回避）")
        tapFormat = nil
    }

    // バッファサイズ計算
    let bufferSize: AVAudioFrameCount
    if let tapFormat {
        bufferSize = AVAudioFrameCount(tapFormat.sampleRate * 0.02)
    } else {
        bufferSize = 1024
    }
    audioBuffer.removeAll()
    lastFlushTime = Date()
    isFirstBuffer = true  // ✅ 初回バッファ受信フラグをリセット
    startTime = Date()  // ✅ マイク開始時刻を記録（初期フレームスキップ用）

    // ------------------------------------------------------------
    // ✅ Tapインストール (手動構築した safeFormat を使用)
    // ------------------------------------------------------------
    inputNode.installTap(onBus: 0, bufferSize: bufferSize, format: tapFormat) { [weak self] buffer, _ in
        guard let self = self else { return }

        // --- Converter作成ロジック ---
        if self.converter == nil || self.isFirstBuffer {
            let actualFormat = buffer.format
            if actualFormat.sampleRate == 0 { return } // ガード

            if self.converter == nil {
                print("✅ MicrophoneCapture: Converter作成 Input:\(actualFormat.sampleRate)Hz -> Output:\(self.outFormat.sampleRate)Hz")
                let conv = AVAudioConverter(from: actualFormat, to: self.outFormat)
                conv?.sampleRateConverterQuality = .max
                self.converter = conv
            }
            self.isFirstBuffer = false
        }

      guard let converter = self.converter else { return }

      // ✅ 変換前の入力バッファを外へ通知（ライブSTT用）
      // - 再生中ゲート/初期フレームスキップより前に流すことで「AI応答中でもSTTでバージイン検知」が可能になる
      self.onInputBuffer?(buffer)
      // ✅ 追加: どの画面からでも“同じマイク入力”を購読できるようにブロードキャスト
      NotificationCenter.default.post(name: Notifications.inputBuffer, object: buffer)

      // ✅ 初回接続時の音声認識問題対策：マイク開始直後の初期フレームをスキップ
      if let startTime = self.startTime {
        let elapsed = Date().timeIntervalSince(startTime) * 1000.0  // ミリ秒
        if elapsed < self.initialSkipDurationMs {
          // 開始後200ms以内は音声データを送信しない（初期ノイズをスキップ）
          return
        } else {
          // 200ms経過したら、以降は通常通り処理
          self.startTime = nil  // フラグをクリア（一度だけチェック）
          print("✅ MicrophoneCapture: 初期フレームスキップ期間終了（\(String(format: "%.1f", elapsed))ms経過）")
        }
      }

      // ✅ AEC対策：再生中ゲート制御
      let inputRMS = self.calculateRMS(from: buffer)

      // -------------------------------------------------------
      // ✅ 追加: 計算したRMS音量を外部へ通知
      // -------------------------------------------------------
      self.onVolume?(inputRMS)
      NotificationCenter.default.post(name: Notifications.rms, object: inputRMS)

      if self.isAIPlayingAudio {
        // ✅ 再生中はサーバ送信用のマイクデータを遮断（AI音声混入を防ぐ）
        // NOTE: バージインは STT 側で検知する（ここでは解除しない）
        return
      }

      // ✅ 送る前に24kHz mono PCM16LEへ必ずダウンサンプル＆量子化
      // ✅ AVAudioEngineのタップはFloat32が多い。常にAVAudioConverterで24kHz/mono/Int16に変換
      // ✅ 変換用フォーマット（送信用）：24kHz/mono/PCM16LE
      // ✅ 入力バッファのフォーマットから送信フォーマットへの変換を確実に実行
      let ratio = self.outFormat.sampleRate / buffer.format.sampleRate
      let framesOut = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 8)  // 余裕を持たせる
      guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: framesOut) else { return }
      outBuf.frameLength = framesOut

      var error: NSError?
      let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      if status == .haveData || status == .endOfStream, outBuf.frameLength > 0 {
        // ✅ バッファに蓄積（20msごとに追加）
        // ✅ 必ずint16ChannelDataから取得（PCM16LE形式）
        guard let ch0 = outBuf.int16ChannelData else { return }
        let byteCount = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let ptr = ch0.pointee

        self.flushQueue.async {
          // ✅ 音声データをバッファに追加（PCM16LE形式のData）
          self.audioBuffer.append(Data(bytes: ptr, count: byteCount))

          // ✅ 60ms経過したらバッチ送信（反応速度重視）
          let now = Date()
          let elapsed = now.timeIntervalSince(self.lastFlushTime) * 1000.0  // ミリ秒
          if elapsed >= self.batchDurationMs && !self.audioBuffer.isEmpty {
            let batchData = self.audioBuffer
            self.audioBuffer.removeAll()
            self.lastFlushTime = now

            // ✅ バッチデータをAVAudioPCMBufferとして再構築
            let batchFrames = batchData.count / MemoryLayout<Int16>.size
            guard batchFrames > 0,
                  let batchBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: AVAudioFrameCount(batchFrames)) else {
              return
            }
            batchBuf.frameLength = AVAudioFrameCount(batchFrames)

            if let batchCh0 = batchBuf.int16ChannelData {
              batchData.withUnsafeBytes { rawPtr in
                guard let basePtr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
                batchCh0.pointee.initialize(from: basePtr, count: batchFrames)
              }
              self.onPCM(batchBuf)  // ← 60msバッチでコールバック
            }
          }
        }
      }
    }

    // ✅ エンジンの所有権がある場合のみ開始（または再開）
    if ownsEngine && !engine.isRunning {
      try engine.start()
      print("✅ MicrophoneCapture: エンジンを開始（タップインストール後、ownsEngine=true）")
    }
    // 共通エンジンの場合、所有者が開始する必要があるため、ここでは開始しない
    running = true
  }

  public func stop() {
    guard running else { return }
    // ✅ 開始時刻をリセット
    startTime = nil
    // ✅ 残りのバッファをフラッシュ
    flushQueue.sync {
      if !audioBuffer.isEmpty {
        let batchData = audioBuffer
        audioBuffer.removeAll()

        let batchFrames = batchData.count / MemoryLayout<Int16>.size
        if batchFrames > 0, let batchBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: AVAudioFrameCount(batchFrames)) {
          batchBuf.frameLength = AVAudioFrameCount(batchFrames)
          if let batchCh0 = batchBuf.int16ChannelData {
            batchData.withUnsafeBytes { rawPtr in
              guard let basePtr = rawPtr.baseAddress?.assumingMemoryBound(to: Int16.self) else { return }
              batchCh0.pointee.initialize(from: basePtr, count: batchFrames)
            }
            onPCM(batchBuf)
          }
        }
      }
    }
    engine.inputNode.removeTap(onBus: 0)
    // ✅ エンジンの所有権がある場合のみ停止
    if ownsEngine {
      engine.stop()
      engine.reset()  // ← 個別エンジンの場合、完全にリセット
      applyPendingVoiceProcessingIfPossible()
    }

    // ★ 再開に備えて初期化
    converter = nil
    isFirstBuffer = true

    running = false
  }
}

extension MicrophoneCapture {
  /// VoiceProcessingのON/OFFを安全に切り替える（iOS 13+のみ）
  private func setVoiceProcessingEnabled(_ enabled: Bool) {
    guard #available(iOS 13.0, *) else { return }
    guard ownsEngine else {
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled skip (shared engine) -> \(enabled)")
      return
    }
    // ⚠️ 共有エンジンが稼働中の切替はクラッシュすることがあるため、実行条件を厳格化
    if engine.isRunning && !ownsEngine {
      pendingVoiceProcessingEnabled = enabled
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled defer (engine running, shared) -> \(enabled)")
      return
    }
    if engine.isRunning {
      pendingVoiceProcessingEnabled = enabled
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled defer (engine running) -> \(enabled)")
      return
    }
    do {
      try engine.inputNode.setVoiceProcessingEnabled(enabled)
      pendingVoiceProcessingEnabled = nil
      print("✅ MicrophoneCapture: VoiceProcessingEnabled = \(enabled)")
    } catch {
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled設定失敗 - \(error)")
    }
  }

  private func applyPendingVoiceProcessingIfPossible() {
    guard let pending = pendingVoiceProcessingEnabled else { return }
    guard #available(iOS 13.0, *) else { return }
    guard !engine.isRunning else { return }
    do {
      try engine.inputNode.setVoiceProcessingEnabled(pending)
      print("✅ MicrophoneCapture: VoiceProcessingEnabled applied (pending) = \(pending)")
      pendingVoiceProcessingEnabled = nil
    } catch {
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled pending apply failed - \(error)")
    }
  }
}
