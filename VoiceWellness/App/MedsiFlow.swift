import SwiftUI

struct MedsiFlow: View {
    private enum Step { case recommendation, centers, confirmation }

    private let centers = ["Центр", "Север", "Юг"]
    @Environment(\.dismiss) private var dismiss
    @State private var step = Step.recommendation
    @State private var selected: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch step {
                    case .recommendation:
                        Text("Отмечен повторяющийся кашель").font(.largeTitle.bold())
                        Text("В нескольких замерах отмечены эпизоды кашля. Если кашель долго не проходит, он может быть симптомом состояния, которое требует лечения.")
                        Text("Обратитесь к терапевту в МЕДСИ. Врач поможет выяснить причину и подскажет, нужно ли обследование. Выберите удобный медцентр.")
                        Text("Тестовый сигнал. Сценарий запущен кнопкой Max.").font(.footnote).foregroundStyle(.secondary)
                    case .centers:
                        Text("Выберите медцентр").font(.largeTitle.bold())
                        Text("Условные варианты для прототипа.").foregroundStyle(.secondary)
                        ForEach(centers, id: \.self) { center in
                            Button {
                                selected = center
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text("МЕДСИ · \(center)").font(.headline)
                                        Text("Демонстрационный медцентр").font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                    Image(systemName: selected == center ? "checkmark.circle.fill" : "circle")
                                        .accessibilityHidden(true)
                                }
                                .foregroundStyle(emerald)
                                .padding(16)
                                .background(.white.opacity(0.65), in: .rect(cornerRadius: 16))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected == center ? .isSelected : [])
                        }
                    case .confirmation:
                        Text("Медцентр выбран").font(.largeTitle.bold())
                        if let selected { Text("МЕДСИ · \(selected)").font(.headline) }
                        Text("Выбор подтверждён в прототипе. Запись и отправка данных в МЕДСИ пока недоступны.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(24)
            }
            .safeAreaInset(edge: .bottom) {
                Button {
                    switch step {
                    case .recommendation: step = .centers
                    case .centers: if selected != nil { step = .confirmation }
                    case .confirmation: dismiss()
                    }
                } label: {
                    Text(buttonTitle).frame(maxWidth: .infinity, minHeight: 48)
                }
                .buttonStyle(.glassProminent)
                .tint(emerald)
                .disabled(step == .centers && selected == nil)
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
                .background(pearl)
            }
            .background(pearl.ignoresSafeArea())
            .navigationTitle("МЕДСИ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .recommendation {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Назад") { step = step == .confirmation ? .centers : .recommendation }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
        }
    }

    private var buttonTitle: String {
        switch step {
        case .recommendation: "Записаться к врачу"
        case .centers: "Подтвердить выбор"
        case .confirmation: "Готово"
        }
    }
}
