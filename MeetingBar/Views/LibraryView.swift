import SwiftData
import SwiftUI

struct LibraryView: View {
  @Environment(\.openSettings) private var openSettings
  @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
  @State private var searchText = ""
  @State private var selectedRecordingID: UUID?
  let controller: AppController

  private var filteredRecordings: [Recording] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !query.isEmpty else {
      return recordings
    }
    return recordings.filter { recording in
      recording.title.localizedCaseInsensitiveContains(query)
        || recording.transcript.localizedCaseInsensitiveContains(query)
    }
  }

  private var pinnedRecordings: [Recording] {
    filteredRecordings.filter(\.isPinned)
  }

  private var unpinnedRecordings: [Recording] {
    filteredRecordings.filter { !$0.isPinned }
  }

  private var orderedRecordings: [Recording] {
    pinnedRecordings + unpinnedRecordings
  }

  var body: some View {
    NavigationSplitView {
      librarySidebar
        .navigationSplitViewColumnWidth(min: 270, ideal: 310, max: 360)
    } detail: {
      ZStack {
        MeetingBarBackdrop()
        if let recording = recordings.first(where: { $0.id == selectedRecordingID }) {
          RecordingDetailView(recording: recording, controller: controller)
        } else {
          LibraryWelcomeView(hasRecordings: !recordings.isEmpty, controller: controller)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .meetingBarWindowTint()
    .toolbar {
      ToolbarItem {
        Button {
          openSettings()
        } label: {
          Label("Settings", systemImage: "slider.horizontal.3")
        }
        .help("MeetingBar Settings")
      }
    }
    .onAppear {
      selectFirstRecordingIfNeeded()
    }
    .onChange(of: orderedRecordings.map(\.id)) {
      selectFirstRecordingIfNeeded()
    }
  }

  private var librarySidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 11) {
        MeetingBarLogo(size: 38)
        VStack(alignment: .leading, spacing: 1) {
          Text("MeetingBar")
            .font(.headline)
          Label(
            controller.transcriptionPreferences.provider == .onDevice
              ? "Private · on this Mac"
              : "Cloud · ElevenLabs",
            systemImage: controller.transcriptionPreferences.provider == .onDevice
              ? "lock.fill"
              : "cloud.fill"
          )
            .font(.caption2)
            .foregroundStyle(.secondary)
        }
        Spacer()
      }
      .padding(.horizontal, 18)
      .padding(.top, 16)
      .padding(.bottom, 15)

      searchField
        .padding(.horizontal, 14)
        .padding(.bottom, 12)

      Divider()
        .opacity(0.55)

      ScrollView {
        LazyVStack(alignment: .leading, spacing: 5) {
          if filteredRecordings.isEmpty {
            SidebarEmptyState(isSearching: !searchText.isEmpty)
          } else {
            if !pinnedRecordings.isEmpty {
              sidebarSectionTitle("Pinned", symbol: "pin.fill")
              recordingRows(pinnedRecordings)
            }

            if !unpinnedRecordings.isEmpty {
              sidebarSectionTitle(
                pinnedRecordings.isEmpty ? "Meetings" : "Recent",
                symbol: "clock"
              )
              recordingRows(unpinnedRecordings)
            }
          }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 10)
      }

      Divider()
        .opacity(0.55)

      SidebarRecordingControl(controller: controller)
        .padding(12)
    }
    .background(.ultraThinMaterial)
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.tertiary)
      TextField("Search meetings", text: $searchText)
        .textFieldStyle(.plain)
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 11)
    .frame(height: 34)
    .background(MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
    }
  }

  private func sidebarSectionTitle(_ title: String, symbol: String) -> some View {
    Label(title.uppercased(), systemImage: symbol)
      .font(.caption2.weight(.bold))
      .tracking(0.7)
      .foregroundStyle(.tertiary)
      .padding(.horizontal, 9)
      .padding(.top, 9)
      .padding(.bottom, 3)
  }

  @ViewBuilder
  private func recordingRows(_ rows: [Recording]) -> some View {
    ForEach(rows) { recording in
      RecordingRow(
        recording: recording,
        controller: controller,
        isSelected: recording.id == selectedRecordingID
      ) {
        selectedRecordingID = recording.id
      }
    }
  }

  private func selectFirstRecordingIfNeeded() {
    guard selectedRecordingID == nil
      || !recordings.contains(where: { $0.id == selectedRecordingID })
    else {
      return
    }
    selectedRecordingID = orderedRecordings.first?.id ?? recordings.first?.id
  }
}

