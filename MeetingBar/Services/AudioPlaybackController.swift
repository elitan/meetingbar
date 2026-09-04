import AVFoundation
import Foundation
import Observation

@MainActor
@Observable
final class AudioPlaybackController {
  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var isPlaying = false
  private(set) var isPreparing = false
  private(set) var enhancementDescription: String?
  private(set) var errorMessage: String?

  var isPrepared: Bool {
    player != nil
  }

  @ObservationIgnored private var player: AVAudioPlayer?
  @ObservationIgnored private var progressTask: Task<Void, Never>?
  @ObservationIgnored private var preparationTask: Task<Void, Never>?
  @ObservationIgnored private var processorTask: Task<PreparedPlaybackAudio, Error>?
  @ObservationIgnored private var currentURL: URL?
  @ObservationIgnored private var preparedRecordingID: UUID?

  func prepare(url: URL) {
    guard currentURL != url else {
      return
    }

    unload()
    errorMessage = nil
    do {
      try installPlayer(url: url)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  func prepareAndPlay(
    recordingID: UUID,
    fallbackAudioURL: URL,
    fileStore: RecordingFileStore
  ) {
    guard preparedRecordingID != recordingID else {
      return
    }

    unload()
    preparedRecordingID = recordingID
    isPreparing = true
    errorMessage = nil

    let processorTask = Task.detached(priority: .userInitiated) {
      try PlaybackAudioProcessor().prepare(
        recordingID: recordingID,
        fallbackAudioURL: fallbackAudioURL,
        fileStore: fileStore
      )
    }
    self.processorTask = processorTask
    preparationTask = Task { [weak self] in
      do {
        let prepared = try await processorTask.value
        guard !Task.isCancelled, let self, self.preparedRecordingID == recordingID else {
          return
        }
        try self.installPlayer(url: prepared.audioURL)
        self.enhancementDescription = prepared.enhancementDescription
      } catch is CancellationError {
        return
      } catch {
        guard !Task.isCancelled, let self, self.preparedRecordingID == recordingID else {
          return
        }
        do {
          try self.installPlayer(url: fallbackAudioURL)
          self.enhancementDescription = "Original level; automatic balancing was unavailable"
        } catch {
          self.errorMessage = error.localizedDescription
        }
      }

      guard let self, self.preparedRecordingID == recordingID else {
        return
      }
      self.isPreparing = false
      self.preparationTask = nil
      self.processorTask = nil
      self.startPlayback()
    }
  }

  func toggle() {
    guard let player else {
      return
    }

    if player.isPlaying {
      pause()
      return
    }

    startPlayback()
  }

  func seek(to time: TimeInterval) {
    guard let player else {
      return
    }
    let clampedTime = min(max(0, time), duration)
    player.currentTime = clampedTime
    currentTime = clampedTime
  }

  func unload() {
    preparationTask?.cancel()
    preparationTask = nil
    processorTask?.cancel()
    processorTask = nil
    progressTask?.cancel()
    progressTask = nil
    player?.stop()
    player = nil
    currentURL = nil
    preparedRecordingID = nil
    currentTime = 0
    duration = 0
    isPlaying = false
    isPreparing = false
    enhancementDescription = nil
  }

  func clearError() {
    errorMessage = nil
  }

  private func pause() {
    player?.pause()
    currentTime = player?.currentTime ?? currentTime
    isPlaying = false
    progressTask?.cancel()
    progressTask = nil
  }

  private func startPlayback() {
    guard let player else {
      return
    }
    if currentTime >= duration {
      player.currentTime = 0
      currentTime = 0
    }
    guard player.play() else {
      errorMessage = "macOS could not start audio playback."
      return
    }
    isPlaying = true
    startProgressUpdates()
  }

  private func installPlayer(url: URL) throws {
    let player = try AVAudioPlayer(contentsOf: url)
    player.prepareToPlay()
    self.player = player
    currentURL = url
    duration = player.duration
  }

  private func startProgressUpdates() {
    progressTask?.cancel()
    progressTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .milliseconds(100))
        guard !Task.isCancelled, let self, let player = self.player else {
          return
        }

        currentTime = player.currentTime
        guard player.isPlaying else {
          currentTime = duration
          isPlaying = false
          progressTask = nil
          return
        }
      }
    }
  }
}
