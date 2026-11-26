package ru.mts.voicewellness

import android.Manifest
import android.content.ActivityNotFoundException
import android.content.Intent
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.net.Uri
import android.widget.Toast
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.BackHandler
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.Canvas
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.selection.selectable
import androidx.compose.foundation.selection.selectableGroup
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ShowChart
import androidx.compose.material.icons.filled.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.ContentScale
import androidx.compose.ui.res.painterResource
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.semantics.Role
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.lifecycle.lifecycleScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.LocalDate
import java.time.format.DateTimeFormatter
import java.util.Locale

private val Pearl = Color(0xFFF7F7F0)
private val OnPearl = Color(0xFF101310)
private val Muted = Color(0xFF646760)
private val Glass = Color(0xFFFDFEF9)
private val Pill = RoundedCornerShape(50)
private val Ink = Color(0xFF13251D)
private val Emerald = Color(0xFF07563F)
private val Soft = Color(0xFFE1ECE3)
private val Russian = Locale.forLanguageTag("ru-RU")

private fun number(value: Double) = String.format(Russian, "%.2f", value).trimEnd('0').trimEnd(',')
private fun date(value: Long) = Instant.ofEpochMilli(value).atZone(ZoneId.systemDefault())
    .format(DateTimeFormatter.ofPattern("d MMM, HH:mm", Russian))

private enum class Tab(val label: String, val icon: ImageVector) {
    TODAY("Сегодня", Icons.Default.GraphicEq),
    SIGNAL("Сигнал", Icons.Default.Waves),
    HISTORY("Динамика", Icons.AutoMirrored.Filled.ShowChart),
    SETTINGS("Настройки", Icons.Default.Settings),
}

