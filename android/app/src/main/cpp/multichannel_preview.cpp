#include <jni.h>
#include <aaudio/AAudio.h>
#include <android/log.h>
#include <thread>
#include <atomic>
#include <fstream>
#include <vector>
#include <cstring>
#include <cmath>
#include <algorithm>
#include <string>


#define LOGI(...) __android_log_print(ANDROID_LOG_INFO, "multichannel_preview", __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, "multichannel_preview", __VA_ARGS__)

// WAV information structure and forward declaration for header parser
struct WavInfo {
    int sampleRate = 44100;
    int channels = 2;
    int bitsPerSample = 16;
    int audioFormat = 1; // 1=PCM, 3=IEEE float
    size_t dataOffset = 0;
    size_t dataSize = 0;
};
static bool parseWavHeader(std::ifstream &ifs, WavInfo &info);

static AAudioStream* gStream = nullptr;
static std::thread gThread;
static std::atomic<bool> gStop{false};
static std::atomic<bool> gDoSeek{false};
static std::atomic<double> gSeekSec{0.0};
static std::atomic<float> gVolume{1.0f};
static std::atomic<float> gPan{0.0f};
static int gDeviceChannels = 2;

// --- BPM detection utilities (simple envelope + autocorrelation) ---
static bool buildEnvelopeDownsampled(std::ifstream &ifs, const WavInfo &info, std::vector<float> &env, float &envFs) {
    // Target envelope sampling rate ~200 Hz
    const float targetFs = 200.0f;
    const int bytesPerSample = info.bitsPerSample / 8; // 2 for 16-bit, 3 for 24-bit, 4 for float32
    const int frameBytes = bytesPerSample * info.channels;
    if (frameBytes <= 0 || info.sampleRate <= 0 || info.dataSize == 0) return false;

    int decim = std::max(1, (int)std::floor((float)info.sampleRate / targetFs));
    envFs = (float)info.sampleRate / (float)decim;

    const size_t totalFrames = info.dataSize / frameBytes;
    if (totalFrames < (size_t)info.sampleRate) {
        // menos de 1s de áudio
        return false;
    }

    const size_t chunkFrames = 4096; // frames por chunk
    std::vector<unsigned char> buffer(chunkFrames * frameBytes);
    ifs.seekg((std::streamoff)info.dataOffset, std::ios::beg);

    int decimCount = 0;
    double acc = 0.0;
    size_t framesProcessed = 0;
    while (framesProcessed < totalFrames) {
        const size_t framesToRead = std::min(chunkFrames, totalFrames - framesProcessed);
        const size_t bytesToRead = framesToRead * frameBytes;
        ifs.read(reinterpret_cast<char*>(buffer.data()), (std::streamsize)bytesToRead);
        if (!ifs) break;
        // process frames
        const unsigned char* p = buffer.data();
        for (size_t f = 0; f < framesToRead; ++f) {
            float mono = 0.0f;
            if (info.audioFormat == 1 && info.bitsPerSample == 16) {
                // PCM16
                const int16_t* s = reinterpret_cast<const int16_t*>(p);
                int sum = 0;
                for (int ch = 0; ch < info.channels; ++ch) {
                    sum += (int)s[ch];
                }
                mono = (float)sum / (float)(info.channels * 32768.0f);
            } else if (info.audioFormat == 1 && info.bitsPerSample == 24) {
                // PCM24 little-endian
                const unsigned char* q = p;
                double sum = 0.0;
                for (int ch = 0; ch < info.channels; ++ch) {
                    int b0 = q[0];
                    int b1 = q[1];
                    int b2 = q[2];
                    int v = (b2 << 16) | (b1 << 8) | b0;
                    if (v & 0x800000) v |= ~0xFFFFFF; // sign extend
                    sum += (double)v / 8388608.0; // 2^23
                    q += 3;
                }
                mono = (float)(sum / (double)info.channels);
            } else if (info.audioFormat == 3 && info.bitsPerSample == 32) {
                // IEEE float32 little-endian
                const unsigned char* q = p;
                double sum = 0.0;
                for (int ch = 0; ch < info.channels; ++ch) {
                    float fv;
                    std::memcpy(&fv, q, sizeof(float));
                    // clamp just in case
                    if (fv > 1.5f) fv = 1.5f;
                    if (fv < -1.5f) fv = -1.5f;
                    sum += (double)fv;
                    q += 4;
                }
                mono = (float)(sum / (double)info.channels);
            } else {
                // Unsupported
                return false;
            }
            const float v = std::fabs(mono);
            acc += v;
            decimCount++;
            if (decimCount >= decim) {
                env.push_back((float)(acc / (double)decim));
                acc = 0.0;
                decimCount = 0;
            }
            p += frameBytes;
        }
        framesProcessed += framesToRead;
    }

    if (env.size() < (size_t)(envFs * 3)) {
        // menos de 3s de envelope
        return false;
    }

    // Smooth envelope with small moving average (~50 ms)
    const int w = std::max(1, (int)std::round(envFs * 0.05f));
    if (w > 1) {
        std::vector<float> sm(env.size(), 0.0f);
        double sum = 0.0;
        for (size_t i = 0; i < env.size(); ++i) {
            sum += env[i];
            if (i >= (size_t)w) sum -= env[i - w];
            sm[i] = (float)(sum / (double)std::min((size_t)w, i + 1));
        }
        env.swap(sm);
    }
    return true;
}

