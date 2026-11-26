import Charts
import SwiftUI

let emerald = Color(red: 0.02, green: 0.34, blue: 0.24)
let pearl = Color(red: 0.97, green: 0.97, blue: 0.94)
private let russian = Locale(identifier: "ru_RU")

@main
struct VoiceWellnessApp: App {
    @UIApplicationDelegateAdaptor(HealthNotificationDelegate.self) private var notificationDelegate
    var body: some Scene {
        WindowGroup {
            WellnessView()
                .tint(emerald)
                .preferredColorScheme(.light)
                .environment(\.locale, russian)
        }
    }
}

private enum RecordingRequest: String, Identifiable {
    case reading, vowel

    var id: Self { self }
    var source: MeasurementSource { self == .vowel ? .sustainedVowel : .microphone }
    var title: String { self == .vowel ? "Скажите «А-а-а»" : "Замер голоса" }
}

private struct RecordingSteps<Content: View>: View {
    let initial: RecordingRequest
    let model: MeasurementModel
    @ViewBuilder let content: (RecordingRequest, Int?, Measurement?) -> Content
    @State private var reading: Measurement?

    var body: some View {
        let combined = initial == .reading
        let step: RecordingRequest = combined && reading != nil ? .vowel : initial
        content(step, combined ? (reading == nil ? 1 : 2) : nil, reading)
            .onChange(of: model.result?.id) {
                guard combined, reading == nil,
                      let result = model.result, result.source == .microphone,
                      result.metrics != nil else { return }
                reading = result
            }
    }
}

