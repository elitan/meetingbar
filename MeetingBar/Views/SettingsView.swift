import SwiftUI

struct SettingsView: View {
  let controller: AppController
  @State private var microphoneGranted = AudioCaptureController.hasMicrophonePermission
  @State private var screenGranted = AudioCaptureController.hasScreenPermission

  var body: some View {
    Form {
      Section("Recording shortcut") {
        LabeledContent("Toggle recording") {
          MeetingShortcutRecorder()
        }
        Text("MeetingBar keeps the last working shortcut when macOS or another registered shortcut rejects a new combination.")
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
        Text("Ready transcripts are kept indefinitely. Their source audio is deleted 30 days after the meeting ends. Audio for queued or failed transcripts is never deleted automatically.")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Section("Recording consent") {
        Text("Only record when everyone involved has been informed and recording is lawful in your location and context.")
      }
    }
    .formStyle(.grouped)
    .frame(width: 520, height: 520)
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
      Label("Ready — \(TranscriptionQueue.modelIdentifier)", systemImage: "checkmark.circle.fill")
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
