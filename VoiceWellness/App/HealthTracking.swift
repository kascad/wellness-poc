import Observation
import OSLog
import SwiftUI
import UserNotifications

@MainActor @Observable
final class HealthTracking {
    static let shared = HealthTracking()
    static let category = "health-recommendation"
    private static let demoInterval: TimeInterval = 120
    private static let demoStartedKey = "notificationDemoStarted"
    private static let logger = Logger(subsystem: "com.mts.prototype.voicewellness", category: "notification-demo")

    enum Action: String {
        case consulted, later, skip
    }

    struct Recommendation: Codable, Identifiable {
        var id = UUID()
        let text: String
        let demo: Bool
        var reminderID: String?
        var reminderDate: Date?
    }

    private let defaults = UserDefaults.standard
    private let notifications = UNUserNotificationCenter.current()
    private(set) var paused: Bool
    private(set) var active: Recommendation?
    private(set) var reminderError: String?
    private(set) var scheduling = false
    private var scheduleIntent: UUID?

    private init() {
        paused = defaults.bool(forKey: "healthTrackingPaused")
        if let data = defaults.data(forKey: "activeHealthRecommendation") {
            active = try? JSONDecoder().decode(Recommendation.self, from: data)
        }
    }

    func setPaused(_ value: Bool) {
        paused = value
        defaults.set(value, forKey: "healthTrackingPaused")
        if value {
            cancelReminder()
            reminderError = nil
        }
    }

    // Called only when a recommendation is explicitly confirmed by its source.
    func recordRecommendation(_ text: String, demo: Bool = false) {
        guard !paused, active == nil else { return }
        active = Recommendation(text: text, demo: demo)
        persist()
    }

    func recoverAfterLaunch() {
        if paused { cancelReminder() }
    }

    func startDemoAutomatically() async {
        #if targetEnvironment(simulator)
        guard !defaults.bool(forKey: Self.demoStartedKey) else { return }
        await startDemo()
        #endif
    }

    func startDemo() async {
        guard !paused, !scheduling, active?.reminderID == nil, active?.demo != false else { return }
        if active == nil {
            recordRecommendation("Если осиплость сохраняется, можно обсудить её с ЛОР-врачом.", demo: true)
        }
        guard let active else { return }
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: Self.demoInterval, repeats: true)
        if await schedule(active, trigger: trigger, date: trigger.nextTriggerDate()) {
            defaults.set(true, forKey: Self.demoStartedKey)
            Self.logger.info("System demo notification scheduled with a 120-second repeating trigger")
        }
    }

    func respond(_ action: Action, recommendationID: UUID) async {
        guard let recommendation = active, recommendation.id == recommendationID else { return }
        cancelReminder()
        reminderError = nil
        guard action == .later else {
            active = nil
            persist()
            return
        }
        guard !paused else { return }

        let calendar = Calendar.current
        let date = calendar.date(byAdding: .day, value: 1, to: .now) ?? Date.now.addingTimeInterval(86_400)
        let trigger = UNCalendarNotificationTrigger(
            dateMatching: calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date),
            repeats: false
        )
        _ = await schedule(recommendation, trigger: trigger, date: date)
    }

    private func schedule(_ recommendation: Recommendation, trigger: UNNotificationTrigger, date: Date?) async -> Bool {
        let intent = UUID()
        let requestID = "health-reminder-\(intent.uuidString)"
        scheduleIntent = intent
        scheduling = true
        reminderError = nil
        defer {
            if scheduleIntent == intent {
                scheduleIntent = nil
                scheduling = false
            }
        }
        do {
            let status = await notifications.notificationSettings().authorizationStatus
            let allowed: Bool
            switch status {
            case .authorized, .provisional, .ephemeral: allowed = true
            case .notDetermined: allowed = try await notifications.requestAuthorization(options: [.alert, .sound])
            default: allowed = false
            }
            guard scheduleIntent == intent else { return false }
            guard allowed else {
                reminderError = "Разрешите уведомления для «Голоса» в настройках iOS."
                return false
            }
            let content = UNMutableNotificationContent()
            content.title = recommendation.demo ? "Голос · демо" : "Напоминание от «Голоса»"
            content.body = recommendation.text
            content.sound = .default
            content.categoryIdentifier = Self.category
            content.userInfo = ["recommendationID": recommendation.id.uuidString]
            active?.reminderID = requestID
            active?.reminderDate = date
            persist()
            try await notifications.add(UNNotificationRequest(identifier: requestID, content: content, trigger: trigger))
            guard scheduleIntent == intent else {
                notifications.removePendingNotificationRequests(withIdentifiers: [requestID])
                return false
            }
            return true
        } catch {
            guard scheduleIntent == intent else { return false }
            cancelReminder()
            reminderError = "Не удалось запланировать напоминание. Попробуйте ещё раз."
            return false
        }
    }

    private func cancelReminder() {
        scheduleIntent = nil
        scheduling = false
        if let id = active?.reminderID {
            notifications.removePendingNotificationRequests(withIdentifiers: [id])
            notifications.removeDeliveredNotifications(withIdentifiers: [id])
        }
        active?.reminderID = nil
        active?.reminderDate = nil
        persist()
    }

    private func persist() {
        if let active, let data = try? JSONEncoder().encode(active) {
            defaults.set(data, forKey: "activeHealthRecommendation")
        } else {
            defaults.removeObject(forKey: "activeHealthRecommendation")
        }
    }
}

