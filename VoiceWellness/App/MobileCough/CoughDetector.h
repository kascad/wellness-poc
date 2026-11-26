#ifndef VW_COUGH_DETECTOR_H
#define VW_COUGH_DETECTOR_H
#include <stdint.h>

// Mono, floating point PCM. Returns -1 when there is too little usable audio.
int32_t vw_cough_count(const float *samples, int32_t count, int32_t sample_rate);
double vw_cough_window_logit(const float *samples); // Exactly 16000 samples.
#endif