class MainActivity : ComponentActivity() {
    private var demoHistory = false
    private lateinit var store: MeasurementStore
    private lateinit var recommendations: Recommendations
    private lateinit var recommendationPreferences: SharedPreferences
    private var recommendation by mutableStateOf<Recommendation?>(null)
    private val recommendationListener = SharedPreferences.OnSharedPreferenceChangeListener { _, _ ->
        recommendation = recommendations.current()
    }
    private var history by mutableStateOf(listOf<Measurement>())
    private var paused by mutableStateOf(false)
    private var source by mutableStateOf<Source?>(null)
    private var result by mutableStateOf<Measurement?>(null)
    private var readingStep by mutableStateOf<Measurement?>(null)
    private var error by mutableStateOf<String?>(null)
    private var busy by mutableStateOf(false)
    private var recording by mutableStateOf(false)
    private var elapsed by mutableIntStateOf(0)
    private var waveform by mutableStateOf(List(28) { .04f })
    private var microphone: Microphone? = null
    private var task: Job? = null
    private var generation = 0
    private var permissionAttempt: Int? = null
    private val permission = registerForActivityResult(ActivityResultContracts.RequestPermission()) { granted ->
        val attempt = permissionAttempt
        permissionAttempt = null
        if (attempt != generation || source == null || paused) return@registerForActivityResult
        if (granted) start()
        else error = "Разрешите доступ к микрофону в настройках Android."
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        val requestedDemo = (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0 &&
            intent.getBooleanExtra("demo_history", false)
        demoHistory = BuildConfig.BUNDLED_TEST_HISTORY || requestedDemo
        store = MeasurementStore(this, demoHistory)
        if (BuildConfig.BUNDLED_TEST_HISTORY) store.seedBundledHistory(this)
        recommendations = Recommendations(this)
        recommendationPreferences = getSharedPreferences("recommendation", MODE_PRIVATE)
        recommendationPreferences.registerOnSharedPreferenceChangeListener(recommendationListener)
        recommendation = recommendations.current()
        history = store.load()
        paused = store.paused
        setContent {
            MaterialTheme(colorScheme = lightColorScheme(primary = Emerald, onPrimary = Color.White,
                background = Pearl, onBackground = Ink, surface = Pearl, onSurface = Ink,
                secondaryContainer = Soft, onSecondaryContainer = Emerald), typography = Typography().let {
                    it.copy(bodyLarge = it.bodyLarge.copy(letterSpacing = 0.sp),
                        bodyMedium = it.bodyMedium.copy(letterSpacing = 0.sp),
                        bodySmall = it.bodySmall.copy(letterSpacing = 0.sp),
                        labelLarge = it.labelLarge.copy(fontSize = 16.sp, letterSpacing = 0.sp),
                        labelSmall = it.labelSmall.copy(letterSpacing = 0.sp))
                }) {
                App()
            }
        }
    }

    override fun onDestroy() {
        recommendationPreferences.unregisterOnSharedPreferenceChangeListener(recommendationListener)
        super.onDestroy()
    }

    override fun onStop() {
        if (microphone != null) {
            cancel()
            error = "Замер остановлен при сворачивании приложения."
        }
        super.onStop()
    }

    private fun open(next: Source) {
        if (paused) return
        source = next
        readingStep = null
        error = null
        result = null
    }

    private fun start() {
        val selection = source ?: return
        if (paused || busy || permissionAttempt != null) return
        if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) != PackageManager.PERMISSION_GRANTED) {
            permissionAttempt = generation
            permission.launch(Manifest.permission.RECORD_AUDIO)
            return
        }
        val attempt = ++generation
        val input = Microphone()
        microphone = input
        busy = true
        recording = false
        elapsed = 0
        waveform = List(28) { .04f }
        error = null
        task = lifecycleScope.launch {
            try {
                val measurement = withContext(Dispatchers.IO) {
                    input.record(selection, onCaptureEnded = {
                        runOnUiThread { if (generation == attempt) recording = false }
                    }) { peak, seconds ->
                        runOnUiThread {
                            if (generation == attempt && input.isCapturing) {
                                recording = true
                                elapsed = seconds
                                waveform = waveform.drop(1) + peak
                            }
                        }
                    }
                }
                if (generation == attempt && !paused && source == selection) {
                    updateHistory(history + measurement)
                    if (selection == Source.READING) {
                        readingStep = measurement
                        source = Source.VOWEL
                    } else {
                        result = measurement
                    }
                }
            } catch (failure: Exception) {
                if (generation == attempt) error = failure.localizedMessage ?: "Не удалось выполнить замер."
            } finally {
                if (generation == attempt) {
                    microphone = null
                    busy = false
                    recording = false
                }
            }
        }
    }

    private fun cancel() {
        generation++
        microphone?.stop()
        microphone = null
        task?.cancel()
        busy = false
        recording = false
    }

    private fun close() {
        cancel()
        source = null
        readingStep = null
    }

    private fun updateHistory(updated: List<Measurement>) {
        store.save(updated)
        history = updated
    }

    private fun openMyMts() {
        val appLink = "mymts://action/service?alias=intellektualnaya-zapis-promo"
        val helpLink = "https://support.mts.ru/servisi_voicetech/intellektualnaya-zapis/kak-podklyuchit-uslugu-intellektualnaya-zapis"
        for (link in listOf(appLink, helpLink)) {
            try {
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(link)))
                return
            } catch (_: ActivityNotFoundException) {
                // Try the next destination when no app can open this link.
            }
        }
        Toast.makeText(this, "Не удалось открыть Мой МТС или инструкцию.", Toast.LENGTH_SHORT).show()
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun App() {
        var tab by remember { mutableStateOf(if (demoHistory) Tab.HISTORY else Tab.TODAY) }
        var showTelephony by remember { mutableStateOf(false) }
        val recordingSource = source
        BackHandler(enabled = recordingSource != null) { close() }
        Scaffold(
            containerColor = Pearl,
            bottomBar = {
                if (recordingSource == null) {
                    Surface(
                        modifier = Modifier.navigationBarsPadding().padding(horizontal = 22.dp, vertical = 7.dp),
                        shape = Pill, color = Glass, shadowElevation = 2.dp
                    ) {
                        Row(Modifier.fillMaxWidth().padding(4.dp).selectableGroup()) {
                            Tab.entries.forEach { entry ->
                                val selected = tab == entry
                                Column(
                                    Modifier.weight(1f).heightIn(min = 52.dp).clip(Pill)
                                        .background(if (selected) Color(0xFFE8EAE1) else Color.Transparent)
                                        .selectable(selected = selected, role = Role.Tab, onClick = { tab = entry })
                                        .padding(horizontal = 2.dp, vertical = 4.dp),
                                    horizontalAlignment = Alignment.CenterHorizontally,
                                    verticalArrangement = Arrangement.spacedBy(2.dp, Alignment.CenterVertically)
                                ) {
                                    val tint = if (selected) Emerald else OnPearl
                                    Icon(entry.icon, null, Modifier.size(23.dp), tint = tint)
                                    Text(entry.label, style = MaterialTheme.typography.labelSmall,
                                        color = tint, fontWeight = FontWeight.SemiBold)
                                }
                            }
                        }
                    }
                }
            },
        ) { padding ->
            val scrollState = key(recordingSource, tab) { rememberScrollState() }
            Column(Modifier.fillMaxSize().padding(padding).verticalScroll(scrollState)
                .padding(horizontal = 24.dp, vertical = 23.dp), verticalArrangement = Arrangement.spacedBy(19.dp)) {
                if (recordingSource != null) {
                    Recording(recordingSource)
                } else {
                    when (tab) {
                        Tab.TODAY -> Today(onTelephony = { showTelephony = true })
                        Tab.SIGNAL -> Signal()
                        Tab.HISTORY -> History()
                        Tab.SETTINGS -> Settings()
                    }
                }
            }
        }
        if (showTelephony) TelephonySheet { showTelephony = false }
    }

    @OptIn(ExperimentalMaterial3Api::class)
    @Composable
    private fun TelephonySheet(close: () -> Unit) {
        val sheet = rememberModalBottomSheetState(skipPartiallyExpanded = true)
        var demo by remember { mutableStateOf<Measurement?>(null) }
        var demoBusy by remember { mutableStateOf(false) }
        var demoError by remember { mutableStateOf<String?>(null) }
        val scope = rememberCoroutineScope()
        ModalBottomSheet(onDismissRequest = close, sheetState = sheet, containerColor = Pearl) {
            Column(Modifier.fillMaxWidth().fillMaxHeight(.94f).verticalScroll(rememberScrollState()).padding(horizontal = 24.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)) {
                Box(Modifier.fillMaxWidth().heightIn(min = 45.dp)) {
                    Text("Телефония", Modifier.align(Alignment.Center), fontWeight = FontWeight.Bold)
                    GlassButton("Готово", modifier = Modifier.align(Alignment.CenterEnd), onClick = close)
                }
                Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Icon(Icons.Default.Phone, null, Modifier.size(26.dp), tint = OnPearl)
                    Text("talk-recording", style = MaterialTheme.typography.headlineSmall, fontWeight = FontWeight.Bold, color = OnPearl)
                }
                Text("Подключение к телефонным звонкам появится после интеграции с услугой VoiceTech «Интеллектуальная запись».")
                GlassButton("Открыть Мой МТС", onClick = ::openMyMts)
                Button(onClick = {
                    demoBusy = true
                    demoError = null
                    scope.launch {
                        try {
                            val metrics = withContext(Dispatchers.Default) { telephonyDemo() }
                            if (!paused) {
                                val entry = Measurement(source = Source.TELEPHONY_DEMO, input = "Синтетический звук", speech = metrics)
                                updateHistory(history + entry)
                                demo = entry
                            }
                        } catch (failure: Exception) {
                            demoError = failure.localizedMessage
                        } finally {
                            demoBusy = false
                        }
                    }
                }, enabled = !demoBusy && !paused) { Text("Запустить демозамер") }
                demo?.let { Details(it) }
                demoError?.let { Text(it, color = Muted) }
                Spacer(Modifier.height(16.dp))
            }
        }
    }

    @Composable
    private fun Today(onTelephony: () -> Unit) {
        val zone = ZoneId.systemDefault()
        val today = LocalDate.now(zone)
        val assessment = remember(history, zone, today) {
            Fatigue.days(history, zone).lastOrNull { it.date == today }
        }
        Row(Modifier.fillMaxWidth().padding(top = 13.dp), horizontalArrangement = Arrangement.SpaceBetween) {
            Column {
                Title("Голос")
                Text(today.format(DateTimeFormatter.ofPattern("d MMMM", Russian)), color = Ink.copy(alpha = .65f))
            }
            Image(painterResource(R.drawable.eco_logo), null, Modifier.size(32.dp))
        }
        Image(painterResource(R.drawable.voice_wave), null,
            Modifier.fillMaxWidth().height(237.dp).clip(RoundedCornerShape(30.dp)), contentScale = ContentScale.Crop)
        Column(Modifier.fillMaxWidth(), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(14.dp)) {
            Text(assessment?.guidance ?: "Сегодня ещё нет оценки. Сделайте голосовой замер.",
                color = Muted, textAlign = TextAlign.Center)
            if (paused) Footnote("Отслеживание приостановлено")
            Button({ open(Source.READING) }, Modifier.fillMaxWidth().heightIn(min = 54.dp), enabled = !paused) {
                Text("Начать замер", fontWeight = FontWeight.Bold)
            }
            GlassButton("Скажите «А-а-а»", Icons.Default.Mic, !paused) { open(Source.VOWEL) }
            GlassButton("Телефония · демо", Icons.Default.Phone, !paused, onClick = onTelephony)
        }
    }

    @Composable
    private fun Recording(selection: Source) {
        Box(Modifier.fillMaxWidth().heightIn(min = 46.dp)) {
            Text(if (selection == Source.VOWEL) "Скажите «А-а-а»" else "Замер голоса",
                Modifier.align(Alignment.Center), style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            FilledTonalIconButton(::close, Modifier.align(Alignment.CenterStart),
                colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Glass, contentColor = Emerald)) {
                Icon(Icons.Default.Close, "Закрыть")
            }
        }
        val reading = readingStep
        if (selection == Source.READING || reading != null) {
            Text(if (selection == Source.READING) "Шаг 1 из 2" else "Шаг 2 из 2", Modifier.fillMaxWidth(),
                color = Emerald, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
        }
        val measured = result
        if (measured != null) {
            Text("Замер сохранён", Modifier.fillMaxWidth(), style = MaterialTheme.typography.headlineLarge,
                fontWeight = FontWeight.Bold, color = OnPearl, textAlign = TextAlign.Center)
            FatigueReadout(measured.date)
            Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
                Button(::close) { Text("Готово") }
            }
            return
        }
        error?.let { message ->
            Title("Не удалось выполнить замер")
            Text(message)
            Button(::start) { Text("Повторить запись") }
            return
        }
        Column(Modifier.fillMaxWidth().padding(top = 12.dp), horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(24.dp)) {
            if (reading != null) {
                val status = if (reading.speech != null) "Замер речи сохранён"
                else "Чтение сохранено, но речи недостаточно для расчёта темпа и пауз."
                Text(status, color = if (reading.speech != null) Emerald else Muted, textAlign = TextAlign.Center)
            }
            if (selection == Source.VOWEL) {
                Text("А-а-а", style = MaterialTheme.typography.headlineLarge, fontWeight = FontWeight.Bold)
                Text("После запуска подождите секунду в тишине. Затем потяните «А-а-а» 3–4 секунды удобным голосом и завершите запись.",
                    textAlign = TextAlign.Center)
                Text("Держите микрофон на привычном расстоянии.", color = Muted, textAlign = TextAlign.Center)
            } else {
                Text("Прочитайте вслух", color = Muted)
                Text("Утром было тихо. За окном шумели деревья. Я открыл окно и прислушался. Ветер стих, и город постепенно просыпался.",
                    style = MaterialTheme.typography.headlineSmall, fontSize = 28.sp, lineHeight = 33.sp, fontWeight = FontWeight.SemiBold, textAlign = TextAlign.Center)
            }
            when {
                recording -> {
                    Canvas(Modifier.fillMaxWidth().height(60.dp)) {
                        val step = size.width / (waveform.size + 1)
                        waveform.forEachIndexed { index, peak ->
                            val x = step * (index + 1)
                            val bar = (peak * size.height).coerceAtLeast(5.dp.toPx()) / 2
                            drawLine(Emerald.copy(alpha = .6f), Offset(x, center.y - bar), Offset(x, center.y + bar), 3.dp.toPx())
                        }
                    }
                    Text(String.format(Russian, "● %02d:%02d", elapsed / 60, elapsed % 60), color = Color(0xFFAE2424))
                    FilledTonalIconButton(onClick = { microphone?.stop(); recording = false },
                        modifier = Modifier.size(75.dp),
                        colors = IconButtonDefaults.filledTonalIconButtonColors(containerColor = Glass, contentColor = Emerald)) {
                        Icon(Icons.Default.Stop, "Завершить запись")
                    }
                    Text("Завершить", color = Muted)
                }
                busy -> {
                    CircularProgressIndicator()
                    Text(if (microphone?.isCapturing == true) "Подключаем микрофон…" else "Обрабатываем запись…", color = Muted)
                }
                else -> Button(::start) { Text("Начать запись") }
            }
        }
    }

    private fun latestManualMeasurement() = history.filter { it.source != Source.TELEPHONY_DEMO }.maxByOrNull { it.date }

    @Composable
    private fun Signal() {
        var showCoughAlert by remember { mutableStateOf(false) }
        var showMedsi by remember { mutableStateOf(false) }
        Row(Modifier.fillMaxWidth().padding(top = 13.dp), verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.SpaceBetween) {
            Title("Сигнал")
            Box(Modifier.sizeIn(minWidth = 48.dp, minHeight = 48.dp)
                .semantics { contentDescription = "Max, тестовый сценарий кашля" }
                .clickable(role = Role.Button) { showCoughAlert = true },
                contentAlignment = Alignment.Center) {
                Text("Max", Modifier.background(Color(0xFFB81F2E), Pill).padding(horizontal = 14.dp, vertical = 7.dp),
                    color = Color.White, fontWeight = FontWeight.Bold)
            }
        }
        FatigueReadout(latestManualMeasurement()?.date)
        if (showCoughAlert) {
            AlertDialog(
                onDismissRequest = { showCoughAlert = false },
                title = { Text("Отмечен повторяющийся кашель") },
                text = { Text("Тестовый сигнал. Если кашель долго не проходит, обсудите его с врачом.") },
                confirmButton = {
                    TextButton({
                        showCoughAlert = false
                        showMedsi = true
                    }) { Text("Записаться к врачу") }
                },
                dismissButton = { TextButton({ showCoughAlert = false }) { Text("Закрыть") } },
            )
        }
        if (showMedsi) MedsiFlow { showMedsi = false }
    }

    @Composable
    private fun FatigueReadout(timestamp: Long?) {
        val zone = ZoneId.systemDefault()
        val days = remember(history, zone) { Fatigue.days(history, zone) }
        val day = timestamp?.let { Instant.ofEpochMilli(it).atZone(zone).toLocalDate() }
        val estimate = days.lastOrNull { it.date == day }
        Column(
            Modifier.fillMaxWidth().padding(top = 26.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.spacedBy(12.dp),
        ) {
            if (estimate != null) {
                val score = estimate.score
                Column(
                    Modifier.fillMaxWidth().clearAndSetSemantics {
                        contentDescription = "Усталость за день, $score из 100"
                    },
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(12.dp),
                ) {
                    Text("Усталость за день", style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.SemiBold)
                    BoxWithConstraints(Modifier.fillMaxWidth().height(184.dp), contentAlignment = Alignment.Center) {
                        val fontScale = LocalDensity.current.fontScale
                        val size = minOf(160f, maxWidth.value / (score.toString().length * .68f * fontScale))
                        Text(
                            score.toString(),
                            Modifier.graphicsLayer { scaleX = .79f; scaleY = 1.14f },
                            fontSize = size.sp,
                            lineHeight = size.sp,
                            letterSpacing = 0.sp,
                            fontWeight = FontWeight.SemiBold,
                            color = Emerald,
                            maxLines = 1,
                        )
                    }
                    Text("из 100", style = MaterialTheme.typography.bodyMedium, color = Muted)
                }
                if (estimate.preliminary) Footnote("Предварительная оценка")
            } else {
                Text("Пока нет оценки", color = Muted)
            }
            timestamp?.let { Box(Modifier.padding(top = 16.dp)) { Footnote(date(it)) } }
            if (estimate != null) {
                Text(estimate.guidance, Modifier.padding(start = 16.dp, top = 36.dp, end = 16.dp),
                    style = MaterialTheme.typography.bodyMedium, color = Muted, textAlign = TextAlign.Center)
            }
        }
    }

    @Composable
    private fun History() {
        var period by remember { mutableIntStateOf(if (demoHistory) 30 else 1) }
        val today = LocalDate.now()
        val days = remember(history, today) { Fatigue.days(history) }
        val start = today.minusDays(period.toLong() - 1)
        val points = days.filter { it.date >= start && it.date <= today }
        Box(Modifier.padding(top = 13.dp)) { Title("Динамика") }
        Chips(listOf(1, 7, 30), period, { if (it == 1) "1 день" else "$it дней" }) { period = it }
        CardBlock("Усталость") {
            if (period == 1) {
                FatigueGauge(points.lastOrNull()?.score)
            } else if (points.isNotEmpty()) {
                FatigueChart(points, start, today)
                Footnote("Дней с оценкой: ${points.size} из $period")
            }
            if (points.isEmpty()) {
                Text(if (period == 1) "Сегодня нет оценки" else "За этот период нет оценок")
                Footnote(Fatigue.EMPTY)
            }
        }
        points.lastOrNull()?.let { latest ->
            Text(latest.guidance, Modifier.fillMaxWidth().padding(start = 16.dp, top = 24.dp, end = 16.dp),
                style = MaterialTheme.typography.bodyMedium, color = Muted, textAlign = TextAlign.Center)
        }
        if (demoHistory && period == 30) {
            val zone = ZoneId.systemDefault()
            val episode = history.filter { (it.cough?.episodeCount ?: 0) > 0 }.sortedBy { it.date }
            if (episode.isNotEmpty()) {
                val format = DateTimeFormatter.ofPattern("d MMMM", Russian)
                val first = Instant.ofEpochMilli(episode.first().date).atZone(zone).format(format)
                val last = Instant.ofEpochMilli(episode.last().date).atZone(zone).format(format)
                CardBlock("Кашель и охриплость") {
                    Text("$first — $last")
                    Footnote("В этот период выросла частота кашля и снизился CPPS. Затем показатели восстановились.")
                }
            }
        }
    }

    @Composable
    private fun FatigueGauge(score: Int?) {
        Box(Modifier.fillMaxWidth(), contentAlignment = Alignment.Center) {
            Column(Modifier.widthIn(max = 264.dp).fillMaxWidth().semantics(mergeDescendants = true) {}) {
                Box(Modifier.fillMaxWidth().height(132.dp), contentAlignment = Alignment.BottomCenter) {
                    Canvas(Modifier.fillMaxSize()) {
                        val inset = 12.dp.toPx()
                        val radius = minOf(center.x - inset, size.height - inset * 2)
                        if (radius <= 0) return@Canvas
                        val origin = Offset(center.x - radius, size.height - inset - radius)
                        val bounds = androidx.compose.ui.geometry.Size(radius * 2, radius * 2)
                        val stroke = androidx.compose.ui.graphics.drawscope.Stroke(
                            width = 14.dp.toPx(), cap = androidx.compose.ui.graphics.StrokeCap.Round,
                        )
                        drawArc(Emerald.copy(alpha = .13f), 180f, 180f, false, origin, bounds, style = stroke)
                        if (score != null) {
                            if (score > 0) drawArc(Emerald, 180f, score * 1.8f, false, origin, bounds, style = stroke)
                            val angle = Math.PI * (1 + score / 100.0)
                            drawCircle(Color.White, 4.dp.toPx(), Offset(
                                center.x + radius * kotlin.math.cos(angle).toFloat(),
                                size.height - inset + radius * kotlin.math.sin(angle).toFloat(),
                            ))
                        }
                    }
                    Column(Modifier.padding(bottom = 12.dp), horizontalAlignment = Alignment.CenterHorizontally) {
                        Text(score?.toString() ?: "—", fontSize = 56.sp, lineHeight = 60.sp,
                            fontWeight = FontWeight.SemiBold, color = Emerald)
                        Footnote("из 100")
                    }
                }
                Row(Modifier.fillMaxWidth().padding(horizontal = 10.dp), horizontalArrangement = Arrangement.SpaceBetween) {
                    Footnote("0")
                    Footnote("100")
                }
            }
        }
    }

    @Composable
    private fun FatigueChart(points: List<FatigueDay>, start: LocalDate, end: LocalDate) {
        val span = end.toEpochDay() - start.toEpochDay()
        val dateFormat = DateTimeFormatter.ofPattern("dd.MM", Russian)
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            Canvas(Modifier.weight(1f).height(190.dp).semantics {
                contentDescription = points.joinToString(prefix = "Усталость. ") {
                    "${it.date.format(dateFormat)}: ${it.score} из 100"
                }
            }) {
                val margin = 5.dp.toPx()
                val width = size.width - 2 * margin
                val height = size.height - 2 * margin
                for (i in 0..4) {
                    val y = margin + height * i / 4
                    drawLine(Soft, Offset(margin, y), Offset(size.width - margin, y))
                }
                fun position(day: FatigueDay) = Offset(
                    margin + width * (day.date.toEpochDay() - start.toEpochDay()) / span,
                    margin + height * (1 - day.score / 100f),
                )
                points.zipWithNext().forEach { (a, b) ->
                    if (a.date.plusDays(1) == b.date) drawLine(Emerald, position(a), position(b), 2.dp.toPx())
                }
                points.forEach { drawCircle(Emerald, 3.dp.toPx(), position(it)) }
            }
            Column(Modifier.height(190.dp), verticalArrangement = Arrangement.SpaceBetween,
                horizontalAlignment = Alignment.End) {
                listOf(100, 75, 50, 25, 0).forEach { Footnote(it.toString()) }
            }
        }
        Row(Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
            val step = if (span == 6L) 2L else 7L
            ((0L until span step step).toList() + span).forEach {
                Text(start.plusDays(it).format(dateFormat), style = MaterialTheme.typography.labelSmall, color = Muted)
            }
        }
    }

    @Composable
    private fun Settings() {
        var deletion by remember { mutableStateOf<Set<String>?>(null) }
        var details by remember { mutableStateOf<Measurement?>(null) }
        BackHandler(details != null) { details = null }
        details?.let { entry ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                IconButton({ details = null }) { Icon(Icons.Default.Close, "Закрыть") }
                Text(sourceName(entry.source), style = MaterialTheme.typography.titleLarge, fontWeight = FontWeight.Bold)
            }
            Details(entry)
            return
        }
        Box(Modifier.padding(top = 40.dp)) { Title("Настройки") }
        SettingsSection("Отслеживание") {
            Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
                Text("Приостановить отслеживание", Modifier.weight(1f))
                Switch(paused, onCheckedChange = {
                    paused = it
                    store.paused = it
                    if (it) {
                        recommendations.cancelReminder()
                        close()
                    }
                }, modifier = Modifier.semantics { contentDescription = "Приостановить отслеживание" })
            }
            HorizontalDivider(color = Soft)
            Text("На паузе новые замеры и напоминания отключены. История доступна.", color = Muted)
            if (!paused && recommendation == null && (applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE) != 0) {
                TextButton(onClick = { recommendations.createDemo() }) { Text("Создать демо-рекомендацию") }
            }
        }
        SettingsSection("Данные") {
            Text("Расчёт и история хранятся на устройстве")
            HorizontalDivider(color = Soft)
            Text("Запись запускается вручную. Аудио обрабатывается в памяти. В истории остаются дата, источник и метрики.", color = Muted)
            HorizontalDivider(color = Soft)
            Text("Телефония работает в деморежиме и использует синтетический звук.", color = Muted)
        }
        SettingsSection("Управление записями") {
            if (history.isEmpty()) Text("История пуста", color = Muted)
            history.asReversed().forEach { entry ->
                Row(Modifier.fillMaxWidth().clickable { details = entry }.padding(vertical = 5.dp),
                    verticalAlignment = Alignment.CenterVertically) {
                    Column(Modifier.weight(1f)) {
                        Text(date(entry.date))
                        Footnote(sourceName(entry.source))
                    }
                    IconButton({ deletion = setOf(entry.id) }) { Icon(Icons.Default.DeleteOutline, "Удалить замер") }
                    Icon(Icons.Default.ChevronRight, null, tint = Muted)
                }
                HorizontalDivider(color = Soft)
            }
            if (history.isNotEmpty()) TextButton({ deletion = history.map { it.id }.toSet() }) {
                Text("Удалить всю историю", color = MaterialTheme.colorScheme.error)
            }
        }
        deletion?.let { ids ->
            AlertDialog(onDismissRequest = { deletion = null }, title = { Text("Удалить выбранные замеры?") },
                text = { Text("Метрики будут удалены из истории и графиков.") }, containerColor = Pearl,
                dismissButton = { TextButton({ deletion = null }) { Text("Отмена") } },
                confirmButton = { TextButton({ updateHistory(history.filterNot { it.id in ids }); deletion = null }) { Text("Удалить") } })
        }
    }

}