static void autocorrelationRange(const std::vector<float> &env, float envFs, int lagMin, int lagMax, double &bestCorr, int &bestLag, double &avgCorr) {
    // Zero-mean
    double mean = 0.0;
    for (float v : env) mean += v;
    mean /= (double)env.size();

    double var = 0.0;
    std::vector<float> z(env.size());
    for (size_t i = 0; i < env.size(); ++i) {
        float d = env[i] - (float)mean;
        z[i] = d;
        var += (double)d * (double)d;
    }
    if (var <= 1e-12) { bestCorr = 0.0; bestLag = lagMin; avgCorr = 0.0; return; }

    bestCorr = -1.0; bestLag = lagMin; avgCorr = 0.0;
    int count = 0;
    for (int L = lagMin; L <= lagMax; ++L) {
        const size_t N = z.size() - (size_t)L;
        if (N <= 10) continue;
        double num = 0.0;
        for (size_t i = 0; i < N; ++i) {
            num += (double)z[i] * (double)z[i + L];
        }
        // Normalize by variance part (approx): var is sum(z^2)
        double corr = num / var;
        if (corr > bestCorr) { bestCorr = corr; bestLag = L; }
        avgCorr += corr;
        count++;
    }
    if (count > 0) avgCorr /= (double)count; else avgCorr = 0.0;
}

