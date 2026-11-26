package ru.mts.voicewellness

import kotlin.math.*

internal const val SAMPLE_RATE = 16000

internal data class SpeechMetrics(val syllables: Int, val pace: Double, val articulation: Double, val pause: Double?)

internal fun median(values: List<Double>): Double? {
    if (values.isEmpty()) return null
    val sorted = values.sorted()
    return (sorted[(sorted.size - 1) / 2] + sorted[sorted.size / 2]) / 2
}

internal class InsufficientSpeech : IllegalStateException("Распознано слишком мало речи. Повторите запись в тихом месте.")

internal object VoiceAnalyzer {
    fun speech(samples: FloatArray): SpeechMetrics {
        val hop = SAMPLE_RATE / 100
        val window = hop * 3
        val levels = levels(samples, window, hop)
        fun insufficient(): Nothing = throw InsufficientSpeech()
        if (levels.isEmpty()) insufficient()
        val sorted = levels.sorted()
        val loud = sorted[((sorted.size - 1) * .99).toInt()]
        val threshold = maxOf(-58.0, loud - 25, min(sorted[sorted.size / 10] + 8, loud - 7))
        val active = levels.indices.filter { levels[it] >= threshold }
        if (active.isEmpty()) insufficient()
        val pauses = active.zipWithNext().map { (a, b) -> (b - a - 1) * .01 }.filter { it >= .25 }
        val duration = (active.last() - active.first() + 1) * .01
        val speaking = duration - pauses.sum()
        if (speaking < 1.5) insufficient()
        val smooth = levels.indices.map { i ->
            val range = max(0, i - 2)..min(levels.lastIndex, i + 2)
            range.sumOf { levels[it] } / range.count()
        }
        val nuclei = mutableListOf<Int>()
        for (i in 1 until smooth.lastIndex) {
            if (smooth[i] < threshold || smooth[i] <= smooth[i - 1] || smooth[i] < smooth[i + 1]) continue
            val left = (maxOf(0, i - 12)..i).minOf { smooth[it] }
            val right = (i..min(smooth.lastIndex, i + 12)).minOf { smooth[it] }
            if (smooth[i] - max(left, right) < 2 || !voiced(samples, i * hop, window)) continue
            val previous = nuclei.lastOrNull()
            if (previous == null || i - previous >= 9) nuclei.add(i)
            else if (smooth[i] > smooth[previous]) nuclei[nuclei.lastIndex] = i
        }
        if (nuclei.size < 3) insufficient()
        return SpeechMetrics(nuclei.size, nuclei.size / duration, nuclei.size / speaking, median(pauses))
    }

    private fun levels(samples: FloatArray, window: Int, hop: Int): List<Double> {
        return (0..samples.size - window step hop).map { start ->
            var energy = 0.0
            for (i in start until start + window) energy += samples[i] * samples[i]
            10 * log10(max(1e-12, energy / window))
        }
    }

    private fun voiced(samples: FloatArray, start: Int, window: Int): Boolean {
        val segment = DoubleArray(window / 2) { samples[start + it * 2].toDouble() }
        val mean = segment.average()
        for (i in segment.indices) segment[i] -= mean
        for (lag in 8000 / 450..min(segment.size / 2, 8000 / 75)) {
            var product = 0.0
            var left = 0.0
            var right = 0.0
            for (i in 0 until segment.size - lag) {
                val a = segment[i]
                val b = segment[i + lag]
                product += a * b
                left += a * a
                right += b * b
            }
            if (product > .65 * sqrt(left * right)) return true
        }
        return false
    }

    fun vowel(samples: FloatArray): Double {
        val block = SAMPLE_RATE / 50
        val levels = levels(samples, block, block)
        require(levels.size >= 100) { "Потяните «А-а-а» непрерывно 3–4 секунды." }
        val voice = levels.sorted()[((levels.size - 1) * .8).toInt()]
        require(voice > -48) { "Голос слишком тихий. Повторите замер ближе к микрофону." }
        val noise = levels.take(15).sorted()[7]
        require(voice - noise >= 15) { "Начните с секунды тишины и повторите в тихом месте." }
        val threshold = max(noise + 12, voice - 14)
        var start = 0
        var bestStart = 0
        var bestLength = 0
        for (i in 0..levels.size) {
            if (i == levels.size || levels[i] < threshold) {
                if (i - start > bestLength) {
                    bestStart = start
                    bestLength = i - start
                }
                start = i + 1
            }
        }
        require(bestLength >= 90) { "Потяните «А-а-а» непрерывно 3–4 секунды." }
        val from = bestStart * block
        val end = from + bestLength * block
        val clipped = (from until end).count { abs(samples[it]) >= .985 }
        require(clipped.toDouble() / (end - from) < .005) { "Звук перегружен. Отодвиньте микрофон и повторите." }

        val frame = 640
        val size = 2048
        val low = 16
        val high = 320
        val window = DoubleArray(frame) { .5 - .5 * cos(2 * PI * it / (frame - 1)) }
        val cepstra = (from + 3200..end - 3200 - frame step 160).map { offset ->
            val re = DoubleArray(size)
            val im = DoubleArray(size)
            val mean = (0 until frame).sumOf { samples[offset + it].toDouble() } / frame
            for (i in 0 until frame) re[i] = (samples[offset + i] - mean) * window[i]
            fft(re, im)
            for (i in re.indices) {
                re[i] = ln(max(1e-12, re[i] * re[i] + im[i] * im[i]))
                im[i] = 0.0
            }
            fft(re, im)
            DoubleArray(high + 2) { 20 * log10(max(1e-12, abs(re[it]) / size)) }
        }
        val center = (low + high) / 2.0
        val variance = (low..high).sumOf { (it - center).pow(2) }
        return cepstra.indices.map { i ->
            val neighbors = max(0, i - 2)..min(cepstra.lastIndex, i + 2)
            val smooth = DoubleArray(high - low + 1) { index ->
                val q = low + index
                neighbors.sumOf { cepstra[it][q - 1] + cepstra[it][q] + cepstra[it][q + 1] } / (3 * neighbors.count())
            }
            val mean = smooth.average()
            val slope = (low..high).sumOf { (it - center) * (smooth[it - low] - mean) } / variance
            val peak = (ceil(SAMPLE_RATE / 450.0).toInt()..SAMPLE_RATE / 70).maxBy { smooth[it - low] }
            smooth[peak - low] - (mean + slope * (peak - center))
        }.average()
    }

    private fun fft(re: DoubleArray, im: DoubleArray) {
        val count = re.size
        var j = 0
        for (i in 1 until count) {
            var bit = count shr 1
            while ((j and bit) != 0) {
                j = j xor bit
                bit = bit shr 1
            }
            j = j xor bit
            if (i < j) {
                val a = re[i]; re[i] = re[j]; re[j] = a
                val b = im[i]; im[i] = im[j]; im[j] = b
            }
        }
        var size = 2
        while (size <= count) {
            val angle = -2 * PI / size
            val stepR = cos(angle)
            val stepI = sin(angle)
            for (start in 0 until count step size) {
                var wr = 1.0
                var wi = 0.0
                for (a in start until start + size / 2) {
                    val b = a + size / 2
                    val tr = wr * re[b] - wi * im[b]
                    val ti = wr * im[b] + wi * re[b]
                    re[b] = re[a] - tr; im[b] = im[a] - ti
                    re[a] += tr; im[a] += ti
                    val next = wr * stepR - wi * stepI
                    wi = wr * stepI + wi * stepR
                    wr = next
                }
            }
            size *= 2
        }
    }
}
