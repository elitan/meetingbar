import AppKit
import KeyboardShortcuts
import SwiftData
import SwiftUI

struct LibraryView: View {
  @Query(sort: \Recording.startedAt, order: .reverse) private var recordings: [Recording]
  @State private var searchText = ""
  @State private var pendingDeletion: Recording?
  @State private var deletionError: String?
  @FocusState private var isSearchFocused: Bool
  @FocusState private var isListFocused: Bool
  private var audioPlayback: AudioPlaybackController { controller.audioPlayback }
  let controller: AppController
  @Bindable var navigation: MeetingBarNavigation

  private var searchQuery: String {
    searchText.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private var filteredRecordings: [Recording] {
    guard !searchQuery.isEmpty else {
      return recordings
    }
    return recordings.filter { recording in
      recording.title.localizedCaseInsensitiveContains(searchQuery)
        || recording.transcript.localizedCaseInsensitiveContains(searchQuery)
    }
  }

  /// Date groups while browsing; a single flat result list while searching.
  private var sections: [LibrarySection] {
    guard !searchQuery.isEmpty else {
      return LibraryGrouping.sections(for: recordings)
    }
    let results = filteredRecordings
    guard !results.isEmpty else {
      return []
    }
    return [
      LibrarySection(
        title: results.count == 1 ? "1 Result" : "\(results.count) Results",
        recordings: results
      )
    ]
  }

  private var selectedRecording: Recording? {
    recordings.first(where: { $0.id == navigation.selectedRecordingID })
  }

  var body: some View {
    NavigationSplitView {
      librarySidebar
        .navigationSplitViewColumnWidth(min: 250, ideal: 290, max: 360)
    } detail: {
      switch navigation.workspace {
      case .library:
        ZStack {
          MeetingBarBackdrop()
          if let recording = selectedRecording {
            RecordingDetailView(
              recording: recording,
              controller: controller,
              audioPlayback: audioPlayback,
              highlight: searchQuery,
              onDelete: { pendingDeletion = recording }
            )
          } else {
            LibraryWelcomeView(hasRecordings: !recordings.isEmpty, controller: controller)
          }
        }
      case .settings:
        SettingsView(controller: controller, selectedSection: $navigation.settingsSection)
      }
    }
    .navigationSplitViewStyle(.balanced)
    .meetingBarWindowTint()
    .onAppear {
      selectFirstRecordingIfNeeded()
      focusSearchIfRequested()
    }
    .onChange(of: recordings.map(\.id)) {
      selectFirstRecordingIfNeeded()
    }
    .onChange(of: navigation.wantsSearchFocus) {
      focusSearchIfRequested()
    }
    .alert(
      "Delete this meeting?",
      isPresented: Binding(
        get: { pendingDeletion != nil },
        set: { if !$0 { pendingDeletion = nil } }
      ),
      presenting: pendingDeletion
    ) { recording in
      Button("Cancel", role: .cancel) {}
      Button("Delete", role: .destructive) {
        delete(recording)
      }
    } message: { recording in
      Text(
        "“\(recording.title)” and all of its transcript and audio files will be removed immediately. This cannot be undone."
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
  }

  private var librarySidebar: some View {
    VStack(spacing: 0) {
      HStack(spacing: 11) {
        MeetingBarLogo(size: 28)
        VStack(alignment: .leading, spacing: 1) {
          Text("MeetingBar")
            .font(.system(size: 17, weight: .semibold))
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
      .padding(.bottom, 12)

      if navigation.workspace == .library {
        libraryNavigation
      } else {
        settingsNavigation
      }

      Divider()
        .opacity(0.55)

      SidebarRecordingControl(controller: controller)
        .padding(.horizontal, 14)
        .padding(.top, 14)

      Button {
        if navigation.workspace == .library {
          navigation.showSettings()
        } else {
          navigation.showLibrary()
        }
      } label: {
        Label(
          navigation.workspace == .library ? "Settings" : "Back to Library",
          systemImage: navigation.workspace == .library ? "gearshape" : "arrow.left"
        )
        .font(.subheadline)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .frame(height: 36)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .padding(.horizontal, 14)
      .padding(.vertical, 8)
    }
    .background(MeetingBarTheme.sidebar)
  }

  private var libraryNavigation: some View {
    VStack(spacing: 0) {
      searchField
        .padding(.horizontal, 14)
        .padding(.vertical, 12)

      if sections.isEmpty {
        SidebarEmptyState(isSearching: !searchQuery.isEmpty)
        Spacer(minLength: 0)
      } else {
        ScrollViewReader { proxy in
          ScrollView {
            LazyVStack(alignment: .leading, spacing: 5) {
              ForEach(sections) { section in
                sidebarSectionTitle(section.title)
                ForEach(section.recordings) { recording in
                  RecordingRow(
                    recording: recording,
                    controller: controller,
                    searchQuery: searchQuery,
                    isSelected: recording.id == navigation.selectedRecordingID,
                    onDelete: { pendingDeletion = recording }
                  ) {
                    navigation.selectedRecordingID = recording.id
                    isListFocused = true
                  }
                  .id(recording.id)
                }
              }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 10)
          }
          // Keyboard support for the meeting list: arrows move, Delete asks to delete, Space plays.
          .focusable()
          .focusEffectDisabled()
          .focused($isListFocused)
          .onKeyPress(.upArrow) {
            moveSelection(by: -1, proxy: proxy)
          }
          .onKeyPress(.downArrow) {
            moveSelection(by: 1, proxy: proxy)
          }
          .onKeyPress(.space) {
            // Leave Space alone while renaming a meeting inline.
            guard !(NSApp.keyWindow?.firstResponder is NSTextView),
              let recording = selectedRecording,
              controller.audioURL(for: recording) != nil
            else {
              return .ignored
            }
            controller.togglePlayback(for: recording)
            return .handled
          }
          .onDeleteCommand {
            if let recording = selectedRecording, !recording.isCapturing {
              pendingDeletion = recording
            }
          }
        }
      }
    }
  }

  private func moveSelection(by offset: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
    guard !(NSApp.keyWindow?.firstResponder is NSTextView) else {
      return .ignored
    }
    let ids = sections.flatMap { $0.recordings.map(\.id) }
    guard !ids.isEmpty else {
      return .ignored
    }
    let current = ids.firstIndex(where: { $0 == navigation.selectedRecordingID })
    let next = current.map { min(max($0 + offset, 0), ids.count - 1) } ?? 0
    navigation.selectedRecordingID = ids[next]
    proxy.scrollTo(ids[next])
    return .handled
  }

  private var settingsNavigation: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 5) {
        sidebarSectionTitle("Settings")
        ForEach(SettingsSection.allCases) { section in
          Button {
            navigation.showSettings(section)
          } label: {
            HStack(spacing: 11) {
              Image(systemName: section.symbol)
                .foregroundStyle(.secondary)
                .frame(width: 22)
              Text(section.title)
                .font(.subheadline.weight(.semibold))
              Spacer()
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.bold))
                .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .background(
              navigation.settingsSection == section
                ? MeetingBarTheme.selection
                : Color.clear,
              in: RoundedRectangle(cornerRadius: 8, style: .continuous)
            )
          }
          .buttonStyle(.plain)
        }
      }
      .padding(.horizontal, 9)
      .padding(.vertical, 10)
    }
  }

  private var searchField: some View {
    HStack(spacing: 8) {
      Image(systemName: "magnifyingglass")
        .foregroundStyle(.tertiary)
      TextField("Search meetings", text: $searchText)
        .textFieldStyle(.plain)
        .focused($isSearchFocused)
        .onSubmit {
          isListFocused = true
        }
        .onKeyPress(.downArrow) {
          isListFocused = true
          return .handled
        }
        .onExitCommand {
          searchText = ""
          isSearchFocused = false
        }
      if !searchText.isEmpty {
        Button {
          searchText = ""
        } label: {
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Clear search")
      } else if !isSearchFocused {
        Text("⌘F")
          .font(.caption2.weight(.medium))
          .foregroundStyle(.tertiary)
          .padding(.horizontal, 5)
          .padding(.vertical, 2)
          .overlay {
            RoundedRectangle(cornerRadius: 4, style: .continuous)
              .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
          }
          .accessibilityHidden(true)
      }
    }
    .font(.subheadline)
    .padding(.horizontal, 11)
    .frame(height: 34)
    .background(
      MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .overlay {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .stroke(
          isSearchFocused ? MeetingBarTheme.accent.opacity(0.35) : MeetingBarTheme.subtleBorder,
          lineWidth: 1
        )
    }
  }

  private func sidebarSectionTitle(_ title: String) -> some View {
    Text(title.uppercased())
      .font(.system(size: 10, weight: .medium))
      .tracking(1)
      .foregroundStyle(.secondary)
      .padding(.horizontal, 9)
      .padding(.top, 9)
      .padding(.bottom, 3)
  }

  private func delete(_ recording: Recording) {
    do {
      if navigation.selectedRecordingID == recording.id {
        audioPlayback.unload()
      }
      try controller.delete(recording)
    } catch {
      deletionError = error.localizedDescription
    }
  }

  private func selectFirstRecordingIfNeeded() {
    guard selectedRecording == nil else {
      return
    }
    navigation.selectedRecordingID = sections.first?.recordings.first?.id ?? recordings.first?.id
  }

  private func focusSearchIfRequested() {
    guard navigation.wantsSearchFocus else {
      return
    }
    navigation.wantsSearchFocus = false
    Task { @MainActor in
      isSearchFocused = true
    }
  }
}

struct LibrarySection: Identifiable {
  let title: String
  let recordings: [Recording]
  var id: String { title }
}

enum LibraryGrouping {
  /// Groups newest-first recordings into Pinned, then Today, Yesterday, Previous 7 Days,
  /// Previous 30 Days, and one section per older month.
  static func sections(
    for recordings: [Recording],
    now: Date = .now,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> [LibrarySection] {
    var sections: [(title: String, recordings: [Recording])] = []
    let pinned = recordings.filter(\.isPinned)
    if !pinned.isEmpty {
      sections.append(("Pinned", pinned))
    }

    let startOfToday = calendar.startOfDay(for: now)
    func daysBefore(_ days: Int) -> Date {
      calendar.date(byAdding: .day, value: -days, to: startOfToday) ?? startOfToday
    }

    for recording in recordings where !recording.isPinned {
      let date = recording.startedAt
      let title: String
      if date >= startOfToday {
        title = "Today"
      } else if date >= daysBefore(1) {
        title = "Yesterday"
      } else if date >= daysBefore(7) {
        title = "Previous 7 Days"
      } else if date >= daysBefore(30) {
        title = "Previous 30 Days"
      } else {
        var style = Date.FormatStyle(locale: locale).month(.wide)
        if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
          style = style.year()
        }
        style.timeZone = calendar.timeZone
        title = date.formatted(style)
      }

      // Recordings arrive newest first, so each group is a contiguous run.
      if sections.last?.title == title {
        sections[sections.count - 1].recordings.append(recording)
      } else {
        sections.append((title, [recording]))
      }
    }
    return sections.map { LibrarySection(title: $0.title, recordings: $0.recordings) }
  }
}

enum TranscriptSearch {
  /// A short excerpt around the first match, without speaker labels, to show why a meeting matched.
  static func snippet(in transcript: String, matching query: String, radius: Int = 40) -> String? {
    let text =
      transcript
      .replacing(#/Speaker \d+:\s*/#, with: "")
      .replacing(#/\s+/#, with: " ")
    guard !query.isEmpty,
      let match = text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive])
    else {
      return nil
    }
    let start =
      text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex)
      ?? text.startIndex
    let end =
      text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex)
      ?? text.endIndex
    var snippet = text[start..<end].trimmingCharacters(in: .whitespaces)
    if start > text.startIndex { snippet = "…" + snippet }
    if end < text.endIndex { snippet += "…" }
    return snippet
  }

  /// Applies `attributes` to every case-insensitive occurrence of `query` in `text`.
  static func highlighted(
    _ text: String,
    matching query: String,
    with attributes: AttributeContainer
  ) -> AttributedString {
    var attributed = AttributedString(text)
    guard !query.isEmpty else {
      return attributed
    }
    var searchStart = attributed.startIndex
    while let range = attributed[searchStart...].range(
      of: query, options: [.caseInsensitive, .diacriticInsensitive])
    {
      attributed[range].mergeAttributes(attributes)
      searchStart = range.upperBound
    }
    return attributed
  }
}

private struct RecordingRow: View {
  @Bindable var recording: Recording
  let controller: AppController
  let searchQuery: String
  let isSelected: Bool
  let onDelete: () -> Void
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
      return MeetingBarTheme.mint
    case .failed:
      return MeetingBarTheme.coral
    }
  }

