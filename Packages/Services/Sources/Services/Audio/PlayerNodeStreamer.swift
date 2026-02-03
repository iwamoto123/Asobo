import AVFoundation

/// ✅ 出力RMSモニタリング用のクラス
public final class OutputMonitor {
  private var recentRMS: [Double] = []
  private let windowSize: Int = 10  // 直近10フレーム（約200ms）
  private let queue = DispatchQueue(label: "com.asobo.output.monitor")
  
  public var currentRMS: Double {
    queue.sync {
      guard !recentRMS.isEmpty else { return -60.0 }  // 無音時は-60dBFS
      return recentRMS.reduce(0, +) / Double(recentRMS.count)
    }
  }
  
  public func updateRMS(_ rms: Double) {
    queue.async {
      self.recentRMS.append(rms)
      if self.recentRMS.count > self.windowSize {
        self.recentRMS.removeFirst()
      }
    }
  }
  
  public func reset() {
    queue.async {
      self.recentRMS.removeAll()
    }
  }
}

public final class PlayerNodeStreamer {
  public struct VoiceFXState {
    public let enabled: Bool
    public let useVarispeed: Bool
    public let timePitchPitch: Float
    public let timePitchRate: Float
    public let timePitchOverlap: Float
    public let varispeedRate: Float
    
    public init(
      enabled: Bool,
      useVarispeed: Bool,
      timePitchPitch: Float,
      timePitchRate: Float,
      timePitchOverlap: Float,
      varispeedRate: Float
    ) {
      self.enabled = enabled
      self.useVarispeed = useVarispeed
      self.timePitchPitch = timePitchPitch
      self.timePitchRate = timePitchRate
      self.timePitchOverlap = timePitchOverlap
      self.varispeedRate = varispeedRate
    }
  }
  private let engine: AVAudioEngine
  private var ownsEngine: Bool  // エンジンの所有権を持つかどうか
  private var player = AVAudioPlayerNode()
  // 🎛️ 声質を加工するかどうか（オフにするとAI音声を素のまま再生）
  private var enableVoiceEffect = true
  // ⚙️ ボイスチェンジ方式（true: Varispeed、false: TimePitch）
  private var useVarispeed = true
  // 🎤 フィラー音源を録音/準備する間はエフェクトを外す（必要なときだけtrueに）
  private let bypassVoiceEffectForFillerPrep = false
  private let timePitchNode = AVAudioUnitTimePitch()   // ピッチ/速度調整用（従来）
  private let varispeedNode = AVAudioUnitVarispeed()   // 早回し方式（推奨）
  private var outFormat: AVAudioFormat?  // start()で設定される
  private let inFormat: AVAudioFormat
  private var converter: AVAudioConverter?  // start()で設定される
  
  // ✅ prepareForNextStreamでPlayerNodeを作り直す（前の音が混ざる/再度鳴る問題の根本対策）
  private var hardResetPlayerOnPrepare: Bool = false
  
  // ✅ 出力RMSモニタリング
  public let outputMonitor = OutputMonitor()

  // 受信チャンクを貯める簡易ジッタバッファ
  private var queue: [Data] = []
  private var queuedFrames: AVAudioFrameCount = 0
  private let prebufferSec: Double = 0.2 // 200ms たまったらスタート（実機での安定性向上）
  
  // ✅ 追加: 正確な再生状態追跡用
  private var pendingBufferCount: Int = 0
  private let stateLock = NSLock()
  // ✅ 停止要求フラグ（バッファを破棄せず自然に枯渇させる）
  private var stopRequested: Bool = false
  // ✅ 最初のチャンク受信時に状態をログするためのフラグ
  private var firstChunkLogged: Bool = false
  
  // ✅ 追加: 再生状態変更通知クロージャ
  public var onPlaybackStateChange: ((Bool) -> Void)?

  // ✅ 追加: 再生開始待ち（UI同期用）
  private struct PlaybackStartWaiter {
    let id: UUID
    let expectedEvent: Int
    let continuation: CheckedContinuation<Bool, Never>
  }
  private let playbackStartWaitersLock = NSLock()
  private var playbackStartWaiters: [PlaybackStartWaiter] = []
  private var playbackStartEventCounter: Int = 0

