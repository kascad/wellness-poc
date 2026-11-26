package ru.mts.voicewellness

import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import kotlin.math.roundToInt

internal data class FatigueDay(val date: LocalDate, val score: Int)

internal object Fatigue {
    const val DEFAULT_SCORE = 66
    const val EMPTY = "Баллы появятся после замеров за три предыдущих дня и нового замера."

    private enum class Metric(val weight: Double) {
        PACE(25.0), ARTICULATION(20.0), PAUSE(20.0), CPPS(25.0), COUGH(10.0);

        fun severity(value: Double, baseline: Double): Double = when (this) {
            PACE, ARTICULATION -> (baseline - value) / maxOf(.3 * baseline, .3)
            PAUSE -> (value - baseline) / maxOf(baseline, .5)
            CPPS -> (baseline - value) / 4
            COUGH -> (value - baseline) / 6
        }

        fun profile(entry: Measurement): String? = when (this) {
            CPPS -> entry.input.takeIf { entry.cpps != null }
            COUGH -> entry.source.name.takeIf { entry.cough != null }
            else -> entry.source.name.takeIf { entry.speech != null }
        }

        fun dailyValue(entries: List<Measurement>, key: String): Double? {
            val matches = entries.filter { profile(it) == key }
            if (this == COUGH) {
                val summaries = matches.mapNotNull { it.cough }.filter {
                    it.analyzedDuration.isFinite() && it.analyzedDuration > 0
                }
                val duration = summaries.sumOf { it.analyzedDuration }
                return if (duration > 0) 60.0 * summaries.sumOf { it.episodeCount } / duration else null
            }
            return median(matches.mapNotNull {
                when (this) {
                    PACE -> it.speech?.pace
                    ARTICULATION -> it.speech?.articulation
                    PAUSE -> it.speech?.let { speech -> speech.pause ?: 0.0 }
                    CPPS -> it.cpps
                    COUGH -> null
                }
            }.filter { it.isFinite() })
        }
    }

    fun days(history: List<Measurement>, zone: ZoneId = ZoneId.systemDefault()): List<FatigueDay> {
        val grouped = history.filter { it.source != Source.TELEPHONY_DEMO }.groupBy {
            Instant.ofEpochMilli(it.date).atZone(zone).toLocalDate()
        }
        val dates = grouped.keys.sorted()
        return dates.mapIndexedNotNull { index, date ->
            val today = grouped.getValue(date)
            val earlier = dates.subList(0, index).asReversed()
            var weighted = 0.0
            var total = 0.0
            var voiceWeight = 0.0
            for (metric in Metric.entries) {
                val scores = today.mapNotNull(metric::profile).distinct().mapNotNull { key ->
                    val value = metric.dailyValue(today, key) ?: return@mapNotNull null
                    val reference = earlier.asSequence().mapNotNull {
                        metric.dailyValue(grouped.getValue(it), key)
                    }.take(7).toList()
                    val baseline = if (reference.size >= 3) median(reference) else null
                    baseline?.let { metric.severity(value, it).coerceIn(0.0, 1.0) }
                }
                val score = median(scores) ?: continue
                weighted += metric.weight * score
                total += metric.weight
                if (metric != Metric.COUGH) voiceWeight += metric.weight
            }
            if (voiceWeight > 0) FatigueDay(date, (100 * weighted / total).roundToInt()) else null
        }
    }
}
