import Foundation

struct SpeechMetrics: Codable, Sendable {
    let syllables: Int
    let speechDuration: Double
    let elapsedDuration: Double
    let pauses: [Double]

    var speechRate: Double { Double(syllables) / elapsedDuration }
    var articulationRate: Double { Double(syllables) / speechDuration }
    var medianPause: Double? {
        let sorted = pauses.sorted()
        guard !sorted.isEmpty else { return nil }
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }
}

enum SpeechError: LocalizedError {
    case insufficientSpeech
    var errorDescription: String? {
        "Распознано слишком мало речи. Прочитайте текст ещё раз в тихом месте."
    }
}

enum SpeechAnalyzer {
    // Adapted method: relative intensity threshold, peak dip and voicing gate,
    // as used by Avrova's wav_analizer.praat. Thresholds are prototype values.
    static func analyze(_ samples: [Float], sampleRate: Int) throws -> SpeechMetrics {
        let hop = max(1, sampleRate / 100)
        let step = Double(hop) / Double(sampleRate)
        let window = hop * 3
        guard samples.count >= window else { throw SpeechError.insufficientSpeech }
        let starts = Array(stride(from: 0, through: samples.count - window, by: hop))
        let levels = starts.map { start in
            let energy = samples[start..<(start + window)].reduce(0.0) { $0 + Double($1 * $1) }
            return 10 * log10(max(1e-10, energy / Double(window)))
        }
        let ordered = levels.sorted()
        let loud = ordered[Int(Double(ordered.count - 1) * 0.99)]
        let quiet = ordered[ordered.count / 10]
        let threshold = max(-58, loud - 25, min(quiet + 8, loud - 7))
        let active = levels.indices.filter { levels[$0] >= threshold }
        guard let first = active.first, let last = active.last else { throw SpeechError.insufficientSpeech }
        // Keep only internal pauses of at least 250 ms. Short gaps are part of speech.
        let pauses = zip(active, active.dropFirst()).compactMap { left, right -> Double? in
            let duration = Double(right - left - 1) * step
            return duration >= 0.25 ? duration : nil
        }
        let elapsed = Double(last - first + 1) * step
        let speech = elapsed - pauses.reduce(0, +)
        guard speech >= 1.5 else { throw SpeechError.insufficientSpeech }

        let smooth = levels.indices.map { index in
            let range = max(0, index - 2)...min(levels.count - 1, index + 2)
            return range.reduce(0.0) { $0 + levels[$1] } / Double(range.count)
        }
        var nuclei: [Int] = []
        for i in 1..<(smooth.count - 1) where smooth[i] >= threshold && smooth[i] > smooth[i - 1] && smooth[i] >= smooth[i + 1] {
            let left = max(0, i - 12)
            let right = min(smooth.count - 1, i + 12)
            let valley = max(smooth[left...i].min()!, smooth[i...right].min()!)
            guard smooth[i] - valley >= 2,
                  voiced(samples, start: starts[i], window: window, sampleRate: sampleRate) else { continue }
            if let previous = nuclei.last, Double(i - previous) * step < 0.09 {
                if smooth[i] > smooth[previous] { nuclei[nuclei.count - 1] = i }
            } else {
                nuclei.append(i)
            }
        }
        guard nuclei.count >= 3 else { throw SpeechError.insufficientSpeech }
        return SpeechMetrics(syllables: nuclei.count, speechDuration: speech, elapsedDuration: elapsed, pauses: pauses)
    }

    private static func voiced(_ samples: [Float], start: Int, window: Int, sampleRate: Int) -> Bool {
        let strideSize = max(1, sampleRate / 8000)
        let segment = stride(from: start, to: start + window, by: strideSize).map { Double(samples[$0]) }
        let mean = segment.reduce(0, +) / Double(segment.count)
        let centered = segment.map { $0 - mean }
        let minLag = max(1, sampleRate / strideSize / 450)
        let maxLag = min(segment.count / 2, sampleRate / strideSize / 75)
        guard minLag <= maxLag else { return false }
        for lag in minLag...maxLag {
            var leftEnergy = 0.0
            var rightEnergy = 0.0
            var product = 0.0
            for index in 0..<(centered.count - lag) {
                let left = centered[index]
                let right = centered[index + lag]
                product += left * right
                leftEnergy += left * left
                rightEnergy += right * right
            }
            if product > 0.65 * sqrt(leftEnergy * rightEnergy) { return true }
        }
        return false
    }
}
