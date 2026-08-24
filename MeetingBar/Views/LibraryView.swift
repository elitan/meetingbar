import SwiftData
import SwiftUI

struct LibraryView: View {
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
      List(selection: $selectedRecordingID) {
        if pinnedRecordings.isEmpty {
          recordingRows(unpinnedRecordings)
        } else {
          Section("Pinned") {
            recordingRows(pinnedRecordings)
          }
          if !unpinnedRecordings.isEmpty {
            Section("Meetings") {
              recordingRows(unpinnedRecordings)
            }
          }
        }
      }
      .navigationTitle("Meetings")
      .searchable(text: $searchText, prompt: "Search titles and transcripts")
      .overlay {
        if filteredRecordings.isEmpty {
          ContentUnavailableView(
            searchText.isEmpty ? "No meetings yet" : "No results",
            systemImage: searchText.isEmpty ? "waveform" : "magnifyingglass",
            description: Text(
              searchText.isEmpty
                ? "Start a recording from the menu bar or global shortcut."
                : "Try another title or transcript phrase."
            )
          )
        }
      }
    } detail: {
      if let recording = recordings.first(where: { $0.id == selectedRecordingID }) {
        RecordingDetailView(recording: recording, controller: controller)
      } else {
        ContentUnavailableView(
          "Select a meeting",
          systemImage: "text.bubble",
          description: Text("Its transcript and source audio controls will appear here.")
        )
      }
    }
    .navigationSplitViewStyle(.balanced)
    .onAppear {
      if selectedRecordingID == nil {
        selectedRecordingID = orderedRecordings.first?.id
      }
    }
  }

  @ViewBuilder
  private func recordingRows(_ rows: [Recording]) -> some View {
    ForEach(rows) { recording in
      RecordingRow(recording: recording, controller: controller)
        .tag(recording.id)
    }
  }
}

private struct RecordingRow: View {
  @Bindable var recording: Recording
  let controller: AppController
  @State private var isRenaming = false
  @State private var draftTitle = ""
  @State private var isHovering = false
  @FocusState private var isTitleFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 6) {
        if isRenaming {
          TextField("Meeting title", text: $draftTitle)
            .font(.headline)
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
            .font(.headline)
            .lineLimit(1)
            .onTapGesture(count: 2) {
              beginRename()
            }
        }

        Spacer(minLength: 4)

        if recording.isPinned || isHovering {
          Button {
            togglePin()
          } label: {
            Image(systemName: recording.isPinned ? "pin.fill" : "pin")
              .foregroundStyle(recording.isPinned ? Color.accentColor : Color.secondary)
          }
          .buttonStyle(.plain)
          .help(recording.isPinned ? "Unpin meeting" : "Pin meeting")
        }
      }
      HStack(spacing: 6) {
        StatusBadge(recording: recording)
        Text(recording.startedAt, format: .dateTime.year().month().day().hour().minute())
        Text("·")
        Text(DurationText.string(seconds: recording.durationSeconds))
          .monospacedDigit()
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 4)
    .contentShape(Rectangle())
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

struct StatusBadge: View {
  let recording: Recording

  private var label: String {
    if recording.isCapturing {
      return "Recording"
    }
    return recording.status.label
  }

  private var color: Color {
    if recording.isCapturing {
      return .red
    }
    switch recording.status {
    case .queued, .transcribing:
      return .orange
    case .ready:
      return .green
    case .failed:
      return .red
    }
  }

  var body: some View {
    Text(label)
      .font(.caption2.weight(.semibold))
      .foregroundStyle(color)
  }
}
