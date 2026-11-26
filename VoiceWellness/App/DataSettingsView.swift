import SwiftUI

struct DataSettingsView: View {
    let model: MeasurementModel
    let tracking: HealthTracking
    @State private var pendingDeletion: Set<UUID> = []
    @State private var confirmDeletion = false
    @State private var deletionError = false

    var body: some View {
        NavigationStack {
            List {
                Section("Отслеживание") {
                    Toggle("Приостановить отслеживание", isOn: Binding(
                        get: { tracking.paused },
                        set: { tracking.setPaused($0) }
                    ))
                    Text("На паузе новые замеры и напоминания отключены. История доступна.")
                        .foregroundStyle(.secondary)
                    #if DEBUG || targetEnvironment(simulator)
                    if !tracking.paused, tracking.active?.demo != false, tracking.active?.reminderID == nil {
                        Button("Запустить тестовые уведомления") {
                            Task { await tracking.startDemo() }
                        }
                        .disabled(tracking.scheduling)
                    }
                    if let error = tracking.reminderError {
                        Text(error).foregroundStyle(.secondary)
                    }
                    #endif
                }
                Section("Данные") {
                    Label("Расчёт и история хранятся на устройстве", systemImage: "iphone")
                    Text("Запись запускается вручную. После замера временный аудиофайл удаляется. В истории остаются дата, источник и метрики.")
                        .foregroundStyle(.secondary)
                    Text("Телефония работает в деморежиме и использует синтетический звук.")
                        .foregroundStyle(.secondary)
                }
                Section("Управление записями") {
                    if model.history.isEmpty {
                        Text("История пуста").foregroundStyle(.secondary)
                    }
                    ForEach(model.history.reversed()) { entry in
                        NavigationLink {
                            ScrollView {
                                MeasurementDetails(entry: entry).padding(24)
                            }
                            .background(pearl.ignoresSafeArea())
                            .navigationTitle(entry.source.label)
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                Text(entry.source.label).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions(allowsFullSwipe: false) {
                            Button("Удалить", role: .destructive) { requestDeletion([entry.id]) }
                        }
                    }
                    if !model.history.isEmpty {
                        Button("Удалить всю историю", role: .destructive) {
                            requestDeletion(Set(model.history.map(\.id)))
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(pearl.ignoresSafeArea())
            .navigationTitle("Настройки")
            .alert("Удалить выбранные замеры?", isPresented: $confirmDeletion) {
                Button("Отмена", role: .cancel) {}
                Button("Удалить", role: .destructive) {
                    do { try model.deleteMeasurements(ids: pendingDeletion) }
                    catch { deletionError = true }
                }
            } message: {
                Text("Метрики будут удалены из истории и графиков.")
            }
            .alert("Не удалось удалить замеры", isPresented: $deletionError) {
                Button("OK", role: .cancel) {}
            }
        }
    }

    private func requestDeletion(_ ids: Set<UUID>) {
        pendingDeletion = ids
        confirmDeletion = true
    }
}
