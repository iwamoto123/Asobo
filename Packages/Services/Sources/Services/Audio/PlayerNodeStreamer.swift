import AVFoundation

public final class PlayerNodeStreamer {
  private let engine = AVAudioEngine()
  private let player = AVAudioPlayerNode()
  private var outFormat: AVAudioFormat?  // start()で設定される
  private let inFormat: AVAudioFormat
  private var converter: AVAudioConverter?  // start()で設定される

  // 受信チャンクを貯める簡易ジッタバッファ
  private var queue: [Data] = []
  private var queuedFrames: AVAudioFrameCount = 0
  private let prebufferSec: Double = 0.2 // 200ms たまったらスタート（実機での安定性向上）

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
    
    // ⚠️ エンジンの開始は後でAudioSessionが設定された後に行う
    // 実機ではAudioSessionがアクティブになる前にエンジンを開始すると失敗する
    
    // エンジンを準備（開始はstart()メソッドで行う）
    engine.prepare()
  }
  
  /// AudioSessionが設定された後にエンジンを開始する
  public func start() throws {
    // エンジンがまだ開始されていない場合のみ開始
    guard !engine.isRunning else { return }
    
    do {
      try engine.start()
      // 実際にミキサへ接続された後のフォーマットを取得
      let format = player.outputFormat(forBus: 0)
      self.outFormat = format
      
      // 受信(Int16/24k/mono) → 出力(Float32/44.1/48k/ステレオ)へ必ず変換
      guard let conv = AVAudioConverter(from: inFormat, to: format) else {
        throw NSError(domain: "PlayerNodeStreamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter 作成失敗"])
      }
      self.converter = conv
      
      print("✅ PlayerNodeStreamer: エンジン開始成功 - outFormat: \(format.sampleRate)Hz, \(format.channelCount)ch")
    } catch {
      print("❌ PlayerNodeStreamer: エンジン開始失敗 - \(error.localizedDescription)")
      throw error
    }
  }

  /// 受信した Int16/mono（既定 24kHz）のPCMチャンクを再生
  public func playChunk(_ data: Data) {
    // エンジンが実行中でない場合、またはoutFormat/converterが設定されていない場合は何もしない
    guard engine.isRunning,
          let format = outFormat,
          let conv = converter else {
      print("⚠️ PlayerNodeStreamer: エンジンが実行中ではないか、アウトプットフォーマットが設定されていません。start()を呼んでください。")
      return
    }
    
    queue.append(data)
    let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    // outFormatに変換後のフレーム数を概算して加算
    let ratio = format.sampleRate / inFormat.sampleRate
    queuedFrames += AVAudioFrameCount(Double(frames) * ratio)

    // まだプリロール未達なら貯めるだけ
    // 実機では十分なデータが蓄積されるまで待つことが重要
    let targetFrames = AVAudioFrameCount(format.sampleRate * prebufferSec)
    if !player.isPlaying, queuedFrames < targetFrames {
      // デバッグログ（最初の数回のみ）
      if queue.count == 1 {
        print("📦 PlayerNodeStreamer: バッファリング中... \(queuedFrames)/\(targetFrames) frames")
      }
      return
    }
    
    // 十分なデータが蓄積された（または既に再生中）
    if !player.isPlaying && queue.count > 0 {
      print("▶️ PlayerNodeStreamer: 再生開始 - \(queue.count) chunks, \(queuedFrames) frames")
    }

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
    guard let outBuf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: outCap) else { return }

    var err: NSError?
    let status = conv.convert(to: outBuf, error: &err) { _, outStatus in
      outStatus.pointee = .haveData
      return inBuf
    }
    guard (status == .haveData || status == .endOfStream), outBuf.frameLength > 0 else {
      if let error = err {
        print("⚠️ PlayerNodeStreamer: 変換エラー - \(error.localizedDescription)")
      }
      return
    }

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
