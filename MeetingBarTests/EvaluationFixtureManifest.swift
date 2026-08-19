import Foundation

struct EvaluationFixtureManifest: Codable {
  let dataset: String
  let license: String
  let fixtures: [EvaluationFixture]
}

struct EvaluationFixture: Codable {
  let id: String
  let language: String
  let audioPath: String
  let reference: String
  let maximumWER: Double?
}
