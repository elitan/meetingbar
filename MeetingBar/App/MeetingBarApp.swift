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

@main
struct MeetingBarApp: App {
  private let modelContainer: ModelContainer
  @State private var controller: AppController
  @State private var navigation = MeetingBarNavigation()

  init() {
    let environment = ProcessInfo.processInfo.environment
    let isRunningTests = MeetingBarRuntime.isRunningTests(environment: environment)

    do {
      let container = try ModelContainer(for: Recording.self)
      modelContainer = container
      let secretStore: any TranscriptionSecretStoring =
        isRunningTests
        ? EmptyTranscriptionSecretStore()
        : KeychainTranscriptionSecretStore()
      _controller = State(
        initialValue: try AppController(
          modelContext: container.mainContext,
          fileStore: RecordingFileStore(),
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
    }
    .defaultSize(width: 1120, height: 720)
    .commands {
      MeetingBarCommands(navigation: navigation)
    }

    Window("Welcome to MeetingBar", id: "onboarding") {
      OnboardingView(controller: controller)
        .modelContainer(modelContainer)
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
    openWindow(id: "main")
    NSApplication.shared.activate(ignoringOtherApps: true)
  }
}
