import AppKit
import SwiftUI

struct MenuBarStatusLabel: View {
  @Environment(\.openWindow) private var openWindow
  let controller: AppController

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: controller.capture.state.isRecording ? "record.circle.fill" : "waveform")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(controller.capture.state.isRecording ? .red : .primary)
      if controller.capture.state.isRecording {
        Text(DurationText.string(seconds: controller.capture.elapsedSeconds))
          .monospacedDigit()
      }
    }
    .task {
      await controller.launch()
      if !controller.onboardingComplete {
        openWindow(id: "onboarding")
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
    }
  }
}

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  let controller: AppController

  var body: some View {
    if controller.capture.state.isRecording {
      Text("Recording · \(DurationText.string(seconds: controller.capture.elapsedSeconds))")
        .foregroundStyle(.red)
    } else if controller.capture.state == .starting {
      Text("Starting…")
    } else if controller.capture.state == .stopping {
      Text("Stopping…")
    } else {
      Text("Ready")
    }

    Button(controller.capture.state.isRecording ? "Stop Recording" : "Start Recording") {
      Task {
        await controller.toggleRecording()
      }
    }
    .disabled(controller.capture.state == .starting || controller.capture.state == .stopping)

    Menu {
      if controller.microphonePreferences.connectedMicrophones.isEmpty {
        Text("No microphone connected")
      } else {
        ForEach(controller.microphonePreferences.connectedMicrophones) { microphone in
          Button {
            controller.prioritizeMicrophone(microphone.id)
          } label: {
            Label(
              microphone.name,
              systemImage: microphone.id == controller.microphonePreferences.activeMicrophoneID
                ? "checkmark.circle.fill" : "mic"
            )
          }
        }
      }

      if !controller.microphonePreferences.unavailableMicrophones.isEmpty {
        Divider()
        Text(
          "\(controller.microphonePreferences.unavailableMicrophones.count) unavailable microphone\(controller.microphonePreferences.unavailableMicrophones.count == 1 ? "" : "s") remembered"
        )
      }

      Divider()
      Button("Manage Microphone Priority…") {
        openSettings()
        NSApplication.shared.activate(ignoringOtherApps: true)
      }
    } label: {
      Label("Microphone: \(displayedMicrophoneName)", systemImage: "mic")
    }

    if let warning = controller.capture.latestWarning, controller.capture.state.isRecording {
      Text(warning)
    }

    if let error = controller.lastErrorMessage {
      Divider()
      Text(error)
      Button("Dismiss Error") {
        controller.clearError()
      }
    }

    Divider()

    Button("Open Library") {
      openWindow(id: "library")
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    Button("Settings…") {
      openSettings()
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    Divider()

    Button("Quit MeetingBar") {
      Task {
        await controller.quit()
      }
    }
  }

  private var displayedMicrophoneName: String {
    if let activeMicrophoneName = controller.capture.activeMicrophoneName {
      return activeMicrophoneName
    }
    return controller.microphonePreferences.activeMicrophone?.name ?? "None"
  }
}
