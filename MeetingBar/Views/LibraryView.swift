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

  var body: some View {
    NavigationSplitView {
      List(filteredRecordings, selection: $selectedRecordingID) { recording in
        RecordingRow(recording: recording)
          .tag(recording.id)
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
        selectedRecordingID = recordings.first?.id
      }
    }
  }
}

private struct RecordingRow: View {
  let recording: Recording

  var body: some View {
    VStack(alignment: .leading, spacing: 5) {
      Text(recording.title)
        .font(.headline)
        .lineLimit(1)
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

