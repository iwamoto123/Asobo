import AVFoundation

public final class PlayerNodeStreamer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var outFormat: AVAudioFormat!
  private let inFormat: AVAudioFormat
  private var converter: AVAudioConverter!

  // 受信チャンクを貯める簡易ジッタバッファ
  private var queue: [Data] = []
  private var queuedFrames: AVAudioFrameCount = 0
  private let prebufferSec: Double = 0.12 // 120ms たまったらスタート

  /// `sourceSampleRate` はサーバのPCMレートに合わせて（既定 24k）
  public init(sourceSampleRate: Double = 24_000.0) {
    guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: sourceSampleRate,
                                    channels: 1,
                                    interleaved: true) else {
      fatalError("inFormat 作成失敗")
    }
    self.inFormat = inFmt

    engine.attach(player)
    // ✅ フォーマットは渡さず、エンジンに任せる（装置とミキサの整合を自動解決）
    engine.connect(player, to: engine.mainMixerNode, format: nil)
    try? engine.start()

    // 実際にミキサへ接続された後のフォーマットを取得
    self.outFormat = player.outputFormat(forBus: 0)

    // 受信(Int16/24k/mono) → 出力(Float32/44.1/48k/ステレオ)へ必ず変換
    guard let conv = AVAudioConverter(from: inFormat, to: outFormat) else {
      fatalError("AVAudioConverter 作成失敗")
    }
    self.converter = conv

    // デバッグ：現状の実フォーマットを出力（必要なら残す）
    // print("player out:", outFormat)
    // print("mixer in :", engine.mainMixerNode.inputFormat(forBus: 0))
    // print("output in:", engine.outputNode.inputFormat(forBus: 0))
  }

  /// 受信した Int16/mono（既定 24kHz）のPCMチャンクを再生
  public func playChunk(_ data: Data) {
    queue.append(data)
    let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    // outFormatに変換後のフレーム数を概算して加算
    let ratio = outFormat.sampleRate / inFormat.sampleRate
    queuedFrames += AVAudioFrameCount(Double(frames) * ratio)

    // まだプリロール未達なら貯めるだけ
    let targetFrames = AVAudioFrameCount(outFormat.sampleRate * prebufferSec)
    if !player.isPlaying, queuedFrames < targetFrames { return }

    // まとめて1ブロックにしてから変換→スケジュール
    let merged = queue.reduce(into: Data()) { $0.append($1) }
    queue.removeAll(keepingCapacity: true)
    queuedFrames = 0

    let inFrames = AVAudioFrameCount(merged.count / MemoryLayout<Int16>.size)
    guard let inBuf = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: inFrames) else { return }
    inBuf.frameLength = inFrames
    merged.withUnsafeBytes { (ptr: UnsafeRawBufferPointer) in
      let dst = inBuf.int16ChannelData![0]
      memcpy(dst, ptr.baseAddress!, merged.count)
    }

    let outCap = AVAudioFrameCount(ceil(Double(inFrames) * ratio))
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCap) else { return }

    var err: NSError?
    let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
      outStatus.pointee = .haveData
      return inBuf
    }
    guard (status == .haveData || status == .endOfStream), outBuf.frameLength > 0 else { return }

    // ここで多少まとまった塊として再生に渡す
    player.scheduleBuffer(outBuf, completionHandler: nil)
    if !player.isPlaying { player.play() }
  }

  public func stop() {
    queue.removeAll()
    queuedFrames = 0
    player.stop()
  }
}