@Composable
private fun Title(text: String) {
    Text(text, style = MaterialTheme.typography.headlineLarge, fontSize = 34.sp, fontWeight = FontWeight.Bold, color = OnPearl)
}

@Composable
private fun CardBlock(title: String, content: @Composable ColumnScope.() -> Unit) {
    Surface(Modifier.fillMaxWidth(), color = Color(0xFFFDFEF9), shape = RoundedCornerShape(20.dp)) {
        Column(Modifier.padding(16.dp), verticalArrangement = Arrangement.spacedBy(8.dp)) {
            Text(title, style = MaterialTheme.typography.titleMedium, fontWeight = FontWeight.Bold)
            content()
        }
    }
}

@Composable
private fun Details(entry: Measurement) {
    val rows = entry.speech?.let {
        listOf(
            "Темп речи" to "${number(it.pace)} слога/с",
            "Темп артикуляции" to "${number(it.articulation)} слога/с",
            "Слоги · оценка" to it.syllables.toString(),
            "Медианная пауза" to (it.pause?.let { value -> "${number(value)} с" } ?: "Нет пауз от 0,25 с"),
        )
    } ?: entry.cpps?.let { listOf("CPPS" to "${number(it)} дБ") }.orEmpty()
    val detailRows = rows + entry.cough?.let {
        listOf("Вероятный кашель" to it.episodeCount.toString())
    }.orEmpty()
    Surface(Modifier.fillMaxWidth(), color = Glass, shape = RoundedCornerShape(20.dp)) {
        Column(Modifier.padding(horizontal = 15.dp)) {
            detailRows.forEachIndexed { index, (label, value) ->
                if (index > 0) HorizontalDivider(color = Soft)
                Row(Modifier.fillMaxWidth().padding(vertical = 11.dp),
                    verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                    Text(label, Modifier.weight(1f))
                    Text(value, color = Muted, textAlign = TextAlign.End)
                }
            }
            if (entry.cpps != null) Box(Modifier.padding(bottom = 12.dp)) { Footnote(entry.input.substringBefore(" · ")) }
        }
    }
}

