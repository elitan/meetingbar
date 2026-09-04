import AppKit
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
    openWindow(id: controller.onboardingComplete ? "main" : "onboarding")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}

struct MenuBarView: View {
  @Environment(\.openWindow) private var openWindow
  let controller: AppController
  let navigation: MeetingBarNavigation

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
      Button {
        openSettingsWindow()
      } label: {
        Image(systemName: "gearshape")
          .font(.system(size: 14, weight: .semibold))
          .foregroundStyle(.secondary)
          .frame(width: 30, height: 30)
          .background(MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 9))
      }
      .buttonStyle(.plain)
      .help("Settings")
    }
  }

  private var recordingCard: some View {
    VStack(spacing: 14) {
      HStack {
        HStack(spacing: 7) {
          Circle()
            .fill(statusColor)
            .frame(width: 7, height: 7)
            .shadow(color: statusColor.opacity(0.40), radius: 4)
          Text(controller.capture.state.isRecording ? "Recording now" : "Ready to record")
            .font(.subheadline.weight(.semibold))
        }
        Spacer()
        Text(
          controller.capture.state.isRecording
            ? DurationText.string(seconds: controller.capture.elapsedSeconds)
            : "MIC + MAC"
        )
        .font(.caption.monospacedDigit().weight(.semibold))
        .foregroundStyle(.secondary)
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
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 17, style: .continuous))
    .overlay {
      RoundedRectangle(cornerRadius: 17, style: .continuous)
        .stroke(statusColor.opacity(controller.capture.state.isRecording ? 0.24 : 0.11), lineWidth: 1)
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
        MeetingBarIconTile(symbol: "mic.fill", color: MeetingBarTheme.mint, size: 34)
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
      .background(MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 12))
      .overlay {
        RoundedRectangle(cornerRadius: 12)
          .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
      }
    }
    .buttonStyle(.plain)
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
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }

  private func openSettingsWindow(section: SettingsSection? = nil) {
    navigation.showSettings(section)
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
