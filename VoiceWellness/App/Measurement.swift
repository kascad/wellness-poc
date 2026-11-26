import AVFoundation
import Foundation
import Observation

enum MeasurementSource: String, Codable, Sendable {
    case microphone, telephonyDemo, sustainedVowel

    var label: String {
        switch self {
        case .microphone: "Микрофон"
        case .telephonyDemo: "Телефония · демо"
        case .sustainedVowel: "Гласная «А»"
        }
    }
}

struct Measurement: Identifiable, Codable, Sendable {
    var id = UUID()
    var date = Date()
    let source: MeasurementSource
    var metrics: SpeechMetrics?
    var voiceQuality: VoiceQuality?
    var cough: CoughSummary?
}

protocol TelephonyAudioSource: Sendable {
    func loadSubscriberAudio() async throws -> (samples: [Float], sampleRate: Int)
}

struct DemoTelephonyAudioSource: TelephonyAudioSource {
    // Synthetic voiced bursts exercise the same PCM pipeline as the microphone.
    func loadSubscriberAudio() async throws -> (samples: [Float], sampleRate: Int) {
        let rate = 8_000
        let nuclei = [0.2, 0.45, 0.69, 0.91, 1.18, 1.88, 2.11, 2.35, 2.61, 2.86, 3.55, 3.82, 4.06, 4.30]
        let samples = (0..<(rate * 5)).map { index -> Float in
            let time = Double(index) / Double(rate)
            let envelope = nuclei.reduce(0.0) { amplitude, center in
                let offset = (time - center) / 0.058
                return amplitude + exp(-offset * offset)
            }
            return Float(0.25 * envelope * sin(2 * .pi * 155 * time))
        }
        return (samples, rate)
    }
}

enum RecorderError: LocalizedError {
    case permission, unavailable, inputStart

    var errorDescription: String? {
        switch self {
        case .permission: "Разрешите доступ к микрофону в настройках iPhone."
        case .inputStart:
            "Не удалось запустить микрофон. Проверьте, выбран ли рабочий аудиовход, и повторите замер."
        case .unavailable: "Не удалось записать звук. Попробуйте ещё раз."
        }
    }
}

