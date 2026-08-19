import Foundation

struct AudioMixer: Sendable {
  private var systemSamples: [Float] = []
  private var readIndex = 0

  var bufferedSystemSampleCount: Int {
    systemSamples.count - readIndex
  }

  mutating func appendSystem(_ samples: [Float]) {
    guard !samples.isEmpty else {
      return
    }
    compactIfNeeded()
    systemSamples.append(contentsOf: samples)
  }

  mutating func mixMicrophone(_ microphoneSamples: [Float]) -> [Float] {
    guard !microphoneSamples.isEmpty else {
      return []
    }

    var mixed = [Float]()
    mixed.reserveCapacity(microphoneSamples.count)

    for microphoneSample in microphoneSamples {
      guard readIndex < systemSamples.count else {
        mixed.append(clamp(microphoneSample))
        continue
      }
      let systemSample = systemSamples[readIndex]
      readIndex += 1
      mixed.append(clamp((microphoneSample + systemSample) * 0.5))
    }

    compactIfNeeded()
    return mixed
  }

  mutating func drainSystemTail() -> [Float] {
    guard readIndex < systemSamples.count else {
      systemSamples.removeAll(keepingCapacity: true)
      readIndex = 0
      return []
    }
    let tail = Array(systemSamples[readIndex...]).map(clamp)
    systemSamples.removeAll(keepingCapacity: true)
    readIndex = 0
    return tail
  }

  private mutating func compactIfNeeded() {
    guard readIndex > 8_192, readIndex * 2 > systemSamples.count else {
      return
    }
    systemSamples.removeFirst(readIndex)
    readIndex = 0
  }

  private func clamp(_ sample: Float) -> Float {
    min(1, max(-1, sample))
  }
}
