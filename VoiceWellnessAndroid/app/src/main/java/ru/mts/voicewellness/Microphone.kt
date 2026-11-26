package ru.mts.voicewellness

import android.annotation.SuppressLint
import android.media.AudioFormat
import android.media.AudioRecord
import android.os.Build
import android.os.SystemClock
import android.util.Log
import android.media.MediaRecorder
import java.util.concurrent.atomic.AtomicBoolean
import kotlin.math.abs

internal class Microphone {
    private val running = AtomicBoolean(true)
    val isCapturing: Boolean get() = running.get()
    fun stop() { running.set(false) }

    @SuppressLint("MissingPermission")
    fun record(source: Source, onCaptureEnded: () -> Unit, level: (Float, Int) -> Unit): Measurement {
        val openedAt = SystemClock.elapsedRealtime()
        val format = AudioFormat.CHANNEL_IN_MONO
        val encoding = AudioFormat.ENCODING_PCM_16BIT
        val minimum = AudioRecord.getMinBufferSize(SAMPLE_RATE, format, encoding)
        check(minimum > 0) { "Аудиовход недоступен." }
        val recorder = AudioRecord(MediaRecorder.AudioSource.VOICE_RECOGNITION, SAMPLE_RATE, format, encoding, minimum * 2)
        val buffer = ShortArray(SAMPLE_RATE / 20)
        val duration = if (source == Source.VOWEL) 10 else 60
        val samples = FloatArray(duration * SAMPLE_RATE)
        var count = 0
        var hasSignal = false
        val input = try {
            check(recorder.state == AudioRecord.STATE_INITIALIZED) { "Не удалось открыть микрофон." }
            if (!running.get()) throw java.util.concurrent.CancellationException()
            recorder.startRecording()
            check(recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) { "Не удалось запустить запись." }
            val firstReadDeadline = SystemClock.elapsedRealtime() + 2500
            var device = recorder.routedDevice
            while (running.get() && count < samples.size) {
                if (Build.VERSION.SDK_INT >= 29 && (count == 0 || count / SAMPLE_RATE != (count + buffer.size) / SAMPLE_RATE) &&
                    recorder.activeRecordingConfiguration?.isClientSilenced == true) {
                    error("Android отключил звук с микрофона. Проверьте системный доступ к микрофону и закройте другие приложения, которые его используют.")
                }
                val mode = if (count == 0) AudioRecord.READ_NON_BLOCKING else AudioRecord.READ_BLOCKING
                val n = recorder.read(buffer, 0, minOf(buffer.size, samples.size - count), mode)
                if (n == 0 && count == 0) {
                    check(SystemClock.elapsedRealtime() < firstReadDeadline) {
                        "Микрофон не передал звук вовремя. Проверьте аудиовход и повторите запись."
                    }
                    Thread.sleep(15)
                    continue
                }
                check(n > 0) { "Запись с микрофона прервалась." }
                val current = recorder.routedDevice
                if (count == 0) {
                    device = current
                    Log.d("VoiceMicrophone", "First PCM frame after ${SystemClock.elapsedRealtime() - openedAt} ms")
                }
                if (source == Source.VOWEL && current?.id != device?.id) {
                    error("Аудиовход изменился. Повторите замер с одним микрофоном.")
                }
                var peak = 0f
                for (i in 0 until n) {
                    val sample = buffer[i] / 32768f
                    samples[count++] = sample
                    peak = maxOf(peak, abs(sample))
                }
                hasSignal = hasSignal || peak >= 0.001f
                level(peak, count / SAMPLE_RATE)
            }
            device?.let {
                val address = if (Build.VERSION.SDK_INT >= 28) it.address else it.id.toString()
                listOf(it.productName.toString(), it.type.toString(), address).filter(String::isNotBlank).joinToString(" · ")
            } ?: "Микрофон Android"
        } finally {
            if (recorder.recordingState == AudioRecord.RECORDSTATE_RECORDING) recorder.stop()
            recorder.release()
        }
        stop()
        onCaptureEnded()
        check(hasSignal) { "С микрофона поступила только тишина. Проверьте системный доступ и выбранный аудиовход." }
        val audio = samples.copyOf(count)
        return when (source) {
            Source.READING -> {
                val cough = CoughAnalyzer.analyze(audio)
                val speech = try {
                    VoiceAnalyzer.speech(audio)
                } catch (error: InsufficientSpeech) {
                    if (cough == null || cough.episodeCount == 0) throw error
                    null
                }
                Measurement(source = source, input = input, speech = speech, cough = cough)
            }
            Source.VOWEL -> Measurement(
                source = source, input = input, cpps = VoiceAnalyzer.vowel(audio), cough = CoughAnalyzer.analyze(audio),
            )
            Source.TELEPHONY_DEMO -> error("Демозамер не использует микрофон.")
        }
    }
}
