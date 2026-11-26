import Foundation

struct CoughSummary: Codable, Sendable {
    let episodeCount: Int
    let analyzedDuration: Double
    var modelVersion: Int? = nil
}

enum CoughAnalyzer {
    static let modelVersion = 1

    static func analyze(samples: [Float], sampleRate: Int) -> CoughSummary? {
        guard let count = Int32(exactly: samples.count), let rate = Int32(exactly: sampleRate), rate > 0 else {
            return nil
        }
        let episodes = samples.withUnsafeBufferPointer { vw_cough_count($0.baseAddress, count, rate) }
        guard episodes >= 0 else { return nil }
        return CoughSummary(episodeCount: Int(episodes), analyzedDuration: Double(count) / Double(rate),
                            modelVersion: modelVersion)
    }
}
