import AVFoundation

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

  public init?(onPCM: @escaping (AVAudioPCMBuffer) -> Void) {
    self.onPCM = onPCM
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

      // 出力側（24kHz）で20ms相当=480フレームを目安に確保
      let targetFrames = AVAudioFrameCount(self.outFormat.sampleRate * 0.02) // 480
      guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: targetFrames) else { return }

      var error: NSError?
      let status = self.converter.convert(to: outBuf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      if (status == .haveData || status == .endOfStream), outBuf.frameLength > 0 {
        // ✅ バッファに蓄積（20msごとに追加）
        guard let ch0 = outBuf.int16ChannelData else { return }
        let bytes = Int(outBuf.frameLength) * MemoryLayout<Int16>.size
        let ptr = ch0.pointee
        
        self.flushQueue.async {
          // ✅ 音声データをバッファに追加
          self.audioBuffer.append(Data(bytes: ptr, count: bytes))
          
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
