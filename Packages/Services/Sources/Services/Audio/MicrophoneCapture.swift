import AVFoundation

public final class MicrophoneCapture {
  private let engine = AVAudioEngine()
  private let outFormat: AVAudioFormat
  private let converter: AVAudioConverter
  private let onPCM: (AVAudioPCMBuffer) -> Void
  private var running = false

  public init?(onPCM: @escaping (AVAudioPCMBuffer) -> Void) {
    self.onPCM = onPCM
    let inputNode = engine.inputNode
    let inFormat  = inputNode.inputFormat(forBus: 0)
    guard
      let out = AVAudioFormat(commonFormat: .pcmFormatInt16,
                              sampleRate: 24_000,
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

    // 入力側の tap フレーム数は「20ms 相当」
    let framesPer20ms = AVAudioFrameCount(inFormat.sampleRate * 0.02)

    inputNode.installTap(onBus: 0, bufferSize: framesPer20ms, format: inFormat) { [weak self] buffer, _ in
      guard let self else { return }

      // 出力側（24kHz）でも20ms相当=480フレームを目安に確保
      let targetFrames = AVAudioFrameCount(self.outFormat.sampleRate * 0.02) // 480
      guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: targetFrames) else { return }

      var error: NSError?
      let status = self.converter.convert(to: outBuf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData
        return buffer
      }

      if (status == .haveData || status == .endOfStream), outBuf.frameLength > 0 {
        self.onPCM(outBuf)               // ← 毎回20ms刻みで即時コールバック
      }
    }

    try engine.start()
    running = true
  }

  public func stop() {
    guard running else { return }
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    running = false
  }
}
