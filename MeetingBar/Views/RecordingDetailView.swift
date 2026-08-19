import AVFoundation
import Observation
import SwiftData
import SwiftUI

struct RecordingDetailView: View {
  @Bindable var recording: Recording
  let controller: AppController
  @State private var confirmsDeletion = false
  @State private var deletionError: String?
  @State private var audioPlayback = AudioPlaybackController()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        HStack(spacing: 12) {
          TextField("Meeting title", text: $recording.title)
            .font(.title2.weight(.semibold))
            .textFieldStyle(.plain)
            .onSubmit {
              controller.save(recording)
            }

          Button {
            recording.isPinned.toggle()
            controller.save(recording)
          } label: {
            Image(systemName: recording.isPinned ? "pin.fill" : "pin")
          }
          .buttonStyle(.plain)
          .foregroundStyle(recording.isPinned ? Color.accentColor : Color.secondary)
          .help(recording.isPinned ? "Unpin meeting" : "Pin meeting")
        }

        HStack(spacing: 10) {
          StatusBadge(recording: recording)
          Text(recording.startedAt, format: .dateTime.year().month().day().hour().minute())
          Text(DurationText.string(seconds: recording.durationSeconds))
            .monospacedDigit()
          if let language = recording.detectedLanguage {
            Text(language.uppercased())
          }
          if recording.wasRecovered {
            Label("Recovered", systemImage: "wrench.and.screwdriver")
          }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)

        if let error = recording.errorMessage {
          HStack(alignment: .top) {
            Image(systemName: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
            Text(error)
            Spacer()
            if recording.status == .failed, controller.audioURL(for: recording) != nil {
              Button("Retry") {
                controller.retry(recording)
              }
            }
          }
          .padding(12)
          .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        }

        if !recording.captureWarnings.isEmpty {
          DisclosureGroup("Warnings (\(recording.captureWarnings.count))") {
            VStack(alignment: .leading, spacing: 6) {
              ForEach(Array(recording.captureWarnings.enumerated()), id: \.offset) { _, warning in
                Text("• \(warning)")
              }
            }
            .padding(.top, 6)
          }
        }

        GroupBox("Transcript") {
          VStack(alignment: .leading, spacing: 12) {
            if recording.status == .ready {
              Text(recording.transcript.isEmpty ? "No speech was detected." : recording.transcript)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if recording.status == .transcribing {
              HStack {
                ProgressView()
                  .controlSize(.small)
                Text("Transcribing on this Mac…")
              }
            } else if recording.status == .queued {
              Text("Waiting for the transcription engine.")
                .foregroundStyle(.secondary)
            } else {
              Text("Transcription is unavailable until this meeting is retried.")
                .foregroundStyle(.secondary)
            }

            if recording.status == .ready, !recording.transcript.isEmpty {
              Button("Copy Transcript", systemImage: "doc.on.doc") {
                controller.copyTranscript(recording)
              }
            }

            if recording.status == .ready, controller.audioURL(for: recording) != nil {
              Button(
                SpeakerTranscriptFormatter.containsSpeakerLabels(recording.transcript)
                  ? "Transcribe Again"
                  : "Detect Speakers",
                systemImage: "person.2.wave.2"
              ) {
                controller.retry(recording)
              }
            }
          }
          .padding(4)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("Source audio") {
          if controller.audioURL(for: recording) != nil {
            let playbackDuration =
              audioPlayback.duration > 0
              ? audioPlayback.duration
              : recording.durationSeconds
            VStack(alignment: .leading, spacing: 12) {
              HStack(spacing: 12) {
                Button(
                  audioPlayback.isPlaying ? "Pause" : "Play",
                  systemImage: audioPlayback.isPlaying ? "pause.fill" : "play.fill"
                ) {
                  audioPlayback.toggle()
                }
                .disabled(audioPlayback.isPreparing)

                Slider(
                  value: Binding(
                    get: { audioPlayback.currentTime },
                    set: { audioPlayback.seek(to: $0) }
                  ),
                  in: 0...max(playbackDuration, 0.1)
                )
                .disabled(audioPlayback.isPreparing)

                Text(
                  "\(DurationText.string(seconds: audioPlayback.currentTime)) / "
                    + DurationText.string(seconds: playbackDuration)
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 88, alignment: .trailing)
              }

              if audioPlayback.isPreparing {
                HStack(spacing: 8) {
                  ProgressView()
                    .controlSize(.small)
                  Text("Balancing playback levels…")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
              } else if let enhancementDescription = audioPlayback.enhancementDescription {
                Label(enhancementDescription, systemImage: "waveform.badge.magnifyingglass")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }

              HStack {
                Button("Reveal in Finder", systemImage: "folder") {
                  controller.revealAudio(for: recording)
                }
                Spacer()
                if let expiry = recording.audioExpiresAt {
                  Text("Deletes \(expiry, format: .dateTime.year().month().day())")
                    .foregroundStyle(.secondary)
                }
              }
            }
            .padding(4)
          } else {
            Label("Audio deleted; transcript retained", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary)
              .padding(4)
          }
        }

        Divider()

        Button("Delete Meeting…", systemImage: "trash", role: .destructive) {
          confirmsDeletion = true
        }
      }
      .padding(24)
      .frame(maxWidth: 760, alignment: .leading)
    }
    .alert("Delete this meeting?", isPresented: $confirmsDeletion) {
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        do {
          audioPlayback.unload()
          try controller.delete(recording)
        } catch {
          deletionError = error.localizedDescription
        }
      }
    } message: {
      Text(
        "The transcript and any source audio will be removed immediately. This cannot be undone.")
    }
    .alert(
      "Meeting could not be deleted",
      isPresented: Binding(
        get: { deletionError != nil },
        set: { if !$0 { deletionError = nil } }
      )
    ) {
      Button("OK") {}
    } message: {
      Text(deletionError ?? "Unknown error")
    }
    .alert(
      "Recording could not be played",
      isPresented: Binding(
        get: { audioPlayback.errorMessage != nil },
        set: { if !$0 { audioPlayback.clearError() } }
      )
    ) {
      Button("OK") {
        audioPlayback.clearError()
      }
    } message: {
      Text(audioPlayback.errorMessage ?? "Unknown error")
    }
    .onAppear {
      prepareAudioPlayback()
    }
    .onChange(of: recording.id) {
      prepareAudioPlayback()
    }
    .onChange(of: recording.audioRelativePath) {
      prepareAudioPlayback()
    }
    .onDisappear {
      audioPlayback.unload()
    }
  }

  private func prepareAudioPlayback() {
    guard let audioURL = controller.audioURL(for: recording) else {
      audioPlayback.unload()
      return
    }
    audioPlayback.prepare(
      recordingID: recording.id,
      fallbackAudioURL: audioURL,
      fileStore: controller.fileStore
    )
  }
}

@MainActor
@Observable
final class AudioPlaybackController {
  private(set) var currentTime: TimeInterval = 0
  private(set) var duration: TimeInterval = 0
  private(set) var isPlaying = false
  private(set) var isPreparing = false
  private(set) var enhancementDescription: String?
  private(set) var errorMessage: String?

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

  func prepare(
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
