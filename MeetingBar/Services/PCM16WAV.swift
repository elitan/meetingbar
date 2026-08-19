import Foundation

enum WAVError: LocalizedError, Equatable {
  case fileTooSmall
  case unsupportedFormat
  case invalidDataChunk

  var errorDescription: String? {
    switch self {
    case .fileTooSmall:
      "The partial recording is too small to recover."
    case .unsupportedFormat:
      "The partial recording is not a MeetingBar PCM WAV file."
    case .invalidDataChunk:
      "The partial recording has an invalid audio data chunk."
    }
  }
}

final class PCM16WAVWriter {
  static let sampleRate: UInt32 = 16_000
  static let channelCount: UInt16 = 1
  static let bitsPerSample: UInt16 = 16

  private let partialURL: URL
  private let finalURL: URL
  private let fileHandle: FileHandle
  private(set) var sampleCount: UInt64 = 0
  private var isFinished = false

  init(partialURL: URL, finalURL: URL, fileManager: FileManager = .default) throws {
    self.partialURL = partialURL
    self.finalURL = finalURL
    fileManager.createFile(atPath: partialURL.path, contents: nil)
    fileHandle = try FileHandle(forWritingTo: partialURL)
    try fileHandle.write(contentsOf: Self.header(dataByteCount: 0))
  }

  deinit {
    try? fileHandle.close()
  }

  func append(floatSamples: [Float]) throws {
    guard !isFinished, !floatSamples.isEmpty else {
      return
    }

    var data = Data(capacity: floatSamples.count * MemoryLayout<Int16>.size)
    for sample in floatSamples {
      let clipped = min(1, max(-1, sample))
      let scaled = clipped == -1 ? Int16.min : Int16((clipped * Float(Int16.max)).rounded())
      var littleEndian = scaled.littleEndian
      Swift.withUnsafeBytes(of: &littleEndian) { bytes in
        data.append(contentsOf: bytes)
      }
    }
    try fileHandle.write(contentsOf: data)
    sampleCount += UInt64(floatSamples.count)
  }

  func append(pcm16Samples: [Int16]) throws {
    guard !isFinished, !pcm16Samples.isEmpty else {
      return
    }
    var littleEndianSamples = pcm16Samples.map(\.littleEndian)
    let data = littleEndianSamples.withUnsafeMutableBytes { bytes in
      Data(bytes)
    }
    try fileHandle.write(contentsOf: data)
    sampleCount += UInt64(pcm16Samples.count)
  }

  func finish(fileManager: FileManager = .default) throws -> URL {
    guard !isFinished else {
      return finalURL
    }
    isFinished = true

    let dataByteCount = UInt32(clamping: sampleCount * UInt64(MemoryLayout<Int16>.size))
    try fileHandle.seek(toOffset: 0)
    try fileHandle.write(contentsOf: Self.header(dataByteCount: dataByteCount))
    try fileHandle.synchronize()
    try fileHandle.close()

    if fileManager.fileExists(atPath: finalURL.path) {
      try fileManager.removeItem(at: finalURL)
    }
    try fileManager.moveItem(at: partialURL, to: finalURL)
    return finalURL
  }

  private static func header(dataByteCount: UInt32) -> Data {
    var data = Data()
    data.appendASCII("RIFF")
    data.appendLittleEndian(36 &+ dataByteCount)
    data.appendASCII("WAVE")
    data.appendASCII("fmt ")
    data.appendLittleEndian(UInt32(16))
    data.appendLittleEndian(UInt16(1))
    data.appendLittleEndian(channelCount)
    data.appendLittleEndian(sampleRate)
    let byteRate = sampleRate * UInt32(channelCount) * UInt32(bitsPerSample / 8)
    data.appendLittleEndian(byteRate)
    data.appendLittleEndian(channelCount * bitsPerSample / 8)
    data.appendLittleEndian(bitsPerSample)
    data.appendASCII("data")
    data.appendLittleEndian(dataByteCount)
    return data
  }
}

enum WAVRepair {
  static func repairAndFinalize(
    partialURL: URL,
    finalURL: URL,
    fileManager: FileManager = .default
  ) throws -> URL {
    let fileHandle = try FileHandle(forUpdating: partialURL)
    defer { try? fileHandle.close() }

    let attributes = try fileManager.attributesOfItem(atPath: partialURL.path)
    let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    guard fileSize >= 44 else {
      throw WAVError.fileTooSmall
    }

    let prefix = try fileHandle.read(upToCount: 44) ?? Data()
    guard prefix.count == 44,
      prefix.asciiString(in: 0..<4) == "RIFF",
      prefix.asciiString(in: 8..<12) == "WAVE",
      prefix.asciiString(in: 36..<40) == "data"
    else {
      throw WAVError.unsupportedFormat
    }

    let dataByteCount = fileSize - 44
    guard dataByteCount <= UInt64(UInt32.max), dataByteCount.isMultiple(of: 2) else {
      throw WAVError.invalidDataChunk
    }

    try fileHandle.seek(toOffset: 4)
    try fileHandle.write(contentsOf: Data.littleEndian(UInt32(36 + dataByteCount)))
    try fileHandle.seek(toOffset: 40)
    try fileHandle.write(contentsOf: Data.littleEndian(UInt32(dataByteCount)))
    try fileHandle.synchronize()
    try fileHandle.close()

    if fileManager.fileExists(atPath: finalURL.path) {
      try fileManager.removeItem(at: finalURL)
    }
    try fileManager.moveItem(at: partialURL, to: finalURL)
    return finalURL
  }
}

extension Data {
  fileprivate mutating func appendASCII(_ string: String) {
    append(string.data(using: .ascii) ?? Data())
  }

  fileprivate mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      append(contentsOf: bytes)
    }
  }

  fileprivate static func littleEndian<T: FixedWidthInteger>(_ value: T) -> Data {
    var littleEndian = value.littleEndian
    return Swift.withUnsafeBytes(of: &littleEndian) { Data($0) }
  }

  fileprivate func asciiString(in range: Range<Int>) -> String? {
    guard range.lowerBound >= 0, range.upperBound <= count else {
      return nil
    }
    return String(data: self[range], encoding: .ascii)
  }
}
