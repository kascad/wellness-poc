package ru.mts.voicewellness

internal data class CoughSummary(val episodeCount: Int, val analyzedDuration: Double)

internal object CoughAnalyzer {
    init { System.loadLibrary("voice_cough") }

    private external fun nativeCount(samples: FloatArray, sampleRate: Int): Int

    fun analyze(samples: FloatArray): CoughSummary? {
        val episodes = nativeCount(samples, SAMPLE_RATE)
        return if (episodes < 0) null else CoughSummary(episodes, samples.size.toDouble() / SAMPLE_RATE)
    }
}
