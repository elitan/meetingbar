@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum AudioConversionError: LocalizedError {
  case invalidSampleBuffer
  case converterUnavailable
  case conversionFailed

  var errorDescription: String? {
    switch self {
    case .invalidSampleBuffer:
      "ScreenCaptureKit returned an invalid audio buffer."
    case .converterUnavailable:
      "The selected audio device uses a format MeetingBar cannot convert."
    case .conversionFailed:
      "MeetingBar could not convert an audio buffer to 16 kHz mono."
    }
  }
}

struct ConvertedAudioBuffer: Sendable {
  let samples: [Float]
  let presentationTimeSeconds: Double?
}

final class AudioSampleConverter {
  private static let targetFormat = AVAudioFormat(
    commonFormat: .pcmFormatFloat32,
    sampleRate: 16_000,
    channels: 1,
    interleaved: false
  )!

  private var inputFormat: AVAudioFormat?
  private var converter: AVAudioConverter?

  func convert(_ sampleBuffer: CMSampleBuffer) throws -> ConvertedAudioBuffer {
    guard CMSampleBufferIsValid(sampleBuffer), let buffer = sampleBuffer.audioPCMBuffer else {
      throw AudioConversionError.invalidSampleBuffer
    }

    if inputFormat != buffer.format {
      inputFormat = buffer.format
      if buffer.format == Self.targetFormat {
        converter = nil
      } else {
        guard let newConverter = AVAudioConverter(from: buffer.format, to: Self.targetFormat) else {
          throw AudioConversionError.converterUnavailable
        }
        converter = newConverter
      }
    }

    let convertedBuffer: AVAudioPCMBuffer
    if let converter {
      let ratio = Self.targetFormat.sampleRate / buffer.format.sampleRate
      let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1_024)
      guard
        let output = AVAudioPCMBuffer(
          pcmFormat: Self.targetFormat,
          frameCapacity: capacity
        )
      else {
        throw AudioConversionError.conversionFailed
      }

      var conversionError: NSError?
      let input = ConverterInput(buffer: buffer)
      let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
        input.next(status: inputStatus)
      }
      if conversionError != nil || status == .error {
        throw conversionError ?? AudioConversionError.conversionFailed
      }
      convertedBuffer = output
    } else {
      convertedBuffer = buffer
    }

    guard let channel = convertedBuffer.floatChannelData?[0] else {
      throw AudioConversionError.conversionFailed
    }
    let samples = Array(
      UnsafeBufferPointer(
        start: channel,
        count: Int(convertedBuffer.frameLength)
      )
    )
    let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    let presentationTimeSeconds =
      presentationTime.isValid && presentationTime.isNumeric
      ? CMTimeGetSeconds(presentationTime)
      : nil
    return ConvertedAudioBuffer(
      samples: samples,
      presentationTimeSeconds: presentationTimeSeconds
    )
  }
}

private final class ConverterInput: @unchecked Sendable {
  private let buffer: AVAudioPCMBuffer
  private var wasSupplied = false

  init(buffer: AVAudioPCMBuffer) {
    self.buffer = buffer
  }

  func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
    if wasSupplied {
      status.pointee = .noDataNow
      return nil
    }
    wasSupplied = true
    status.pointee = .haveData
    return buffer
  }
}

extension CMSampleBuffer {
  fileprivate var audioPCMBuffer: AVAudioPCMBuffer? {
    guard let formatDescription = CMSampleBufferGetFormatDescription(self),
      let streamDescription = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)
    else {
      return nil
    }

    var mutableDescription = streamDescription.pointee
    guard let format = AVAudioFormat(streamDescription: &mutableDescription) else {
      return nil
    }

    let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(self))
    guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frameCount) else {
      return nil
    }
    buffer.frameLength = frameCount

    var bufferListSize = 0
    let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      self,
      bufferListSizeNeededOut: &bufferListSize,
      bufferListOut: nil,
      bufferListSize: 0,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: nil
    )
    guard sizeStatus == noErr, bufferListSize >= MemoryLayout<AudioBufferList>.size else {
      return nil
    }

    let rawBufferList = UnsafeMutableRawPointer.allocate(
      byteCount: bufferListSize,
      alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { rawBufferList.deallocate() }
    let audioBufferList = rawBufferList.assumingMemoryBound(to: AudioBufferList.self)
    var blockBuffer: CMBlockBuffer?

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
      self,
      bufferListSizeNeededOut: nil,
      bufferListOut: audioBufferList,
      bufferListSize: bufferListSize,
      blockBufferAllocator: nil,
      blockBufferMemoryAllocator: nil,
      flags: 0,
      blockBufferOut: &blockBuffer
    )
    guard status == noErr else {
      return nil
    }

    let sourceBuffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let destinationBuffers = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
    for index in 0..<min(sourceBuffers.count, destinationBuffers.count) {
      let source = sourceBuffers[index]
      var destination = destinationBuffers[index]
      destination.mDataByteSize = source.mDataByteSize
      if let sourceData = source.mData, let destinationData = destination.mData {
        memcpy(destinationData, sourceData, Int(source.mDataByteSize))
      }
      destinationBuffers[index] = destination
    }
    return buffer
  }
}
