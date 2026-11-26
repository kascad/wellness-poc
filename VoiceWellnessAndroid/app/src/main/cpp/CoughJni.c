#include <jni.h>
#include "CoughDetector.h"

JNIEXPORT jint JNICALL Java_ru_mts_voicewellness_CoughAnalyzer_nativeCount(
    JNIEnv *env, jobject instance, jfloatArray audio, jint rate) {
    (void)instance;
    jsize count = (*env)->GetArrayLength(env, audio);
    jfloat *samples = (*env)->GetFloatArrayElements(env, audio, NULL);
    if (!samples) return -1;
    jint episodes = vw_cough_count(samples, count, rate);
    (*env)->ReleaseFloatArrayElements(env, audio, samples, JNI_ABORT);
    return episodes;
}