private struct RecordingRow: View {
  @Bindable var recording: Recording
  let controller: AppController
  let isSelected: Bool
  let onSelect: () -> Void
  @State private var isRenaming = false
  @State private var draftTitle = ""
  @State private var isHovering = false
  @FocusState private var isTitleFocused: Bool

  private var statusColor: Color {
    if recording.isCapturing {
      return MeetingBarTheme.coral
    }
    switch recording.status {
    case .queued, .transcribing:
      return MeetingBarTheme.amber
    case .ready:
      return MeetingBarTheme.accent
    case .failed:
      return MeetingBarTheme.coral
    }
  }

  private var statusSymbol: String {
    if recording.isCapturing {
      return "waveform"
    }
    switch recording.status {
    case .queued:
      return "clock"
    case .transcribing:
      return "sparkles"
    case .ready:
      return "text.alignleft"
    case .failed:
      return "exclamationmark"
    }
  }

  var body: some View {
    HStack(alignment: .top, spacing: 10) {
      MeetingBarIconTile(symbol: statusSymbol, color: statusColor, size: 34)
        .overlay(alignment: .topTrailing) {
          if recording.isPinned {
            Image(systemName: "pin.fill")
              .font(.system(size: 7, weight: .bold))
              .foregroundStyle(.white)
              .frame(width: 13, height: 13)
              .background(MeetingBarTheme.accent, in: Circle())
              .offset(x: 3, y: -3)
          }
        }

      VStack(alignment: .leading, spacing: 5) {
        HStack(spacing: 6) {
          if isRenaming {
            TextField("Meeting title", text: $draftTitle)
              .font(.subheadline.weight(.semibold))
              .textFieldStyle(.plain)
              .focused($isTitleFocused)
              .onSubmit {
                commitRename()
              }
              .onExitCommand {
                cancelRename()
              }
          } else {
            Text(recording.title)
              .font(.subheadline.weight(.semibold))
              .lineLimit(1)
              .truncationMode(.tail)
              .frame(maxWidth: .infinity, alignment: .leading)
              .help(recording.title)
          }

          if isHovering, !isRenaming {
            HStack(spacing: 3) {
              Button {
                beginRename()
              } label: {
                Image(systemName: "pencil")
                  .frame(width: 20, height: 20)
              }
              .help("Rename meeting")

              Button {
                togglePin()
              } label: {
                Image(systemName: recording.isPinned ? "pin.slash" : "pin")
                  .frame(width: 20, height: 20)
              }
              .help(recording.isPinned ? "Unpin meeting" : "Pin meeting")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .buttonStyle(.plain)
            .fixedSize()
          }
        }
        .frame(minHeight: 20)

        HStack(spacing: 5) {
          Circle()
            .fill(statusColor)
            .frame(width: 5, height: 5)
          if recording.status != .ready || recording.isCapturing {
            Text(recording.isCapturing ? "Recording" : recording.status.label)
          }
          Text(recording.startedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
          Text("·")
          Text(DurationText.string(seconds: recording.durationSeconds))
            .monospacedDigit()
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .background(
      isSelected ? MeetingBarTheme.accent.opacity(0.14) : Color.clear,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay {
      if isSelected {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
          .stroke(MeetingBarTheme.accent.opacity(0.20), lineWidth: 1)
      }
    }
    .onTapGesture {
      onSelect()
    }
    .onHover { hovering in
      isHovering = hovering
    }
    .onChange(of: isTitleFocused) { wasFocused, isFocused in
      if wasFocused, !isFocused, isRenaming {
        commitRename()
      }
    }
    .contextMenu {
      Button(recording.isPinned ? "Unpin" : "Pin") {
        togglePin()
      }
      Button("Rename") {
        beginRename()
      }
    }
    .accessibilityElement(children: .combine)
    .accessibilityAddTraits(isSelected ? [.isSelected] : [])
  }

  private func beginRename() {
    draftTitle = recording.title
    isRenaming = true
    Task { @MainActor in
      isTitleFocused = true
    }
  }

  private func commitRename() {
    guard isRenaming else {
      return
    }
    let title = draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    if !title.isEmpty, title != recording.title {
      controller.rename(recording, to: title)
    }
    isRenaming = false
    isTitleFocused = false
  }

  private func cancelRename() {
    draftTitle = recording.title
    isRenaming = false
    isTitleFocused = false
  }

  private func togglePin() {
    recording.isPinned.toggle()
    controller.save(recording)
  }
}

private struct SidebarEmptyState: View {
  let isSearching: Bool

  var body: some View {
    VStack(spacing: 9) {
      MeetingBarIconTile(
        symbol: isSearching ? "magnifyingglass" : "waveform",
        color: MeetingBarTheme.accent,
        size: 42
      )
      Text(isSearching ? "Nothing found" : "Your meetings live here")
        .font(.subheadline.weight(.semibold))
      Text(isSearching ? "Try a different phrase." : "Start a recording below.")
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .padding(.vertical, 36)
  }
}

private struct SidebarRecordingControl: View {
  let controller: AppController

  private var isTransitioning: Bool {
    controller.capture.state == .starting || controller.capture.state == .stopping
  }

  var body: some View {
    VStack(spacing: 9) {
      if controller.capture.state.isRecording {
        HStack {
          HStack(spacing: 6) {
            Circle()
              .fill(MeetingBarTheme.coral)
              .frame(width: 7, height: 7)
            Text("Recording")
              .font(.caption.weight(.semibold))
              .foregroundStyle(MeetingBarTheme.coral)
          }
          Spacer()
          Text(DurationText.string(seconds: controller.capture.elapsedSeconds))
            .font(.caption.monospacedDigit().weight(.medium))
            .foregroundStyle(.secondary)
        }

        MeetingBarAudioMeter(
          microphoneLevel: controller.capture.levels.microphone,
          systemLevel: controller.capture.levels.system,
          barCount: 26
        )
        .frame(height: 24)
      }

      Button {
        Task {
          await controller.toggleRecording()
        }
      } label: {
        Label(
          controller.capture.state.isRecording ? "Stop Recording" : "New Recording",
          systemImage: controller.capture.state.isRecording ? "stop.fill" : "record.circle"
        )
      }
      .buttonStyle(
        MeetingBarPrimaryButtonStyle(isRecording: controller.capture.state.isRecording)
      )
      .disabled(isTransitioning)
    }
  }
}

private struct LibraryWelcomeView: View {
  let hasRecordings: Bool
  let controller: AppController

  var body: some View {
    VStack(spacing: 24) {
      ZStack {
        Circle()
          .fill(MeetingBarTheme.accent.opacity(0.09))
          .frame(width: 142, height: 142)
        Circle()
          .stroke(MeetingBarTheme.accent.opacity(0.12), lineWidth: 1)
          .frame(width: 108, height: 108)
        MeetingBarLogo(size: 68)
      }

      VStack(spacing: 8) {
        Text(hasRecordings ? "Choose a meeting" : "Remember every conversation")
          .font(.system(size: 30, weight: .bold, design: .rounded))
        Text(
          hasRecordings
            ? "Its transcript, speakers, and source audio will appear here."
            : controller.transcriptionPreferences.provider == .onDevice
              ? "Capture your microphone and Mac audio, then search the transcript later. Everything stays on this Mac."
              : "Capture your microphone and Mac audio, then let ElevenLabs create a searchable transcript after Stop."
        )
        .font(.body)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: 480)
      }

      if !hasRecordings {
        Button {
          Task {
            await controller.toggleRecording()
          }
        } label: {
          Label("Start Your First Recording", systemImage: "record.circle")
        }
        .buttonStyle(MeetingBarPrimaryButtonStyle())
        .frame(width: 230)
        .disabled(controller.capture.state.isBusy)
      }

      HStack(spacing: 22) {
        Label("Microphone + system audio", systemImage: "waveform")
        Label("On-device transcription", systemImage: "lock.shield")
      }
      .font(.caption)
      .foregroundStyle(.tertiary)
    }
    .padding(42)
  }
}

struct StatusBadge: View {
  let recording: Recording

  private var label: String {
    if recording.isCapturing {
      return "Recording"
    }
    return recording.status.label
  }

  private var symbol: String {
    if recording.isCapturing {
      return "record.circle.fill"
    }
    switch recording.status {
    case .queued:
      return "clock"
    case .transcribing:
      return "sparkles"
    case .ready:
      return "checkmark"
    case .failed:
      return "exclamationmark.triangle.fill"
    }
  }

  private var tone: MeetingBarStatusTone {
    if recording.isCapturing {
      return .recording
    }
    switch recording.status {
    case .queued, .transcribing:
      return .warning
    case .ready:
      return .success
    case .failed:
      return .recording
    }
  }

  var body: some View {
    MeetingBarPill(text: label, symbol: symbol, tone: tone)
  }
}