final class HealthNotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([
            UNNotificationCategory(identifier: HealthTracking.category, actions: [
                UNNotificationAction(identifier: HealthTracking.Action.consulted.rawValue, title: "Уже обратился"),
                UNNotificationAction(identifier: HealthTracking.Action.later.rawValue, title: "Позже"),
                UNNotificationAction(identifier: HealthTracking.Action.skip.rawValue, title: "Пропустить", options: [.destructive])
            ], intentIdentifiers: [])
        ])
        HealthTracking.shared.recoverAfterLaunch()
        return true
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse) async {
        guard let action = HealthTracking.Action(rawValue: response.actionIdentifier),
              let raw = response.notification.request.content.userInfo["recommendationID"] as? String,
              let id = UUID(uuidString: raw) else { return }
        await HealthTracking.shared.respond(action, recommendationID: id)
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let id = notification.request.content.userInfo["recommendationID"] as? String
        return await MainActor.run {
            let tracking = HealthTracking.shared
            return !tracking.paused && tracking.active?.id.uuidString == id ? [.banner, .list, .sound] : []
        }
    }
}

struct HealthRecommendationCard: View {
    let tracking: HealthTracking
    let recommendation: HealthTracking.Recommendation

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(recommendation.demo ? "Рекомендация · демо" : "Активная рекомендация").font(.headline)
            Text(recommendation.text)
            if let date = recommendation.reminderDate, date > .now {
                Text("Напоминание: \(date.formatted(date: .abbreviated, time: .shortened))").font(.footnote)
            }
            if let error = tracking.reminderError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            action("Уже обратился", .consulted, .green)
            action("Позже", .later, .yellow, foreground: .black)
                .disabled(tracking.paused)
            action("Пропустить", .skip, .red)
        }
        .padding(16)
        .background(.white.opacity(0.7), in: .rect(cornerRadius: 20))
    }

    private func action(_ title: String, _ action: HealthTracking.Action, _ background: Color,
                        foreground: Color = .white) -> some View {
        Button {
            Task { await tracking.respond(action, recommendationID: recommendation.id) }
        } label: {
            Text(title).font(.headline).frame(maxWidth: .infinity, minHeight: 44)
                .foregroundStyle(foreground)
                .background(background, in: .capsule)
        }
        .buttonStyle(.plain)
        .disabled(tracking.scheduling)
    }
}
