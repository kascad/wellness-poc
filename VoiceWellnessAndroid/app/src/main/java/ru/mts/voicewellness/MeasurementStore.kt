package ru.mts.voicewellness

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.UUID

internal enum class Source { READING, VOWEL, TELEPHONY_DEMO }

internal data class Measurement(
    val id: String = UUID.randomUUID().toString(),
    val date: Long = System.currentTimeMillis(),
    val source: Source,
    val input: String,
    val speech: SpeechMetrics? = null,
    val cpps: Double? = null,
    val cough: CoughSummary? = null,
)

internal class MeasurementStore(context: Context, demo: Boolean = false) {
    private val preferences = context.getSharedPreferences(if (demo) "voice_wellness_demo" else "voice_wellness", Context.MODE_PRIVATE)
    var paused: Boolean
        get() = preferences.getBoolean("paused", false)
        set(value) { preferences.edit().putBoolean("paused", value).apply() }

    fun load(): List<Measurement> {
        val data = JSONArray(preferences.getString("measurements", "[]"))
        return (0 until data.length()).map { i ->
            val item = data.getJSONObject(i)
            val speech = item.optJSONObject("speech")?.let {
                SpeechMetrics(it.getInt("syllables"), it.getDouble("pace"), it.getDouble("articulation"),
                    if (it.isNull("pause")) null else it.getDouble("pause"))
            }
            val cough = item.optJSONObject("cough")?.let {
                CoughSummary(it.getInt("episodeCount"), it.getDouble("analyzedDuration"))
            }
            Measurement(item.getString("id"), item.getLong("date"), Source.valueOf(item.getString("source")),
                item.getString("input"), speech, if (item.isNull("cpps")) null else item.getDouble("cpps"), cough)
        }
    }

    fun save(history: List<Measurement>) {
        val data = JSONArray()
        history.forEach { entry ->
            val item = JSONObject()
                .put("id", entry.id).put("date", entry.date).put("source", entry.source.name)
                .put("input", entry.input).put("cpps", entry.cpps ?: JSONObject.NULL)
            entry.speech?.let {
                item.put("speech", JSONObject().put("syllables", it.syllables).put("pace", it.pace)
                    .put("articulation", it.articulation).put("pause", it.pause ?: JSONObject.NULL))
            }
            entry.cough?.let {
                item.put("cough", JSONObject().put("episodeCount", it.episodeCount)
                    .put("analyzedDuration", it.analyzedDuration))
            }
            data.put(item)
        }
        preferences.edit().putString("measurements", data.toString()).apply()
    }
}
