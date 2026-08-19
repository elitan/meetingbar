import Foundation
import XCTest
@testable import MeetingBar

final class WAVRecoveryTests: XCTestCase {
  func testCleanFinishWritesFinalHeaderAndAtomicallyRenames() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = directory.appending(path: "audio.partial.wav")
    let final = directory.appending(path: "audio.wav")
    let writer = try PCM16WAVWriter(partialURL: partial, finalURL: final)
    try writer.append(floatSamples: [0, 0.5, -0.5])

    _ = try writer.finish()

    XCTAssertFalse(FileManager.default.fileExists(atPath: partial.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
    let data = try Data(contentsOf: final)
    XCTAssertEqual(littleEndianUInt32(data, offset: 4), UInt32(data.count - 8))
    XCTAssertEqual(littleEndianUInt32(data, offset: 40), 6)
  }

  func testInterruptedWriterHeaderIsRecoverable() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = directory.appending(path: "audio.partial.wav")
    let final = directory.appending(path: "audio.wav")

    var writer: PCM16WAVWriter? = try PCM16WAVWriter(partialURL: partial, finalURL: final)
    try writer?.append(floatSamples: [0.25, -0.25, 0, 0.5])
    writer = nil

    _ = try WAVRepair.repairAndFinalize(partialURL: partial, finalURL: final)

    let data = try Data(contentsOf: final)
    XCTAssertEqual(littleEndianUInt32(data, offset: 4), UInt32(data.count - 8))
    XCTAssertEqual(littleEndianUInt32(data, offset: 40), 8)
  }

  func testTruncatedPartialIsRejected() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let partial = directory.appending(path: "audio.partial.wav")
    let final = directory.appending(path: "audio.wav")
    try Data([0, 1, 2]).write(to: partial)

    XCTAssertThrowsError(
      try WAVRepair.repairAndFinalize(partialURL: partial, finalURL: final)
    ) { error in
      XCTAssertEqual(error as? WAVError, .fileTooSmall)
    }
  }

  private func makeTemporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  private func littleEndianUInt32(_ data: Data, offset: Int) -> UInt32 {
    data.withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}

