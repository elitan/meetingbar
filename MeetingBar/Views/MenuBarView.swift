import AppKit
import KeyboardShortcuts
import SwiftData
import SwiftUI

struct MenuBarStatusLabel: View {
  @Environment(\.openWindow) private var openWindow
  let controller: AppController
  let navigation: MeetingBarNavigation

  var body: some View {
    HStack(spacing: 4) {
      Image(systemName: controller.capture.state.isRecording ? "record.circle.fill" : "waveform")
        .symbolRenderingMode(.hierarchical)
        .foregroundStyle(controller.capture.state.isRecording ? MeetingBarTheme.coral : .primary)
      if controller.capture.state.isRecording {
        Text(DurationText.string(seconds: controller.capture.elapsedSeconds))
          .monospacedDigit()
      }
    }
    .task {
      await controller.launch()
      if ProcessInfo.processInfo.arguments.contains("--open-library") {
        navigation.showLibrary()
        openPrimaryInterface()
      } else if !controller.onboardingComplete {
        openPrimaryInterface()
      }
    }
  }

  private func openPrimaryInterface() {
    MeetingBarApplicationPresentation.openWindow(
      id: controller.onboardingComplete ? "main" : "onboarding",
      using: openWindow
    )
  }
}

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  @Query(MenuBarView.recentDescriptor) private var latestRecordings: [Recording]
  let controller: AppController
  let navigation: MeetingBarNavigation

  private static var recentDescriptor: FetchDescriptor<Recording> {
    var descriptor = FetchDescriptor<Recording>(
      sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
    )
    descriptor.fetchLimit = 4
    return descriptor
  }

  /// The live recording already has the card above, so list the meetings before it.
  private var recentRecordings: [Recording] {
    Array(latestRecordings.filter { !$0.isCapturing }.prefix(3))
  }

  var body: some View {
    ZStack {
      MeetingBarBackdrop()

      VStack(spacing: 0) {
        popoverHeader
          .padding(.horizontal, 16)
          .padding(.top, 15)
          .padding(.bottom, 13)

        Divider()
          .opacity(0.55)

        VStack(spacing: 13) {
          recordingCard
          microphonePicker

          if let warning = controller.capture.latestWarning,
            controller.capture.state.isRecording
          {
            compactMessage(
              warning,
              symbol: "exclamationmark.triangle.fill",
              color: MeetingBarTheme.amber
            )
          }

          if let error = controller.lastErrorMessage {
            compactMessage(
              error,
              symbol: "xmark.octagon.fill",
              color: MeetingBarTheme.coral,
              canDismiss: true
            )
          }

          if !recentRecordings.isEmpty {
            recentSection
          }
        }
        .padding(14)

        Divider()
          .opacity(0.55)

        popoverFooter
          .padding(10)
      }
    }
    .frame(width: 342)
    .fixedSize(horizontal: false, vertical: true)
    .meetingBarWindowTint()
  }

  private var popoverHeader: some View {
    HStack(spacing: 10) {
      MeetingBarLogo(size: 34)
      VStack(alignment: .leading, spacing: 1) {
        Text("MeetingBar")
          .font(.headline)
        Text(statusText)
          .font(.caption)
          .foregroundStyle(statusColor)
      }
      Spacer()
    }
  }

  private var recordingCard: some View {
    VStack(spacing: 14) {
      HStack {
        HStack(spacing: 7) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
          Text(controller.capture.state.isRecording ? "Recording now" : "Ready to record")
            .font(.subheadline.weight(.semibold))
        }
        Spacer()
        if controller.capture.state.isRecording {
          Text(DurationText.string(seconds: controller.capture.elapsedSeconds))
            .font(.caption.monospacedDigit().weight(.semibold))
            .foregroundStyle(.secondary)
        } else if let shortcut = KeyboardShortcuts.getShortcut(for: .toggleMeetingRecording) {
          Text(shortcut.description)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .help("Start or stop recording from any app")
        }
      }

      MeetingBarAudioMeter(
        microphoneLevel: controller.capture.levels.microphone,
        systemLevel: controller.capture.levels.system,
        barCount: 28,
        color: controller.capture.state.isRecording
          ? MeetingBarTheme.coral
          : MeetingBarTheme.accent
      )
      .frame(height: 42)

      Button {
        Task {
          await controller.toggleRecording()
        }
      } label: {
        Label(recordingButtonTitle, systemImage: recordingButtonSymbol)
      }
      .buttonStyle(
        MeetingBarPrimaryButtonStyle(isRecording: controller.capture.state.isRecording)
      )
      .disabled(controller.capture.state == .starting || controller.capture.state == .stopping)
      .keyboardShortcut(.return, modifiers: [])
    }
    .padding(15)
    .background(MeetingBarTheme.surface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .stroke(
          statusColor.opacity(controller.capture.state.isRecording ? 0.24 : 0.11), lineWidth: 1)
    }
  }

  private var microphonePicker: some View {
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
          "\(controller.microphonePreferences.unavailableMicrophones.count) remembered but unavailable"
        )
      }

      Divider()
      Button("Manage Microphone Priority…") {
        openSettingsWindow(section: .capture)
      }
    } label: {
      HStack(spacing: 10) {
        MeetingBarIconTile(symbol: "mic.fill", size: 30)
        VStack(alignment: .leading, spacing: 1) {
          Text("Input microphone")
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(displayedMicrophoneName)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
        }
        Spacer()
        Image(systemName: "chevron.up.chevron.down")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.tertiary)
      }
      .padding(10)
      .background(MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8)
          .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
  }

  private var recentSection: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("RECENT")
        .font(.system(size: 10, weight: .medium))
        .tracking(1)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.bottom, 2)

      ForEach(recentRecordings) { recording in
        MenuBarRecentRow(recording: recording) {
          navigation.showRecording(recording.id)
          MeetingBarApplicationPresentation.openWindow(id: "main", using: openWindow)
        }
      }
    }
  }

  private var popoverFooter: some View {
    HStack(spacing: 6) {
      Button {
        openLibraryWindow()
      } label: {
        Label("Library", systemImage: "rectangle.stack")
      }

      Button {
        openSettingsWindow()
      } label: {
        Label("Settings", systemImage: "slider.horizontal.3")
      }

      Spacer()

      Button {
        Task {
          await controller.quit()
        }
      } label: {
        Image(systemName: "power")
      }
      .help("Quit MeetingBar")
    }
    .buttonStyle(.borderless)
    .font(.subheadline)
  }

  private var statusText: String {
    switch controller.capture.state {
    case .idle:
      controller.transcriptionPreferences.provider == .onDevice
        ? "Private · on this Mac"
        : "Transcription · ElevenLabs"
    case .starting:
      "Starting capture…"
    case .recording:
      "Microphone and Mac audio"
    case .stopping:
      "Saving recording…"
    }
  }

  private var statusColor: Color {
    switch controller.capture.state {
    case .recording:
      MeetingBarTheme.coral
    case .starting, .stopping:
      MeetingBarTheme.amber
    case .idle:
      MeetingBarTheme.mint
    }
  }

  private var recordingButtonTitle: String {
    switch controller.capture.state {
    case .idle:
      "Start Recording"
    case .starting:
      "Starting…"
    case .recording:
      "Stop & Transcribe"
    case .stopping:
      "Saving…"
    }
  }

  private var recordingButtonSymbol: String {
    controller.capture.state.isRecording ? "stop.fill" : "record.circle"
  }

  private var displayedMicrophoneName: String {
    if let activeMicrophoneName = controller.capture.activeMicrophoneName {
      return activeMicrophoneName
    }
    return controller.microphonePreferences.activeMicrophone?.name ?? "No microphone"
  }

  @ViewBuilder
  private func compactMessage(
    _ message: String,
    symbol: String,
    color: Color,
    canDismiss: Bool = false
  ) -> some View {
    HStack(alignment: .top, spacing: 9) {
      Image(systemName: symbol)
        .foregroundStyle(color)
      Text(message)
        .font(.caption)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 2)
      if canDismiss {
        Button {
          controller.clearError()
        } label: {
          Image(systemName: "xmark")
            .font(.caption2.weight(.bold))
        }
        .buttonStyle(.plain)
      }
    }
    .padding(10)
    .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
  }

  private func openLibraryWindow() {
    navigation.showLibrary()
    MeetingBarApplicationPresentation.openWindow(id: "main", using: openWindow)
  }

  private func openSettingsWindow(section: SettingsSection? = nil) {
    navigation.showSettings(section)
    MeetingBarApplicationPresentation.openWindow(id: "main", using: openWindow)
  }
}

