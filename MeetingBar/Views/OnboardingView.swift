import AppKit
import SwiftUI

struct OnboardingView: View {
  @Environment(\.dismissWindow) private var dismissWindow
  @Environment(\.openWindow) private var openWindow
  let controller: AppController
  @State private var consentAccepted = false
  @State private var microphoneGranted = AudioCaptureController.hasMicrophonePermission
  @State private var screenGranted = AudioCaptureController.hasScreenPermission
  @State private var launchAtLogin = true
  @State private var elevenLabsAPIKey = ""
  @State private var apiKeyMessage: String?

  private var canFinish: Bool {
    consentAccepted && microphoneGranted && screenGranted && controller.modelReadiness == .ready
  }

  var body: some View {
    ZStack {
      MeetingBarBackdrop()

      HStack(spacing: 0) {
        onboardingHero
          .frame(width: 260)

        Divider()
          .opacity(0.55)

        VStack(spacing: 0) {
          ScrollView {
            VStack(alignment: .leading, spacing: 14) {
              Text("A few things before your first meeting")
                .font(.system(size: 25, weight: .bold, design: .rounded))
              Text("Setup takes a minute. Recording stays one shortcut away after this.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

              setupStep(number: 1, title: "Record with consent", symbol: "person.2.badge.gearshape") {
                Toggle(
                  "I will inform participants and only record when it is lawful.",
                  isOn: $consentAccepted
                )
              }

              setupStep(number: 2, title: "Allow both audio sources", symbol: "lock.shield") {
                VStack(spacing: 10) {
                  permissionButton("Microphone", granted: microphoneGranted) {
                    Task {
                      microphoneGranted = await controller.requestMicrophonePermission()
                    }
                  }

                  permissionButton(
                    "Screen & System Audio Recording",
                    granted: screenGranted
                  ) {
                    screenGranted = controller.requestScreenPermission()
                  }

                  Divider()

                  if controller.microphonePreferences.connectedMicrophones.isEmpty {
                    Label("No microphone connected", systemImage: "mic.slash")
                      .font(.subheadline)
                      .foregroundStyle(MeetingBarTheme.amber)
                  } else {
                    LabeledContent("Preferred microphone") {
                      Picker("Preferred microphone", selection: preferredMicrophoneBinding) {
                        ForEach(controller.microphonePreferences.connectedMicrophones) { microphone in
                          Text(microphone.name).tag(microphone.id)
                        }
                      }
                      .labelsHidden()
                      .frame(maxWidth: 235)
                    }
                  }

                  HStack {
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") {
                      microphoneGranted = AudioCaptureController.hasMicrophonePermission
                      screenGranted = AudioCaptureController.hasScreenPermission
                      controller.refreshMicrophones()
                    }
                    .controlSize(.small)
                  }
                }
              }

              setupStep(number: 3, title: "Choose transcription", symbol: "text.bubble") {
                VStack(spacing: 11) {
                  LabeledContent("Provider") {
                    Picker(
                      "Provider",
                      selection: Binding(
                        get: { controller.transcriptionPreferences.provider },
                        set: { controller.setTranscriptionProvider($0) }
                      )
                    ) {
                      ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.label).tag(provider)
                      }
                    }
                    .labelsHidden()
                    .frame(width: 210)
                  }

                  LabeledContent("Meeting language") {
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
                    .labelsHidden()
                    .frame(width: 190)
                  }

                  if controller.transcriptionPreferences.provider == .onDevice {
                    LabeledContent("Speech model") {
                      Picker(
                        "Speech model",
                        selection: Binding(
                          get: { controller.transcriptionPreferences.quality },
                          set: { controller.setTranscriptionQuality($0) }
                        )
                      ) {
                        ForEach(TranscriptionQuality.allCases) { quality in
                          Text(quality.label).tag(quality)
                        }
                      }
                      .labelsHidden()
                      .frame(width: 210)
                    }
                  } else {
                    LabeledContent("Speech model") {
                      Picker(
                        "Speech model",
                        selection: Binding(
                          get: { controller.transcriptionPreferences.elevenLabsModel },
                          set: { controller.setElevenLabsTranscriptionModel($0) }
                        )
                      ) {
                        ForEach(ElevenLabsTranscriptionModel.allCases) { model in
                          Text(model.label).tag(model)
                        }
                      }
                      .labelsHidden()
                      .frame(width: 210)
                    }
                  }

                  if controller.transcriptionPreferences.provider == .elevenLabs {
                    Divider()
                    HStack(spacing: 9) {
                      SecureField(
                        controller.transcriptionPreferences.hasElevenLabsAPIKey
                          ? "Enter a replacement API key"
                          : "Paste ElevenLabs API key",
                        text: $elevenLabsAPIKey
                      )
                      .textFieldStyle(.roundedBorder)

                      Button(
                        controller.transcriptionPreferences.hasElevenLabsAPIKey
                          ? "Replace"
                          : "Save"
                      ) {
                        saveElevenLabsAPIKey()
                      }
                      .buttonStyle(.borderedProminent)
                      .disabled(
                        elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      )
                    }

                    HStack {
                      if controller.transcriptionPreferences.hasElevenLabsAPIKey {
                        MeetingBarPill(
                          text: "Saved locally",
                          symbol: "checkmark",
                          tone: .success
                        )
                      } else {
                        Text("Required for cloud transcription")
                          .font(.caption)
                          .foregroundStyle(.secondary)
                      }
                      Spacer()
                      Link(
                        "Create API Key",
                        destination: URL(string: "https://elevenlabs.io/app/settings/api-keys")!
                      )
                      .font(.caption)
                    }

                    if let apiKeyMessage {
                      Text(apiKeyMessage)
                        .font(.caption)
                        .foregroundStyle(MeetingBarTheme.amber)
                    }

                    Text(
                      "MeetingBar balances and merges both tracks locally, then uploads one temporary mono file after Stop. It requests deletion from ElevenLabs after saving the transcript and retries failed deletion requests. ElevenLabs may still retain service logs or backups; this is not Zero Retention Mode."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                  }

                  Divider()

                  HStack(alignment: .top, spacing: 10) {
                    modelSetupStatus
                    Spacer()
                    if controller.modelReadiness != .ready
                      || (controller.transcriptionPreferences.provider == .onDevice
                        && controller.speakerModelReadiness != .ready)
                    {
                      Button(
                        controller.transcriptionPreferences.provider == .onDevice
                          ? "Prepare Models"
                          : "Check Configuration",
                        systemImage: controller.transcriptionPreferences.provider == .onDevice
                          ? "arrow.down.circle"
                          : "checkmark.circle"
                      ) {
                        Task {
                          await controller.prepareModel()
                        }
                      }
                      .buttonStyle(.borderedProminent)
                    }
                  }
                }
              }

              setupStep(number: 4, title: "Make it effortless", symbol: "bolt.fill") {
                VStack(spacing: 11) {
                  LabeledContent("Toggle recording") {
                    MeetingShortcutRecorder()
                  }

                  Divider()

                  Toggle(
                    "Remind me when an online meeting starts",
                    isOn: Binding(
                      get: { controller.meetingReminderPreferences.isEnabled },
                      set: { controller.setMeetingRemindersEnabled($0) }
                    )
                  )

                  Toggle(
                    "Include browser calls such as Google Meet",
                    isOn: Binding(
                      get: { controller.meetingReminderPreferences.includesBrowsers },
                      set: { controller.setMeetingRemindersIncludeBrowsers($0) }
                    )
                  )
                  .disabled(!controller.meetingReminderPreferences.isEnabled)

                  Toggle("Launch MeetingBar at login", isOn: $launchAtLogin)
                }
              }
            }
            .padding(26)
          }

          Divider()
            .opacity(0.55)

          HStack(spacing: 14) {
            Label("Start and stop tones confirm every recording", systemImage: "speaker.wave.2")
              .font(.caption)
              .foregroundStyle(.secondary)
            Spacer()
            Button("Finish Setup") {
              _ = controller.setLaunchAtLogin(launchAtLogin)
              controller.completeOnboarding()
              dismissWindow(id: "onboarding")
              MeetingBarApplicationPresentation.openWindow(id: "main", using: openWindow)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canFinish)
          }
          .padding(.horizontal, 24)
          .padding(.vertical, 16)
          .background(.ultraThinMaterial)
        }
      }
    }
    .frame(width: 850, height: 720)
    .meetingBarWindowTint()
    .interactiveDismissDisabled(!controller.onboardingComplete)
    .onAppear {
      NSApplication.shared.activate(ignoringOtherApps: true)
      controller.refreshMicrophones()
      if controller.modelReadiness == .notDownloaded {
        Task {
          await controller.prepareModel()
        }
      }
    }
  }

  private var onboardingHero: some View {
    ZStack {
      LinearGradient(
        colors: [
          MeetingBarTheme.accent.opacity(0.24),
          MeetingBarTheme.accent.opacity(0.07),
          Color.clear,
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
      )

      VStack(alignment: .leading, spacing: 22) {
        MeetingBarLogo(size: 58)

        VStack(alignment: .leading, spacing: 7) {
          Text("MeetingBar")
            .font(.system(size: 30, weight: .bold, design: .rounded))
          Text("A private memory for every conversation.")
            .font(.body)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }

        VStack(alignment: .leading, spacing: 15) {
          heroFeature("Mic + Mac audio", symbol: "waveform")
          heroFeature("Swedish + English", symbol: "character.bubble")
          heroFeature("Speaker detection", symbol: "person.2.wave.2")
          heroFeature("Local or cloud transcription", symbol: "lock.fill")
        }

        Spacer()

        Text("No meeting bot. One library, with quick menu-bar controls.")
          .font(.caption)
          .foregroundStyle(.tertiary)
          .fixedSize(horizontal: false, vertical: true)
      }
      .padding(28)
    }
  }

  private func heroFeature(_ title: String, symbol: String) -> some View {
    Label(title, systemImage: symbol)
      .font(.subheadline.weight(.medium))
      .foregroundStyle(.secondary)
  }

  private func setupStep<Content: View>(
    number: Int,
    title: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) -> some View {
    MeetingBarCard(padding: 17, cornerRadius: 17) {
      HStack(alignment: .top, spacing: 13) {
        ZStack {
          RoundedRectangle(cornerRadius: 11, style: .continuous)
            .fill(MeetingBarTheme.accent.opacity(0.12))
          VStack(spacing: 1) {
            Image(systemName: symbol)
              .font(.caption.weight(.semibold))
            Text("\(number)")
              .font(.caption2.weight(.bold))
          }
          .foregroundStyle(MeetingBarTheme.accent)
        }
        .frame(width: 38, height: 38)

        VStack(alignment: .leading, spacing: 12) {
          Text(title)
            .font(.headline)
          content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  private func permissionButton(
    _ title: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 10) {
      MeetingBarIconTile(
        symbol: granted ? "checkmark" : "lock",
        color: granted ? MeetingBarTheme.mint : MeetingBarTheme.amber,
        size: 32
      )
      Text(title)
        .font(.subheadline.weight(.medium))
      Spacer()
      if granted {
        MeetingBarPill(text: "Allowed", tone: .success)
      } else {
        Button("Allow", action: action)
          .buttonStyle(.borderedProminent)
          .controlSize(.small)
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
    VStack(alignment: .leading, spacing: 7) {
      transcriptionModelSetupStatus
      if controller.transcriptionPreferences.provider == .onDevice {
        speakerModelSetupStatus
      }
    }
  }

  @ViewBuilder
  private var transcriptionModelSetupStatus: some View {
    switch controller.modelReadiness {
    case .notDownloaded:
      Label(
        controller.transcriptionPreferences.provider == .onDevice
          ? "Speech model not prepared"
          : "Cloud transcription not configured",
        systemImage: controller.transcriptionPreferences.provider == .onDevice
          ? "arrow.down.circle"
          : "cloud"
      )
        .font(.caption)
        .foregroundStyle(.secondary)
    case .downloading(let progress):
      VStack(alignment: .leading, spacing: 4) {
        ProgressView(value: progress)
          .frame(width: 190)
        Text("Downloading \(Int(progress * 100))%")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    case .ready:
      MeetingBarPill(
        text: controller.transcriptionPreferences.provider == .onDevice
          ? "Speech model ready"
          : "ElevenLabs configured",
        symbol: "checkmark",
        tone: .success
      )
    case .failed(let message):
      Text(message)
        .font(.caption)
        .foregroundStyle(MeetingBarTheme.amber)
        .lineLimit(2)
    }
  }

  @ViewBuilder
  private var speakerModelSetupStatus: some View {
    switch controller.speakerModelReadiness {
    case .notDownloaded:
      Label("Speaker model not prepared", systemImage: "arrow.down.circle")
        .font(.caption)
        .foregroundStyle(.secondary)
    case .downloading:
      HStack(spacing: 8) {
        ProgressView()
          .controlSize(.small)
        Text("Preparing speaker model…")
          .font(.caption)
      }
    case .ready:
      MeetingBarPill(text: "Speaker model ready", symbol: "checkmark", tone: .success)
    case .failed(let message):
      Text("Speaker model: \(message)")
        .font(.caption)
        .foregroundStyle(MeetingBarTheme.amber)
        .lineLimit(2)
    }
  }

  private func saveElevenLabsAPIKey() {
    do {
      try controller.saveElevenLabsAPIKey(elevenLabsAPIKey)
      elevenLabsAPIKey = ""
      apiKeyMessage = nil
    } catch {
      apiKeyMessage = error.localizedDescription
    }
  }
}