struct WellnessView: View {
    @State private var model = MeasurementModel()
    @State private var tracking = HealthTracking.shared
    @State private var recordingRequest: RecordingRequest?
    @State private var showTelephony = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView {
            Tab("Сегодня", systemImage: "waveform") {
                today
            }
            Tab("Сигнал", systemImage: "waveform.path") {
                SignalView(history: model.history, tracking: tracking)
            }
            Tab("Динамика", systemImage: "chart.xyaxis.line") {
                HistoryView(history: model.history)
            }
            Tab("Настройки", systemImage: "gearshape") {
                DataSettingsView(model: model, tracking: tracking)
            }
        }
        .fullScreenCover(item: $recordingRequest, onDismiss: { model.cancel() }) { request in
            RecordingSteps(initial: request, model: model) { current, step, reading in
                recordingScreen(current, step: step, reading: reading)
            }
        }
        .sheet(isPresented: $showTelephony) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        Label("talk-recording", systemImage: "phone")
                            .font(.title.bold())
                        Text("Подключение к телефонным звонкам появится после интеграции с услугой VoiceTech «Интеллектуальная запись».")
                        Button("Открыть Мой МТС") {
                            let service = URL(string: "mymts://action/service?alias=intellektualnaya-zapis-promo")!
                            let help = URL(string: "https://support.mts.ru/servisi_voicetech/intellektualnaya-zapis/kak-podklyuchit-uslugu-intellektualnaya-zapis")!
                            openURL(service) { accepted in
                                if !accepted { openURL(help) }
                            }
                        }
                        .buttonStyle(.glass)
                        Button("Запустить демозамер") { Task { await model.runTelephonyDemo() } }
                            .buttonStyle(.glassProminent)
                            .disabled(model.busy)
                        if let result = model.result, result.source == .telephonyDemo, let metrics = result.metrics {
                            MetricRows(metrics: metrics)
                        }
                        if let error = model.error { Text(error).foregroundStyle(.secondary) }
                    }
                    .padding(24)
                }
                .background(pearl.ignoresSafeArea())
                .navigationTitle("Телефония")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") { showTelephony = false }.disabled(model.busy)
                    }
                }
            }
            .interactiveDismissDisabled(model.busy)
        }
        .onChange(of: tracking.paused) { _, paused in
            if paused {
                model.cancel()
                recordingRequest = nil
                showTelephony = false
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background, model.recording {
                model.cancel()
                model.error = "Запись остановлена при сворачивании приложения."
            }
        }
    }

    private var today: some View {
        ScrollView {
            VStack(spacing: 19) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Голос").font(.system(.largeTitle, design: .default, weight: .bold))
                        Text(Date.now.formatted(.dateTime.day().month(.wide).locale(russian)))
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Image("EcoLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .accessibilityHidden(true)
                }
                if let path = Bundle.main.path(forResource: "voice-wave", ofType: "jpg"),
                   let artwork = UIImage(contentsOfFile: path) {
                    Image(uiImage: artwork)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 230)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .clipShape(.rect(cornerRadius: 30))
                        .accessibilityHidden(true)
                }
                VStack(spacing: 6) {
                    Text("Ваш голос сегодня").font(.title2.bold())
                    Text(tracking.paused ? "Отслеживание приостановлено" : "Короткий замер темпа и пауз").foregroundStyle(.secondary)
                }
                Button {
                    model.resetResult()
                    recordingRequest = .reading
                } label: {
                    Text("Начать замер").font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glassProminent)
                .disabled(tracking.paused)
                Button {
                    model.resetResult()
                    recordingRequest = .vowel
                } label: {
                    Label("Скажите «А-а-а»", systemImage: "mic")
                        .frame(minHeight: 30)
                }
                .buttonStyle(.glass)
                .disabled(tracking.paused)
                if let last = model.history.last(where: { $0.source == .microphone }) {
                    Text("Последний замер · \(last.date.formatted(.dateTime.day().month().hour().minute().locale(russian)))")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button {
                    model.resetResult()
                    showTelephony = true
                } label: {
                    Label("Телефония · демо", systemImage: "phone")
                        .frame(minHeight: 30)
                }
                .buttonStyle(.glass)
                .disabled(tracking.paused)
            }
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }

    private func recordingScreen(_ request: RecordingRequest, step: Int?, reading: Measurement?) -> some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 26) {
                    if let step {
                        Text("Шаг \(step) из 2").font(.subheadline.weight(.semibold))
                            .foregroundStyle(emerald)
                    }
                    if let result = model.result, result.source == request.source {
                        Text("Замер сохранён").font(.largeTitle.bold())
                        if let reading {
                            Text("Чтение").font(.headline)
                            MeasurementDetails(entry: reading)
                            Text("Гласная «А»").font(.headline)
                        }
                        MeasurementDetails(entry: result)
                        if result.source == .microphone, result.metrics == nil {
                            Text("Для расчёта темпа и пауз в записи было мало речи. Повторите чтение, чтобы перейти к «А-а-а».")
                                .font(.footnote).foregroundStyle(.secondary)
                            Button("Повторить чтение") { model.resetResult() }
                                .buttonStyle(.glass)
                        }
                        Button("Готово") { recordingRequest = nil }
                            .buttonStyle(.glassProminent)
                    } else if let error = model.error {
                        ContentUnavailableView("Не удалось выполнить замер", systemImage: "waveform.badge.exclamationmark",
                                               description: Text(error))
                        Button("Повторить запись") {
                            model.error = nil
                            Task { await model.start(source: request.source) }
                        }
                        .buttonStyle(.glassProminent)
                    } else {
                        if request.source == .sustainedVowel {
                            if reading != nil {
                                Label("Замер речи сохранён", systemImage: "checkmark.circle")
                                    .foregroundStyle(emerald)
                            }
                            Text("А-а-а").font(.largeTitle.bold())
                            Text("После запуска подождите секунду в тишине. Затем потяните «А-а-а» 3–4 секунды удобным голосом и завершите запись.")
                                .multilineTextAlignment(.center)
                            Text("Держите микрофон на привычном расстоянии.")
                                .foregroundStyle(.secondary)
                        } else {
                            Text("Прочитайте вслух").foregroundStyle(.secondary)
                            Text("Утром было тихо. За окном шумели деревья. Я открыл окно и прислушался. Ветер стих, и город постепенно просыпался.")
                                .font(.title.weight(.semibold))
                                .multilineTextAlignment(.center)
                        }
                        if model.recording {
                            HStack(spacing: 3) {
                                ForEach(model.levels.indices, id: \.self) { index in
                                    Capsule().fill(emerald.opacity(0.58))
                                        .frame(width: 4, height: 4 + 58 * min(1, model.levels[index]))
                                }
                            }
                            .frame(height: 65).accessibilityHidden(true)
                            Label(String(format: "%02d:%02d", model.elapsed / 60, model.elapsed % 60), systemImage: "record.circle.fill")
                                .monospacedDigit().foregroundStyle(.red)
                            Button {
                                Task { await model.finish() }
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.title)
                                    .frame(width: 65, height: 65)
                            }
                            .buttonStyle(.glass)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Завершить запись")
                            Text("Завершить").foregroundStyle(.secondary)
                        } else if model.busy {
                            ProgressView("Выполняем замер…")
                        } else {
                            Button("Начать запись") { Task { await model.start(source: request.source) } }
                                .buttonStyle(.glassProminent)
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(26)
            }
            .background(pearl.ignoresSafeArea())
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть", systemImage: "xmark") { recordingRequest = nil }
                        .labelStyle(.iconOnly)
                        .disabled(model.busy)
                }
            }
            .task(id: model.recording) {
                while model.recording && !Task.isCancelled {
                    model.updateMeter()
                    if model.elapsed >= (request.source == .sustainedVowel ? 10 : 60) {
                        await model.finish()
                        break
                    }
                    try? await Task.sleep(for: .milliseconds(80))
                }
            }
        }
    }
}