  /// ✅ 共通エンジンを使用する場合（AEC有効化のため推奨）
  public init(sharedEngine: AVAudioEngine, sourceSampleRate: Double = 24_000.0, ownsEngine: Bool = false) {
    self.engine = sharedEngine
    self.ownsEngine = ownsEngine
    guard let inFmt = AVAudioFormat(commonFormat: .pcmFormatInt16,
                                    sampleRate: sourceSampleRate,
                                    channels: 1,
                                    interleaved: true) else {
      fatalError("inFormat 作成失敗")
    }
    self.inFormat = inFmt

    engine.attach(player)
    engine.attach(timePitchNode)
    engine.attach(varispeedNode)
    // --- TimePitch 設定（元の方式に戻す場合はこちらを使う） ---
    timePitchNode.pitch = 550.0   // 犯罪者声防止にしっかりプラス方向へ
    timePitchNode.rate = 1.15     // 早口気味で元気に
    timePitchNode.overlap = 12.0  // ケロりを抑えつつ滑らかに
    // --- Varispeed 設定（推奨：早回しで自然な高音+早口） ---
    varispeedNode.rate = 1.35    // 1.2〜1.4あたりがマスコット寄り

    // ✅ AEC対策：48kHz/1chで明示的に接続（AECは48kHz/モノのパスで最も安定）
    // エンジン内は48kHz/monoで統一し、送信時に24kHzに変換
    guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
      fatalError("48kHz/1chフォーマット作成失敗")
    }
    if !enableVoiceEffect {
      engine.connect(player, to: engine.mainMixerNode, format: mono48k)
      print("ℹ️ PlayerNodeStreamer: Voice FX disabled（素の音声を再生）")
    } else if bypassVoiceEffectForFillerPrep {
      // 一時的にプレイヤーをミキサーへ直結（ピッチ/速度加工なし）
      // ✅ フィラー素材を「素の声」で録っておきたいとき用
      engine.connect(player, to: engine.mainMixerNode, format: mono48k)
      print("⚠️ PlayerNodeStreamer: Voice FX bypass中（bypassVoiceEffectForFillerPrep=true）。falseに戻すとVarispeed経路に復帰します。")
    } else if useVarispeed {
      engine.connect(player, to: varispeedNode, format: mono48k)
      engine.connect(varispeedNode, to: engine.mainMixerNode, format: mono48k)
    } else {
      engine.connect(player, to: timePitchNode, format: mono48k)
      engine.connect(timePitchNode, to: engine.mainMixerNode, format: mono48k)
    }
    
    // ⚠️ エンジンの開始は後でAudioSessionが設定された後に行う
    // 実機ではAudioSessionがアクティブになる前にエンジンを開始すると失敗する
    
