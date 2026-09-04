import SwiftUI

struct SettingsView: View {
  let controller: AppController
  @State private var selectedSection: SettingsSection? = .capture
  @State private var microphoneGranted = AudioCaptureController.hasMicrophonePermission
  @State private var screenGranted = AudioCaptureController.hasScreenPermission
  @State private var elevenLabsAPIKey = ""
  @State private var apiKeyFeedback: APIKeyFeedback?

  var body: some View {
    NavigationSplitView {
      List(SettingsSection.allCases, selection: $selectedSection) { section in
        Label(section.title, systemImage: section.symbol)
          .tag(section)
      }
      .navigationTitle("Settings")
      .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 220)
    } detail: {
      ZStack {
        MeetingBarBackdrop()
        ScrollView {
          VStack(alignment: .leading, spacing: 18) {
            switch selectedSection ?? .capture {
            case .capture:
              captureSettings
            case .transcription:
              transcriptionSettings
            case .general:
              generalSettings
            }
          }
          .padding(28)
          .frame(maxWidth: 760, alignment: .leading)
          .frame(maxWidth: .infinity)
        }
      }
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minWidth: 800, minHeight: 650)
    .meetingBarWindowTint()
    .onAppear {
      refreshPermissionStatus()
      controller.refreshMicrophones()
    }
  }

  @ViewBuilder
  private var captureSettings: some View {
    SettingsPageHeader(
      title: "Capture",
      subtitle: "Choose your microphone and make every recording dependable.",
      symbol: "waveform"
    )

    SettingsCard(
      title: "Microphone priority",
      subtitle: "The first connected microphone is selected automatically.",
      symbol: "mic.fill"
    ) {
      if let activeMicrophone = controller.microphonePreferences.activeMicrophone {
        HStack(spacing: 10) {
          MeetingBarPill(text: "In use", symbol: "checkmark", tone: .success)
          Text(activeMicrophone.name)
            .font(.subheadline.weight(.medium))
          Spacer()
          Button("Refresh", systemImage: "arrow.clockwise") {
            controller.refreshMicrophones()
          }
          .controlSize(.small)
        }
      } else {
        HStack {
          Label("No microphone connected", systemImage: "mic.slash")
            .foregroundStyle(MeetingBarTheme.amber)
          Spacer()
          Button("Refresh") {
            controller.refreshMicrophones()
          }
        }
      }

      Divider()

      if controller.microphonePreferences.microphones.isEmpty {
        Text("Connect a microphone, then refresh this list.")
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .padding(.vertical, 8)
      } else {
        VStack(spacing: 0) {
          ForEach(
            Array(controller.microphonePreferences.microphones.enumerated()),
            id: \.element.id
          ) { index, microphone in
            microphoneRow(microphone, index: index)
            if index < controller.microphonePreferences.microphones.count - 1 {
              Divider()
                .padding(.leading, 42)
            }
          }
        }
      }

      Text(
        "Unavailable devices stay in the list, so a preferred studio microphone takes over again as soon as it reconnects."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }

    SettingsCard(
      title: "Permissions",
      subtitle: "MeetingBar requires both sources before a recording can start.",
      symbol: "lock.shield"
    ) {
      permissionRow(title: "Microphone", granted: microphoneGranted) {
        Task {
          microphoneGranted = await controller.requestMicrophonePermission()
        }
      }
      Divider()
      permissionRow(title: "Screen & System Audio Recording", granted: screenGranted) {
        screenGranted = controller.requestScreenPermission()
      }
      Divider()
      Button("Refresh Permission Status", systemImage: "arrow.clockwise") {
        refreshPermissionStatus()
      }
      .controlSize(.small)
    }

    SettingsCard(
      title: "Recording safety",
      subtitle: "Protect meetings from being missed or left running.",
      symbol: "checkmark.shield"
    ) {
      SettingToggleRow(
        title: "Stop forgotten recordings automatically",
        detail:
          "Ask after Zoom, Teams, or a browser stops using the microphone for one minute, or after both audio sources stay quiet for five minutes. The recording stops after a 30-second countdown.",
        isOn: Binding(
          get: { controller.recordingSafetyPreferences.isEnabled },
          set: { controller.setRecordingSafetyEnabled($0) }
        )
      )

      Divider()

      SettingToggleRow(
        title: "Prompt when an online meeting starts",
        detail:
          "Show a centered reminder when Zoom, Microsoft Teams, or an included browser begins using the microphone.",
        isOn: Binding(
          get: { controller.meetingReminderPreferences.isEnabled },
          set: { controller.setMeetingRemindersEnabled($0) }
        )
      )

      Divider()

      SettingToggleRow(
        title: "Include browser microphone activity",
        detail:
          "Supports Google Meet and other browser calls, but may also notice non-meeting sites that use the microphone.",
        isOn: Binding(
          get: { controller.meetingReminderPreferences.includesBrowsers },
          set: { controller.setMeetingRemindersIncludeBrowsers($0) }
        )
      )
      .disabled(
        !controller.meetingReminderPreferences.isEnabled
          && !controller.recordingSafetyPreferences.isEnabled
      )

      if controller.meetingReminderPreferences.isEnabled {
        Divider()
        HStack {
          MeetingBarPill(text: "Detection ready", symbol: "checkmark", tone: .success)
          Text("No Notification Center permission required")
            .font(.caption)
            .foregroundStyle(.secondary)
          Spacer()
          Button("Show Test Reminder") {
            controller.showTestMeetingReminder()
          }
          .controlSize(.small)
        }

        if let message = controller.meetingReminderMonitorError {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(MeetingBarTheme.amber)
        }
      }
    }
  }

  @ViewBuilder
  private var transcriptionSettings: some View {
    SettingsPageHeader(
      title: "Transcription",
      subtitle: "Choose where every new recording is transcribed and which model it uses.",
      symbol: "text.bubble"
    )

    SettingsCard(
      title: "Provider and model",
      subtitle: "This choice applies to new recordings and manual retries.",
      symbol: "sparkles"
    ) {
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
        .frame(width: 220)
      }

      Text(controller.transcriptionPreferences.provider.detail)
        .font(.caption)
        .foregroundStyle(.secondary)

      Divider()

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

      Divider()

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
          .frame(width: 220)
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
          .frame(width: 220)
        }
      }

      Text(controller.transcriptionPreferences.configuration.modelDetail)
        .font(.caption)
        .foregroundStyle(.secondary)

      Text(
        "Choose Swedish or English only if automatic detection repeatedly picks the wrong language. Mixed-language conversations remain best effort."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }

    if controller.transcriptionPreferences.provider == .elevenLabs {
      SettingsCard(
        title: "ElevenLabs API key",
        subtitle: "Stored in macOS Keychain and never written to MeetingBar's database.",
        symbol: "key.fill"
      ) {
        HStack(spacing: 10) {
          SecureField(
            controller.transcriptionPreferences.hasElevenLabsAPIKey
              ? "Enter a replacement key"
              : "Paste your API key",
            text: $elevenLabsAPIKey
          )
          .textFieldStyle(.roundedBorder)

          Button(controller.transcriptionPreferences.hasElevenLabsAPIKey ? "Replace" : "Save") {
            saveElevenLabsAPIKey()
          }
          .buttonStyle(.borderedProminent)
          .disabled(elevenLabsAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }

        HStack(spacing: 10) {
          if controller.transcriptionPreferences.hasElevenLabsAPIKey {
            MeetingBarPill(text: "Saved in Keychain", symbol: "checkmark", tone: .success)
            Button("Remove Key", role: .destructive) {
              removeElevenLabsAPIKey()
            }
            .controlSize(.small)
          } else {
            Label("An API key is required before cloud transcription can run.", systemImage: "key")
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

        if let apiKeyFeedback {
          Label(apiKeyFeedback.message, systemImage: apiKeyFeedback.symbol)
            .font(.caption)
            .foregroundStyle(apiKeyFeedback.color)
        }

        Divider()

        Label {
          Text(
            "After Stop, MeetingBar balances and aligns both tracks locally, then uploads one temporary mono file. This avoids billing the meeting duration twice. Once the transcript is safely stored here, MeetingBar requests deletion from ElevenLabs and retries failed deletion requests. ElevenLabs may still retain service logs or backups under its policies; this is not Zero Retention Mode."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        } icon: {
          Image(systemName: "icloud.and.arrow.up")
            .foregroundStyle(MeetingBarTheme.amber)
        }
      }

      SettingsCard(
        title: "Cloud transcription",
        subtitle: "One balanced upload begins after Stop; your source recordings stay on this Mac.",
        symbol: "cloud"
      ) {
        modelStatusRow(
          title: controller.transcriptionPreferences.elevenLabsModel.label,
          symbol: "waveform.and.mic",
          readiness: controller.modelReadiness,
          readyDetail: "Single-upload transcription with automatic remote cleanup"
        )
        if controller.modelReadiness != .ready
          && controller.transcriptionPreferences.hasElevenLabsAPIKey
        {
          Divider()
          HStack {
            Spacer()
            Button("Check Configuration", systemImage: "arrow.clockwise") {
              Task {
                await controller.prepareModel()
              }
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    } else {
      SettingsCard(
        title: "On-device models",
        subtitle: "Downloaded once, then used without sending meeting audio away.",
        symbol: "cpu"
      ) {
        modelStatusRow(
          title: "Speech recognition",
          symbol: "waveform.and.mic",
          readiness: controller.modelReadiness,
          readyDetail: controller.transcriptionPreferences.quality.modelIdentifier
        )

        Divider()

        modelStatusRow(
          title: "Speaker detection",
          symbol: "person.2.wave.2",
          readiness: controller.speakerModelReadiness,
          readyDetail: "Ready to separate multiple voices"
        )

        if controller.modelReadiness != .ready
          || controller.speakerModelReadiness != .ready
        {
          Divider()
          HStack {
            Spacer()
            Button("Download or Prepare Models", systemImage: "arrow.down.circle") {
              Task {
                await controller.prepareModel()
              }
            }
            .buttonStyle(.borderedProminent)
          }
        }
      }
    }

    SettingsCard(
      title: "How processing works",
      subtitle: "Recording always starts immediately; transcription follows after Stop.",
      symbol: "bolt.horizontal.circle"
    ) {
      HStack(alignment: .top, spacing: 18) {
        processStep(number: "1", title: "Capture", detail: "Mic + Mac audio")
        Image(systemName: "arrow.right")
          .foregroundStyle(.tertiary)
          .padding(.top, 13)
        processStep(
          number: "2",
          title: "Transcribe",
          detail: controller.transcriptionPreferences.provider == .onDevice
            ? "On this Mac"
            : "ElevenLabs cloud"
        )
        Image(systemName: "arrow.right")
          .foregroundStyle(.tertiary)
          .padding(.top, 13)
        processStep(number: "3", title: "Remember", detail: "Search anytime")
      }
      .frame(maxWidth: .infinity)
    }
  }

  private func saveElevenLabsAPIKey() {
    do {
      try controller.saveElevenLabsAPIKey(elevenLabsAPIKey)
      elevenLabsAPIKey = ""
      apiKeyFeedback = .success("API key saved securely.")
    } catch {
      apiKeyFeedback = .failure(error.localizedDescription)
    }
  }

  private func removeElevenLabsAPIKey() {
    do {
      try controller.removeElevenLabsAPIKey()
      elevenLabsAPIKey = ""
      apiKeyFeedback = .success("API key removed from Keychain.")
    } catch {
      apiKeyFeedback = .failure(error.localizedDescription)
    }
  }

  @ViewBuilder
  private var generalSettings: some View {
    SettingsPageHeader(
      title: "General",
      subtitle: "Shortcut, startup, storage, and privacy.",
      symbol: "slider.horizontal.3"
    )

    SettingsCard(
      title: "Recording shortcut",
      subtitle: "Start or stop without leaving the app you are in.",
      symbol: "keyboard"
    ) {
      LabeledContent("Toggle recording") {
        MeetingShortcutRecorder()
      }
      Text(
        "MeetingBar keeps the last working shortcut when macOS or another registered shortcut rejects a new combination."
      )
      .font(.caption)
      .foregroundStyle(.secondary)
    }

    SettingsCard(
      title: "Startup",
      subtitle: "Keep MeetingBar one click or shortcut away.",
      symbol: "power"
    ) {
      SettingToggleRow(
        title: "Launch MeetingBar at login",
        detail: "Runs quietly in the menu bar with no Dock icon.",
        isOn: Binding(
          get: { controller.launchAtLoginEnabled },
          set: { _ = controller.setLaunchAtLogin($0) }
        )
      )
    }

    SettingsCard(
      title: "Storage",
      subtitle: "Keep recordings and searchable text on this Mac.",
      symbol: "internaldrive"
    ) {
      HStack(alignment: .top, spacing: 12) {
        MeetingBarIconTile(symbol: "text.document", color: MeetingBarTheme.mint, size: 36)
        VStack(alignment: .leading, spacing: 3) {
          Text("Transcripts")
            .font(.subheadline.weight(.semibold))
          Text("Kept indefinitely until you delete the meeting.")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      HStack(alignment: .top, spacing: 12) {
        MeetingBarIconTile(symbol: "waveform", color: MeetingBarTheme.coral, size: 36)
        VStack(alignment: .leading, spacing: 3) {
          Text("Source audio")
            .font(.subheadline.weight(.semibold))
          Text(
            "Kept indefinitely on this Mac. Deleting a meeting removes both its transcript and audio."
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
      }
    }

    SettingsCard(
      title: "Recording consent",
      subtitle: "Privacy starts with the people in the conversation.",
      symbol: "person.badge.shield.checkmark"
    ) {
      Text(
        "Only record when everyone involved has been informed and recording is lawful in your location and context."
      )
      .font(.subheadline)
      .foregroundStyle(.secondary)
    }
  }

  private func microphoneRow(
    _ microphone: MicrophonePreference,
    index: Int
  ) -> some View {
    HStack(spacing: 12) {
      Text("\(index + 1)")
        .font(.caption.monospacedDigit().weight(.bold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 24)
        .background(MeetingBarTheme.quietFill, in: Circle())

      VStack(alignment: .leading, spacing: 2) {
        Text(microphone.name)
          .font(.subheadline.weight(.medium))
        Text(
          microphone.isConnected
            ? "Connected"
            : "Unavailable · last seen \(microphone.lastSeenAt.formatted(date: .abbreviated, time: .omitted))"
        )
        .font(.caption)
        .foregroundStyle(microphone.isConnected ? Color.secondary : MeetingBarTheme.amber)
      }

      Spacer()

      if microphone.id == controller.microphonePreferences.activeMicrophoneID {
        MeetingBarPill(text: "In use", tone: .success)
      }

      HStack(spacing: 3) {
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
    .padding(.vertical, 8)
  }

  private func permissionRow(
    title: String,
    granted: Bool,
    action: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 12) {
      MeetingBarIconTile(
        symbol: granted ? "checkmark" : "lock",
        color: granted ? MeetingBarTheme.mint : MeetingBarTheme.amber,
        size: 34
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

  @ViewBuilder
  private func modelStatusRow(
    title: String,
    symbol: String,
    readiness: ModelReadiness,
    readyDetail: String
  ) -> some View {
    HStack(spacing: 12) {
      MeetingBarIconTile(symbol: symbol, size: 38)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))
        switch readiness {
        case .notDownloaded:
          Text("Not prepared")
            .font(.caption)
            .foregroundStyle(.secondary)
        case .downloading(let progress):
          VStack(alignment: .leading, spacing: 4) {
            ProgressView(value: progress)
              .frame(maxWidth: 260)
            Text(progress > 0 ? "Downloading \(Int(progress * 100))%" : "Preparing…")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        case .ready:
          Text(readyDetail)
            .font(.caption)
            .foregroundStyle(.secondary)
        case .failed(let message):
          Text(message)
            .font(.caption)
            .foregroundStyle(MeetingBarTheme.amber)
            .lineLimit(2)
        }
      }
      Spacer()
      if readiness == .ready {
        MeetingBarPill(text: "Ready", symbol: "checkmark", tone: .success)
      }
    }
  }

  private func processStep(number: String, title: String, detail: String) -> some View {
    VStack(spacing: 5) {
      Text(number)
        .font(.caption.weight(.bold))
        .foregroundStyle(.white)
        .frame(width: 28, height: 28)
        .background(MeetingBarTheme.accentGradient, in: Circle())
      Text(title)
        .font(.caption.weight(.semibold))
      Text(detail)
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
  }

  private func refreshPermissionStatus() {
    microphoneGranted = AudioCaptureController.hasMicrophonePermission
    screenGranted = AudioCaptureController.hasScreenPermission
  }
}

private enum APIKeyFeedback {
  case success(String)
  case failure(String)

  var message: String {
    switch self {
    case .success(let message), .failure(let message):
      message
    }
  }

  var symbol: String {
    switch self {
    case .success:
      "checkmark.circle"
    case .failure:
      "exclamationmark.triangle"
    }
  }

  var color: Color {
    switch self {
    case .success:
      MeetingBarTheme.mint
    case .failure:
      MeetingBarTheme.amber
    }
  }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
  case capture
  case transcription
  case general

  var id: Self { self }

  var title: String {
    switch self {
    case .capture:
      "Capture"
    case .transcription:
      "Transcription"
    case .general:
      "General"
    }
  }

  var symbol: String {
    switch self {
    case .capture:
      "waveform"
    case .transcription:
      "text.bubble"
    case .general:
      "slider.horizontal.3"
    }
  }
}

private struct SettingsPageHeader: View {
  let title: String
  let subtitle: String
  let symbol: String

  var body: some View {
    HStack(spacing: 14) {
      MeetingBarIconTile(symbol: symbol, size: 46)
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.system(size: 28, weight: .bold, design: .rounded))
        Text(subtitle)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
    }
    .padding(.bottom, 2)
  }
}

private struct SettingsCard<Content: View>: View {
  let title: String
  let subtitle: String
  let symbol: String
  @ViewBuilder let content: Content

  init(
    title: String,
    subtitle: String,
    symbol: String,
    @ViewBuilder content: () -> Content
  ) {
    self.title = title
    self.subtitle = subtitle
    self.symbol = symbol
    self.content = content()
  }

  var body: some View {
    MeetingBarCard(padding: 18, cornerRadius: 18) {
      VStack(alignment: .leading, spacing: 14) {
        HStack(spacing: 11) {
          MeetingBarIconTile(symbol: symbol, size: 36)
          VStack(alignment: .leading, spacing: 2) {
            Text(title)
              .font(.headline)
            Text(subtitle)
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        Divider()
        content
      }
    }
  }
}

private struct SettingToggleRow: View {
  let title: String
  let detail: String
  @Binding var isOn: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.medium))
        Text(detail)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }
      Spacer(minLength: 20)
      Toggle("", isOn: $isOn)
        .labelsHidden()
    }
  }
}
