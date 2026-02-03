import Foundation
import AVFoundation
import Network

extension ConversationController {
    // MARK: - Stream / playback diagnostics
    func handleFirstAudioChunk(for turnId: Int) {
        guard turnMetrics.firstAudio == nil else { return }
        player.clearStopRequestForPlayback(playbackTurnId: turnId, reason: "first audio chunk")
        turnMetrics.firstAudio = Date()
        logTurnStageTiming(event: "firstAudio", at: turnMetrics.firstAudio!)
        logFirstAudioChunkContext(turnId: turnId)
    }

    func logFirstAudioChunkContext(turnId: Int) {
        let playbackIdText = playbackTurnId.map(String.init) ?? "nil"
        let session = AVAudioSession.sharedInstance()
        let route = session.currentRoute
        let outputs = route.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        let inputs = route.inputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🎯 ConversationController: first audio chunk - turnId=\(turnId), playbackTurnId=\(playbackIdText), currentTurnId=\(currentTurnId)")
        print("🎯 ConversationController: route outputs=[\(outputs.isEmpty ? "none" : outputs)], inputs=[\(inputs.isEmpty ? "none" : inputs)], category=\(session.category.rawValue), mode=\(session.mode.rawValue), sampleRate=\(session.sampleRate)")
        player.logFirstChunkStateIfNeeded()
    }

    func logTurnLatencySummary(context: String) {
        let m = turnMetrics
        var parts: [String] = []
        func add(_ label: String, _ start: Date?, _ end: Date?) {
            if let s = start, let e = end, e >= s {
                parts.append("\(label)=\(String(format: "%.2f", e.timeIntervalSince(s)))s")
            }
        }

        add("listen->speechEnd", m.listenStart, m.speechEnd)
        add("speechEnd->request", m.speechEnd, m.requestStart)
        add("request->firstByte", m.requestStart, m.firstByte)
        add("request->firstAudio", m.requestStart, m.firstAudio)
        add("request->firstText", m.requestStart, m.firstText)
        add("request->playbackEnd", m.requestStart, m.playbackEnd)
        add("firstByte->firstAudio", m.firstByte, m.firstAudio)
        add("firstByte->firstText", m.firstByte, m.firstText)
        add("request->streamComplete", m.requestStart, m.streamComplete)
        add("audioPlay->done", m.firstAudio, m.playbackEnd)

        if parts.isEmpty {
            print("⏱️ Latency: \(context) (no metrics)")
        } else {
            print("⏱️ Latency: \(context) | " + parts.joined(separator: ", "))
        }
    }

    func logTurnStageTiming(event: String, at time: Date) {
        var parts: [String] = []
        func add(_ label: String, _ start: Date?) {
            guard let start else { return }
            let delta = time.timeIntervalSince(start)
            parts.append("\(label)=\(String(format: "%.2f", delta))s")
        }
        add("listen->\(event)", turnMetrics.listenStart)
        add("speechEnd->\(event)", turnMetrics.speechEnd)
        add("request->\(event)", turnMetrics.requestStart)
        if parts.isEmpty {
            print("⏱️ TurnTiming[\(event)]: (no anchors)")
        } else {
            print("⏱️ TurnTiming[\(event)]: " + parts.joined(separator: ", "))
        }
    }

    // MARK: - Network / route diagnostics
    func logNetworkEnvironment() {
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "ConversationController.NetworkEnv")
        monitor.pathUpdateHandler = { path in
            let status: String
            switch path.status {
            case .satisfied: status = "satisfied"
            case .requiresConnection: status = "requiresConnection"
            case .unsatisfied: status = "unsatisfied"
            @unknown default: status = "unknown"
            }

            let activeInterfaces = path.availableInterfaces
                .filter { path.usesInterfaceType($0.type) }
                .map { iface -> String in
                    switch iface.type {
                    case .wifi: return "wifi"
                    case .cellular: return "cellular"
                    case .wiredEthernet: return "ethernet"
                    case .loopback: return "loopback"
                    case .other: return "other"
                    @unknown default: return "unknown"
                    }
                }
                .joined(separator: ",")

            let constrained = path.isConstrained ? "true" : "false"
            let expensive = path.isExpensive ? "true" : "false"
            print("📶 ConversationController: Network status=\(status), activeInterfaces=[\(activeInterfaces)], expensive=\(expensive), constrained=\(constrained)")

            monitor.cancel()
        }
        monitor.start(queue: queue)

        // 念のためタイムアウトでキャンセル
        queue.asyncAfter(deadline: .now() + 2.0) {
            monitor.cancel()
        }
    }

    func handleAudioRouteChange(_ notification: Notification) {
        guard isRealtimeActive else { return }
        let reasonValue = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
        let reason = reasonValue.flatMap(AVAudioSession.RouteChangeReason.init) ?? .unknown
        let session = AVAudioSession.sharedInstance()
        let outputs = session.currentRoute.outputs.map { $0.portType.rawValue }.joined(separator: ",")
        print("🔄 ConversationController: audio route change detected - reason=\(reason.rawValue), outputs=[\(outputs.isEmpty ? "none" : outputs)]")

        // ✅ categoryChange(=3) はアプリ内のAudioSession再設定（例: 画面遷移/再生準備）でも頻発する。
        // ここで毎回 prepareForNextStream() / engine restart を走らせると、再生中にバッファが破棄されたり
        // RemoteIOの初期化が競合して 561015905 で落ちることがあるため、無視する。
        if reason == .categoryChange {
            print("ℹ️ ConversationController: route change ignored (categoryChange)")
            return
        }

        // ルート変更でパイプラインが途切れた場合に備えて再開を試みる
        player.prepareForNextStream()
        if !sharedAudioEngine.isRunning {
            do {
                try sharedAudioEngine.start()
                print("✅ ConversationController: sharedAudioEngine restarted after route change")
            } catch {
                print("⚠️ ConversationController: sharedAudioEngine restart failed after route change - \(error.localizedDescription)")
            }
        }
        player.resumeIfNeeded()
    }
}
