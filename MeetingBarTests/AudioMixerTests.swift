import XCTest

@testable import MeetingBar

final class AudioMixerTests: XCTestCase {
  func testMixesAlignedMicrophoneAndSystemSamples() {
    var mixer = AudioMixer()
    mixer.appendSystem([0.4, -0.4])
    assertFloatArraysEqual(mixer.mixMicrophone([0.2, 0.2]), [0.6, -0.2], accuracy: 0.0001)
  }

  func testMissingSystemInputIsSilenceAtFullMicrophoneGain() {
    var mixer = AudioMixer()
    XCTAssertEqual(mixer.mixMicrophone([0.2, -0.7]), [0.2, -0.7])
  }

  func testUnequalBuffersKeepSystemTail() {
    var mixer = AudioMixer()
    mixer.appendSystem([0.2, 0.4, 0.6])

    assertFloatArraysEqual(mixer.mixMicrophone([0.2]), [0.4], accuracy: 0.0001)
    XCTAssertEqual(mixer.drainSystemTail(), [0.4, 0.6])
  }

  func testShortSystemBufferFallsBackToMicrophone() {
    var mixer = AudioMixer()
    mixer.appendSystem([0.8])

    assertFloatArraysEqual(mixer.mixMicrophone([0.8, -0.4]), [1, -0.4], accuracy: 0.0001)
  }

  func testClippingIsPrevented() {
    var mixer = AudioMixer()
    mixer.appendSystem([1, -1])
    let output = mixer.mixMicrophone([1, -1])

    XCTAssertEqual(output, [1, -1])
    XCTAssertTrue(output.allSatisfy { (-1...1).contains($0) })
  }
}

extension XCTestCase {
  fileprivate func assertFloatArraysEqual(
    _ expression1: @autoclosure () throws -> [Float],
    _ expression2: @autoclosure () throws -> [Float],
    accuracy: Float,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    do {
      let first = try expression1()
      let second = try expression2()
      XCTAssertEqual(first.count, second.count, file: file, line: line)
      for (left, right) in zip(first, second) {
        XCTAssertEqual(left, right, accuracy: accuracy, file: file, line: line)
      }
    } catch {
      XCTFail(error.localizedDescription, file: file, line: line)
    }
  }
}
