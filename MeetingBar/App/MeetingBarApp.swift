import SwiftData
import SwiftUI

@main
struct MeetingBarApp: App {
  private let modelContainer: ModelContainer
  @State private var controller: AppController

  init() {
    do {
      let container = try ModelContainer(for: Recording.self)
      modelContainer = container
      _controller = State(initialValue: try AppController(modelContext: container.mainContext))
    } catch {
      fatalError("MeetingBar could not initialize its local library: \(error.localizedDescription)")
    }
  }

  var body: some Scene {
    MenuBarExtra {
      MenuBarView(controller: controller)
    } label: {
      MenuBarStatusLabel(controller: controller)
    }
    .menuBarExtraStyle(.menu)

    Window("MeetingBar", id: "library") {
      LibraryView(controller: controller)
        .modelContainer(modelContainer)
    }
    .defaultSize(width: 920, height: 620)

    Window("Welcome to MeetingBar", id: "onboarding") {
      OnboardingView(controller: controller)
        .modelContainer(modelContainer)
    }
    .windowResizability(.contentSize)

    Settings {
      SettingsView(controller: controller)
        .modelContainer(modelContainer)
    }
  }
}

