package ru.mts.voicewellness

import androidx.activity.compose.BackHandler
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.window.Dialog
import androidx.compose.ui.window.DialogProperties

private enum class MedsiStep { RECOMMENDATION, CENTERS, CONFIRMATION }

@Composable
internal fun MedsiFlow(close: () -> Unit) {
    var step by rememberSaveable { mutableStateOf(MedsiStep.RECOMMENDATION) }
    var selected by rememberSaveable { mutableStateOf<String?>(null) }
    val back = {
        when (step) {
            MedsiStep.RECOMMENDATION -> close()
            MedsiStep.CENTERS -> step = MedsiStep.RECOMMENDATION
            MedsiStep.CONFIRMATION -> step = MedsiStep.CENTERS
        }
    }
    Dialog(onDismissRequest = back, properties = DialogProperties(usePlatformDefaultWidth = false, decorFitsSystemWindows = false)) {
        BackHandler(onBack = back)
        Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.background) {
            Column(Modifier.safeDrawingPadding().padding(horizontal = 24.dp)) {
                Box(Modifier.fillMaxWidth().heightIn(min = 56.dp)) {
                    if (step != MedsiStep.RECOMMENDATION) {
                        TextButton(back, Modifier.align(Alignment.CenterStart)) { Text("Назад") }
                    }
                    Text("МЕДСИ", Modifier.align(Alignment.Center), fontWeight = FontWeight.Bold)
                    TextButton(close, Modifier.align(Alignment.CenterEnd)) { Text("Закрыть") }
                }
                key(step) {
                    Column(Modifier.weight(1f).fillMaxWidth().verticalScroll(rememberScrollState()).padding(vertical = 20.dp),
                        verticalArrangement = Arrangement.spacedBy(18.dp)) {
                        when (step) {
                            MedsiStep.RECOMMENDATION -> {
                                MedsiTitle("Отмечен повторяющийся кашель")
                                Text("В нескольких замерах отмечены эпизоды кашля. Если кашель долго не проходит, он может быть симптомом состояния, которое требует лечения.")
                                Text("Обратитесь к терапевту в МЕДСИ. Врач поможет выяснить причину и подскажет, нужно ли обследование. Выберите удобный медцентр.")
                                Text("Тестовый сигнал. Сценарий запущен кнопкой Max.",
                                    style = MaterialTheme.typography.bodySmall, color = Color(0xFF646760))
                            }
                            MedsiStep.CENTERS -> {
                                MedsiTitle("Выберите медцентр")
                                Text("Условные варианты для прототипа.")
                                Column(Modifier.selectableGroup(), verticalArrangement = Arrangement.spacedBy(10.dp)) {
                                    listOf("Центр", "Север", "Юг").forEach { center ->
                                        Row(
                                            Modifier.fillMaxWidth().background(Color.White.copy(alpha = .65f), RoundedCornerShape(16.dp))
                                                .selectable(selected == center, role = Role.RadioButton) { selected = center }
                                                .padding(16.dp),
                                            verticalAlignment = Alignment.CenterVertically,
                                        ) {
                                            Column(Modifier.weight(1f)) {
                                                Text("МЕДСИ · $center", fontWeight = FontWeight.SemiBold)
                                                Text("Демонстрационный медцентр", style = MaterialTheme.typography.bodySmall)
                                            }
                                            RadioButton(selected = selected == center, onClick = null)
                                        }
                                    }
                                }
                            }
                            MedsiStep.CONFIRMATION -> {
                                MedsiTitle("Медцентр выбран")
                                selected?.let { Text("МЕДСИ · $it", fontWeight = FontWeight.SemiBold) }
                                Text("Выбор подтверждён в прототипе. Запись и отправка данных в МЕДСИ пока недоступны.")
                            }
                        }
                    }
                }
                Button(
                    onClick = {
                        when (step) {
                            MedsiStep.RECOMMENDATION -> step = MedsiStep.CENTERS
                            MedsiStep.CENTERS -> if (selected != null) step = MedsiStep.CONFIRMATION
                            MedsiStep.CONFIRMATION -> close()
                        }
                    },
                    modifier = Modifier.fillMaxWidth().padding(vertical = 10.dp).heightIn(min = 48.dp),
                    enabled = step != MedsiStep.CENTERS || selected != null,
                ) {
                    Text(when (step) {
                        MedsiStep.RECOMMENDATION -> "Записаться к врачу"
                        MedsiStep.CENTERS -> "Подтвердить выбор"
                        MedsiStep.CONFIRMATION -> "Готово"
                    })
                }
            }
        }
    }
}

@Composable
private fun MedsiTitle(title: String) {
    Text(title, style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
}
