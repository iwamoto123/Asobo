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

    inputNode.installTap(onBus: 0, bufferSize: 1024, format: inFormat) { [weak self] buffer, _ in
      guard let self else { return }

      // 出力バッファを用意（24kHz/mono/Int16）
      let ratio    = self.outFormat.sampleRate / inFormat.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1)
      guard let outBuf = AVAudioPCMBuffer(pcmFormat: self.outFormat, frameCapacity: capacity) else { return }

      // ✅ ステータスで判定（戻り値は AVAudioConverterOutputStatus）
      var error: NSError?
      let status = self.converter.convert(to: outBuf, error: &error) { _, outStatus in
        outStatus.pointee = .haveData   // 第二引数だけ .pointee を使う
        return buffer                   // 入力として元バッファを渡す
      }

      if status == .haveData, outBuf.frameLength > 0 {
        self.onPCM(outBuf)
      }
      // 必要なら: status == .error のとき error をログ
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
