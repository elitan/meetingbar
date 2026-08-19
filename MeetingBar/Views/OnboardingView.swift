import AppKit
import SwiftUI

struct OnboardingView: View {
  @Environment(\.dismissWindow) private var dismissWindow
  let controller: AppController
  @State private var consentAccepted = false
  @State private var microphoneGranted = AudioCaptureController.hasMicrophonePermission
  @State private var screenGranted = AudioCaptureController.hasScreenPermission
  @State private var launchAtLogin = true

  private var canFinish: Bool {
    consentAccepted && microphoneGranted && screenGranted && controller.modelReadiness == .ready
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      VStack(alignment: .leading, spacing: 6) {
        Image(systemName: "waveform.circle.fill")
          .font(.system(size: 44))
        Text("MeetingBar")
          .font(.largeTitle.bold())
        Text(
          "One shortcut records the room and your calls, then transcribes everything on this Mac."
        )
        .foregroundStyle(.secondary)
      }

      Divider()

      setupRow(number: 1, title: "Recording consent") {
        Toggle(
          "I will inform participants and only record when it is lawful.",
          isOn: $consentAccepted
        )
      }

      setupRow(number: 2, title: "Permissions") {
        VStack(alignment: .leading, spacing: 8) {
          permissionButton("Microphone", granted: microphoneGranted) {
            Task {
              microphoneGranted = await controller.requestMicrophonePermission()
            }
          }
          permissionButton("Screen & System Audio Recording", granted: screenGranted) {
            screenGranted = controller.requestScreenPermission()
          }
          if controller.microphonePreferences.connectedMicrophones.isEmpty {
            Label("No microphone connected", systemImage: "mic.slash")
              .foregroundStyle(.orange)
          } else {
            Picker("Preferred microphone", selection: preferredMicrophoneBinding) {
              ForEach(controller.microphonePreferences.connectedMicrophones) { microphone in
                Text(microphone.name).tag(microphone.id)
              }
            }
            .pickerStyle(.menu)
          }
          Button("Refresh Permission Status") {
            microphoneGranted = AudioCaptureController.hasMicrophonePermission
            screenGranted = AudioCaptureController.hasScreenPermission
            controller.refreshMicrophones()
          }
          .buttonStyle(.link)
        }
      }

      setupRow(number: 3, title: "On-device transcription model") {
        VStack(alignment: .leading, spacing: 10) {
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

          HStack {
            modelSetupStatus
            Spacer()
            if controller.modelReadiness != .ready {
              Button("Download and Prepare") {
                Task {
                  await controller.prepareModel()
                }
              }
            }
          }
        }
      }

      setupRow(number: 4, title: "Shortcut and startup") {
        VStack(alignment: .leading, spacing: 10) {
          LabeledContent("Toggle recording") {
            MeetingShortcutRecorder()
          }
          Toggle("Launch MeetingBar at login", isOn: $launchAtLogin)
        }
      }

      Divider()

      HStack {
        Text("The start and stop tones confirm recording without opening a window.")
          .font(.caption)
          .foregroundStyle(.secondary)
        Spacer()
        Button("Finish Setup") {
          _ = controller.setLaunchAtLogin(launchAtLogin)
          Task {
            _ = await controller.requestNotificationPermission()
          }
          controller.completeOnboarding()
          dismissWindow(id: "onboarding")
        }
        .buttonStyle(.borderedProminent)
        .disabled(!canFinish)
      }
    }
    .padding(28)
    .frame(width: 620)
    .interactiveDismissDisabled(!controller.onboardingComplete)
    .onAppear {
      NSApplication.shared.activate(ignoringOtherApps: true)
      if controller.modelReadiness == .notDownloaded {
        Task {
          await controller.prepareModel()
        }
      }
    }
  }

  private func setupRow<Content: View>(
    number: Int,
    title: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    HStack(alignment: .top, spacing: 12) {
      Text("\(number)")
        .font(.headline)
        .frame(width: 26, height: 26)
        .background(.quaternary, in: Circle())
      VStack(alignment: .leading, spacing: 8) {
        Text(title)
          .font(.headline)
        content()
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func permissionButton(
    _ title: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack {
      Label(title, systemImage: granted ? "checkmark.circle.fill" : "circle")
        .foregroundStyle(granted ? .green : .primary)
      Spacer()
      if !granted {
        Button("Allow", action: action)
      }
    }
  }

  private var preferredMicrophoneBinding: Binding<String> {
    Binding(
      get: {
        controller.microphonePreferences.activeMicrophoneID
          ?? controller.microphonePreferences.connectedMicrophones.first?.id
          ?? ""
      },
      set: { microphoneID in
        controller.prioritizeMicrophone(microphoneID)
      }
    )
  }

  @ViewBuilder
  private var modelSetupStatus: some View {
    switch controller.modelReadiness {
    case .notDownloaded:
      Text(controller.transcriptionPreferences.quality.detail)
        .foregroundStyle(.secondary)
    case .downloading(let progress):
      VStack(alignment: .leading) {
        ProgressView(value: progress)
          .frame(width: 220)
        Text("Downloading \(Int(progress * 100))%")
          .font(.caption)
      }
    case .ready:
      Label("Model ready", systemImage: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed(let message):
      Text(message)
        .foregroundStyle(.orange)
        .lineLimit(2)
    }
  }
}
