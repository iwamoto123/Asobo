import AVFoundation

/// ✅ マイク入力キャプチャとフォーマット変換
/// 
/// ## 重要な設定ポイント
/// 1. **出力フォーマット**: 24kHz/mono/PCM16LE（OpenAI Realtime APIの要求仕様）
/// 2. **バッチ送信**: 200msごとにまとめて送信（ネットワーク効率とVADの精度向上）
/// 3. **フォーマット変換**: AVAudioConverterで確実に24kHz/mono/PCM16に変換
/// 
/// ## 変換フロー
/// - 入力: デバイス依存（通常48kHz/mono/Float32、AEC適用後）
/// - エンジン内: 48kHz/monoで処理（AEC最適化のため）
/// - 送信時変換: AVAudioConverterで24kHz/mono/PCM16LEに変換（サーバ送信の直前）
/// - バッファリング: 200ms分をまとめて送信
/// - 出力: 24kHz/mono/PCM16LE形式のAVAudioPCMBuffer
/// 
/// ## AEC対策
/// - **エンジン内は48kHz/monoで統一**: AECは48kHz/モノのパスで最も安定
/// - **再生中のマイク送信ゲート**: AI再生中はマイク入力をサーバに送信しない（ハーフデュプレックス）
/// - **バージイン検出**: バージイン検出時のみ送信を再開
public final class MicrophoneCapture {
  private let engine = AVAudioEngine()
  private let outFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private let onPCM: (AVAudioPCMBuffer) -> Void
  private var running = false
  
  // ✅ バッチ送信用：20ms×10（=200ms）をまとめて送信
  private var audioBuffer: Data = Data()
  private let batchDurationMs: Double = 200.0  // 200msバッチ
  private var lastFlushTime: Date = Date()
  private let flushQueue = DispatchQueue(label: "com.asobo.audio.flush")
  
  // ✅ AEC対策：再生中ゲート制御
  private var isAIPlayingAudio: Bool = false
  private var userBargeIn: Bool = false
  private var outputMonitor: OutputMonitor?
  private let rmsMarginDb: Double = 12.0  // 入力RMSが出力RMS+12dB以上でバージイン
  private let playbackQuietDbThreshold: Double = -35.0  // 出力が-35dBFS以下でバージイン許可
  private var recentInputRMS: [Double] = []  // 直近200msの入力RMS
  private let rmsWindowSize: Int = 10  // 10フレーム（約200ms）

  public init?(onPCM: @escaping (AVAudioPCMBuffer) -> Void, outputMonitor: OutputMonitor? = nil) {
    self.onPCM = onPCM
    self.outputMonitor = outputMonitor
    let inputNode = engine.inputNode
    let inFormat  = inputNode.inputFormat(forBus: 0)
    guard
      let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                              sampleRate: 24_000,  // ✅ 24kHzに変更（OpenAI Realtime APIの要求仕様に合わせる）
                              channels: 1,
                              interleaved: true),
      let conv = AVAudioConverter(from: inFormat, to: out)
    else { return nil }
    self.outFormat = out
    self.converter = conv
  }
  
  /// ✅ AI再生状態を設定
  public func setAIPlayingAudio(_ isPlaying: Bool) {
    isAIPlayingAudio = isPlaying
    if !isPlaying {
      // 再生終了時にバージインフラグをリセット
      userBargeIn = false
      recentInputRMS.removeAll()
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
  private func checkBargeIn(inputRMS: Double, outputRMS: Double) -> Bool {
    // 直近200msの入力RMSを記録
    recentInputRMS.append(inputRMS)
    if recentInputRMS.count > rmsWindowSize {
      recentInputRMS.removeFirst()
    }
    
    // 直近200msの平均入力RMS
    let avgInputRMS = recentInputRMS.reduce(0, +) / Double(recentInputRMS.count)
    
    // バージイン条件：
    // 1. 入力RMSが出力RMS+マージン以上
    // 2. 出力RMSが一定以下（スピーカーが鳴っていない）
    let condition1 = avgInputRMS > (outputRMS + rmsMarginDb)
    let condition2 = outputRMS < playbackQuietDbThreshold
    
    return condition1 && condition2
  }

  public func start() throws {
    guard !running else { return }
    let inputNode = engine.inputNode
    let inFormat  = inputNode.inputFormat(forBus: 0)

    // ✅ 入力側の tap フレーム数は「20ms 相当」（内部バッファリング用）
    let framesPer20ms = AVAudioFrameCount(inFormat.sampleRate * 0.02)
    audioBuffer.removeAll()
    lastFlushTime = Date()

    inputNode.installTap(onBus: 0, bufferSize: framesPer20ms, format: inFormat) { [weak self] buffer, _ in
      guard let self else { return }
      
      // ✅ AEC対策：再生中ゲート制御
      let inputRMS = self.calculateRMS(from: buffer)
      let outputRMS = self.outputMonitor?.currentRMS ?? -60.0
      
      if self.isAIPlayingAudio && !self.userBargeIn {
        // バージイン判定
        if self.checkBargeIn(inputRMS: inputRMS, outputRMS: outputRMS) {
          self.userBargeIn = true
          print("🎤 MicrophoneCapture: バージイン検出 - inputRMS: \(String(format: "%.1f", inputRMS))dB, outputRMS: \(String(format: "%.1f", outputRMS))dB")
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
      let status = self.converter.convert(to: outBuf, error: &error) { inCount, outStatus in
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
          
          // ✅ 200ms経過したらバッチ送信
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
              self.onPCM(batchBuf)  // ← 200msバッチでコールバック
            }
          }
        }
      }
    }

    try engine.start()
    running = true
  }

  public func stop() {
    guard running else { return }
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
    engine.stop()
    running = false
  }
}