  /// Shown when a search matched the transcript rather than the title.
  private var searchSnippet: AttributedString? {
    guard !searchQuery.isEmpty,
      !recording.title.localizedCaseInsensitiveContains(searchQuery),
      let snippet = TranscriptSearch.snippet(in: recording.transcript, matching: searchQuery)
    else {
      return nil
    }
    var match = AttributeContainer()
    match.foregroundColor = MeetingBarTheme.text
    match.font = .caption.weight(.semibold)
    return TranscriptSearch.highlighted(snippet, matching: searchQuery, with: match)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
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

        // Always reserve the action width. Hover changes visibility, never layout.
        HStack(spacing: 3) {
          Button {
            beginRename()
          } label: {
            Image(systemName: "pencil")
              .frame(width: 20, height: 20)
          }
          .help("Rename meeting")
          .opacity(isHovering && !isRenaming ? 1 : 0)
          .allowsHitTesting(isHovering && !isRenaming)
          .accessibilityHidden(!isHovering || isRenaming)

          Button {
            togglePin()
          } label: {
            Image(systemName: recording.isPinned ? "pin.fill" : "pin")
              .frame(width: 20, height: 20)
          }
          .help(recording.isPinned ? "Unpin meeting" : "Pin meeting")
          .opacity(!isRenaming && (isHovering || recording.isPinned) ? 1 : 0)
          .allowsHitTesting(!isRenaming && (isHovering || recording.isPinned))
          .accessibilityHidden(isRenaming || (!isHovering && !recording.isPinned))
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .buttonStyle(.plain)
        .fixedSize()
      }
      .frame(minHeight: 20)

      HStack(spacing: 5) {
        Circle()
          .fill(statusColor)
          .frame(width: 5, height: 5)
        if recording.status != .ready || recording.isCapturing {
          Text(recording.isCapturing ? "Recording" : recording.status.label)
          Text("·")
        }
        Text(MeetingDateText.string(for: recording.startedAt))
        Text("·")
        Text(DurationText.compact(seconds: recording.durationSeconds))
          .monospacedDigit()
      }
      .font(.caption2)
      .foregroundStyle(.secondary)
      .lineLimit(1)

      if let searchSnippet {
        Text(searchSnippet)
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 9)
    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    .background(
      isSelected ? MeetingBarTheme.selection : isHovering ? MeetingBarTheme.quietFill : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
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
      Divider()
      Button("Delete Meeting…", systemImage: "trash", role: .destructive, action: onDelete)
        .disabled(recording.isCapturing)
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
        HStack {
          Label(
            controller.capture.state.isRecording ? "Stop Recording" : "New Recording",
            systemImage: controller.capture.state.isRecording ? "stop.fill" : "record.circle"
          )
          if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleMeetingRecording) {
            Spacer(minLength: 6)
            Text(shortcut.description)
              .font(.caption.weight(.medium))
              .opacity(0.6)
          }
        }
      }
      .buttonStyle(
        MeetingBarPrimaryButtonStyle(isRecording: controller.capture.state.isRecording)
      )
      .disabled(isTransitioning)
      .help("Works from any app with the global shortcut")
    }
  }
}

private struct LibraryWelcomeView: View {
  let hasRecordings: Bool
  let controller: AppController

  var body: some View {
    VStack(spacing: 24) {
      MeetingBarLogo(size: 54)

      VStack(spacing: 8) {
        Text(hasRecordings ? "Choose a meeting" : "Remember every conversation")
          .font(.system(size: 28, weight: .semibold))
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
        Label(
          controller.transcriptionPreferences.provider == .onDevice
            ? "On-device transcription" : "ElevenLabs transcription",
          systemImage: controller.transcriptionPreferences.provider == .onDevice
            ? "lock.shield" : "cloud"
        )
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
