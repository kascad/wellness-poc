import SwiftUI

private enum SpeechIndicator: CaseIterable {
    case pace, pause

    var title: String { self == .pace ? "Темп речи" : "Медианная пауза" }

    func value(in sample: Measurement) -> Double? {
        self == .pace ? sample.metrics?.speechRate : sample.metrics?.medianPause
    }

    func describe(_ value: Double) -> String {
        "\(number(value)) \(self == .pace ? "слога/с" : "с")"
    }
}

struct SignalView: View {
    let history: [Measurement]
    let tracking: HealthTracking
    private let requiredReferenceCount = 3

    var body: some View {
        let samples = history.filter { $0.source == .microphone && $0.metrics != nil }.sorted { $0.date < $1.date }
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Сигнал").font(.largeTitle.bold())
                if tracking.paused {
                    Label("Отслеживание приостановлено", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                if let recommendation = tracking.active {
                    HealthRecommendationCard(tracking: tracking, recommendation: recommendation)
                }
                if let last = samples.last {
                    Text("Последний замер").font(.title2.bold())
                    Text(last.date.formatted(date: .abbreviated, time: .shortened))
                        .foregroundStyle(.secondary)
                    MeasurementDetails(entry: last)
                    Text("Сравнение с предыдущими").font(.title3.bold())
                    if samples.count <= requiredReferenceCount {
                        Label("База сравнения: \(samples.count - 1) из \(requiredReferenceCount)", systemImage: "waveform")
                        Text("Сделайте ещё несколько замеров в похожих условиях. Сравнение появится после трёх предыдущих записей.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(SpeechIndicator.allCases, id: \.self) { indicator in
                            comparison(indicator, last: last, earlier: Array(samples.dropLast().suffix(7)))
                        }
                        Text("Сравнение с медианой последних семи предыдущих замеров или всех доступных, если их меньше.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Text("Темп и паузы описывают изменения речи. По ним пока нельзя оценить уровень усталости.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                vowelSignal
                coughSignal
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }

    private var coughSignal: some View {
        let start = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
        let samples = history.filter {
            ($0.source == .microphone || $0.source == .sustainedVowel) && $0.date >= start
        }.compactMap(\.cough).filter { $0.modelVersion == CoughAnalyzer.modelVersion }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Кашель · 7 дней").font(.title3.bold())
            if samples.isEmpty {
                Text("Пока нет записей, проверенных на кашель.")
            } else {
                let episodes = samples.reduce(0) { $0 + $1.episodeCount }
                let duration = samples.reduce(0.0) { $0 + $1.analyzedDuration }
                LabeledContent("Вероятных эпизодов", value: episodes.formatted())
                Text("Время анализа записей: \(number(duration)) с")
                Text("Частота: \(number(Double(episodes) * 60 / duration)) эпиз./мин записи")
            }
            Text("Учитываются только ручные замеры с микрофона. По этому показателю нельзя определить причину кашля.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private var vowelSignal: some View {
        let recordings = history.sorted { $0.date < $1.date }.compactMap(\.voiceQuality)
        return VStack(alignment: .leading, spacing: 9) {
            Text("Звучание голоса · CPPS").font(.title3.bold())
            if let current = recordings.last {
                Text("\(number(current.cpps)) дБ").font(.title2.bold()).foregroundStyle(emerald)
                let reference = recordings.dropLast().filter { $0.profile == current.profile }.suffix(7)
                Text(current.inputName).font(.footnote).foregroundStyle(.secondary)
                if reference.count >= 5 {
                    let values = reference.map(\.cpps).sorted()
                    let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
                    let delta = current.cpps - median
                    let signed = delta.formatted(.number.sign(strategy: .always()).precision(.fractionLength(1)).locale(Locale(identifier: "ru_RU")))
                    Text("Личная медиана: \(number(median)) дБ · разница \(signed) дБ")
                    Text("Сравнение с \(reference.count) предыдущими замерами на том же микрофоне.")
                        .font(.footnote).foregroundStyle(.secondary)
                } else {
                    Text("Личная база: \(reference.count) из 5 предыдущих замеров на этом микрофоне.")
                }
            } else {
                Text("Сделайте первый замер «А-а-а» на вкладке «Сегодня».")
            }
            Text("Показатель описывает звучание голоса. Причину изменений по нему определить нельзя.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func comparison(_ indicator: SpeechIndicator, last: Measurement, earlier: [Measurement]) -> some View {
        let values = earlier.compactMap(indicator.value).sorted()
        return VStack(alignment: .leading, spacing: 5) {
            Text(indicator.title).font(.headline)
            if let current = indicator.value(in: last), values.count >= requiredReferenceCount {
                let median = (values[(values.count - 1) / 2] + values[values.count / 2]) / 2
                let difference = Int(((current / median - 1) * 100).rounded())
                Text("\(indicator.describe(current)) · ранее \(indicator.describe(median))")
                Text(difference == 0 ? "Разница меньше 1%" : "\(difference > 0 ? "+" : "−")\(abs(difference))% к предыдущей медиане")
                    .font(.subheadline).foregroundStyle(emerald)
            } else {
                Text("Недостаточно замеров с измеримыми паузами.").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(.white.opacity(0.65), in: .rect(cornerRadius: 16))
    }
}

struct PeriodSummary: View {
    let history: [Measurement]

    var body: some View {
        let samples = history.sorted { $0.date < $1.date }
        if !samples.isEmpty {
            VStack(alignment: .leading, spacing: 9) {
                Text("Что изменилось").font(.headline)
                Text("Замеров за период: \(samples.count)").foregroundStyle(.secondary)
                if samples.count == 1 {
                    Text("Для сравнения нужен ещё один замер.")
                } else {
                    ForEach(SpeechIndicator.allCases, id: \.self) { indicator in
                        let values = samples.compactMap(indicator.value)
                        if values.count >= 2, let first = values.first, let last = values.last {
                            Text("\(indicator.title): \(indicator.describe(first)) → \(indicator.describe(last))")
                        } else {
                            Text("Для сравнения пауз нужны два замера с паузами от 0,25 с.")
                        }
                    }
                    Text("Первое и последнее доступные значения за период. Разница между ними сама по себе не показывает устойчивый тренд.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(.white.opacity(0.65), in: .rect(cornerRadius: 16))
        }
    }
}
