# Голос · Wellness PoC

Прототип голосовых замеров для iOS и Android. Поддерживает оценку темпа речи, слогов и пауз, измерение CPPS на гласной «А» и подсчёт вероятных эпизодов кашля.

- [iOS](VoiceWellness/README.md) · SwiftUI и Xcode.
- [Android](VoiceWellnessAndroid/README.md) · Kotlin, Jetpack Compose и Gradle.
- [Модели и обучение](VoiceWellness/ML/README.md) · общий локальный детектор кашля, параметры обучения, экспериментальный экспорт Core ML и результаты оценки.

Собирайте приложения из одного клона. Android использует код и веса общего детектора из `VoiceWellness/App/MobileCough`. Исходные аудиодатасеты скачиваются отдельно по инструкциям раздела ML.
