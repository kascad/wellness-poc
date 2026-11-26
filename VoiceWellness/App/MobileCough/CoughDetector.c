#include "CoughDetector.h"

#include <math.h>
#include <stdlib.h>
#include "CoughWeights.h"

enum { Rate = 16000, Frame = 400, Hop = 160, FFT = 512, Frames = 98, Bands = 24 };

static void fft(double real[], double imag[]) {
    for (int i = 1, j = 0; i < FFT; ++i) {
        int bit = FFT / 2;
        while (j & bit) { j ^= bit; bit >>= 1; }
        j ^= bit;
        if (i < j) {
            double temp = real[i];
            real[i] = real[j];
            real[j] = temp;
        }
    }
    for (int size = 2; size <= FFT; size *= 2) {
        const double angle = -6.2831853071795864769 / size;
        const double step_real = cos(angle), step_imag = sin(angle);
        for (int base = 0; base < FFT; base += size) {
            double w_real = 1, w_imag = 0;
            for (int j = 0; j < size / 2; ++j) {
                int u = base + j, v = u + size / 2;
                double vr = real[v] * w_real - imag[v] * w_imag;
                double vi = real[v] * w_imag + imag[v] * w_real;
                real[v] = real[u] - vr; imag[v] = imag[u] - vi;
                real[u] += vr; imag[u] += vi;
                double previous = w_real;
                w_real = w_real * step_real - w_imag * step_imag;
                w_imag = previous * step_imag + w_imag * step_real;
            }
        }
    }
}

static int ascending(const void *a, const void *b) {
    double left = *(const double *)a, right = *(const double *)b;
    return (left > right) - (left < right);
}

double vw_cough_window_logit(const float *samples) {
    double energy[Frames] = {0}, maximum = 0;
    int loudest = 0;
    for (int t = 0; t < Frames; ++t) {
        for (int i = 0; i < Frame; ++i) {
            double sample = samples[t * Hop + i];
            energy[t] += sample * sample / Frame;
        }
        if (energy[t] > maximum) { maximum = energy[t]; loudest = t; }
    }
    if (maximum <= 1e-10) return -INFINITY;
    const double scale = 1 / sqrt(maximum);
    const double active_floor = fmax(1e-10, maximum / 1000);
    double useful[Bands][Frames], previous[Bands] = {0}, delta[Bands] = {0};
    int active = 0;
    for (int t = 0; t < Frames; ++t) {
        double real[FFT] = {0}, imag[FFT] = {0};
        for (int i = 0; i < Frame; ++i) real[i] = samples[t * Hop + i] * scale * hann[i];
        fft(real, imag);
        double power[FFT / 2 + 1];
        for (int i = 0; i <= FFT / 2; ++i) power[i] = (real[i]*real[i] + imag[i]*imag[i]) / FFT;
        int coefficient = 0;
        for (int b = 0; b < Bands; ++b) {
            double mel = 0;
            for (int j = 0; j < (int)mel_length[b]; ++j) {
                mel += power[(int)mel_start[b] + j] * mel_weights[coefficient++];
            }
            mel = log(fmax(mel, 1e-8));
            if (energy[t] > active_floor) useful[b][active] = mel;
            if (t) delta[b] += fabs(mel - previous[b]);
            previous[b] = mel;
        }
        if (energy[t] > active_floor) ++active;
    }
    double score = model_parameters[0];
    for (int b = 0; b < Bands; ++b) {
        double sum = 0, variance = 0;
        for (int i = 0; i < active; ++i) sum += useful[b][i];
        double mean = sum / active;
        for (int i = 0; i < active; ++i) {
            double v = useful[b][i] - mean;
            variance += v * v;
        }
        qsort(useful[b], active, sizeof(double), ascending);
        double position = 0.9 * (active - 1);
        int lower = (int)position, upper = (int)ceil(position);
        double p90 = useful[b][lower] + (position - lower) * (useful[b][upper] - useful[b][lower]);
        score += model_weights[b] * mean + model_weights[Bands+b] * sqrt(variance / active)
               + model_weights[2*Bands+b] * p90 + model_weights[3*Bands+b] * delta[b] / (Frames-1);
    }
    double peak = fabs(samples[0]);
    int changes = 0;
    for (int i = 1; i < Rate; ++i) {
        peak = fmax(peak, fabs(samples[i]));
        if (signbit(samples[i]) != signbit(samples[i-1])) ++changes;
    }
    const double tail[] = { (double)active / Frames, (double)loudest / Frames,
                           (double)changes / (Rate-1), peak * scale, log(maximum) };
    for (int i = 0; i < 5; ++i) score += model_weights[4*Bands+i] * tail[i];
    return score;
}

int32_t vw_cough_count(const float *samples, int32_t count, int32_t sample_rate) {
    if (!samples || sample_rate < 8000 || sample_rate > 192000 || count < sample_rate) return -1;
    double ratio = (double)sample_rate / Rate;
    int length = (int)(count / ratio);
    float *resampled = NULL;
    if (sample_rate != Rate) {
        resampled = malloc((size_t)length * sizeof(float));
        if (!resampled) return -1;
        for (int i = 0; i < length; ++i) {
            // Average over the destination sample's source interval.
            double start = i * ratio, end = fmin(count, (i + 1) * ratio);
            double total = 0;
            for (int j = (int)start; j < count && j < end; ++j) {
                total += samples[j] * (fmin(end, j + 1.) - fmax(start, j));
            }
            resampled[i] = (float)(total / (end - start));
        }
        samples = resampled;
    }
    int episodes = 0, previous_end = -1;
    for (int i = 0; ; i += Rate / 4) {
        int start = i < length - Rate ? i : length - Rate;
        if (vw_cough_window_logit(samples + start) >= model_parameters[1]) {
            if (start > previous_end) ++episodes;
            previous_end = start + Rate;
        }
        if (start == length - Rate) break;
    }
    free(resampled);
    return episodes;
}
