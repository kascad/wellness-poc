import SwiftUI

struct SignalView: View {
    let history: [Measurement]

    var body: some View {
        let lastMeasurement = history.filter { $0.source != .telephonyDemo }.max { $0.date < $1.date }
        let lastScore = lastMeasurement.flatMap { latest in
            Fatigue.days(history).last { Calendar.current.isDate($0.date, inSameDayAs: latest.date) }
        }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Сигнал").font(.largeTitle.bold())
                let score = lastScore?.score ?? Fatigue.defaultScore
                VStack(spacing: 12) {
                    Text("Усталость за день")
                        .font(.headline)
                        .accessibilityHidden(true)
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
                    if let lastMeasurement {
                        Text(lastMeasurement.date.formatted(date: .abbreviated, time: .shortened))
                            .font(.footnote).foregroundStyle(.secondary)
                            .padding(.top, 16)
                    }
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
                .padding(.top, 26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }
}
