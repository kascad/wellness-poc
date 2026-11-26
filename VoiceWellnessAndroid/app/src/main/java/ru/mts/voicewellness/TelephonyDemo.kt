package ru.mts.voicewellness

import kotlin.math.PI
import kotlin.math.exp
import kotlin.math.pow
import kotlin.math.sin

internal fun telephonyDemo(): SpeechMetrics {
    val peaks = doubleArrayOf(.2, .45, .69, .91, 1.18, 1.88, 2.11, 2.35, 2.61, 2.86, 3.55, 3.82, 4.06, 4.30)
    val samples = FloatArray(SAMPLE_RATE * 5) { index ->
        val t = index.toDouble() / SAMPLE_RATE
        val amplitude = peaks.sumOf { exp(-((t - it) / .058).pow(2)) }
        (.25 * amplitude * sin(2 * PI * 155 * t)).toFloat()
    }
    return VoiceAnalyzer.speech(samples)
}
