import AppKit
import Observation
import SwiftData
import SwiftUI

enum MeetingBarWorkspace: String, CaseIterable, Identifiable {
  case library
  case settings

  var id: Self { self }

  var title: String {
    switch self {
    case .library:
      "Library"
    case .settings:
      "Settings"
    }
  }

  var symbol: String {
    switch self {
    case .library:
      "rectangle.stack"
    case .settings:
      "slider.horizontal.3"
    }
  }
}

@MainActor
@Observable
final class MeetingBarNavigation {
  var workspace: MeetingBarWorkspace = .library
  var settingsSection: SettingsSection = .capture

  func showLibrary() {
    workspace = .library
  }

  func showSettings(_ section: SettingsSection? = nil) {
    if let section {
      settingsSection = section
    }
    workspace = .settings
  }
}

enum MeetingBarRuntime {
  static func isRunningTests(environment: [String: String]) -> Bool {
    environment["XCTestConfigurationFilePath"] != nil
  }
}

@MainActor
enum MeetingBarApplicationPresentation {
  private static var primaryWindows: Set<ObjectIdentifier> = []

  static func startInMenuBarMode() {
    primaryWindows.removeAll()
    NSApplication.shared.setActivationPolicy(.accessory)
  }

  static func openWindow(id: String, using openWindow: OpenWindowAction) {
    NSApplication.shared.setActivationPolicy(.regular)
    Task { @MainActor in
      // Give AppKit one run-loop turn to publish the activation-policy change.
      // Opening a SwiftUI scene in the same turn can be dropped when the app
      // has just transitioned out of accessory mode.
      await Task.yield()
      openWindow(id: id)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }
  }

  static func primaryWindowDidOpen(_ window: NSWindow) {
    primaryWindows.insert(ObjectIdentifier(window))
    NSApplication.shared.setActivationPolicy(.regular)
  }

  static func primaryWindowWillClose(_ window: NSWindow) {
    primaryWindows.remove(ObjectIdentifier(window))
    if shouldBecomeAccessory(primaryWindowCount: primaryWindows.count) {
      NSApplication.shared.setActivationPolicy(.accessory)
    }
  }

  static func shouldBecomeAccessory(primaryWindowCount: Int) -> Bool {
    primaryWindowCount == 0
  }
}

private struct MeetingBarPrimaryWindowBehavior: NSViewRepresentable {
  func makeNSView(context: Context) -> MeetingBarWindowLifecycleView {
    MeetingBarWindowLifecycleView()
  }

  func updateNSView(_ nsView: MeetingBarWindowLifecycleView, context: Context) {}
}

@MainActor
private final class MeetingBarWindowLifecycleView: NSView {
  private weak var observedWindow: NSWindow?

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard observedWindow !== window else {
      return
    }
    if let observedWindow {
      NotificationCenter.default.removeObserver(
        self,
        name: NSWindow.willCloseNotification,
        object: observedWindow
      )
    }
    observedWindow = window
    guard let window else {
      return
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification,
      object: window
    )
    MeetingBarApplicationPresentation.primaryWindowDidOpen(window)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else {
      return
    }
    MeetingBarApplicationPresentation.primaryWindowWillClose(window)
  }
}

private extension View {
  func meetingBarPrimaryWindowBehavior() -> some View {
    background(MeetingBarPrimaryWindowBehavior().frame(width: 0, height: 0))
  }
}

@main
struct MeetingBarApp: App {
  private let modelContainer: ModelContainer
  @State private var controller: AppController
  @State private var navigation = MeetingBarNavigation()

  init() {
    let environment = ProcessInfo.processInfo.environment
    let isRunningTests = MeetingBarRuntime.isRunningTests(environment: environment)
    if !isRunningTests {
      MeetingBarApplicationPresentation.startInMenuBarMode()
    }

    do {
      let container = try ModelContainer(for: Recording.self)
      let fileStore = try RecordingFileStore()
      modelContainer = container
      let secretStore: any TranscriptionSecretStoring =
        isRunningTests
        ? EmptyTranscriptionSecretStore()
        : LocalTranscriptionSecretStore(rootURL: fileStore.rootURL)
      _controller = State(
        initialValue: AppController(
          modelContext: container.mainContext,
          fileStore: fileStore,
          transcriptionSecretStore: secretStore
        )
      )
    } catch {
      fatalError("MeetingBar could not initialize its local library: \(error.localizedDescription)")
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(controller: controller, navigation: navigation)
    } label: {
      MenuBarStatusLabel(controller: controller, navigation: navigation)
    }
    .menuBarExtraStyle(.window)

    Window("MeetingBar", id: "main") {
      LibraryView(controller: controller, navigation: navigation)
        .modelContainer(modelContainer)
        .meetingBarPrimaryWindowBehavior()
    }
    .defaultSize(width: 1120, height: 720)
    .commands {
      MeetingBarCommands(navigation: navigation)
    }

    Window("Welcome to MeetingBar", id: "onboarding") {
      OnboardingView(controller: controller)
        .modelContainer(modelContainer)
        .meetingBarPrimaryWindowBehavior()
    }
    .windowResizability(.contentSize)
  }
}

private struct MeetingBarCommands: Commands {
  @Environment(\.openWindow) private var openWindow
  let navigation: MeetingBarNavigation

  var body: some Commands {
    CommandGroup(replacing: .appSettings) {
      Button("Settings…") {
        navigation.showSettings()
        openMainWindow()
      }
      .keyboardShortcut(",", modifiers: .command)
    }

    CommandMenu("MeetingBar") {
      Button("Open Library") {
        navigation.showLibrary()
        openMainWindow()
      }
      .keyboardShortcut("l", modifiers: [.command, .shift])
    }
  }

  private func openMainWindow() {
    MeetingBarApplicationPresentation.openWindow(id: "main", using: openWindow)
  }
}
