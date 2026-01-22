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
  private let engine: AVAudioEngine
  private var ownsEngine: Bool  // エンジンの所有権を持つかどうか
  private let outFormat: AVAudioFormat
  private var converter: AVAudioConverter?  // ✅ エンジン開始後に再作成する可能性があるため、varに変更
  private let onPCM: (AVAudioPCMBuffer) -> Void
  // ✅ 追加: 音量レベル（dB）を通知するコールバック
  public var onVolume: ((Double) -> Void)?
  // ✅ 追加: VAD確率を通知するコールバック
  public var onVADProbability: ((Float) -> Void)?  // Silero VAD の生確率を通知（UI/Viz 用）
  // ✅ 追加: バージイン検知時に呼び出すコールバック
  public var onBargeIn: (() -> Void)?
  private var running = false
  private var vad: SileroVAD?
  private var vadBuffer16k: [Float] = []
  private let vadChunkSize = 512
  private let vadTargetSampleRate: Double = 16_000
  private let vadQueue = DispatchQueue(label: "com.asobo.audio.vad")
  private let vadQueueSpecificKey = DispatchSpecificKey<Bool>()
  private var lastVADSignalLogTime: Date?
  private var vadLogCounter: Int = 0
  private var vadConverter: AVAudioConverter?
  // ✅ VAD確率の最新値（バージイン判定にも共通利用）
  private var latestVADProbability: Float = 0.0
  private let vadProbabilityLock = NSLock()
  // ✅ Silero VAD による割り込み判定用（連続検出ヒステリシス）
  private let bargeInVADThreshold: Float = 0.5
  private let bargeInHoldDuration: TimeInterval = 0.15  // 150ms 以上連続でspeechを検出したらバージイン
  private var vadSpeechStartTimeForBargeIn: Date?
  
  // ✅ バッチ送信用：60msごとにまとめて送信（反応速度重視）
  // 変更前: 200ms (安定重視)
  // 変更後: 60ms (反応速度重視、AECが効いているため短縮可能)
  private var audioBuffer: Data = Data()
  private let batchDurationMs: Double = 60.0  // 60msバッチ
  private var lastFlushTime: Date = Date()
  private let flushQueue = DispatchQueue(label: "com.asobo.audio.flush")
  
  // ✅ AEC対策：再生中ゲート制御
  private var isAIPlayingAudio: Bool = false
  private var userBargeIn: Bool = false
  private var outputMonitor: OutputMonitor?
  // ✅ バージイン判定の補助ログ用に入力RMSの短期履歴を保持
  private var recentInputRMS: [Double] = []  // 直近60msの入力RMS
  // 変更前: 10 (約200msの平均を見るため遅い)
  // 変更後: 3 (約60msの平均で判断、一瞬の発話に反応させる)
  private let rmsWindowSize: Int = 3  // 3フレーム（約60ms）
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
    self.vad = try? SileroVAD()
    // ✅ VADバッファへのアクセスをvadQueueに直列化するためのマーカー
    vadQueue.setSpecific(key: vadQueueSpecificKey, value: true)
  }
  
  /// ✅ 独自エンジンを使用する場合（後方互換性のため）
  public convenience init?(onPCM: @escaping (AVAudioPCMBuffer) -> Void, outputMonitor: OutputMonitor? = nil) {
    let engine = AVAudioEngine()
    self.init(sharedEngine: engine, onPCM: onPCM, outputMonitor: outputMonitor, ownsEngine: true)
  }
  
  /// ✅ AI再生状態を設定
  public func setAIPlayingAudio(_ isPlaying: Bool) {
    isAIPlayingAudio = isPlaying
    if !isPlaying {
      // 再生終了時にバージインフラグをリセット
      userBargeIn = false
      recentInputRMS.removeAll()
      vadSpeechStartTimeForBargeIn = nil
    }
    
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
  
  /// ✅ バージイン判定
  private func checkBargeIn(inputRMS: Double, outputRMS _: Double, vadProbability: Float) -> Bool {
    // VADが一定以上で「人声」と判定された場合のみ、一定時間継続を待ってから許可
    let now = Date()
    guard vadProbability >= bargeInVADThreshold else {
      vadSpeechStartTimeForBargeIn = nil
      return false
    }

    // 直近60msの入力RMSを記録（反応速度重視）
    recentInputRMS.append(inputRMS)
    if recentInputRMS.count > rmsWindowSize {
      recentInputRMS.removeFirst()
    }
    
    // VADが継続している時間をチェック（ヒステリシス）
    if vadSpeechStartTimeForBargeIn == nil {
      vadSpeechStartTimeForBargeIn = now
      return false
    }
    let elapsed = now.timeIntervalSince(vadSpeechStartTimeForBargeIn ?? now)
    return elapsed >= bargeInHoldDuration
  }

  public func start() throws {
    guard !running else { return }
    let inputNode = engine.inputNode
    
    // ✅ 追加: 強力なAEC有効化設定 (iOS 13+)
    // VoiceProcessingモードであっても、明示的にバイパス無効（＝処理有効）を設定するのが安全
    if #available(iOS 13.0, *) {
      setVoiceProcessingEnabled(true)
    }
    
    // ✅ 既にタップがインストールされている場合は先に削除（エラー回避）
    inputNode.removeTap(onBus: 0)
    
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
    
    var tapFormat: AVAudioFormat?
    let inputFormat = inputNode.outputFormat(forBus: 0)
    
    if inputFormat.sampleRate > 0 && inputFormat.channelCount > 0 {
        // エンジンがすでに有効なフォーマットを持っているならそれを使う
        print("✅ MicrophoneCapture: 既存フォーマット使用: \(inputFormat.sampleRate)Hz")
        tapFormat = inputFormat
    } else {
        // ⚠️ 0Hzの場合: nilはダメ(クラッシュ)、適当な48kもダメ(クラッシュ)
        // iOSのVoiceProcessingIO入力の「正解」フォーマットを手動構築して渡す
        print("⚠️ MicrophoneCapture: 0Hz検出 -> 48kHz/Float32を手動構築します")
        
        // 【重要】commonFormat: .pcmFormatFloat32, interleaved: false がiOSハードウェアの標準
        tapFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000,
            channels: 1,
            interleaved: false
        )
    }
    
    // 万が一作成失敗したら安全に停止
    guard let safeFormat = tapFormat else {
        throw NSError(domain: "MicrophoneCapture", code: -1, userInfo: [
            NSLocalizedDescriptionKey: "フォーマット構築失敗"
        ])
    }

    // バッファサイズ計算
    let framesPer20ms = AVAudioFrameCount(safeFormat.sampleRate * 0.02)
    audioBuffer.removeAll()
    lastFlushTime = Date()
    isFirstBuffer = true  // ✅ 初回バッファ受信フラグをリセット
    startTime = Date()  // ✅ マイク開始時刻を記録（初期フレームスキップ用）

    // ------------------------------------------------------------
    // ✅ Tapインストール (手動構築した safeFormat を使用)
    // ------------------------------------------------------------
    inputNode.installTap(onBus: 0, bufferSize: framesPer20ms, format: safeFormat) { [weak self] buffer, _ in
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
      if let vadSamples = self.downsampleTo16kSamples(from: buffer) {
        self.enqueueVADProcessing(samples: vadSamples)
      }
      
      let outputRMS = self.outputMonitor?.currentRMS ?? -60.0
      // 最新のVAD確率（SileroVAD）をバージイン判定にも使用
      let vadProbability: Float = {
        self.vadProbabilityLock.lock(); defer { self.vadProbabilityLock.unlock() }
        return self.latestVADProbability
      }()
      
      if self.isAIPlayingAudio && !self.userBargeIn {
        // バージイン判定
        if self.checkBargeIn(inputRMS: inputRMS, outputRMS: outputRMS, vadProbability: vadProbability) {
          self.userBargeIn = true
          let elapsedMs = Int((Date().timeIntervalSince(self.vadSpeechStartTimeForBargeIn ?? Date())) * 1000)
        print("🎤 MicrophoneCapture: バージイン検出 - VAD \(String(format: "%.4f", vadProbability)) を \(elapsedMs)ms 継続検出 (inputRMS: \(String(format: "%.1f", inputRMS))dB, outputRMS: \(String(format: "%.1f", outputRMS))dB)")
          // ✅ コールバックで上位へ通知（UIスレッドで処理）
          DispatchQueue.main.async { [weak self] in
            self?.onBargeIn?()
          }
          // バージイン成立時は送信を許可（response.cancelは上位で送信）
        } else {
          // 再生中でバージイン未検出：送信しない（ループ根絶）
          return
        }
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
      let status = converter.convert(to: outBuf, error: &error) { inCount, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      if (status == .haveData || status == .endOfStream), outBuf.frameLength > 0 {
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
    }
    
    // ★ 再開に備えて初期化
    converter = nil
    vadConverter = nil
    userBargeIn = false
    vadSpeechStartTimeForBargeIn = nil
    recentInputRMS.removeAll()
    isFirstBuffer = true
    // ✅ enqueueVADProcessing と同じキューでVAD状態をリセット（並行アクセスでのクラッシュ防止）
    resetVADState()
    
    running = false
  }
}

extension MicrophoneCapture {
  /// VAD関連の状態をvadQueue上で安全にリセットする
  private func resetVADState() {
    let work = { [weak self] in
      guard let self else { return }
      self.vadBuffer16k.removeAll(keepingCapacity: true)
      self.vad = nil
      self.vadLogCounter = 0
      self.lastVADSignalLogTime = nil
      self.vadProbabilityLock.lock()
      self.latestVADProbability = 0.0
      self.vadProbabilityLock.unlock()
    }
    if DispatchQueue.getSpecific(key: vadQueueSpecificKey) == true {
      work()
    } else {
      vadQueue.sync(execute: work)
    }
  }

  /// VoiceProcessingのON/OFFを安全に切り替える（iOS 13+のみ）
  private func setVoiceProcessingEnabled(_ enabled: Bool) {
    guard #available(iOS 13.0, *) else { return }
    do {
      try engine.inputNode.setVoiceProcessingEnabled(enabled)
      print("✅ MicrophoneCapture: VoiceProcessingEnabled = \(enabled)")
    } catch {
      print("⚠️ MicrophoneCapture: VoiceProcessingEnabled設定失敗 - \(error)")
    }
  }

  // ✅ 48kHz→16kHzへ間引きしてVADに渡す
  private func downsampleTo16kSamples(from buffer: AVAudioPCMBuffer) -> [Float]? {
    let inputRate = buffer.format.sampleRate
    let ratio = inputRate / vadTargetSampleRate

    // Fast path: exact 48k->16k decimation by 3 with stride
    if abs(ratio - 3.0) < 0.01 {
      let step = 3
      let frameCount = Int(buffer.frameLength)
      var samples: [Float] = []
      samples.reserveCapacity(frameCount / step + 1)

      if let floatChannel = buffer.floatChannelData?.pointee {
        for i in stride(from: 0, to: frameCount, by: step) {
          samples.append(floatChannel[i])
        }
        return samples
      } else if let int16Channel = buffer.int16ChannelData?.pointee {
        let scale = Float(Int16.max)
        for i in stride(from: 0, to: frameCount, by: step) {
          samples.append(Float(int16Channel[i]) / scale)
        }
        return samples
      }
      return nil
    }

    // General path: use AVAudioConverter for non-48k inputs (e.g., 44.1k or 24k)
    let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                     sampleRate: vadTargetSampleRate,
                                     channels: buffer.format.channelCount,
                                     interleaved: false)
    if vadConverter == nil || vadConverter?.inputFormat.sampleRate != inputRate {
      vadConverter = AVAudioConverter(from: buffer.format, to: targetFormat!)
      vadConverter?.sampleRateConverterQuality = .max
    }
    guard let converter = vadConverter,
          let targetFormat else { return nil }

    let inFrames = Int(buffer.frameLength)
    let outFrames = Int(Double(inFrames) * (vadTargetSampleRate / inputRate) + 8)
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: AVAudioFrameCount(outFrames)) else {
      return nil
    }

    var error: NSError?
    let status = converter.convert(to: outBuf, error: &error) { _, outStatus in
      outStatus.pointee = .haveData
      return buffer
    }
    guard (status == .haveData || status == .endOfStream),
          let floatChannel = outBuf.floatChannelData?.pointee else {
      if let error { print("❌ VAD converter error: \(error)") }
      return nil
    }

    let framesOut = Int(outBuf.frameLength)
    return Array(UnsafeBufferPointer(start: floatChannel, count: framesOut))
  }

  private func enqueueVADProcessing(samples: [Float]) {
    guard !samples.isEmpty else { return }
    vadQueue.async { [weak self] in
      guard let self else { return }
      if self.vad == nil {
        self.vad = try? SileroVAD()
        if self.vad == nil {
          print("❌ MicrophoneCapture: SileroVAD init failed")
        } else {
          print("🎯 MicrophoneCapture: SileroVAD initialized")
        }
      }
      guard let vad = self.vad else { return }

      self.vadBuffer16k.append(contentsOf: samples)
      while self.vadBuffer16k.count >= self.vadChunkSize {
        // ✅ 念のため再確認（stop()等でリセットが走った場合でもクラッシュしない）
        guard self.vadBuffer16k.count >= self.vadChunkSize else { break }
        let chunk = Array(self.vadBuffer16k.prefix(self.vadChunkSize))
        self.vadBuffer16k.removeFirst(self.vadChunkSize)

        // ✅ 入力スケーリング：VADの観測/判定用に「増幅しない」方針（リミッタのみ）
        // - gainを無音で持ち上げるとノイズが増え、RMS分析も壊れる
        // - クリップだけを避ける（peak>0.98 のときのみ減衰）
        let rms = sqrt(chunk.reduce(0) { $0 + $1 * $1 } / Float(chunk.count))
        let peak = chunk.reduce(0) { max($0, abs($1)) }

        let limiterCeil: Float = 0.98
        var gain: Float = 1.0
        if peak > 1e-6, peak > limiterCeil {
          gain = limiterCeil / peak
        }

        var clippedCount = 0
        let scaled = chunk.map { sample -> Float in
          let v = sample * gain
          if v > 1 { clippedCount += 1; return 1 }
          if v < -1 { clippedCount += 1; return -1 }
          return v
        }

        if shouldLogVADSignal() {
          let nonZeroCount = chunk.reduce(0) { $0 + (abs($1) > 1e-6 ? 1 : 0) }
          let nonZeroRatio = Double(nonZeroCount) / Double(chunk.count)
          let rmsDb = rms > 1e-9 ? 20 * log10(Double(rms)) : -120.0
          let clipRatio = Double(clippedCount) / Double(chunk.count)
          print("🎯 MicrophoneCapture: VAD input stats - peak=\(String(format: "%.6f", peak)), rms=\(String(format: "%.2f", rmsDb))dB, nonZero=\(String(format: "%.2f", nonZeroRatio)), samples=\(chunk.count), sr=16k | scaled(gain=\(String(format: "%.3f", gain)), clip=\(String(format: "%.3f", clipRatio)))")
        }

        let probability = vad.process(segment: scaled)
        // VAD最新値を保持（バージイン判定と共有）
        self.vadProbabilityLock.lock()
        self.latestVADProbability = probability
        self.vadProbabilityLock.unlock()
        self.vadLogCounter &+= 1
        // デバッグ用: VAD確率と入力RMSを適度な頻度でログ出力（約640msごと）
        if self.vadLogCounter % 20 == 0 {
          print("🎯 MicrophoneCapture: VAD prob=\(String(format: "%.4f", probability)), rms=\(String(format: "%.6f", rms)), gain=\(String(format: "%.3f", gain))")
        }
        if let callback = self.onVADProbability {
          DispatchQueue.main.async {
            callback(probability)
          }
        } else {
          print("⚠️ MicrophoneCapture: onVADProbability not set (prob=\(String(format: "%.4f", probability)))")
        }
      }
    }
  }

  private func shouldLogVADSignal() -> Bool {
    let now = Date()
    if let last = lastVADSignalLogTime, now.timeIntervalSince(last) < 1.0 {
      return false
    }
    lastVADSignalLogTime = now
    return true
  }
}