struct MetricRows: View {
    let metrics: SpeechMetrics

    var body: some View {
        VStack(spacing: 0) {
            row("Темп речи", "\(number(metrics.speechRate)) слога/с")
            Divider()
            row("Темп артикуляции", "\(number(metrics.articulationRate)) слога/с")
            Divider()
            row("Слоги · оценка", metrics.syllables.formatted())
            Divider()
            row("Медианная пауза", metrics.medianPause.map { "\(number($0)) с" } ?? "Нет пауз от 0,25 с")
        }
        .padding(.horizontal, 15)
        .background(.white.opacity(0.65), in: .rect(cornerRadius: 20))
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title, value: value)
            .padding(.vertical, 11)
    }
}

func number(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1...2)).locale(russian))
}

private struct HistoryView: View {
    let history: [Measurement]
    @State private var days = 7
    private enum Metric: Hashable { case pauses, pace, voice }
    @State private var metric = Metric.pauses

    private var recent: [Measurement] {
        let start = Calendar.current.date(byAdding: .day, value: 1 - days, to: Calendar.current.startOfDay(for: .now)) ?? .distantPast
        return history.filter { $0.date >= start }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Динамика").font(.largeTitle.bold())
                Picker("Период", selection: $days) {
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                }.pickerStyle(.segmented)
                Picker("Показатель", selection: $metric) {
                    Text("Паузы").tag(Metric.pauses)
                    Text("Темп речи").tag(Metric.pace)
                    Text("CPPS").tag(Metric.voice)
                }.pickerStyle(.segmented)

                let speech = recent.filter { $0.source == .microphone && $0.metrics != nil }
                let latestVoice = recent.last { $0.voiceQuality != nil }?.voiceQuality
                if metric != .voice { PeriodSummary(history: speech) }

                let points = recent.compactMap { entry -> (Date, Double)? in
                    if metric == .voice {
                        guard let quality = entry.voiceQuality, quality.profile == latestVoice?.profile else { return nil }
                        return (entry.date, quality.cpps)
                    }
                    guard entry.source == .microphone, let metrics = entry.metrics else { return nil }
                    return (metric == .pauses ? metrics.medianPause : metrics.speechRate).map { (entry.date, $0) }
                }
                if let last = points.last {
                    Text(number(last.1) + (metric == .voice ? " дБ" : metric == .pauses ? " с" : " слога/с"))
                        .font(.largeTitle.bold()).foregroundStyle(emerald)
                    Chart(points, id: \.0) { point in
                        LineMark(x: .value("Дата", point.0), y: .value("Показатель", point.1))
                            .foregroundStyle(emerald)
                        PointMark(x: .value("Дата", point.0), y: .value("Показатель", point.1))
                            .foregroundStyle(emerald)
                    }
                    .frame(height: 210)
                    if metric == .voice, let latestVoice {
                        Text("Сопоставимых замеров: \(points.count) · \(latestVoice.inputName)")
                            .font(.footnote).foregroundStyle(.secondary)
                        if points.count >= 2, let first = points.first {
                            Text("Первый и последний CPPS: \(number(first.1)) → \(number(last.1)) дБ")
                        }
                    } else {
                        Text("Только замеры с микрофона").font(.footnote).foregroundStyle(.secondary)
                    }
                } else {
                    ContentUnavailableView(
                        "Пока нет данных",
                        systemImage: "chart.xyaxis.line",
                        description: Text(metric == .voice ? "Сделайте замер «А-а-а» на вкладке «Сегодня»." : speech.isEmpty ? "Начните голосовой замер на вкладке «Сегодня»." : "В выбранных записях нет пауз от 0,25 с.")
                    )
                }
            }
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }
}


struct MeasurementDetails: View {
    let entry: Measurement

    var body: some View {
        if let metrics = entry.metrics {
            MetricRows(metrics: metrics)
        }
        if let cough = entry.cough {
            VStack(alignment: .leading, spacing: 6) {
                LabeledContent("Вероятный кашель", value: cough.episodeCount.formatted())
                Text("Эпизодов за \(number(cough.analyzedDuration)) с записи")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.white.opacity(0.65), in: .rect(cornerRadius: 20))
        }
        if let quality = entry.voiceQuality {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("CPPS", value: "\(number(quality.cpps)) дБ")
                Text(quality.inputName).font(.footnote).foregroundStyle(.secondary)
            }
            .padding(16)
            .background(.white.opacity(0.65), in: .rect(cornerRadius: 20))
        }
    }
}
