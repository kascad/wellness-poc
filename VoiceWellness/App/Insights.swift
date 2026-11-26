import SwiftUI

struct SignalView: View {
    let history: [Measurement]

    var body: some View {
        let lastMeasurement = history.filter { $0.source != .telephonyDemo }.max { $0.date < $1.date }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Сигнал").font(.largeTitle.bold())
                FatigueReadout(history: history, date: lastMeasurement?.date)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }
}


struct FatigueReadout: View {
    let history: [Measurement]
    let date: Date?

    var body: some View {
        let estimate = date.flatMap { date in
            Fatigue.days(history).last { Calendar.current.isDate($0.date, inSameDayAs: date) }
        }
        VStack(spacing: 12) {
            Text("Усталость за день")
                .font(.headline)
                .accessibilityHidden(estimate != nil)
            if let estimate {
                let score = estimate.score
                Text(score.formatted())
                    .font(.system(size: 160, weight: .semibold))
                    .fontWidth(.condensed)
                    .monospacedDigit()
                    .foregroundStyle(emerald)
                    .lineLimit(1)
                    .minimumScaleFactor(0.45)
                    .scaleEffect(x: 0.91, y: 1.14)
                    .frame(height: 184)
                    .accessibilityLabel("Усталость за день, \(score) из 100")
                Text("из 100")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                if estimate.preliminary {
                    Text("Предварительная оценка").font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Пока нет оценки").foregroundStyle(.secondary)
            }
            if let date {
                Text(date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
                    .padding(.top, 16)
            }
            if let estimate {
                Text(estimate.guidance)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
                    .padding(.top, 36)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 26)
    }
}
