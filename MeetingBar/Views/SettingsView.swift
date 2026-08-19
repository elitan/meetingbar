import SwiftUI

struct SettingsView: View {
  let controller: AppController
  @State private var microphoneGranted = AudioCaptureController.hasMicrophonePermission
  @State private var screenGranted = AudioCaptureController.hasScreenPermission

  var body: some View {
    Form {
      Section("Microphone priority") {
        if let activeMicrophone = controller.microphonePreferences.activeMicrophone {
          Label("Using \(activeMicrophone.name)", systemImage: "mic.fill")
            .foregroundStyle(.green)
        } else {
          Label("No microphone connected", systemImage: "mic.slash")
            .foregroundStyle(.orange)
        }

        Text(
          "MeetingBar uses the first connected microphone in this list. Unavailable devices stay in place, so a preferred microphone automatically takes over when it reconnects."
        )
        .font(.caption)
        .foregroundStyle(.secondary)

        if controller.microphonePreferences.microphones.isEmpty {
          Text("Connect a microphone, then refresh this list.")
            .foregroundStyle(.secondary)
        } else {
          ForEach(
            Array(controller.microphonePreferences.microphones.enumerated()),
            id: \.element.id
          ) { index, microphone in
            microphoneRow(microphone, index: index)
          }
        }

        Button("Refresh Microphones") {
          controller.refreshMicrophones()
        }
      }

      Section("Recording shortcut") {
        LabeledContent("Toggle recording") {
          MeetingShortcutRecorder()
        }
        Text(
          "MeetingBar keeps the last working shortcut when macOS or another registered shortcut rejects a new combination."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Permissions") {
        permissionRow(
          title: "Microphone",
          granted: microphoneGranted,
          actionTitle: "Request"
        ) {
          Task {
            microphoneGranted = await controller.requestMicrophonePermission()
          }
        }
        permissionRow(
          title: "Screen & System Audio Recording",
          granted: screenGranted,
          actionTitle: "Request"
        ) {
          screenGranted = controller.requestScreenPermission()
        }
        Button("Refresh Permission Status") {
          microphoneGranted = AudioCaptureController.hasMicrophonePermission
          screenGranted = AudioCaptureController.hasScreenPermission
        }
      }

      Section("Transcription accuracy") {
        Picker(
          "Meeting language",
          selection: Binding(
            get: { controller.transcriptionPreferences.language },
            set: { controller.setTranscriptionLanguage($0) }
          )
        ) {
          ForEach(TranscriptionLanguagePreference.allCases) { language in
            Text(language.label).tag(language)
          }
        }

        Picker(
          "Model",
          selection: Binding(
            get: { controller.transcriptionPreferences.quality },
            set: { controller.setTranscriptionQuality($0) }
          )
        ) {
          ForEach(TranscriptionQuality.allCases) { quality in
            Text(quality.label).tag(quality)
          }
        }

        Text(controller.transcriptionPreferences.quality.detail)
          .font(.caption)
          .foregroundStyle(.secondary)
        Text(
          "Automatic is recommended for mixed or unknown-language meetings. Choose Swedish or English only if automatic detection picks the wrong language."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("On-device model") {
        modelStatus
        if controller.modelReadiness != .ready {
          Button("Download or Prepare Model") {
            Task {
              await controller.prepareModel()
            }
          }
        }
      }

      Section("Startup and storage") {
        Toggle(
          "Launch MeetingBar at login",
          isOn: Binding(
            get: { controller.launchAtLoginEnabled },
            set: { _ = controller.setLaunchAtLogin($0) }
          )
        )
        Text(
          "Ready transcripts are kept indefinitely. Their source audio is deleted 30 days after the meeting ends. Audio for queued or failed transcripts is never deleted automatically."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Section("Recording consent") {
        Text(
          "Only record when everyone involved has been informed and recording is lawful in your location and context."
        )
      }
    }
    .formStyle(.grouped)
    .frame(width: 580, height: 780)
  }

  private func microphoneRow(
    _ microphone: MicrophonePreference,
    index: Int
  ) -> some View {
    HStack(spacing: 10) {
      Text("\(index + 1)")
        .monospacedDigit()
        .foregroundStyle(.secondary)
        .frame(width: 18, alignment: .trailing)

      VStack(alignment: .leading, spacing: 2) {
        Text(microphone.name)
        Text(
          microphone.isConnected
            ? "Connected"
            : "Unavailable · last seen \(microphone.lastSeenAt.formatted(date: .abbreviated, time: .omitted))"
        )
        .font(.caption)
        .foregroundStyle(microphone.isConnected ? Color.secondary : Color.orange)
      }

      Spacer()

      if microphone.id == controller.microphonePreferences.activeMicrophoneID {
        Text("In use")
          .font(.caption)
          .foregroundStyle(.green)
      }

      Button {
        controller.prioritizeMicrophone(microphone.id)
      } label: {
        Image(systemName: "arrow.up.to.line")
      }
      .disabled(index == 0)
      .help("Make highest priority")

      Button {
        controller.moveMicrophoneUp(microphone.id)
      } label: {
        Image(systemName: "chevron.up")
      }
      .disabled(index == 0)
      .help("Move up")

      Button {
        controller.moveMicrophoneDown(microphone.id)
      } label: {
        Image(systemName: "chevron.down")
      }
      .disabled(index == controller.microphonePreferences.microphones.count - 1)
      .help("Move down")

      if !microphone.isConnected {
        Button(role: .destructive) {
          controller.forgetMicrophone(microphone.id)
        } label: {
          Image(systemName: "trash")
        }
        .help("Forget microphone")
      }
    }
    .buttonStyle(.borderless)
  }

  @ViewBuilder
  private var modelStatus: some View {
    switch controller.modelReadiness {
    case .notDownloaded:
      Label("Not prepared", systemImage: "arrow.down.circle")
    case .downloading(let progress):
      VStack(alignment: .leading) {
        ProgressView(value: progress)
        Text("Downloading \(Int(progress * 100))%")
          .font(.caption)
      }
    case .ready:
      Label(
        "Ready — \(controller.transcriptionPreferences.quality.modelIdentifier)",
        systemImage: "checkmark.circle.fill"
      )
      .foregroundStyle(.green)
    case .failed(let message):
      Label(message, systemImage: "exclamationmark.triangle")
        .foregroundStyle(.orange)
    }
  }

  private func permissionRow(
    title: String,
    granted: Bool,
    actionTitle: String,
    action: @escaping () -> Void
  ) -> some View {
    HStack {
      Label(title, systemImage: granted ? "checkmark.circle.fill" : "xmark.circle")
        .foregroundStyle(granted ? .green : .secondary)
      Spacer()
      if !granted {
        Button(actionTitle, action: action)
      }
    }
  }
}
