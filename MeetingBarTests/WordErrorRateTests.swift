import Foundation
import XCTest

struct WordErrorRateResult: Equatable {
  let edits: Int
  let referenceWordCount: Int

  var rate: Double {
    guard referenceWordCount > 0 else {
      return edits == 0 ? 0 : 1
    }
    return Double(edits) / Double(referenceWordCount)
  }
}

enum WordErrorRate {
  static func measure(reference: String, hypothesis: String) -> WordErrorRateResult {
    let referenceWords = words(reference)
    let hypothesisWords = words(hypothesis)
    var previous = Array(0...hypothesisWords.count)

    for (referenceIndex, referenceWord) in referenceWords.enumerated() {
      var current = [referenceIndex + 1]
      current.reserveCapacity(hypothesisWords.count + 1)
      for (hypothesisIndex, hypothesisWord) in hypothesisWords.enumerated() {
        let substitutionCost = referenceWord == hypothesisWord ? 0 : 1
        current.append(
          min(
            min(
              current[hypothesisIndex] + 1,
              previous[hypothesisIndex + 1] + 1
            ),
            previous[hypothesisIndex] + substitutionCost
          )
        )
      }
      previous = current
    }

    return WordErrorRateResult(
      edits: previous.last ?? referenceWords.count,
      referenceWordCount: referenceWords.count
    )
  }

  static func words(_ text: String) -> [String] {
    text.lowercased()
      .split { character in
        !character.isLetter && !character.isNumber
      }
      .map(String.init)
  }
}

final class WordErrorRateTests: XCTestCase {
  func testIgnoresCaseAndPunctuationWhilePreservingSwedishWords() {
    let result = WordErrorRate.measure(
      reference: "Räksmörgås, ÄR gott!",
      hypothesis: "räksmörgås är gott"
    )
    XCTAssertEqual(result, WordErrorRateResult(edits: 0, referenceWordCount: 3))
  }

  func testCountsInsertionsDeletionsAndSubstitutions() {
    let result = WordErrorRate.measure(
      reference: "one two three four",
      hypothesis: "one too extra four"
    )
    XCTAssertEqual(result.edits, 2)
    XCTAssertEqual(result.rate, 0.5)
  }
}