    // エンジンを準備（開始はstart()メソッドで行う）
    engine.prepare()
  }
  
  /// ✅ prepareForNextStream() で PlayerNode を作り直すかどうか
  public func setHardResetPlayerOnPrepare(_ enabled: Bool) {
    hardResetPlayerOnPrepare = enabled
  }
  
  /// ✅ 独自エンジンを使用する場合（後方互換性のため）
  public convenience init(sourceSampleRate: Double = 24_000.0) {
    let engine = AVAudioEngine()
    self.init(sharedEngine: engine, sourceSampleRate: sourceSampleRate, ownsEngine: true)
  }
  
  /// AudioSessionが設定された後にエンジンを開始する
  public func start() throws {
    // エンジンがまだ開始されていない場合のみ開始
    guard !engine.isRunning else {
      // エンジンが既に開始されている場合は、フォーマットを再設定
      let format = player.outputFormat(forBus: 0)
      self.outFormat = format
      if let conv = AVAudioConverter(from: inFormat, to: format) {
        self.converter = conv
      }
      return
    }
    
    // ✅ エンジンの所有権がある場合のみ開始
    guard ownsEngine else {
      // 共通エンジンの場合は、フォーマットを設定するだけ
      guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
        throw NSError(domain: "PlayerNodeStreamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "48kHz/1chフォーマット作成失敗"])
      }
      self.outFormat = mono48k
      guard let conv = AVAudioConverter(from: inFormat, to: mono48k) else {
        throw NSError(domain: "PlayerNodeStreamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter 作成失敗"])
      }
      conv.sampleRateConverterQuality = .max
      self.converter = conv
      print("✅ PlayerNodeStreamer: 共通エンジン使用 - outFormat: \(mono48k.sampleRate)Hz, \(mono48k.channelCount)ch")
      return
    }
    
    do {
      try engine.start()
      // ✅ AEC対策：48kHz/1chフォーマットを明示的に使用
      // エンジン内は48kHz/monoで統一（AECが最も安定する）
      guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
        throw NSError(domain: "PlayerNodeStreamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "48kHz/1chフォーマット作成失敗"])
      }
      self.outFormat = mono48k
      
      // 受信(Int16/24k/mono) → 出力(Float32/48k/mono)へ変換
      guard let conv = AVAudioConverter(from: inFormat, to: mono48k) else {
        throw NSError(domain: "PlayerNodeStreamer", code: -1, userInfo: [NSLocalizedDescriptionKey: "AVAudioConverter 作成失敗"])
      }
      conv.sampleRateConverterQuality = .max
      self.converter = conv
      
      // ✅ 出力RMSモニタリング用のタップを設定
      // ⚠️ format: nil を使用（システムが適切なフォーマットを選択）
      // エンジン開始後の実際の出力フォーマットを使用するため、nilを指定
      let mixerNode = engine.mainMixerNode
      mixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
        guard let self = self else { return }
        let rms = self.calculateRMS(from: buffer)
        self.outputMonitor.updateRMS(rms)
      }
      
      print("✅ PlayerNodeStreamer: エンジン開始成功 - outFormat: \(mono48k.sampleRate)Hz, \(mono48k.channelCount)ch (AEC最適化: 48kHz/mono)")
    } catch {
      print("❌ PlayerNodeStreamer: エンジン開始失敗 - \(error.localizedDescription)")
      throw error
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
    
    // dBFSに変換（0.0 = 0dBFS, 1.0 = 0dBFS）
    if rms < 1e-10 {
      return -60.0
    }
    return 20.0 * log10(Double(rms))
  }

  /// ✅ IOサイクルが来ている時だけ安全に play() する（"player did not see an IO cycle." abort回避）
  private func safePlayIfPossible(context: String) -> Bool {
    guard engine.isRunning else {
      print("⚠️ PlayerNodeStreamer: safePlay skipped (\(context)) - engine is not running")
      return false
    }
    // lastRenderTime が nil の間は「まだIOサイクルが来ていない」可能性が高い
    if engine.outputNode.lastRenderTime == nil {
      print("⚠️ PlayerNodeStreamer: safePlay skipped (\(context)) - no IO cycle yet (outputNode.lastRenderTime=nil)")
      return false
    }
    if !player.isPlaying {
      player.play()
      stateLock.lock()
      let stopFlag = stopRequested
      stateLock.unlock()
      print("▶️ PlayerNodeStreamer: player.play() issued (\(context)) - stopRequested=\(stopFlag), engineRunning=\(engine.isRunning), pendingBuffers=\(pendingBufferCount)")
    }
    return true
  }

  /// 受信した Int16/mono（24kHz）のPCMチャンクを再生
  public func playChunk(_ data: Data) {
    playChunk(data, forceStart: false)
  }

  /// 受信した Int16/mono（24kHz）のPCMチャンクを再生（forceStart=trueでプリバッファを無視）
  public func playChunk(_ data: Data, forceStart: Bool) {
    stateLock.lock()
    let shouldStop = stopRequested
    stateLock.unlock()
    if shouldStop { return }
    logFirstChunkStateIfNeeded()

    // ✅ エンジンが停止している場合は再開を試みる
    if !engine.isRunning {
      if ownsEngine {
        // 所有権がある場合は直接再開
        do {
          try engine.start()
          print("✅ PlayerNodeStreamer: エンジンを再開（playChunk受信時、ownsEngine=true）")
        } catch {
          print("❌ PlayerNodeStreamer: エンジン再開失敗 - \(error)")
          return
        }
      } else {
        // 共通エンジンの場合：再開を試みる（Bluetooth接続時などに停止している可能性がある）
        // ⚠️ 注意：共通エンジンの再開は、エンジンの所有者（ConversationController）が行うべきだが、
        // ここで再開を試みることで、初回接続時の問題を回避できる
        do {
          try engine.start()
          print("✅ PlayerNodeStreamer: 共通エンジンを再開（playChunk受信時、ownsEngine=false）")
        } catch {
          print("⚠️ PlayerNodeStreamer: 共通エンジン再開失敗 - \(error.localizedDescription)")
          print("⚠️ PlayerNodeStreamer: エンジンが開始されていないため、音声再生をスキップします")
          return
        }
      }
    }
    
    // ✅ ミュート状態からの復帰
    if player.volume < 0.1 {
      player.volume = 1.0
      print("✅ PlayerNodeStreamer: volumeを1.0に戻す（mute解除）")
    }
    
    // ✅ outFormat/converterが設定されていない場合は再設定
    let format: AVAudioFormat
    let conv: AVAudioConverter
    
    if let existingFormat = outFormat, let existingConv = converter {
      format = existingFormat
      conv = existingConv
    } else {
      // ✅ AEC対策：48kHz/1chフォーマットを明示的に使用
      guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
        print("⚠️ PlayerNodeStreamer: 48kHz/1chフォーマット作成失敗")
        return
      }
      self.outFormat = mono48k
      guard let c = AVAudioConverter(from: inFormat, to: mono48k) else {
        print("⚠️ PlayerNodeStreamer: AVAudioConverter 作成失敗")
        return
      }
      c.sampleRateConverterQuality = .max
      self.converter = c
      format = mono48k
      conv = c
      print("✅ PlayerNodeStreamer: フォーマットを再設定（48kHz/1ch）")
    }
    
    queue.append(data)
    let frames = AVAudioFrameCount(data.count / MemoryLayout<Int16>.size)
    // outFormatに変換後のフレーム数を概算して加算
    let ratio = format.sampleRate / inFormat.sampleRate
    queuedFrames += AVAudioFrameCount(Double(frames) * ratio)

    // まだプリロール未達なら貯めるだけ
    // 実機では十分なデータが蓄積されるまで待つことが重要
    let targetFrames = AVAudioFrameCount(format.sampleRate * prebufferSec)
    if !player.isPlaying, queuedFrames < targetFrames, !forceStart {
      // デバッグログ（最初の数回のみ）
      if queue.count == 1 {
        print("📦 PlayerNodeStreamer: バッファリング中... \(queuedFrames)/\(targetFrames) frames")
      }
      return
    }
    if forceStart, !player.isPlaying, queuedFrames < targetFrames {
      print("⚡️ PlayerNodeStreamer: forceStart=true のためプリバッファを無視して再生開始")
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

    // ---------------------------------------------------------
    // ✅ 修正箇所: completionHandlerでバッファ消化を追跡
    // ---------------------------------------------------------
    
    // 1. スケジュール前にカウンタを増やす
    stateLock.lock()
    let wasEmpty = (pendingBufferCount == 0)
    pendingBufferCount += 1
    stateLock.unlock()
    
    if wasEmpty {
      // 再生開始を通知
      DispatchQueue.main.async {
        self.onPlaybackStateChange?(true)
      }
      // ✅ 再生開始イベント（最初のバッファを積んだ）で待機を解放
      notifyPlaybackStarted()
    }

    // 2. バッファをスケジュール（完了で消化を追跡）
    // ⚠️ Bluetooth(HFP)+VoiceChat では player.isPlaying が「音が鳴り終わった後もしばらくtrue」になりやすいので、
    //    可能なら .dataPlayedBack を使って「実際に鳴り終わった」をトリガーにする
    let onBufferDone: () -> Void = { [weak self] in
      guard let self = self else { return }
      self.stateLock.lock()
      self.pendingBufferCount -= 1
      let isNowEmpty = (self.pendingBufferCount <= 0)
      if self.pendingBufferCount < 0 { self.pendingBufferCount = 0 }
      self.stateLock.unlock()

      if isNowEmpty {
        // ✅ ここで明示的にstopして isPlaying を確実に false に寄せる（終了判定の遅延/固まり防止）
        DispatchQueue.main.async { [weak self] in
          guard let self else { return }
          self.player.stop()
          self.onPlaybackStateChange?(false)
        }
      }
    }

    if #available(iOS 11.0, *) {
      player.scheduleBuffer(
        outBuf,
        at: nil,
        options: [],
        completionCallbackType: .dataPlayedBack
      ) { _ in
        onBufferDone()
      }
    } else {
      player.scheduleBuffer(outBuf) {
        onBufferDone()
      }
    }
    
    if !player.isPlaying {
      // ✅ IOサイクル前の abort 回避：安全に play() できる状態かを確認
      if !safePlayIfPossible(context: "playChunk") {
        // 一度だけ軽くリトライ（IOサイクルが次tickで来ることがある）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
          _ = self?.safePlayIfPossible(context: "playChunk.retry")
        }
      }
    }
  }

  public func stop() {
    let newlyRequested = requestStop(muteWhileDraining: true)
    queue.removeAll()
    queuedFrames = 0
    // ✅ ハング防止：完了通知が来ないケースでも待機が抜けられるようにする
    stateLock.lock()
    pendingBufferCount = 0
    stateLock.unlock()
    stateLock.lock()
    firstChunkLogged = false
    stateLock.unlock()
    
    if newlyRequested {
      DispatchQueue.main.async {
        self.onPlaybackStateChange?(false)
      }
    }
    
    // ✅ 出力モニタリングをリセット
    outputMonitor.reset()
    // ✅ タップを削除
    engine.mainMixerNode.removeTap(onBus: 0)
    notifyPlaybackStartCancelledAll()
  }
  
  /// ✅ エンジンを再開（response.audio.delta受信時に呼ぶ）
  public func resumeIfNeeded() {
    stateLock.lock()
    let shouldStop = stopRequested
    stateLock.unlock()
    guard !shouldStop else { return }
    
    // ✅ エンジンが停止している場合は再開を試みる（共通エンジンの場合も含む）
    if !engine.isRunning {
      do {
        try engine.start()
        if ownsEngine {
          print("✅ PlayerNodeStreamer: エンジンを再開（resumeIfNeeded、ownsEngine=true）")
        } else {
          print("✅ PlayerNodeStreamer: 共通エンジンを再開（resumeIfNeeded、ownsEngine=false）")
        }
      } catch {
        print("⚠️ PlayerNodeStreamer: エンジン再開失敗 - \(error.localizedDescription)")
      }
    }
    player.volume = 1.0  // ✅ volumeを戻す
    // ⚠️ ここで player.play() すると、AudioSession未アクティブ等でIOサイクルがまだ来ていない場合に
    // "player did not see an IO cycle." でabortすることがある。
    // 再生開始は、バッファをスケジュールした playChunk() 側で安全に行う。
  }

  /// ✅ ローカルの音声ファイル（相槌など）を再生する
  /// エフェクター（Varispeed/TimePitch）を通るため、自動的にキャラ声になって再生される
  public func playLocalFile(_ url: URL) {
    stateLock.lock()
    let shouldStop = stopRequested
    stateLock.unlock()
    guard !shouldStop else {
      print("⚠️ PlayerNodeStreamer: stop要求中のためローカル再生をスキップ")
      return
    }

    // エンジンが止まっていれば開始を試みる
    if !engine.isRunning {
      try? engine.start()
    }

    // 進行中の再生（相槌など）があれば即停止してから再生
    if player.isPlaying {
      player.stop()
    }

    guard let file = try? AVAudioFile(forReading: url) else {
      print("⚠️ PlayerNodeStreamer: ファイル読み込み失敗 - \(url.lastPathComponent)")
      return
    }

    // ファイルをスケジュールして即再生
    player.scheduleFile(file, at: nil, completionHandler: nil)
    if !safePlayIfPossible(context: "playLocalFile") {
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
        _ = self?.safePlayIfPossible(context: "playLocalFile.retry")
      }
    }
  }
  
  /// ✅ 参考プロジェクトパターン：再生中かどうかを確認
  public var isPlaying: Bool {
    return player.isPlaying
  }
  
  /// 🎛️ ランタイムでエフェクトON/OFFやVarispeed/TimePitchを切り替える
  public func updateVoiceEffect(enabled: Bool, useVarispeed newUseVarispeed: Bool? = nil) {
    let targetUseVarispeed = newUseVarispeed ?? self.useVarispeed
    guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
      print("⚠️ PlayerNodeStreamer: フォーマット作成失敗（updateVoiceEffect）")
      return
    }
    
    let wasPlaying = player.isPlaying
    if wasPlaying { player.pause() }
    
    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(varispeedNode)
    engine.disconnectNodeOutput(timePitchNode)
    
    if !enabled || bypassVoiceEffectForFillerPrep {
      engine.connect(player, to: engine.mainMixerNode, format: mono48k)
    } else if targetUseVarispeed {
      engine.connect(player, to: varispeedNode, format: mono48k)
      engine.connect(varispeedNode, to: engine.mainMixerNode, format: mono48k)
    } else {
      engine.connect(player, to: timePitchNode, format: mono48k)
      engine.connect(timePitchNode, to: engine.mainMixerNode, format: mono48k)
    }
    
    self.enableVoiceEffect = enabled
    self.useVarispeed = targetUseVarispeed
    
    if wasPlaying { player.play() }
    
    let modeText = (!enabled || bypassVoiceEffectForFillerPrep) ? "bypass" : (targetUseVarispeed ? "Varispeed" : "TimePitch")
    print("🎛️ PlayerNodeStreamer: Voice FX updated -> enabled=\(enabled && !bypassVoiceEffectForFillerPrep), mode=\(modeText)")
  }
  
  /// ✅ 現在のボイスFX設定を退避
  public func snapshotVoiceFXState() -> VoiceFXState {
    VoiceFXState(
      enabled: enableVoiceEffect,
      useVarispeed: useVarispeed,
      timePitchPitch: timePitchNode.pitch,
      timePitchRate: timePitchNode.rate,
      timePitchOverlap: timePitchNode.overlap,
      varispeedRate: varispeedNode.rate
    )
  }
  
  /// ✅ 退避しておいたボイスFX設定を復元
  public func applyVoiceFXState(_ state: VoiceFXState) {
    timePitchNode.pitch = state.timePitchPitch
    timePitchNode.rate = state.timePitchRate
    timePitchNode.overlap = state.timePitchOverlap
    varispeedNode.rate = state.varispeedRate
    updateVoiceEffect(enabled: state.enabled, useVarispeed: state.useVarispeed)
  }
  
  /// ✅ フォールバックTTS用のマスコット寄りプリセット
  public func applyMascotBoostPreset() {
    timePitchNode.pitch = 650.0
    timePitchNode.rate = 1.2
    timePitchNode.overlap = 12.0
    varispeedNode.rate = 1.45
    updateVoiceEffect(enabled: true, useVarispeed: true)
  }

  /// ✅ 保護者フレーズ用のプリセット（早口・高め）
  public func applyParentPhrasePreset() {
    timePitchNode.pitch = 750.0
    timePitchNode.rate = 1.35
    timePitchNode.overlap = 12.0
    varispeedNode.rate = 1.2
    updateVoiceEffect(enabled: true, useVarispeed: true)
  }

  /// ✅ 「声かけ」タブ専用：マスコット寄り（高め）プリセット
  /// - Note: ハンズフリー等の既存挙動に影響を出さないため、呼び出し側（TTSEngine）でのみ使用する
  /// - Note: pitch を効かせるため、TimePitch → Varispeed の直列で接続する
  public func applyParentPhrasesMascotPreset() {
    // スピードは今の体感を維持（Varispeedはそのまま）
    varispeedNode.rate = 1.1
    // 声だけ高く（TimePitch）
    timePitchNode.pitch = 600
    timePitchNode.rate = 1.0
    timePitchNode.overlap = 4.0

    guard let mono48k = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1) else {
      print("⚠️ PlayerNodeStreamer: フォーマット作成失敗（applyParentPhrasesMascotPreset）")
      return
    }

    let wasPlaying = player.isPlaying
    if wasPlaying { player.pause() }

    engine.disconnectNodeOutput(player)
    engine.disconnectNodeOutput(varispeedNode)
    engine.disconnectNodeOutput(timePitchNode)

    // player -> timePitch -> varispeed -> mixer
    engine.connect(player, to: timePitchNode, format: mono48k)
    engine.connect(timePitchNode, to: varispeedNode, format: mono48k)
    engine.connect(varispeedNode, to: engine.mainMixerNode, format: mono48k)

    enableVoiceEffect = true
    useVarispeed = true

    if wasPlaying { player.play() }
    print("🎛️ PlayerNodeStreamer: ParentPhrases Mascot FX applied -> pitch=\(timePitchNode.pitch), varispeed=\(varispeedNode.rate)")
  }

  /// ✅ 再生終了を待つ（簡易ポーリング）
  public func waitForPlaybackToEnd(pollIntervalMs: UInt64 = 50) async {
    while true {
      if Task.isCancelled { break }
      stateLock.lock()
      let pending = pendingBufferCount
      stateLock.unlock()
      // ✅ 完了通知ベース（isPlayingは経路次第で遅延するため信用しない）
      if pending == 0 {
        break
      }
      try? await Task.sleep(nanoseconds: pollIntervalMs * 1_000_000)
    }
  }

  /// ✅ 再生終了を待つ（タイムアウト付き）
  /// - Returns: true=終了検知, false=タイムアウト
  public func waitForPlaybackToEnd(timeout: TimeInterval, pollIntervalMs: UInt64 = 50) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask { [weak self] in
        guard let self else { return false }
        await self.waitForPlaybackToEnd(pollIntervalMs: pollIntervalMs)
        return true
      }
      group.addTask {
        try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        return false
      }
      let result = await group.next() ?? false
      group.cancelAll()
      return result
    }
  }

  /// ✅ 次のストリーム開始前に呼び出して停止要求やミュート状態を解除
  public func prepareForNextStream() {
    let wasPlaying = player.isPlaying
    if wasPlaying {
      print("🔧 PlayerNodeStreamer: prepareForNextStream（wasPlaying=true）")
    }
    
    // ✅ まず確実に停止・バッファ破棄
    player.stop()
    player.reset()
    
    // ✅ 変換器/フォーマット/エフェクトの内部状態を捨てる（ストリーム間の混線対策）
    converter = nil
    outFormat = nil
    timePitchNode.reset()
    varispeedNode.reset()
    
    // ✅ 最強対策：PlayerNode自体を作り直す（内部バッファの残留を根絶）
    if hardResetPlayerOnPrepare {
      engine.disconnectNodeOutput(player)
      engine.detach(player)
      player = AVAudioPlayerNode()
      engine.attach(player)
      // 既存設定で再接続（必須）
      updateVoiceEffect(enabled: enableVoiceEffect, useVarispeed: useVarispeed)
      print("🧼 PlayerNodeStreamer: hard reset PlayerNode on prepare")
    }
    
    stateLock.lock()
    stopRequested = false
    stateLock.unlock()
    queue.removeAll()
    queuedFrames = 0
    // ✅ ハング防止：前回の未完了カウントをリセット
    stateLock.lock()
    pendingBufferCount = 0
    stateLock.unlock()
    if player.volume < 0.9 {
      player.volume = 1.0
    }
    stateLock.lock()
    firstChunkLogged = false
    stateLock.unlock()
  }

  /// 新しい再生ターン開始時に stopRequested を確実に解除しておく
  public func clearStopRequestForPlayback(playbackTurnId: Int, reason: String) {
    stateLock.lock()
    let wasStopping = stopRequested
    stopRequested = false
    firstChunkLogged = false
    stateLock.unlock()
    let prefix = wasStopping ? "🟢" : "ℹ️"
    print("\(prefix) PlayerNodeStreamer: stopRequested cleared for turn \(playbackTurnId) (\(reason)), wasStopping=\(wasStopping)")
  }

  // MARK: - Playback start wait (UI sync)

  /// ✅ 再生開始（= 最初のバッファを積んだ）を待つ
  /// - Returns: true=開始, false=タイムアウト/キャンセル
  public func waitForPlaybackToStart(timeout: TimeInterval? = nil) async -> Bool {
    let expected: Int
    stateLock.lock()
    expected = playbackStartEventCounter + 1
    stateLock.unlock()

    let wait = { [weak self] () async -> Bool in
      guard let self else { return false }
      return await self.waitForPlaybackStartEvent(expectedEvent: expected)
    }

    if let timeout = timeout {
      return await withTaskGroup(of: Bool.self) { group in
        group.addTask { await wait() }
        group.addTask {
          try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
          return false
        }
        let result = await group.next() ?? false
        group.cancelAll()
        return result
      }
    } else {
      return await wait()
    }
  }

  private func waitForPlaybackStartEvent(expectedEvent: Int) async -> Bool {
    stateLock.lock()
    let already = playbackStartEventCounter >= expectedEvent
    stateLock.unlock()
    if already { return true }

    let id = UUID()
    return await withTaskCancellationHandler {
      await withCheckedContinuation { cont in
        playbackStartWaitersLock.lock()
        playbackStartWaiters.append(.init(id: id, expectedEvent: expectedEvent, continuation: cont))
        playbackStartWaitersLock.unlock()
      }
    } onCancel: {
      playbackStartWaitersLock.lock()
      var removed: PlaybackStartWaiter?
      playbackStartWaiters.removeAll { w in
        if w.id == id { removed = w; return true }
        return false
      }
      playbackStartWaitersLock.unlock()
      removed?.continuation.resume(returning: false)
    }
  }

  private func notifyPlaybackStarted() {
    stateLock.lock()
    playbackStartEventCounter += 1
    let current = playbackStartEventCounter
    stateLock.unlock()

    playbackStartWaitersLock.lock()
    if playbackStartWaiters.isEmpty {
      playbackStartWaitersLock.unlock()
      return
    }
    var toResume: [PlaybackStartWaiter] = []
    var toKeep: [PlaybackStartWaiter] = []
    toKeep.reserveCapacity(playbackStartWaiters.count)
    for w in playbackStartWaiters {
      if w.expectedEvent <= current { toResume.append(w) } else { toKeep.append(w) }
    }
    playbackStartWaiters = toKeep
    playbackStartWaitersLock.unlock()
    toResume.forEach { $0.continuation.resume(returning: true) }
  }

  private func notifyPlaybackStartCancelledAll() {
    playbackStartWaitersLock.lock()
    let toResume = playbackStartWaiters
    playbackStartWaiters.removeAll()
    playbackStartWaitersLock.unlock()
    toResume.forEach { $0.continuation.resume(returning: false) }
  }

  @discardableResult
  private func requestStop(muteWhileDraining: Bool) -> Bool {
    stateLock.lock()
    let alreadyStopping = stopRequested
    stopRequested = true
    stateLock.unlock()
    if muteWhileDraining {
      player.volume = 0
    }
    return !alreadyStopping
  }

  /// 最初のチャンク受信時の状態を一度だけログする
  public func logFirstChunkStateIfNeeded() {
    stateLock.lock()
    if firstChunkLogged {
      stateLock.unlock()
      return
    }
    firstChunkLogged = true
    let stopFlag = stopRequested
    stateLock.unlock()

    print("🎯 PlayerNodeStreamer: first audio chunk state - stopRequested=\(stopFlag), volume=\(player.volume), engineRunning=\(engine.isRunning)")
  }
}
