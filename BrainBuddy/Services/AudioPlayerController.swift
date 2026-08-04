import AVFoundation
import Foundation
import Observation

/// Plays back a stored voice note from its temporary file.
@MainActor
@Observable
final class AudioPlayerController {
    private(set) var isPlaying = false
    private(set) var currentTime: TimeInterval = 0
    private(set) var duration: TimeInterval = 0

    private var player: AVAudioPlayer?
    private var ticker: Task<Void, Never>?

    func load(url: URL) {
        stop()
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [])
            try AVAudioSession.sharedInstance().setActive(true, options: [])
            let player = try AVAudioPlayer(contentsOf: url)
            player.prepareToPlay()
            self.player = player
            duration = player.duration
            currentTime = 0
        } catch {
            player = nil
            duration = 0
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
            ticker?.cancel()
        } else {
            player.play()
            isPlaying = true
            startTicker()
        }
    }

    func seek(to time: TimeInterval) {
        guard let player else { return }
        player.currentTime = min(max(0, time), player.duration)
        currentTime = player.currentTime
    }

    func stop() {
        ticker?.cancel()
        ticker = nil
        player?.stop()
        player = nil
        isPlaying = false
        currentTime = 0
        duration = 0
    }

    private func startTicker() {
        ticker?.cancel()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self, let player = self.player else { return }
                self.currentTime = player.currentTime
                if !player.isPlaying {
                    self.isPlaying = false
                    // Reaching the end should rewind, not leave the scrubber stuck.
                    if player.currentTime >= player.duration - 0.05 {
                        player.currentTime = 0
                        self.currentTime = 0
                    }
                    return
                }
            }
        }
    }
}
