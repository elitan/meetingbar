import AppKit
import Combine
import SwiftUI

@MainActor
final class AppBannerPresenter {
  private enum Priority: Int {
    case information
    case meetingReminder
    case recordingContinuation
  }

  private var panel: NSPanel?
  private var currentPriority: Priority?
  private var contentModel: AppBannerContent?
  private var dismissTask: Task<Void, Never>?
  private var presentationID = UUID()

  func presentMeetingReminder(
    applicationName: String,
    onStartRecording: @escaping () -> Void
  ) {
    present(
      title: "\(applicationName) is using your microphone",
      body: "Start a MeetingBar recording?",
      symbolName: "waveform.circle.fill",
      primaryActionTitle: "Start Recording",
      secondaryActionTitle: "Not Now",
      secondaryActionIsDestructive: false,
      priority: .meetingReminder,
      placement: .center,
      duration: .seconds(30),
      onPrimaryAction: onStartRecording,
      onSecondaryAction: nil
    )
  }

  func presentRecordingSilenceReminder(
    secondsRemaining: Int,
    onKeepRecording: @escaping () -> Void,
    onStopRecording: @escaping () -> Void
  ) {
    present(
      title: "Still recording?",
      body: RecordingSilenceBannerText.message(secondsRemaining: secondsRemaining),
      symbolName: "timer",
      primaryActionTitle: "Keep Recording",
      secondaryActionTitle: "Stop Now",
      secondaryActionIsDestructive: true,
      priority: .recordingContinuation,
      placement: .center,
      duration: nil,
      onPrimaryAction: onKeepRecording,
      onSecondaryAction: onStopRecording
    )
  }

  func updateRecordingSilenceReminder(secondsRemaining: Int) {
    guard currentPriority == .recordingContinuation else {
      return
    }
    contentModel?.message = RecordingSilenceBannerText.message(
      secondsRemaining: secondsRemaining
    )
  }

  func presentOnlineMeetingEndedReminder(
    applicationName: String,
    secondsRemaining: Int,
    onKeepRecording: @escaping () -> Void,
    onStopRecording: @escaping () -> Void
  ) {
    present(
      title: "Still recording?",
      body: OnlineMeetingEndedBannerText.message(
        applicationName: applicationName,
        secondsRemaining: secondsRemaining
      ),
      symbolName: "mic.slash.fill",
      primaryActionTitle: "Keep Recording",
      secondaryActionTitle: "Stop Now",
      secondaryActionIsDestructive: true,
      priority: .recordingContinuation,
      placement: .center,
      duration: nil,
      onPrimaryAction: onKeepRecording,
      onSecondaryAction: onStopRecording
    )
  }

  func updateOnlineMeetingEndedReminder(
    applicationName: String,
    secondsRemaining: Int
  ) {
    guard currentPriority == .recordingContinuation else {
      return
    }
    contentModel?.message = OnlineMeetingEndedBannerText.message(
      applicationName: applicationName,
      secondsRemaining: secondsRemaining
    )
  }

  func dismissRecordingContinuationReminder() {
    guard currentPriority == .recordingContinuation else {
      return
    }
    dismiss()
  }

  func presentInformation(title: String, body: String, isError: Bool = false) {
    present(
      title: title,
      body: body,
      symbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
      primaryActionTitle: nil,
      secondaryActionTitle: "Dismiss",
      secondaryActionIsDestructive: false,
      priority: .information,
      placement: .topTrailing,
      duration: .seconds(10),
      onPrimaryAction: nil,
      onSecondaryAction: nil
    )
  }

  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
    currentPriority = nil
    contentModel = nil
  }

  private func present(
    title: String,
    body: String,
    symbolName: String,
    primaryActionTitle: String?,
    secondaryActionTitle: String,
    secondaryActionIsDestructive: Bool,
    priority: Priority,
    placement: AppBannerPlacement,
    duration: Duration?,
    onPrimaryAction: (() -> Void)?,
    onSecondaryAction: (() -> Void)?
  ) {
    guard currentPriority == nil || priority.rawValue >= (currentPriority?.rawValue ?? 0) else {
      return
    }

    dismiss()
    currentPriority = priority
    presentationID = UUID()
    let currentPresentationID = presentationID
    let contentModel = AppBannerContent(message: body)
    self.contentModel = contentModel

    let contentView = AppBannerView(
      title: title,
      content: contentModel,
      symbolName: symbolName,
      primaryActionTitle: primaryActionTitle,
      secondaryActionTitle: secondaryActionTitle,
      secondaryActionIsDestructive: secondaryActionIsDestructive,
      onSecondaryAction: { [weak self] in
        self?.dismiss()
        onSecondaryAction?()
      },
      onPrimaryAction: { [weak self] in
        self?.dismiss()
        onPrimaryAction?()
      }
    )
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)

    let hostingView = NSHostingView(rootView: contentView)
    hostingView.sizingOptions = [.intrinsicContentSize]
    hostingView.layoutSubtreeIfNeeded()
    let panelSize = CGSize(
      width: 420,
      height: min(190, max(126, ceil(hostingView.fittingSize.height)))
    )
    hostingView.sizingOptions = []
    hostingView.frame = CGRect(origin: .zero, size: panelSize)
    hostingView.autoresizingMask = [.width, .height]

    let panel = ActionableBannerPanel(
      contentRect: CGRect(origin: .zero, size: panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = title
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.animationBehavior = .utilityWindow
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.contentView = hostingView
    panel.setContentSize(panelSize)

    let screen =
      NSScreen.screens.first {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
      } ?? NSScreen.main
    if let visibleFrame = screen?.visibleFrame {
      panel.setFrameOrigin(
        AppBannerPosition.origin(
          panelSize: panelSize,
          visibleFrame: visibleFrame,
          placement: placement
        )
      )
    }

    self.panel = panel
    panel.orderFrontRegardless()

    if let duration {
      dismissTask = Task { [weak self] in
        try? await Task.sleep(for: duration)
        guard !Task.isCancelled, self?.presentationID == currentPresentationID else {
          return
        }
        self?.dismiss()
      }
    }
  }
}

