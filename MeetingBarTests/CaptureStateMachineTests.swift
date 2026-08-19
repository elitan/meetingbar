import XCTest
@testable import MeetingBar

final class CaptureStateMachineTests: XCTestCase {
  func testCompleteCaptureCycle() throws {
    var machine = CaptureStateMachine()
    let start = Date(timeIntervalSince1970: 100)

    try machine.apply(.requestStart)
    XCTAssertEqual(machine.state, .starting)
    try machine.apply(.didStart(start))
    XCTAssertEqual(machine.state, .recording(startedAt: start))
    try machine.apply(.requestStop)
    XCTAssertEqual(machine.state, .stopping)
    try machine.apply(.didStop)
    XCTAssertEqual(machine.state, .idle)
  }

  func testRepeatedStartHotkeyIsRejectedWithoutChangingState() throws {
    var machine = CaptureStateMachine()
    try machine.apply(.requestStart)

    XCTAssertThrowsError(try machine.apply(.requestStart))
    XCTAssertEqual(machine.state, .starting)
  }

  func testRepeatedStopHotkeyIsRejectedWithoutChangingState() throws {
    var machine = CaptureStateMachine()
    try machine.apply(.requestStart)
    try machine.apply(.didStart(.now))
    try machine.apply(.requestStop)

    XCTAssertThrowsError(try machine.apply(.requestStop))
    XCTAssertEqual(machine.state, .stopping)
  }

  func testFailedStartReturnsToIdle() throws {
    var machine = CaptureStateMachine()
    try machine.apply(.requestStart)
    try machine.apply(.startFailed)
    XCTAssertEqual(machine.state, .idle)
  }
}

