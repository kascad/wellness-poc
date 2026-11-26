import Foundation

struct FatigueDay: Identifiable {
    let date: Date
    let score: Int
    var id: Date { date }
}

enum Fatigue {
    static let defaultScore = 66
    static let empty = "Баллы появятся после замеров за три предыдущих дня и нового замера."

    private enum Metric: CaseIterable {
        case pace, articulation, pause, cpps, cough

        var weight: Double {
            switch self {
            case .pace, .cpps: 25
            case .articulation, .pause: 20
            case .cough: 10
            }
        }

        func severity(_ value: Double, baseline: Double) -> Double {
            switch self {
            case .pace, .articulation: (baseline - value) / max(0.3 * baseline, 0.3)
            case .pause: (value - baseline) / max(baseline, 0.5)
            case .cpps: (baseline - value) / 4
            case .cough: (value - baseline) / 6
            }
        }
    }

    static func days(_ history: [Measurement], calendar: Calendar = .current) -> [FatigueDay] {
        let real = history.filter { $0.source != .telephonyDemo }
        let grouped = Dictionary(grouping: real) { calendar.startOfDay(for: $0.date) }
        let dates = grouped.keys.sorted()
        return dates.enumerated().compactMap { index, date in
            let today = grouped[date, default: []]
            let earlier = dates.prefix(index)
            var weighted = 0.0, total = 0.0, voiceWeight = 0.0
            for metric in Metric.allCases {
                let profiles = Set(today.compactMap { profile($0, for: metric) })
                let scores = profiles.compactMap { key -> Double? in
                    guard let current = dailyValue(today, metric: metric, key: key) else { return nil }
                    let reference = earlier.reversed().lazy.compactMap {
                        dailyValue(grouped[$0, default: []], metric: metric, key: key)
                    }.prefix(7)
                    guard reference.count >= 3, let baseline = median(Array(reference)) else { return nil }
                    return min(1, max(0, metric.severity(current, baseline: baseline)))
                }
                guard let score = median(scores) else { continue }
                weighted += metric.weight * score
                total += metric.weight
                if metric != .cough { voiceWeight += metric.weight }
            }
            return voiceWeight > 0 ? FatigueDay(date: date, score: Int((100 * weighted / total).rounded())) : nil
        }
    }

    private static func profile(_ entry: Measurement, for metric: Metric) -> String? {
        if metric == .cpps { return entry.voiceQuality?.profile }
        if metric == .cough {
            return entry.cough?.modelVersion == CoughAnalyzer.modelVersion ? entry.source.rawValue : nil
        }
        return entry.metrics == nil ? nil : entry.source.rawValue
    }

    private static func dailyValue(_ entries: [Measurement], metric: Metric, key: String) -> Double? {
        let values = entries.filter { profile($0, for: metric) == key }
        if metric == .cough {
            let summaries = values.compactMap(\.cough).filter { $0.analyzedDuration.isFinite && $0.analyzedDuration > 0 }
            let duration = summaries.reduce(0) { $0 + $1.analyzedDuration }
            return duration > 0 ? 60 * Double(summaries.reduce(0) { $0 + $1.episodeCount }) / duration : nil
        }
        return median(values.compactMap {
            switch metric {
            case .pace: $0.metrics?.speechRate
            case .articulation: $0.metrics?.articulationRate
            case .pause: $0.metrics.map { $0.medianPause ?? 0 }
            case .cpps: $0.voiceQuality?.cpps
            case .cough: nil
            }
        }.filter(\.isFinite))
    }

    private static func median(_ values: [Double]) -> Double? {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return nil }
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }
}