private struct MenuBarRecentRow: View {
  let recording: Recording
  let open: () -> Void
  @State private var isHovering = false

  private var isProcessing: Bool {
    recording.status == .queued || recording.status == .transcribing
  }

  private var detail: String {
    switch recording.status {
    case .queued:
      "Waiting to transcribe…"
    case .transcribing:
      "Transcribing…"
    case .failed:
      "Transcription failed · open to retry"
    case .ready:
      "\(MeetingDateText.string(for: recording.startedAt)) · \(DurationText.compact(seconds: recording.durationSeconds))"
    }
  }

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Group {
          if isProcessing {
            ProgressView()
              .controlSize(.mini)
          } else {
            Image(
              systemName: recording.status == .failed
                ? "exclamationmark.triangle.fill" : "text.alignleft"
            )
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(recording.status == .failed ? MeetingBarTheme.amber : Color.secondary)
          }
        }
        .frame(width: 16)

        VStack(alignment: .leading, spacing: 1) {
          Text(recording.title)
            .font(.subheadline.weight(.medium))
            .lineLimit(1)
          Text(detail)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        }

        Spacer(minLength: 4)

        Image(systemName: "chevron.right")
          .font(.caption2.weight(.bold))
          .foregroundStyle(.tertiary)
          .opacity(isHovering ? 1 : 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
      .background(
        isHovering ? MeetingBarTheme.quietFill : Color.clear,
        in: RoundedRectangle(cornerRadius: 7, style: .continuous)
      )
    }
    .buttonStyle(.plain)
    .onHover { isHovering = $0 }
    .help("Open in Library")
  }
}
