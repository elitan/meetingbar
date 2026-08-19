import SwiftData
import SwiftUI

struct RecordingDetailView: View {
  @Bindable var recording: Recording
  let controller: AppController
  @State private var confirmsDeletion = false
  @State private var deletionError: String?

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        TextField("Meeting title", text: $recording.title)
          .font(.title2.weight(.semibold))
          .textFieldStyle(.plain)
          .onSubmit {
            controller.save(recording)
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
          DisclosureGroup("Capture warnings (\(recording.captureWarnings.count))") {
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
          }
          .padding(4)
          .frame(maxWidth: .infinity, alignment: .leading)
        }

        GroupBox("Source audio") {
          HStack {
            if controller.audioURL(for: recording) != nil {
              Button("Play", systemImage: "play.fill") {
                controller.playAudio(for: recording)
              }
              Button("Reveal in Finder", systemImage: "folder") {
                controller.revealAudio(for: recording)
              }
              Spacer()
              if let expiry = recording.audioExpiresAt {
                Text("Deletes \(expiry, format: .dateTime.year().month().day())")
                  .foregroundStyle(.secondary)
              }
            } else {
              Label("Audio deleted; transcript retained", systemImage: "checkmark.circle")
                .foregroundStyle(.secondary)
            }
          }
          .padding(4)
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
          try controller.delete(recording)
        } catch {
          deletionError = error.localizedDescription
        }
      }
    } message: {
      Text("The transcript and any source audio will be removed immediately. This cannot be undone.")
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
}