@MainActor @Observable
final class MeasurementModel {
    private(set) var history: [Measurement] = []
    private(set) var recording = false
    private(set) var busy = false
    private(set) var result: Measurement?
    var error: String?
    var elapsed = 0
    var levels = Array(repeating: 0.06, count: 28)
    private let telephony: any TelephonyAudioSource
    static var demoHistory: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--demo-history")
        #else
        false
        #endif
    }

    private let storageURL: URL
    private var recorder: AVAudioRecorder?
    private var audioURL: URL?
    private var source: MeasurementSource = .microphone
    private var inputID: String?
    private var inputName = ""


    init(telephony: any TelephonyAudioSource = DemoTelephonyAudioSource()) {
        self.telephony = telephony
        storageURL = URL.applicationSupportDirectory.appending(path: Self.demoHistory ? "voice-measurements-demo.json" : "voice-measurements.json")
        if let data = try? Data(contentsOf: storageURL) {
            do { history = try JSONDecoder().decode([Measurement].self, from: data) }
            catch { self.error = "Не удалось открыть историю замеров." }
        }
    }

    func resetResult() {
        result = nil
        error = nil
    }

    func start(source: MeasurementSource = .microphone) async {
        guard !busy, !recording, !HealthTracking.shared.paused else { return }
        busy = true
        defer { busy = false }
        do {
            guard await AVAudioApplication.requestRecordPermission() else { throw RecorderError.permission }
            try Task.checkCancellation()
            guard !HealthTracking.shared.paused else { return }
            let session = AVAudioSession.sharedInstance()
            #if targetEnvironment(simulator)
            // Keep the simulated input and output on one route during Bluetooth handoff.
            try session.setCategory(.playAndRecord, mode: .default)
            #else
            try session.setCategory(.record, mode: .measurement)
            #endif
            try session.setActive(true)
            let url = URL.temporaryDirectory.appending(path: UUID().uuidString + ".caf")
            audioURL = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: session.sampleRate,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16
            ])
            recorder.isMeteringEnabled = true
            self.recorder = recorder
            if !recorder.record() {
                // A Bluetooth route switch can briefly make the queue unavailable.
                try await Task.sleep(for: .milliseconds(500))
                try Task.checkCancellation()
                guard !HealthTracking.shared.paused else { cancel(); return }
                guard recorder.record() else { throw RecorderError.inputStart }
            }
            self.source = source
            inputID = session.currentRoute.inputs.first?.uid
            inputName = session.currentRoute.inputs.first?.portName ?? ""
            elapsed = 0
            levels = Array(repeating: 0.06, count: 28)
            result = nil
            recording = true
        } catch {
            cancel()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }

    func updateMeter() {
        guard let recorder else { return }
        if source == .sustainedVowel, inputID != AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid {
            cancel()
            error = VoiceQualityError.inputChanged.localizedDescription
            return
        }
        recorder.updateMeters()
        elapsed = Int(recorder.currentTime)
        levels.removeFirst()
        levels.append(max(0.06, pow(10, Double(recorder.averagePower(forChannel: 0)) / 35)))
    }

    func cancel() {
        closeRecorder()
        if let audioURL { try? FileManager.default.removeItem(at: audioURL) }
        audioURL = nil
    }

    private func closeRecorder() {
        recorder?.stop()
        recorder = nil
        recording = false
        if audioURL != nil {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }

    func finish() async {
        guard recording, !busy, let url = audioURL else { return }
        let source = source
        let inputID = inputID
        let inputName = inputName
        let routeMatches = inputID == AVAudioSession.sharedInstance().currentRoute.inputs.first?.uid
        closeRecorder()
        audioURL = nil
        busy = true
        defer {
            busy = false
            try? FileManager.default.removeItem(at: url)
        }
        do {
            let measurement = try await Task.detached(priority: .userInitiated) {
                let file = try AVAudioFile(forReading: url)
                guard file.length > 0,
                      let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                    throw SpeechError.insufficientSpeech
                }
                try file.read(into: buffer)
                guard let channel = buffer.floatChannelData?[0] else { throw RecorderError.unavailable }
                let samples = Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
                let rate = Int(file.processingFormat.sampleRate)
                if source == .sustainedVowel {
                    guard routeMatches, let inputID else { throw VoiceQualityError.inputChanged }
                    let cpps = try VoiceQualityAnalyzer.cpps(samples, sampleRate: rate)
                    let cough = CoughAnalyzer.analyze(samples: samples, sampleRate: rate)
                    return Measurement(source: source, voiceQuality: VoiceQuality(cpps: cpps, inputID: inputID, inputName: inputName, sampleRate: rate), cough: cough)
                }
                let cough = CoughAnalyzer.analyze(samples: samples, sampleRate: rate)
                do {
                    let metrics = try SpeechAnalyzer.analyze(samples, sampleRate: rate)
                    return Measurement(source: source, metrics: metrics, cough: cough)
                } catch SpeechError.insufficientSpeech {
                    guard let cough, cough.episodeCount > 0 else { throw SpeechError.insufficientSpeech }
                    return Measurement(source: source, cough: cough)
                }
            }.value
            try save(measurement)
        } catch { self.error = error.localizedDescription }
    }

    func runTelephonyDemo() async {
        guard !busy, !recording, !HealthTracking.shared.paused else { return }
        busy = true
        defer { busy = false }
        do {
            let source = telephony
            let metrics = try await Task.detached(priority: .userInitiated) {
                let audio = try await source.loadSubscriberAudio()
                return try SpeechAnalyzer.analyze(audio.samples, sampleRate: audio.sampleRate)
            }.value
            try save(Measurement(source: .telephonyDemo, metrics: metrics))
        } catch { self.error = error.localizedDescription }
    }

    private func save(_ measurement: Measurement) throws {
        guard !HealthTracking.shared.paused else { return }
        let updated = history + [measurement]
        try persist(updated)
        result = measurement
    }

    func deleteMeasurements(ids: Set<UUID>) throws {
        try persist(history.filter { !ids.contains($0.id) })
        if let result, ids.contains(result.id) {
            self.result = nil
        }
    }

    private func persist(_ updated: [Measurement]) throws {
        try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: storageURL, options: [.atomic, .completeFileProtection])
        history = updated
    }
}