extern "C" JNIEXPORT jdoubleArray JNICALL
Java_com_example_multitrack_1app_MainActivity_nativeDetectBpmFromWav(JNIEnv* env, jobject /*thiz*/, jstring jpath) {
    const char* cpath = env->GetStringUTFChars(jpath, nullptr);
    std::string path(cpath ? cpath : "");
    if (cpath) env->ReleaseStringUTFChars(jpath, cpath);

    double outBpm = 120.0;
    double outConf = 0.2;

    std::ifstream ifs(path, std::ios::binary);
    if (!ifs) {
        LOGE("nativeDetectBpm: cannot open file");
        jdoubleArray arr = env->NewDoubleArray(2);
        jdouble vals[2] = { outBpm, outConf };
        env->SetDoubleArrayRegion(arr, 0, 2, vals);
        return arr;
    }
    WavInfo info;
    if (!parseWavHeader(ifs, info)) {
        LOGE("nativeDetectBpm: unsupported or invalid wav header\n");
        jdoubleArray arr = env->NewDoubleArray(2);
        jdouble vals[2] = { outBpm, outConf };
        env->SetDoubleArrayRegion(arr, 0, 2, vals);
        return arr;
    }
    // Support PCM16/PCM24/Float32
    bool supported = (info.audioFormat == 1 && (info.bitsPerSample == 16 || info.bitsPerSample == 24))
                     || (info.audioFormat == 3 && info.bitsPerSample == 32);
    if (!supported) {
        LOGE("nativeDetectBpm: unsupported wav for BPM (need PCM16/24 or float32)\n");
        jdoubleArray arr = env->NewDoubleArray(2);
        jdouble vals[2] = { outBpm, outConf };
        env->SetDoubleArrayRegion(arr, 0, 2, vals);
        return arr;
    }

    std::vector<float> envBuf;
    float envFs = 200.0f;
    if (!buildEnvelopeDownsampled(ifs, info, envBuf, envFs)) {
        LOGE("nativeDetectBpm: failed to build envelope");
        jdoubleArray arr = env->NewDoubleArray(2);
        jdouble vals[2] = { outBpm, outConf };
        env->SetDoubleArrayRegion(arr, 0, 2, vals);
        return arr;
    }

    // BPM range: 60..200
    int lagMax = std::max(1, (int)std::round(envFs * 60.0f / 60.0f));
    int lagMin = std::max(1, (int)std::round(envFs * 60.0f / 200.0f));
    if (lagMax <= lagMin + 2) lagMax = lagMin + 3;

    double bestCorr = 0.0, avgCorr = 0.0; int bestLag = lagMin;
    autocorrelationRange(envBuf, envFs, lagMin, lagMax, bestCorr, bestLag, avgCorr);
    if (bestLag < 1) bestLag = std::max(1, lagMin);
    outBpm = 60.0 * (double)envFs / (double)bestLag;

    // Confidence heuristic: ratio of bestCorr to avgCorr
    if (bestCorr <= 1e-9) outConf = 0.2;
    else if (avgCorr <= 1e-9) outConf = std::min(1.0, std::max(0.3, bestCorr));
    else outConf = std::min(1.0, std::max(0.3, bestCorr / std::max(1e-6, avgCorr)));

    jdoubleArray arr = env->NewDoubleArray(2);
    jdouble vals[2] = { outBpm, outConf };
    env->SetDoubleArrayRegion(arr, 0, 2, vals);
    return arr;
}

static bool parseWavHeader(std::ifstream &ifs, WavInfo &info) {
    // Read RIFF header
    char riff[12];
    ifs.seekg(0, std::ios::beg);
    ifs.read(riff, 12);
    if (ifs.gcount() < 12) return false;
    if (std::memcmp(riff, "RIFF", 4) != 0 || std::memcmp(riff + 8, "WAVE", 4) != 0) return false;

    bool haveFmt = false;
    bool haveData = false;
    while (ifs) {
        char hdr[8];
        ifs.read(hdr, 8);
        if (!ifs || ifs.gcount() < 8) break;
        int size = *(int32_t*)(hdr + 4);
        // Ensure little-endian on Android; assuming LE
        if (std::memcmp(hdr, "fmt ", 4) == 0) {
            std::vector<char> buf(size);
            ifs.read(buf.data(), size);
            if ((int)ifs.gcount() < size) return false;
            // Parse fmt
            auto rd16 = [&](int off) { return *(int16_t*)(buf.data() + off); };
            auto rd32 = [&](int off) { return *(int32_t*)(buf.data() + off); };
            info.audioFormat = rd16(0);
            info.channels = rd16(2);
            info.sampleRate = rd32(4);
            // byteRate = rd32(8);
            // blockAlign = rd16(12);
            if (size >= 16) info.bitsPerSample = rd16(14); else info.bitsPerSample = 0;
            haveFmt = true;
        } else if (std::memcmp(hdr, "data", 4) == 0) {
            std::streampos pos = ifs.tellg();
            info.dataOffset = (size_t)pos;
            info.dataSize = (size_t)size;
            // skip payload to continue scanning if needed
            ifs.seekg(size, std::ios::cur);
            haveData = true;
        } else {
            // skip unknown chunk
            ifs.seekg(size, std::ios::cur);
        }
        if (haveFmt && haveData) break;
    }
    return haveFmt && haveData && info.sampleRate > 0 && info.channels > 0 && info.bitsPerSample > 0 && info.dataSize > 0;
}

