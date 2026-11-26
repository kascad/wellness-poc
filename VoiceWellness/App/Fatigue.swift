import Foundation

struct FatigueDay: Identifiable {
    let date: Date
    let score: Int
    let preliminary: Bool
    var id: Date { date }

    var guidance: String {
        switch score {
        case 0...33: "Голосовая усталость низкая. Продолжайте в привычном режиме."
        case 34...66: "Голосовая усталость умеренная. Сделайте короткую паузу в разговорах."
        default: "Голосовая усталость высокая. По возможности сократите разговоры и дайте голосу отдохнуть."
        }
    }
}

enum Fatigue {
    static let empty = "Сделайте замер голоса, чтобы получить оценку."

    private enum Metric: CaseIterable {
        case pace, articulation, pause, cpps, cough

        var weight: Double {
            switch self {
            case .pace, .cpps: 25
            case .articulation, .pause: 20
            case .cough: 10
            }
        }

        var initialReference: Double {
            switch self {
            case .pace: 2.7
            case .articulation: 3.35
            case .pause: 0.55
            case .cpps: 14
            case .cough: 0
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
            var preliminary = false
            for metric in Metric.allCases {
                let profiles = Set(today.compactMap { profile($0, for: metric) })
                let scores = profiles.compactMap { key -> Double? in
                    guard let current = dailyValue(today, metric: metric, key: key) else { return nil }
                    let reference = earlier.reversed().lazy.compactMap {
                        dailyValue(grouped[$0, default: []], metric: metric, key: key)
                    }.prefix(7)
                    let personal = reference.count >= 3 ? median(Array(reference)) : nil
                    if personal == nil { preliminary = true }
                    let baseline = personal ?? metric.initialReference
                    return min(1, max(-1, metric.severity(current, baseline: baseline)))
                }
                guard let score = median(scores) else { continue }
                weighted += metric.weight * score
                total += metric.weight
                if metric != .cough { voiceWeight += metric.weight }
            }
            guard voiceWeight > 0 else { return nil }
            return FatigueDay(date: date, score: score(for: weighted / total), preliminary: preliminary)
        }
    }

    private static func score(for deviation: Double) -> Int {
        let baseline = 12.0
        let span = deviation < 0 ? baseline : 100 - baseline
        return Int((baseline + span * deviation).rounded())
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
