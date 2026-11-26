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
    @State private var selectedTab = MeasurementModel.demoHistory ? 2 : 0
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL

    var body: some View {
        TabView(selection: $selectedTab) {
            Tab("Сегодня", systemImage: "waveform", value: 0) {
                today
            }
            Tab("Сигнал", systemImage: "waveform.path", value: 1) {
                SignalView(history: model.history)
            }
            Tab("Динамика", systemImage: "chart.xyaxis.line", value: 2) {
                HistoryView(history: model.history)
            }
            Tab("Настройки", systemImage: "gearshape", value: 3) {
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
                let last = model.history.filter { $0.source != .telephonyDemo }.max { $0.date < $1.date }
                let day = last.flatMap { latest in
                    Fatigue.days(model.history).last { Calendar.current.isDate($0.date, inSameDayAs: latest.date) }
                }
                Text("Последний замер · Усталость \(day?.score ?? Fatigue.defaultScore) из 100")
                    .font(.footnote).foregroundStyle(.secondary)
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
    @State private var days = MeasurementModel.demoHistory ? 30 : 1

    var body: some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        let start = calendar.date(byAdding: .day, value: 1 - days, to: today) ?? today
        let points = Fatigue.days(history, calendar: calendar).filter { $0.date >= start && $0.date <= today }
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Динамика").font(.largeTitle.bold())
                Picker("Период", selection: $days) {
                    Text("1 день").tag(1)
                    Text("7 дней").tag(7)
                    Text("30 дней").tag(30)
                }.pickerStyle(.segmented)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Усталость").font(.title2.bold())
                    if days == 1 {
                        FatigueGauge(score: points.last?.score ?? Fatigue.defaultScore)
                    } else if !points.isEmpty {
                        Chart {
                            ForEach(Array(zip(points, points.dropFirst())), id: \.0.date) { pair in
                                if calendar.dateComponents([.day], from: pair.0.date, to: pair.1.date).day == 1 {
                                    LineMark(x: .value("День", pair.0.date), y: .value("Балл", pair.0.score),
                                             series: .value("Отрезок", pair.0.date))
                                    .foregroundStyle(emerald)
                                    LineMark(x: .value("День", pair.1.date), y: .value("Балл", pair.1.score),
                                             series: .value("Отрезок", pair.0.date))
                                    .foregroundStyle(emerald)
                                }
                            }
                            ForEach(points) { day in
                                PointMark(x: .value("День", day.date), y: .value("Балл", day.score))
                                    .foregroundStyle(emerald)
                            }
                        }
                        .chartXScale(domain: start...today)
                        .chartXAxis {
                            AxisMarks(values: .automatic(desiredCount: days == 7 ? 7 : 5)) { _ in
                                AxisGridLine()
                                AxisValueLabel(format: .dateTime.day().month(.twoDigits))
                            }
                        }
                        .chartYScale(domain: 0...100)
                        .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) }
                        .frame(height: 210)
                        Text("Дней с оценкой: \(points.count) из \(days)").font(.footnote).foregroundStyle(.secondary)
                    }
                    if points.isEmpty && days != 1 {
                        Text("За этот период нет оценок").font(.headline)
                        Text(Fatigue.empty).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .background(.white.opacity(0.65), in: .rect(cornerRadius: 24))
                if MeasurementModel.demoHistory && days == 30 {
                    let episode = history.filter { ($0.cough?.episodeCount ?? 0) > 0 }.sorted { $0.date < $1.date }
                    if let first = episode.first, let last = episode.last {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Кашель и охриплость").font(.headline)
                            Text(first.date.formatted(.dateTime.day().month().locale(russian)) + " — " +
                                 last.date.formatted(.dateTime.day().month().locale(russian)))
                            Text("В этот период выросла частота кашля и снизился CPPS. Затем показатели восстановились.")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
        .background(pearl.ignoresSafeArea())
    }
}

private struct FatigueGauge: View {
    let score: Int?

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .bottom) {
                Canvas { context, size in
                    let center = CGPoint(x: size.width / 2, y: size.height - 12)
                    let radius = min(center.x - 12, center.y - 12)
                    guard radius > 0 else { return }
                    func arc(_ fraction: Double) -> Path {
                        var path = Path()
                        path.addArc(center: center, radius: radius, startAngle: .degrees(180),
                                    endAngle: .degrees(180 + 180 * fraction), clockwise: false)
                        return path
                    }
                    let stroke = StrokeStyle(lineWidth: 14, lineCap: .round)
                    context.stroke(arc(1), with: .color(emerald.opacity(0.13)), style: stroke)
                    if let score {
                        let fraction = Double(score) / 100
                        if score > 0 { context.stroke(arc(fraction), with: .color(emerald), style: stroke) }
                        let angle = Double.pi * (1 + fraction)
                        let marker = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
                        context.fill(Path(ellipseIn: CGRect(x: marker.x - 4, y: marker.y - 4, width: 8, height: 8)),
                                     with: .color(.white))
                    }
                }
                VStack(spacing: 0) {
                    Text(score.map { String($0) } ?? "—").font(.system(size: 56, weight: .semibold, design: .rounded))
                        .monospacedDigit().foregroundStyle(emerald)
                    Text("из 100").font(.footnote).foregroundStyle(.secondary)
                }.padding(.bottom, 12)
            }.frame(height: 132)
            HStack { Text("0"); Spacer(); Text("100") }
                .font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 10)
        }
        .frame(maxWidth: 264)
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(score.map { "Усталость: \($0) из 100" } ?? "Сегодня нет оценки")
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