static void closeStream() {
    if (gStream) {
        AAudioStream_requestStop(gStream);
        AAudioStream_close(gStream);
        gStream = nullptr;
    }
}

struct MixTrack {
    std::string path;
    int outputChannel = 0; // 0=L,1=R,>=2 pair LR
    float volume = 1.0f;
    float pan = 0.0f; // used when pair
    WavInfo info;
    std::ifstream ifs;
    bool ended = false;
};

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_multitrack_1app_MainActivity_nativePlayAllPreview(
        JNIEnv* env,
        jobject /*thiz*/,
        jobjectArray jFilePaths,
        jintArray jOutputChannels,
        jfloatArray jVolumes,
        jfloatArray jPans,
        jint jDeviceId,
        jint jDeviceChannels) {
    // Build track list
    jsize count = env->GetArrayLength(jFilePaths);
    if (count <= 0) return JNI_FALSE;
    std::vector<MixTrack> tracks;
    tracks.reserve(count);
    // Extract arrays
    jint* outCh = env->GetIntArrayElements(jOutputChannels, nullptr);
    jfloat* vols = env->GetFloatArrayElements(jVolumes, nullptr);
    jfloat* pans = env->GetFloatArrayElements(jPans, nullptr);
    for (jsize i = 0; i < count; ++i) {
        jstring jstr = (jstring)env->GetObjectArrayElement(jFilePaths, i);
        const char* cstr = env->GetStringUTFChars(jstr, nullptr);
        MixTrack mt;
        mt.path = cstr ? std::string(cstr) : std::string();
        env->ReleaseStringUTFChars(jstr, cstr);
        env->DeleteLocalRef(jstr);
        mt.outputChannel = outCh ? outCh[i] : 0;
        mt.volume = vols ? std::max(0.0f, std::min(1.0f, vols[i])) : 1.0f;
        mt.pan = pans ? std::max(-1.0f, std::min(1.0f, pans[i])) : 0.0f;
        if (mt.path.empty()) { tracks.clear(); break; }
        mt.ifs = std::ifstream(mt.path, std::ios::binary);
        if (!mt.ifs.is_open()) { tracks.clear(); break; }
        if (!parseWavHeader(mt.ifs, mt.info)) { tracks.clear(); break; }
        mt.ifs.seekg(mt.info.dataOffset, std::ios::beg);
        tracks.push_back(std::move(mt));
    }
    if (outCh) env->ReleaseIntArrayElements(jOutputChannels, outCh, JNI_ABORT);
    if (vols) env->ReleaseFloatArrayElements(jVolumes, vols, JNI_ABORT);
    if (pans) env->ReleaseFloatArrayElements(jPans, pans, JNI_ABORT);
    if (tracks.empty()) return JNI_FALSE;

    // Validate sample rate consistency
    int baseRate = tracks[0].info.sampleRate;
    for (const auto& t : tracks) {
        if (t.info.sampleRate != baseRate || t.info.bitsPerSample != 16) {
            LOGE("sample rate/bits mismatch");
            for (auto& tt : tracks) { if (tt.ifs.is_open()) tt.ifs.close(); }
            return JNI_FALSE;
        }
    }

    // Setup AAudio stream
    closeStream();
    gStop = false;
    AAudioStreamBuilder* builder = nullptr;
    aaudio_result_t res = AAudio_createStreamBuilder(&builder);
    if (res != AAUDIO_OK || !builder) { LOGE("builder fail %d", res); return JNI_FALSE; }
    int deviceChannels = (int)jDeviceChannels;
    if (deviceChannels < 2) deviceChannels = 2;
    gDeviceChannels = deviceChannels;
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(builder, deviceChannels);
    AAudioStreamBuilder_setSampleRate(builder, baseRate);
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
    if (jDeviceId > 0) {
        AAudioStreamBuilder_setDeviceId(builder, (int)jDeviceId);
    }
    res = AAudioStreamBuilder_openStream(builder, &gStream);
    AAudioStreamBuilder_delete(builder);
    if (res != AAUDIO_OK || !gStream) { LOGE("openStream fail %d", res); return JNI_FALSE; }
    res = AAudioStream_requestStart(gStream);
    if (res != AAUDIO_OK) { LOGE("start fail %d", res); closeStream(); return JNI_FALSE; }
    int outChannels = AAudioStream_getChannelCount(gStream);
    if (outChannels < 2) outChannels = 2;
    int outRate = AAudioStream_getSampleRate(gStream);
    LOGI("AAudio mixer started: outChannels=%d outRate=%d tracks=%d", outChannels, outRate, (int)tracks.size());

    // Writer thread: mix to device
    gThread = std::thread([tracks = std::move(tracks), outChannels]() mutable {
        const size_t BYTES = 4096;
        std::vector<std::vector<char>> bytes(tracks.size(), std::vector<char>(BYTES));
        std::vector<std::vector<int16_t>> samples(tracks.size(), std::vector<int16_t>(BYTES/2));
        while (!gStop.load()) {
            // Apply pending seek request atomically
            if (gDoSeek.load()) {
                double sec = gSeekSec.load();
                if (sec < 0.0) sec = 0.0;
                for (auto &t : tracks) {
                    long long frames = (long long)(sec * t.info.sampleRate);
                    long long bps = (long long)(t.info.bitsPerSample / 8);
                    long long bytes = frames * t.info.channels * bps;
                    if (bytes < 0) bytes = 0;
                    if ((size_t)bytes >= t.info.dataSize) {
                        t.ended = true;
                        t.ifs.clear();
                        t.ifs.seekg((std::streamoff)(t.info.dataOffset + t.info.dataSize), std::ios::beg);
                    } else {
                        t.ended = false;
                        t.ifs.clear();
                        t.ifs.seekg((std::streamoff)(t.info.dataOffset + bytes), std::ios::beg);
                    }
                }
                gDoSeek.store(false);
            }
            bool anyData = false;
            std::vector<int> framesPerTrack(tracks.size(), 0);
            for (size_t i = 0; i < tracks.size(); ++i) {
                auto &t = tracks[i];
                if (t.ended) { framesPerTrack[i] = 0; continue; }
                t.ifs.read(bytes[i].data(), BYTES);
                std::streamsize n = t.ifs.gcount();
                if (n <= 0) { t.ended = true; framesPerTrack[i] = 0; continue; }
                anyData = true;
                int shorts = ((int)n) / 2;
                std::memcpy(samples[i].data(), bytes[i].data(), shorts * sizeof(int16_t));
                framesPerTrack[i] = shorts / t.info.channels;
            }
            if (!anyData) break;
            int frames = 0;
            for (auto f : framesPerTrack) { if (f > 0) { frames = (frames == 0 ? f : std::min(frames, f)); } }
            if (frames <= 0) continue;
            // Accumulate to int32 per channel
            std::vector<int32_t> acc(frames * outChannels);
            std::fill(acc.begin(), acc.end(), 0);
            for (size_t i = 0; i < tracks.size(); ++i) {
                auto &t = tracks[i];
                if (framesPerTrack[i] <= 0) continue;
                float vol = std::max(0.0f, std::min(1.0f, t.volume));
                float pan = std::max(-1.0f, std::min(1.0f, t.pan));
                double tt = (double(pan) + 1.0) / 2.0;
                double angle = (M_PI / 2.0) * tt;
                float lg = (float)std::cos(angle);
                float rg = (float)std::sin(angle);
                int inCh = t.info.channels;
                if (inCh == 2) {
                    for (int f = 0; f < frames; ++f) {
                        int16_t l = samples[i][f*2];
                        int16_t r = samples[i][f*2 + 1];
                        if (t.outputChannel == 0) {
                            int idx = f*outChannels + 0;
                            acc[idx] += int32_t(float(l) * vol);
                        } else if (t.outputChannel == 1) {
                            int idx = f*outChannels + 1;
                            acc[idx] += int32_t(float(r) * vol);
                        } else {
                            // pair to 0/1
                            int idxL = f*outChannels + 0;
                            int idxR = f*outChannels + 1;
                            acc[idxL] += int32_t(float(l) * lg * vol);
                            acc[idxR] += int32_t(float(r) * rg * vol);
                        }
                    }
                } else { // mono
                    for (int f = 0; f < frames; ++f) {
                        int16_t m = samples[i][f];
                        if (t.outputChannel == 0) {
                            int idx = f*outChannels + 0;
                            acc[idx] += int32_t(float(m) * vol);
                        } else if (t.outputChannel == 1) {
                            int idx = f*outChannels + 1;
                            acc[idx] += int32_t(float(m) * vol);
                        } else {
                            int idxL = f*outChannels + 0;
                            int idxR = f*outChannels + 1;
                            acc[idxL] += int32_t(float(m) * lg * vol);
                            acc[idxR] += int32_t(float(m) * rg * vol);
                        }
                    }
                }
            }
            // Apply bus volume and clamp
            float busVol = gVolume.load();
            if (busVol < 0.0f) busVol = 0.0f;
            if (busVol > 1.0f) busVol = 1.0f;
            std::vector<int16_t> out(frames * outChannels);
            for (int f = 0; f < frames; ++f) {
                for (int c = 0; c < outChannels; ++c) {
                    int idx = f*outChannels + c;
                    float s = float(acc[idx]) * busVol;
                    if (s > 32767.0f) s = 32767.0f;
                    if (s < -32768.0f) s = -32768.0f;
                    out[idx] = (int16_t)s;
                }
            }
            int written = 0;
            while (written < frames && !gStop.load()) {
                aaudio_result_t wr = AAudioStream_write(gStream, out.data() + written * outChannels, frames - written, 1000000);
                if (wr < 0) { LOGE("write err %d", wr); break; }
                written += wr;
            }
        }
        // Close files
        for (auto &t : tracks) { if (t.ifs.is_open()) t.ifs.close(); }
    });
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_multitrack_1app_MainActivity_nativeSeekAllPreview(JNIEnv* /*env*/, jobject /*thiz*/, jdouble positionSec) {
    double p = (double)positionSec;
    if (p < 0.0) p = 0.0;
    gSeekSec.store(p);
    gDoSeek.store(true);
}

extern "C" JNIEXPORT jboolean JNICALL
Java_com_example_multitrack_1app_MainActivity_nativePlayWavPreview(
        JNIEnv* env,
        jobject /*thiz*/,
        jstring jFilePath,
        jint jOutputChannel,
        jint jDeviceId,
        jint jDeviceChannels) {
    const char* cpath = env->GetStringUTFChars(jFilePath, nullptr);
    std::string filePath = cpath ? std::string(cpath) : std::string();
    env->ReleaseStringUTFChars(jFilePath, cpath);
    if (filePath.empty()) return JNI_FALSE;

    // Abrir arquivo e parse header
    std::ifstream ifs(filePath, std::ios::binary);
    if (!ifs.is_open()) { LOGE("falha ao abrir arquivo"); return JNI_FALSE; }
    WavInfo winfo;
    if (!parseWavHeader(ifs, winfo)) {
        LOGE("wav inválido/unsupported");
        return JNI_FALSE;
    }
    if (!(winfo.audioFormat == 1 && winfo.bitsPerSample == 16)) {
        LOGE("playWavPreview: only PCM16 supported for playback");
        return JNI_FALSE;
    }
    LOGI("WAV header: rate=%d channels=%d bits=%d dataOffset=%zu dataSize=%zu",
         winfo.sampleRate, winfo.channels, winfo.bitsPerSample, winfo.dataOffset, winfo.dataSize);

    // Reposiciona para o início dos dados
    ifs.seekg(winfo.dataOffset, std::ios::beg);

    // Configurar stream AAudio
    closeStream();
    gStop = false;

    AAudioStreamBuilder* builder = nullptr;
    aaudio_result_t res = AAudio_createStreamBuilder(&builder);
    if (res != AAUDIO_OK || !builder) { LOGE("builder fail %d", res); return JNI_FALSE; }

    int deviceChannels = (int)jDeviceChannels;
    if (deviceChannels < 2) deviceChannels = 2; // mínimo
    AAudioStreamBuilder_setFormat(builder, AAUDIO_FORMAT_PCM_I16);
    AAudioStreamBuilder_setChannelCount(builder, deviceChannels);
    AAudioStreamBuilder_setSampleRate(builder, winfo.sampleRate);
    AAudioStreamBuilder_setDirection(builder, AAUDIO_DIRECTION_OUTPUT);
    AAudioStreamBuilder_setSharingMode(builder, AAUDIO_SHARING_MODE_EXCLUSIVE);
    // selecionar dispositivo, se fornecido
    if (jDeviceId > 0) {
        AAudioStreamBuilder_setDeviceId(builder, (int)jDeviceId);
    }
    LOGI("AAudio builder: deviceId=%d requestedChannels=%d requestedRate=%d",
         (int)jDeviceId, deviceChannels, winfo.sampleRate);

    res = AAudioStreamBuilder_openStream(builder, &gStream);
    AAudioStreamBuilder_delete(builder);
    if (res != AAUDIO_OK || !gStream) { LOGE("openStream fail %d", res); return JNI_FALSE; }

    // Inicia stream
    res = AAudioStream_requestStart(gStream);
    if (res != AAUDIO_OK) { LOGE("start fail %d", res); closeStream(); return JNI_FALSE; }

    int outChannels = AAudioStream_getChannelCount(gStream);
    if (outChannels < 2) outChannels = 2;
    int outRate = AAudioStream_getSampleRate(gStream);
    (void)outRate;
    LOGI("AAudio started: outChannels=%d outRate=%d", outChannels, outRate);

    int sel = (int)jOutputChannel;
    bool pair = false;
    if (sel < 0) sel = 0;
    // valor >=2 indica par em dispositivos estéreo
    if (sel >= 2 && outChannels >= 2) { pair = true; }
    if (sel >= outChannels) sel = outChannels - 1;
    LOGI("Routing preview: selectedOutputChannel=%d pair=%d", sel, pair ? 1 : 0);

    // Thread de escrita
    gThread = std::thread([sel, outChannels, winfo, pair, fp = std::move(filePath)](){
        std::ifstream s(fp, std::ios::binary);
        if (!s.is_open()) { LOGE("reopen fail"); return; }
        s.seekg(winfo.dataOffset, std::ios::beg);
        const size_t BYTES = 4096;
        std::vector<char> buf(BYTES);
        std::vector<int16_t> inSamples(BYTES / 2);
        int logged = 0;
        while (!gStop.load()) {
            s.read(buf.data(), BYTES);
            std::streamsize n = s.gcount();
            if (n <= 0) break;
            int shorts = ((int)n) / 2;
            std::memcpy(inSamples.data(), buf.data(), shorts * sizeof(int16_t));
            // Converter para frames
            int inCh = winfo.channels;
            int frames = shorts / inCh;
            // Preparar buffer de saída interleaved com outChannels
            std::vector<int16_t> out(frames * outChannels);
            if (inCh == 1) {
                for (int f = 0; f < frames; ++f) {
                    int16_t s1 = inSamples[f];
                    for (int c = 0; c < outChannels; ++c) out[f*outChannels + c] = 0;
                    if (pair && outChannels >= 2) {
                        float pan = gPan.load();
                        if (pan < -1.0f) pan = -1.0f; if (pan > 1.0f) pan = 1.0f;
                        // Equal-power pan para mono
                        double t = (double(pan) + 1.0) / 2.0;
                        double angle = (M_PI / 2.0) * t;
                        float lg = (float)std::cos(angle);
                        float rg = (float)std::sin(angle);
                        int16_t ls = static_cast<int16_t>(std::max(-32768.0f, std::min(32767.0f, float(s1) * lg)));
                        int16_t rs = static_cast<int16_t>(std::max(-32768.0f, std::min(32767.0f, float(s1) * rg)));
                        out[f*outChannels + 0] = ls;
                        out[f*outChannels + 1] = rs;
                    } else {
                        out[f*outChannels + sel] = s1;
                    }
                }
            } else { // stereo (2 canais)
                for (int f = 0; f < frames; ++f) {
                    int16_t l = inSamples[f*2];
                    int16_t r = inSamples[f*2 + 1];
                    for (int c = 0; c < outChannels; ++c) out[f*outChannels + c] = 0;
                    if (pair && outChannels >= 2) {
                        // mantém L/R no par 0/1 com pan
                        float pan = gPan.load();
                        if (pan < -1.0f) pan = -1.0f; if (pan > 1.0f) pan = 1.0f;
                        // Equal-power pan para estéreo
                        double t = (double(pan) + 1.0) / 2.0;
                        double angle = (M_PI / 2.0) * t;
                        float lg = (float)std::cos(angle);
                        float rg = (float)std::sin(angle);
                        int16_t ls = static_cast<int16_t>(std::max(-32768.0f, std::min(32767.0f, float(l) * lg)));
                        int16_t rs = static_cast<int16_t>(std::max(-32768.0f, std::min(32767.0f, float(r) * rg)));
                        out[f*outChannels + 0] = ls;
                        out[f*outChannels + 1] = rs;
                    } else {
                        // isola canal selecionado
                        int16_t s = (sel == 0) ? l : r;
                        out[f*outChannels + sel] = s;
                    }
                }
            }
            // Aplicar volume e escrever frames
            int written = 0;
            while (written < frames && !gStop.load()) {
                // Aplicar volume ao bloco atual
                float vol = gVolume.load();
                if (vol < 0.0f) vol = 0.0f;
                if (vol > 1.0f) vol = 1.0f;
                for (int f = 0; f < frames; ++f) {
                    for (int c = 0; c < outChannels; ++c) {
                        int idx = f*outChannels + c;
                        float s = float(out[idx]) * vol;
                        if (s > 32767.0f) s = 32767.0f;
                        if (s < -32768.0f) s = -32768.0f;
                        out[idx] = static_cast<int16_t>(s);
                    }
                }
                aaudio_result_t wr = AAudioStream_write(gStream, out.data() + written * outChannels, frames - written, 1000000 /*1s*/);
                if (wr < 0) { LOGE("write err %d", wr); break; }
                written += wr;
            }
            if (logged < 3) {
                LOGI("Chunk: bytes=%d frames=%d outChannels=%d written=%d", (int)n, frames, outChannels, written);
                logged++;
            }
        }
    });
    return JNI_TRUE;
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_multitrack_1app_MainActivity_nativeStopPreview(JNIEnv* /*env*/, jobject /*thiz*/) {
    LOGI("nativeStopPreview called");
    gStop.store(true);
    if (gThread.joinable()) {
        try { gThread.join(); } catch (...) {}
    }
    closeStream();
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_multitrack_1app_MainActivity_nativeSetPreviewVolume(JNIEnv* /*env*/, jobject /*thiz*/, jfloat vol) {
    float v = vol;
    if (v < 0.0f) v = 0.0f;
    if (v > 1.0f) v = 1.0f;
    gVolume.store(v);
    LOGI("nativeSetPreviewVolume: %f", v);
}

extern "C" JNIEXPORT void JNICALL
Java_com_example_multitrack_1app_MainActivity_nativeSetPreviewPan(JNIEnv* /*env*/, jobject /*thiz*/, jfloat pan) {
    float p = pan;
    if (p < -1.0f) p = -1.0f;
    if (p > 1.0f) p = 1.0f;
    gPan.store(p);
    LOGI("nativeSetPreviewPan: %f", p);
}