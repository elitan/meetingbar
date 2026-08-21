import AppKit
import SwiftUI

@MainActor
final class AppBannerPresenter {
  private enum Priority: Int {
    case information
    case meetingReminder
  }

  private var panel: NSPanel?
  private var currentPriority: Priority?
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
      priority: .meetingReminder,
      placement: .center,
      duration: .seconds(30),
      onPrimaryAction: onStartRecording
    )
  }

  func presentInformation(title: String, body: String, isError: Bool = false) {
    present(
      title: title,
      body: body,
      symbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
      primaryActionTitle: nil,
      priority: .information,
      placement: .topTrailing,
      duration: .seconds(10),
      onPrimaryAction: nil
    )
  }

  func dismiss() {
    dismissTask?.cancel()
    dismissTask = nil
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
    currentPriority = nil
  }

  private func present(
    title: String,
    body: String,
    symbolName: String,
    primaryActionTitle: String?,
    priority: Priority,
    placement: AppBannerPlacement,
    duration: Duration,
    onPrimaryAction: (() -> Void)?
  ) {
    guard currentPriority == nil || priority.rawValue >= (currentPriority?.rawValue ?? 0) else {
      return
    }

    dismiss()
    currentPriority = priority
    presentationID = UUID()
    let currentPresentationID = presentationID

    let contentView = AppBannerView(
      title: title,
      message: body,
      symbolName: symbolName,
      primaryActionTitle: primaryActionTitle,
      onDismiss: { [weak self] in
        self?.dismiss()
      },
      onPrimaryAction: { [weak self] in
        self?.dismiss()
        onPrimaryAction?()
      }
    )

    let panelSize = CGSize(width: 380, height: primaryActionTitle == nil ? 126 : 148)
    let panel = ActionableBannerPanel(
      contentRect: CGRect(origin: .zero, size: panelSize),
      styleMask: [.titled, .nonactivatingPanel, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    panel.titleVisibility = .hidden
    panel.titlebarAppearsTransparent = true
    panel.standardWindowButton(.closeButton)?.isHidden = true
    panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
    panel.standardWindowButton(.zoomButton)?.isHidden = true
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
    panel.contentView = NSHostingView(rootView: contentView)

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

    dismissTask = Task { [weak self] in
      try? await Task.sleep(for: duration)
      guard !Task.isCancelled, self?.presentationID == currentPresentationID else {
        return
      }
      self?.dismiss()
    }
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

private struct AppBannerView: View {
  let title: String
  let message: String
  let symbolName: String
  let primaryActionTitle: String?
  let onDismiss: () -> Void
  let onPrimaryAction: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: symbolName)
          .font(.title2)
          .symbolRenderingMode(.hierarchical)
          .foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
          Text(message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
      }

      HStack {
        Spacer()
        Button(primaryActionTitle == nil ? "Dismiss" : "Not Now", action: onDismiss)
        if let primaryActionTitle {
          Button(primaryActionTitle, action: onPrimaryAction)
            .buttonStyle(.borderedProminent)
        }
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    .overlay {
      RoundedRectangle(cornerRadius: 14)
        .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
    }
    .padding(1)
  }
}