private fun sourceName(source: Source) = when (source) {
    Source.READING -> "Микрофон"
    Source.VOWEL -> "Гласная «А»"
    Source.TELEPHONY_DEMO -> "Телефония · демо"
}

@Composable
private fun Footnote(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = Muted)
}

@Composable
private fun SettingsSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(verticalArrangement = Arrangement.spacedBy(8.dp)) {
        Text(title, style = MaterialTheme.typography.titleSmall, color = Muted)
        Surface(Modifier.fillMaxWidth(), color = Glass, shape = RoundedCornerShape(20.dp)) {
            Column(Modifier.padding(15.dp), verticalArrangement = Arrangement.spacedBy(9.dp), content = content)
        }
    }
}

@Composable
private fun <T> Chips(items: List<T>, value: T, title: (T) -> String, select: (T) -> Unit) {
    Row(Modifier.fillMaxWidth().clip(RoundedCornerShape(8.dp)).background(Color(0xFFE9EAE3))
        .padding(2.dp).selectableGroup()) {
        items.forEach { item ->
            val selected = item == value
            Box(Modifier.weight(1f).heightIn(min = 40.dp).clip(RoundedCornerShape(7.dp))
                .background(if (selected) Color.White else Color.Transparent)
                .selectable(selected = selected, role = Role.Tab, onClick = { select(item) }),
                contentAlignment = Alignment.Center) {
                Text(title(item), textAlign = TextAlign.Center,
                    fontWeight = if (selected) FontWeight.SemiBold else FontWeight.Normal)
            }
        }
    }
}

@Composable
private fun GlassButton(label: String, icon: ImageVector? = null, enabled: Boolean = true,
                        modifier: Modifier = Modifier, onClick: () -> Unit) {
    Surface(modifier = modifier, color = Glass, shape = Pill, shadowElevation = if (enabled) 1.dp else 0.dp) {
        TextButton(onClick = onClick, enabled = enabled, contentPadding = PaddingValues(horizontal = 14.dp, vertical = 7.dp)) {
            if (icon != null) {
                Icon(icon, null, Modifier.size(17.dp))
                Spacer(Modifier.width(6.dp))
            }
            Text(label, fontWeight = FontWeight.Medium)
        }
    }
}
