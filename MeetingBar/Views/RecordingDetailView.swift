import SwiftData
import SwiftUI

struct RecordingDetailView: View {
  @Bindable var recording: Recording
  let controller: AppController
  @State private var confirmsDeletion = false
  @State private var deletionError: String?
  @State private var audioPlayback = AudioPlaybackController()
  @State private var isEditingTitle = false
  @State private var draftTitle = ""
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 22) {
        detailHeader

        if let error = recording.errorMessage {
          DetailAlertCard(
            title: "This meeting needs attention",
            message: error,
            symbol: "exclamationmark.triangle.fill",
            color: MeetingBarTheme.amber
          ) {
            if recording.status == .failed, controller.audioURL(for: recording) != nil {
              Button("Retry Transcription") {
                controller.retry(recording)
              }
              .buttonStyle(.borderedProminent)
            }
          }
        }

        if !recording.captureWarnings.isEmpty {
          warningCard
        }

        transcriptCard
        sourceAudioCard

        HStack {
          Label("Library and audio stored on this Mac", systemImage: "internaldrive.fill")
            .font(.caption)
            .foregroundStyle(.tertiary)
          Spacer()
          Button("Delete Meeting…", systemImage: "trash", role: .destructive) {
            confirmsDeletion = true
          }
          .buttonStyle(.borderless)
        }
        .padding(.horizontal, 4)
      }
      .padding(.horizontal, 34)
      .padding(.vertical, 30)
      .frame(maxWidth: 900, alignment: .leading)
      .frame(maxWidth: .infinity)
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
        "The transcript and any source audio will be removed immediately. This cannot be undone."
      )
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
    .onChange(of: recording.id) {
      cancelTitleEdit()
      audioPlayback.unload()
    }
    .onChange(of: recording.audioRelativePath) {
      audioPlayback.unload()
    }
    .onDisappear {
      audioPlayback.unload()
    }
  }

  private var detailHeader: some View {
    VStack(alignment: .leading, spacing: 15) {
      HStack(alignment: .top, spacing: 14) {
        VStack(alignment: .leading, spacing: 7) {
          if isEditingTitle {
            TextField("Meeting title", text: $draftTitle, axis: .vertical)
              .font(.system(size: 29, weight: .bold, design: .rounded))
              .textFieldStyle(.plain)
              .lineLimit(1...2)
              .focused($isTitleFocused)
              .onSubmit {
                commitTitleEdit()
              }
              .onExitCommand {
                cancelTitleEdit()
              }
              .onChange(of: isTitleFocused) { wasFocused, isFocused in
                if wasFocused, !isFocused, isEditingTitle {
                  commitTitleEdit()
                }
              }
          } else {
            Text(recording.title)
              .font(.system(size: 29, weight: .bold, design: .rounded))
              .lineLimit(2)
              .textSelection(.enabled)
              .onTapGesture(count: 2) {
                beginTitleEdit()
              }
          }

          Text("Double-click a title in the sidebar or edit it here.")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }

        Spacer(minLength: 12)

        Button {
          beginTitleEdit()
        } label: {
          Image(systemName: "pencil")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: 38, height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("Rename meeting")

        Button {
          recording.isPinned.toggle()
          controller.save(recording)
        } label: {
          Image(systemName: recording.isPinned ? "pin.fill" : "pin")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(recording.isPinned ? MeetingBarTheme.accent : Color.secondary)
            .frame(width: 38, height: 38)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
              RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help(recording.isPinned ? "Unpin meeting" : "Pin meeting")
      }

      HStack(spacing: 9) {
        StatusBadge(recording: recording)

        Label(
          recording.startedAt.formatted(
            .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute()
          ),
          systemImage: "calendar"
        )

        Label(DurationText.string(seconds: recording.durationSeconds), systemImage: "clock")
          .monospacedDigit()

        if let language = recording.detectedLanguage {
          Label(language.uppercased(), systemImage: "character.bubble")
        }

        if let transcriptionEngineLabel = recording.transcriptionEngineLabel {
          Label(
            transcriptionEngineLabel,
            systemImage: recording.transcriptionProvider == .elevenLabs
              ? "cloud"
              : "cpu"
          )
        }

        if recording.wasRecovered {
          Label("Recovered", systemImage: "wrench.and.screwdriver")
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .lineLimit(1)
    }
  }

  private var warningCard: some View {
    MeetingBarCard(padding: 15, cornerRadius: 15) {
      DisclosureGroup {
        VStack(alignment: .leading, spacing: 8) {
          ForEach(Array(recording.captureWarnings.enumerated()), id: \.offset) { _, warning in
            HStack(alignment: .top, spacing: 8) {
              Circle()
                .fill(MeetingBarTheme.amber)
                .frame(width: 5, height: 5)
                .padding(.top, 6)
              Text(warning)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
          }
        }
        .padding(.top, 10)
      } label: {
        Label(
          "Capture notes · \(recording.captureWarnings.count)",
          systemImage: "waveform.badge.exclamationmark"
        )
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(MeetingBarTheme.amber)
      }
    }
  }

  private var transcriptCard: some View {
    MeetingBarCard(padding: 0, cornerRadius: 20) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          MeetingBarIconTile(symbol: "text.alignleft", size: 38)
          VStack(alignment: .leading, spacing: 2) {
            Text("Transcript")
              .font(.headline)
            Text(transcriptSubtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }

          Spacer()

          if recording.status == .ready, controller.audioURL(for: recording) != nil {
            Button {
              controller.retry(recording)
            } label: {
              Label(
                SpeakerTranscriptFormatter.containsSpeakerLabels(recording.transcript)
                  ? "Transcribe Again"
                  : "Detect Speakers",
                systemImage: "person.2.wave.2"
              )
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }

          if recording.status == .ready, !recording.transcript.isEmpty {
            Button {
              controller.copyTranscript(recording)
            } label: {
              Label("Copy", systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
        .padding(18)

        Divider()
          .opacity(0.55)

        TranscriptContentView(recording: recording)
          .padding(22)
          .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private var transcriptSubtitle: String {
    let provider = recording.transcriptionProvider ?? .onDevice
    switch recording.status {
    case .ready:
      if SpeakerTranscriptFormatter.containsSpeakerLabels(recording.transcript) {
        return provider == .onDevice
          ? "Speaker-aware, on-device text"
          : "Speaker-aware text · ElevenLabs"
      }
      return provider == .onDevice
        ? "Searchable, on-device text"
        : "Searchable text · ElevenLabs"
    case .queued:
      return "Waiting for the transcription engine"
    case .transcribing:
      return provider == .onDevice
        ? "Processing privately on this Mac"
        : "Uploading and processing with ElevenLabs"
    case .failed:
      return "Transcription needs to be retried"
    }
  }

  @ViewBuilder
  private var sourceAudioCard: some View {
    MeetingBarCard(padding: 0, cornerRadius: 20) {
      VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 12) {
          MeetingBarIconTile(symbol: "waveform", color: MeetingBarTheme.coral, size: 38)
          VStack(alignment: .leading, spacing: 2) {
            Text("Source Audio")
              .font(.headline)
            Text("Balanced automatically for comfortable playback")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer()

          if controller.audioURL(for: recording) != nil {
            Button("Reveal in Finder", systemImage: "folder") {
              controller.revealAudio(for: recording)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
          }
        }
        .padding(18)

        Divider()
          .opacity(0.55)

        audioPlayerContent
          .padding(20)
      }
    }
  }

  @ViewBuilder
  private var audioPlayerContent: some View {
    if controller.audioURL(for: recording) != nil {
      let playbackDuration =
        audioPlayback.duration > 0
        ? audioPlayback.duration
        : recording.durationSeconds

      VStack(alignment: .leading, spacing: 16) {
        HStack(spacing: 15) {
          Button {
            toggleAudioPlayback()
          } label: {
            Image(systemName: audioPlayback.isPlaying ? "pause.fill" : "play.fill")
              .font(.system(size: 15, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 42, height: 42)
              .background(
                audioPlayback.isPlaying
                  ? MeetingBarTheme.recordingGradient
                  : MeetingBarTheme.accentGradient,
                in: Circle()
              )
              .shadow(
                color: (audioPlayback.isPlaying ? MeetingBarTheme.coral : MeetingBarTheme.accent)
                  .opacity(0.22),
                radius: 8,
                y: 3
              )
          }
          .buttonStyle(.plain)
          .disabled(audioPlayback.isPreparing)
          .help(audioPlayback.isPlaying ? "Pause" : "Play")

          VStack(spacing: 7) {
            Slider(
              value: Binding(
                get: { audioPlayback.currentTime },
                set: { audioPlayback.seek(to: $0) }
              ),
              in: 0...max(playbackDuration, 0.1)
            )
            .tint(MeetingBarTheme.accent)
            .disabled(audioPlayback.isPreparing)

            HStack {
              Text(DurationText.string(seconds: audioPlayback.currentTime))
              Spacer()
              Text(DurationText.string(seconds: playbackDuration))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.tertiary)
          }
        }

        HStack(spacing: 8) {
          if audioPlayback.isPreparing {
            ProgressView()
              .controlSize(.small)
            Text("Balancing playback levels…")
          } else if let enhancementDescription = audioPlayback.enhancementDescription {
            Image(systemName: "wand.and.sparkles")
              .foregroundStyle(MeetingBarTheme.accent)
            Text(enhancementDescription)
          } else {
            Image(systemName: "waveform.badge.checkmark")
              .foregroundStyle(MeetingBarTheme.mint)
            Text("Ready · playback balances when you press Play")
          }

          Spacer()
          Text("Kept on this Mac until you delete this meeting")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    } else {
      HStack(spacing: 12) {
        MeetingBarIconTile(symbol: "checkmark", color: MeetingBarTheme.mint, size: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text("Audio unavailable")
            .font(.subheadline.weight(.semibold))
          Text("This older recording no longer has source audio; its transcript remains searchable.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func toggleAudioPlayback() {
    if audioPlayback.isPrepared {
      audioPlayback.toggle()
      return
    }

    guard let audioURL = controller.audioURL(for: recording) else {
      return
    }
    audioPlayback.prepareAndPlay(
      recordingID: recording.id,
      fallbackAudioURL: audioURL,
      fileStore: controller.fileStore
    )
  }

  private func beginTitleEdit() {
    draftTitle = recording.title
    isEditingTitle = true
    Task { @MainActor in
      isTitleFocused = true
    }
  }

  private func commitTitleEdit() {
    guard isEditingTitle else {
      return
    }
    let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != recording.title {
      controller.rename(recording, to: title)
    }
    isEditingTitle = false
    isTitleFocused = false
  }

  private func cancelTitleEdit() {
    draftTitle = recording.title
    isEditingTitle = false
    isTitleFocused = false
  }
}

private struct TranscriptContentView: View {
  let recording: Recording

  var body: some View {
    switch recording.status {
    case .ready:
      if recording.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        TranscriptEmptyState(
          title: "No speech detected",
          message: "The recording is safe to delete if it only contains silence.",
          symbol: "waveform.slash"
        )
      } else {
        SpeakerTranscriptView(transcript: recording.transcript)
          .equatable()
      }
    case .transcribing:
      HStack(spacing: 12) {
        ProgressView()
          .controlSize(.small)
        VStack(alignment: .leading, spacing: 2) {
          Text("Transcribing your meeting")
            .font(.subheadline.weight(.semibold))
          Text("You can start another recording while this continues.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      .frame(maxWidth: .infinity, minHeight: 90, alignment: .center)
    case .queued:
      TranscriptEmptyState(
        title: "Queued for transcription",
        message: "MeetingBar will process this recording next.",
        symbol: "clock"
      )
    case .failed:
      TranscriptEmptyState(
        title: "Transcript unavailable",
        message: "Retry while the source audio is still available.",
        symbol: "exclamationmark.triangle"
      )
    }
  }
}

private struct SpeakerTranscriptView: View, Equatable {
  let transcript: String

  nonisolated static func == (lhs: SpeakerTranscriptView, rhs: SpeakerTranscriptView) -> Bool {
    lhs.transcript == rhs.transcript
  }

  var body: some View {
    let turns = TranscriptTurn.parse(transcript)
    if turns.contains(where: { $0.speakerID != nil }) {
      LazyVStack(alignment: .leading, spacing: 20) {
        ForEach(turns) { turn in
          HStack(alignment: .top, spacing: 13) {
            speakerAvatar(for: turn)
            VStack(alignment: .leading, spacing: 4) {
              if let speakerID = turn.speakerID {
                Text("Speaker \(speakerID)")
                  .font(.caption.weight(.bold))
                  .foregroundStyle(speakerColor(for: speakerID))
              }
              Text(turn.text)
                .font(.body)
                .lineSpacing(4)
            }
          }
        }
      }
      .textSelection(.enabled)
    } else {
      Text(transcript)
        .font(.body)
        .lineSpacing(5)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func speakerAvatar(for turn: TranscriptTurn) -> some View {
    let speakerID = turn.speakerID ?? 0
    return Text(turn.speakerID.map(String.init) ?? "•")
      .font(.caption.weight(.bold))
      .foregroundStyle(speakerColor(for: speakerID))
      .frame(width: 30, height: 30)
      .background(
        speakerColor(for: speakerID).opacity(0.12),
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
  }

  private func speakerColor(for speakerID: Int) -> Color {
    let colors = [
      MeetingBarTheme.accent,
      MeetingBarTheme.coral,
      MeetingBarTheme.mint,
      MeetingBarTheme.amber,
      Color.cyan,
      Color.pink,
    ]
    return colors[abs(speakerID) % colors.count]
  }
}

private struct TranscriptTurn: Identifiable {
  let id: Int
  let speakerID: Int?
  let text: String

  static func parse(_ transcript: String) -> [TranscriptTurn] {
    transcript
      .components(separatedBy: "\n\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .enumerated()
      .map { index, paragraph in
        guard paragraph.hasPrefix("Speaker "), let colon = paragraph.firstIndex(of: ":") else {
          return TranscriptTurn(id: index, speakerID: nil, text: paragraph)
        }
        let numberStart = paragraph.index(paragraph.startIndex, offsetBy: "Speaker ".count)
        let speakerID = Int(paragraph[numberStart..<colon])
        let textStart = paragraph.index(after: colon)
        let text = paragraph[textStart...].trimmingCharacters(in: .whitespacesAndNewlines)
        return TranscriptTurn(id: index, speakerID: speakerID, text: text)
      }
  }
}

private struct TranscriptEmptyState: View {
  let title: String
  let message: String
  let symbol: String

  var body: some View {
    VStack(spacing: 8) {
      MeetingBarIconTile(symbol: symbol, size: 42)
      Text(title)
        .font(.subheadline.weight(.semibold))
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, minHeight: 104)
  }
}

private struct DetailAlertCard<Actions: View>: View {
  let title: String
  let message: String
  let symbol: String
  let color: Color
  @ViewBuilder let actions: Actions

  init(
    title: String,
    message: String,
    symbol: String,
    color: Color,
    @ViewBuilder actions: () -> Actions
  ) {
    self.title = title
    self.message = message
    self.symbol = symbol
    self.color = color
    self.actions = actions()
  }

  var body: some View {
    HStack(alignment: .top, spacing: 13) {
      MeetingBarIconTile(symbol: symbol, color: color, size: 38)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        Text(message)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer()
      actions
    }
    .padding(15)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 15, style: .continuous)
        .stroke(color.opacity(0.16), lineWidth: 1)
    }
  }
}
