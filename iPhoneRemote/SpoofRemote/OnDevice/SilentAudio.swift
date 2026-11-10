import AVFoundation

/// Plays silence, mixed with whatever else is playing, so iOS keeps AnyWhere scheduled while the screen
/// is locked and a location is held. Nothing is heard and other apps' sound isn't interrupted
/// (`mixWithOthers`). Needs `audio` in UIBackgroundModes.
///
/// A phone call or Siri interrupts it; it starts again when the interruption ends. If the media
/// services restart, the engine is built again.
@MainActor
final class SilentAudio {
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var observers: [NSObjectProtocol] = []
    private var wanted = false
    /// Every two seconds: is the engine still running? Another app taking the audio session can stop
    /// it without an interruption notice (StikDebug found the same), so it is checked, not trusted.
    private var health: Task<Void, Never>?

    func start() {
        wanted = true
        guard engine == nil else { return }
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
        } catch {
            return
        }
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 22_050, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 22_050) else { return }
        // A fresh buffer is all zeros: one second of silence, looped.
        buffer.frameLength = buffer.frameCapacity
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        do {
            try engine.start()
        } catch {
            return
        }
        player.scheduleBuffer(buffer, at: nil, options: .loops)
        player.play()
        self.engine = engine
        self.player = player
        observe()
        watchHealth()
    }

    private func watchHealth() {
        guard health == nil else { return }
        health = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self, self.wanted else { return }
                if self.engine?.isRunning != true || self.player?.isPlaying != true { self.restart() }
            }
        }
    }

    func stop() {
        wanted = false
        health?.cancel()
        health = nil
        tearDown()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private func tearDown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        player?.stop()
        engine?.stop()
        player = nil
        engine = nil
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil,
                                            queue: .main) { [weak self] note in
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            guard raw.flatMap(AVAudioSession.InterruptionType.init) == .ended else { return }
            MainActor.assumeIsolated { self?.restart() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil,
                                            queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restart() }
        })
    }

    private func restart() {
        guard wanted else { return }
        tearDown()
        start()
    }
}