enum RecordingSilenceBannerText {
  static func message(secondsRemaining: Int) -> String {
    let seconds = max(0, secondsRemaining)
    let unit = seconds == 1 ? "second" : "seconds"
    return "No microphone or system audio for five minutes.\nRecording will stop automatically in \(seconds) \(unit)."
  }
}

enum OnlineMeetingEndedBannerText {
  static func message(applicationName: String, secondsRemaining: Int) -> String {
    let seconds = max(0, secondsRemaining)
    let unit = seconds == 1 ? "second" : "seconds"
    return "\(applicationName) stopped using your microphone.\nRecording will stop automatically in \(seconds) \(unit)."
  }
}

enum AppBannerPlacement {
  case center
  case topTrailing
}

enum AppBannerPosition {
  static func origin(
    panelSize: CGSize,
    visibleFrame: CGRect,
    placement: AppBannerPlacement,
    margin: CGFloat = 16
  ) -> CGPoint {
    switch placement {
    case .center:
      CGPoint(
        x: visibleFrame.midX - panelSize.width / 2,
        y: visibleFrame.midY - panelSize.height / 2
      )
    case .topTrailing:
      CGPoint(
        x: visibleFrame.maxX - panelSize.width - margin,
        y: visibleFrame.maxY - panelSize.height - margin
      )
    }
  }
}

private final class ActionableBannerPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

@MainActor
private final class AppBannerContent: ObservableObject {
  @Published var message: String

  init(message: String) {
    self.message = message
  }
}

private struct AppBannerView: View {
  let title: String
  @ObservedObject var content: AppBannerContent
  let symbolName: String
  let primaryActionTitle: String?
  let secondaryActionTitle: String
  let secondaryActionIsDestructive: Bool
  let onSecondaryAction: () -> Void
  let onPrimaryAction: () -> Void

  private var symbolColor: Color {
    if symbolName.contains("exclamationmark")
      || symbolName.contains("timer")
      || symbolName.contains("mic.slash")
    {
      return MeetingBarTheme.amber
    }
    if symbolName.contains("checkmark") {
      return MeetingBarTheme.mint
    }
    return MeetingBarTheme.accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 13) {
        MeetingBarIconTile(
          symbol: symbolName,
          color: symbolColor,
          size: 40
        )
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
          Text(content.message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Spacer()
        Button(secondaryActionTitle, action: onSecondaryAction)
          .buttonStyle(
            AppBannerSecondaryButtonStyle(isDestructive: secondaryActionIsDestructive)
          )
        if let primaryActionTitle {
          Button(primaryActionTitle, action: onPrimaryAction)
            .buttonStyle(AppBannerPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(16)
    .padding(.top, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(alignment: .top) {
      LinearGradient(
        colors: [MeetingBarTheme.accent.opacity(0.80), MeetingBarTheme.coral.opacity(0.58)],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(height: 2)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 18,
          topTrailingRadius: 18
        )
      )
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
    }
    .padding(1)
  }
}

private struct AppBannerPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 15)
      .frame(height: 34)
      .background(MeetingBarTheme.accentGradient, in: RoundedRectangle(cornerRadius: 10))
      .opacity(configuration.isPressed ? 0.84 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

private struct AppBannerSecondaryButtonStyle: ButtonStyle {
  let isDestructive: Bool

  func makeBody(configuration: Configuration) -> some View {
    let color = isDestructive ? MeetingBarTheme.coral : Color.secondary
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(color.opacity(0.14), lineWidth: 1)
      }
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}
