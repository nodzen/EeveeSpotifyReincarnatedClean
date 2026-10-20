// AudioRecorder.m - captures Spotify's decoded audio by hooking AudioUnitRender.
//
// Why this version exists: the inline hook (MSHookFunction) can only patch code when the process
// has JIT / a debugger attached. Without it MSHookFunction returned no trampoline and a SECOND call
// crashed the app. Now: probe first, try at most once per process, leave a crash marker so a crash
// inside the hook is never repeated, and always explain the failure in the log and in LastError.

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <stdatomic.h>
#import <pthread.h>
#import <dlfcn.h>
#import <errno.h>
#import <math.h>
#import <unistd.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <sys/sysctl.h>
#import <sys/mman.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <mach-o/getsect.h>
#import <objc/runtime.h>
#import "EVRecorderInternal.h"
#import "include/EVPlayback.h"

#if __has_include(<ptrauth.h>)
#import <ptrauth.h>
#endif

#ifndef MAP_JIT
#define MAP_JIT 0x800
#endif
#ifndef P_TRACED
#define P_TRACED 0x00000800
#endif
#define EV_CS_DEBUGGED 0x10000000u

// csops is not in the public SDK. Resolve it lazily so a missing symbol can
// never stop the tweak from loading.
typedef int (*EVCsopsFn)(pid_t, unsigned int, void *, size_t);
static int evCsops(pid_t pid, unsigned int ops, void *useraddr, size_t usersize) {
    static EVCsopsFn fn;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ fn = (EVCsopsFn)dlsym(RTLD_DEFAULT, "csops"); });
    return fn ? fn(pid, ops, useraddr, usersize) : -1;
}

NSString *const EeveeRecorderStateDidChangeNotification = @"EeveeRecorderStateDidChangeNotification";
NSString *const EeveeRecorderDidFinishNotification = @"EeveeRecorderDidFinishNotification";

#define CALLER_FILTER "libEmbeddedSystemAUs.dylib"   // comment out to capture every caller
#define RING_SAMPLES (4u * 1024u * 1024u)            // power of two
#define WRITE_CHUNK 8192u
#define BATCH_FRAMES 2048u
#define WAV_MAX_BYTES 0xFFFFF000ull
#define MIN_FREE_BYTES (300ull * 1024 * 1024)

typedef OSStatus (*RenderFunction)(AudioUnit, AudioUnitRenderActionFlags *, const AudioTimeStamp *,
                                   UInt32, UInt32, AudioBufferList *);
typedef void (*MSHookFunctionType)(void *symbol, void *replace, void **result);

#pragma mark - State

static RenderFunction originalRender;
static _Atomic(int) hookState;               // 0 untried, 1 installed, 2 failed (never retried)
static NSString *hookMode = @"none";
static NSString *hookError;
static NSString *lastErrorText;
static pthread_mutex_t ctlLock = PTHREAD_MUTEX_INITIALIZER;

static float ring[RING_SAMPLES];
static _Atomic(uint64_t) writeIndex, readIndex;
static _Atomic(bool) capturing, sessionActive, formatReady, abortFlag;
static _Atomic(bool) downloadMode;
static _Atomic(uint64_t) downloadGeneration;
static NSString *downloadKey;
static _Atomic(uint32_t) sampleRate = 44100, fmtChannels, fmtBits, mismatchRate;
static _Atomic(bool) fmtIsFloat;
static _Atomic(uint64_t) framesCaptured, statCalls, statMatched, statCaptured, statDropped, statBadLayout;
static _Atomic(uint32_t) peakBits;
static _Atomic(uintptr_t) callerStart, callerEnd, lastRejectedCaller;
static _Atomic(uint32_t) lastAsbdID, lastAsbdFlags, lastAsbdBits, lastAsbdChannels, lastAsbdRate;
static _Atomic(int32_t) lastAsbdStatus;

static pthread_t writerThread;
static bool threadStarted;
static FILE *outputFile;
static NSString *outputPath;
static NSURL *sessionDir, *sessionWav;
static NSDate *sessionStart;
static uint64_t writtenFramesTotal;
static NSMutableArray<EVMarker *> *markers;
static NSString *lastSessionSummary = @"";

#pragma mark - AudioUnit render-callback tap (no JIT)

// Spotify does not import AudioUnitRender. It installs a render callback on an
// AudioUnit with AudioUnitSetProperty(kAudioUnitProperty_SetRenderCallback).
// Patching that one GOT entry only writes a data pointer, so the tap works
// without JIT/debugger. We wrap the callback, let Spotify fill the buffer, then
// copy the float32 PCM to the existing recorder ring.

typedef OSStatus (*AudioUnitSetPropertyFn)(AudioUnit, AudioUnitPropertyID, AudioUnitScope,
                                           AudioUnitElement, const void *, UInt32);

typedef struct EVTapContext {
    AURenderCallback original;
    void *originalRefCon;
    AudioUnit unit;
    AudioUnitScope scope;
    AudioUnitElement element;
    uint32_t rate;
    uint32_t channels;
    bool rateProbed;
} EVTapContext;

static AudioUnitSetPropertyFn originalSetProperty;
static pthread_mutex_t tapLock = PTHREAD_MUTEX_INITIALIZER;
static _Atomic(int) tapState;                 // 0 untried, 1 installed, 2 failed
static _Atomic(bool) tapCaptureEnabled = true;
static NSString *tapError;
static _Atomic(uint64_t) tapWrapCount, tapCallbackCount;
static _Atomic(uint32_t) tapRate, tapChannels;
static _Atomic(uintptr_t) tapLastUnit, tapLastOriginal;

static NSObject *evSync(void) {
    static NSObject *o; static dispatch_once_t t;
    dispatch_once(&t, ^{ o = [NSObject new]; });
    return o;
}
static void setLastError(NSString *s) { @synchronized(evSync()) { lastErrorText = [s copy]; } }
NSString *EeveeAudioRecorderLastError(void) { @synchronized(evSync()) { return lastErrorText; } }
static void evPostState(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:EeveeRecorderStateDidChangeNotification object:nil];
    });
}
static uint64_t evNowMs(void) {
    struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000ull + (uint64_t)ts.tv_nsec / 1000000ull;
}

uint64_t EVCoreFramesCaptured(void) { return atomic_load_explicit(&framesCaptured, memory_order_relaxed); }
uint32_t EVCoreSampleRate(void) { return atomic_load_explicit(&sampleRate, memory_order_relaxed); }
NSString *EVCoreActiveSessionPath(void) { return atomic_load(&sessionActive) ? sessionDir.path : nil; }

#pragma mark - WAV header

static void put16(uint8_t *p, uint16_t v) { p[0] = v & 255; p[1] = (v >> 8) & 255; }
static void put32(uint8_t *p, uint32_t v) {
    p[0] = v & 255; p[1] = (v >> 8) & 255; p[2] = (v >> 16) & 255; p[3] = (v >> 24) & 255;
}

// Always float32 stereo. Rewrites the header, then returns to the end so appending continues.
static void writeWAVHeader(FILE *f, uint32_t rate, uint64_t bytes) {
    uint8_t h[44] = {0};
    if (bytes > WAV_MAX_BYTES) bytes = WAV_MAX_BYTES;
    memcpy(h, "RIFF", 4);
    put32(h + 4, (uint32_t)(36 + bytes));
    memcpy(h + 8, "WAVEfmt ", 8);
    put32(h + 16, 16);
    put16(h + 20, 3);
    put16(h + 22, 2);
    put32(h + 24, rate);
    put32(h + 28, rate * 8);
    put16(h + 32, 8);
    put16(h + 34, 32);
    memcpy(h + 36, "data", 4);
    put32(h + 40, (uint32_t)bytes);
    fseeko(f, 0, SEEK_SET);
    fwrite(h, 1, sizeof(h), f);
    fflush(f);
    fseeko(f, 0, SEEK_END);
}

#pragma mark - Caller filter (no dladdr on the audio thread)

static uintptr_t stripPAC(void *p) {
#if __has_feature(ptrauth_calls)
    return (uintptr_t)ptrauth_strip(p, ptrauth_key_return_address);
#else
    return (uintptr_t)p;
#endif
}

static void refreshCallerRange(void) {
#ifdef CALLER_FILTER
    if (atomic_load(&callerEnd)) return;
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, CALLER_FILTER)) continue;
        const struct mach_header_64 *hdr = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (!hdr) continue;
        unsigned long size = 0;
        uint8_t *seg = getsegmentdata(hdr, "__TEXT", &size);
        if (!seg || !size) continue;
        atomic_store(&callerStart, (uintptr_t)seg);
        atomic_store_explicit(&callerEnd, (uintptr_t)seg + size, memory_order_release);
        EVI("Hook", @"caller filter resolved: %s [%p - %p]", name, seg, seg + size);
        return;
    }
#endif
}

static bool targetCaller(uintptr_t address) {
#ifdef CALLER_FILTER
    uintptr_t end = atomic_load_explicit(&callerEnd, memory_order_acquire);
    if (!end) return false;
    return address >= atomic_load_explicit(&callerStart, memory_order_relaxed) && address < end;
#else
    (void)address; return true;
#endif
}

#pragma mark - Format

static bool readASBD(AudioUnit unit, AudioStreamBasicDescription *asbd, OSStatus *st) {
    UInt32 size = sizeof(*asbd);
    *st = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0, asbd, &size);
    return *st == noErr;
}

static void inspectFormat(AudioUnit unit) {
    if (atomic_load_explicit(&formatReady, memory_order_relaxed)) return;
    AudioStreamBasicDescription asbd = {0};
    OSStatus st;
    bool ok = readASBD(unit, &asbd, &st);
    atomic_store(&lastAsbdStatus, (int32_t)st);
    if (!ok) return;
    atomic_store(&lastAsbdID, asbd.mFormatID);
    atomic_store(&lastAsbdFlags, asbd.mFormatFlags);
    atomic_store(&lastAsbdBits, asbd.mBitsPerChannel);
    atomic_store(&lastAsbdChannels, asbd.mChannelsPerFrame);
    atomic_store(&lastAsbdRate, (uint32_t)asbd.mSampleRate);
    bool isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0;
    bool bitsOK = isFloat ? asbd.mBitsPerChannel == 32 : asbd.mBitsPerChannel == 16;
    if (asbd.mFormatID == kAudioFormatLinearPCM && bitsOK && asbd.mChannelsPerFrame >= 1 &&
        asbd.mChannelsPerFrame <= 2 && asbd.mSampleRate >= 8000 && asbd.mSampleRate <= 192000) {
        atomic_store(&fmtChannels, asbd.mChannelsPerFrame);
        atomic_store(&fmtBits, asbd.mBitsPerChannel);
        atomic_store(&fmtIsFloat, isFloat);
        atomic_store(&sampleRate, (uint32_t)asbd.mSampleRate);
        atomic_store_explicit(&formatReady, true, memory_order_release);
    }
}

// A changed sample rate (e.g. Bluetooth connected) would corrupt timing, so it aborts the session.
static void recheckRate(AudioUnit unit) {
    AudioStreamBasicDescription asbd = {0};
    OSStatus st;
    if (!readASBD(unit, &asbd, &st)) return;
    uint32_t r = (uint32_t)asbd.mSampleRate;
    if (r && r != atomic_load_explicit(&sampleRate, memory_order_relaxed)) {
        atomic_store(&mismatchRate, r);
        atomic_store(&abortFlag, true);
    }
}

#pragma mark - Ring buffer (realtime side)

static bool pushSamples(const float *samples, uint32_t count) {
    if (!samples || !count || count > RING_SAMPLES) return false;
    uint64_t w = atomic_load_explicit(&writeIndex, memory_order_relaxed);
    uint64_t r = atomic_load_explicit(&readIndex, memory_order_acquire);
    if (w - r + count > RING_SAMPLES) {          // never overwrite what the writer is reading
        atomic_fetch_add_explicit(&statDropped, 1, memory_order_relaxed);
        return false;
    }
    float peak = 0;
    for (uint32_t i = 0; i < count; i++) { float a = fabsf(samples[i]); if (a > peak) peak = a; }
    uint32_t pos = (uint32_t)(w & (RING_SAMPLES - 1));
    uint32_t first = RING_SAMPLES - pos;
    if (first > count) first = count;
    memcpy(ring + pos, samples, first * sizeof(float));
    if (count > first) memcpy(ring, samples + first, (count - first) * sizeof(float));
    atomic_store_explicit(&writeIndex, w + count, memory_order_release);
    uint32_t cur = atomic_load_explicit(&peakBits, memory_order_relaxed), nb;
    float curf; memcpy(&curf, &cur, 4);
    if (peak > curf) { memcpy(&nb, &peak, 4); atomic_store_explicit(&peakBits, nb, memory_order_relaxed); }
    return true;
}

static inline float readSample(const void *base, uint32_t index, bool isFloat) {
    if (isFloat) return ((const float *)base)[index];
    return ((const int16_t *)base)[index] * (1.0f / 32768.0f);
}

static void captureBuffers(AudioBufferList *list, UInt32 frames) {
    if (!list || !frames || list->mNumberBuffers < 1) return;
    uint32_t bits = atomic_load_explicit(&fmtBits, memory_order_relaxed);
    bool isFloat = atomic_load_explicit(&fmtIsFloat, memory_order_relaxed);
    uint32_t bytesPer = bits / 8;
    if (!bytesPer) return;

    const void *left = NULL, *right = NULL;
    uint32_t stride = 1, available = 0;
    const AudioBuffer *b0 = &list->mBuffers[0];
    if (list->mNumberBuffers == 1 && b0->mNumberChannels == 2 && b0->mData) {
        left = b0->mData; right = (const uint8_t *)b0->mData + bytesPer; stride = 2;
        available = b0->mDataByteSize / (bytesPer * 2);
    } else if (list->mNumberBuffers == 1 && b0->mNumberChannels == 1 && b0->mData) {
        left = right = b0->mData; available = b0->mDataByteSize / bytesPer;
    } else if (list->mNumberBuffers >= 2 && b0->mNumberChannels == 1 &&
               list->mBuffers[1].mNumberChannels == 1 && b0->mData && list->mBuffers[1].mData) {
        left = b0->mData; right = list->mBuffers[1].mData;
        uint32_t aL = b0->mDataByteSize / bytesPer, aR = list->mBuffers[1].mDataByteSize / bytesPer;
        available = aL < aR ? aL : aR;
    } else {
        atomic_fetch_add_explicit(&statBadLayout, 1, memory_order_relaxed);
        return;
    }
    if (frames > available) frames = available;

    float temp[BATCH_FRAMES * 2];
    uint32_t i0 = 0;
    while (frames) {
        uint32_t batch = frames > BATCH_FRAMES ? BATCH_FRAMES : frames;
        for (uint32_t i = 0; i < batch; i++) {
            uint32_t idx = (i0 + i) * stride;
            temp[i * 2] = readSample(left, idx, isFloat);
            temp[i * 2 + 1] = readSample(right, idx, isFloat);
        }
        if (pushSamples(temp, batch * 2))
            atomic_fetch_add_explicit(&framesCaptured, batch, memory_order_relaxed);
        i0 += batch; frames -= batch;
    }
    atomic_fetch_add_explicit(&statCaptured, 1, memory_order_relaxed);
}

static void evTapProbeFormat(EVTapContext *ctx, bool final) {
    if (!ctx || ctx->rate) return;
    if (final && ctx->rateProbed) return;
    if (final) ctx->rateProbed = true;

    AudioStreamBasicDescription asbd = {0};
    UInt32 size = sizeof(asbd);
    if (AudioUnitGetProperty(ctx->unit, kAudioUnitProperty_StreamFormat,
                             ctx->scope, ctx->element, &asbd, &size) != noErr) return;
    uint32_t rate = (uint32_t)asbd.mSampleRate;
    if (rate < 8000 || rate > 192000) return;
    ctx->rate = rate;
    atomic_store(&tapRate, rate);
    if (asbd.mChannelsPerFrame >= 1 && asbd.mChannelsPerFrame <= 2) {
        ctx->channels = asbd.mChannelsPerFrame;
        atomic_store(&tapChannels, asbd.mChannelsPerFrame);
    }
}

// Wraps Spotify's render callback without touching its code. The original
// callback fills ioData (float32, interleaved); we copy it afterwards.
static OSStatus evTapRender(void *refCon, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                            UInt32 bus, UInt32 frames, AudioBufferList *data) {
    EVTapContext *ctx = (EVTapContext *)refCon;
    if (!ctx || !ctx->original) return kAudioUnitErr_InvalidParameter;

    OSStatus status = ctx->original(ctx->originalRefCon, flags, time, bus, frames, data);
    atomic_fetch_add_explicit(&tapCallbackCount, 1, memory_order_relaxed);
    atomic_fetch_add_explicit(&statCalls, 1, memory_order_relaxed);
    if (status != noErr || !atomic_load_explicit(&tapCaptureEnabled, memory_order_relaxed) ||
        !atomic_load_explicit(&capturing, memory_order_relaxed) ||
        !atomic_load_explicit(&sessionActive, memory_order_relaxed)) return status;

    evTapProbeFormat(ctx, true);
    if (ctx->rate) {
        uint32_t current = atomic_load_explicit(&sampleRate, memory_order_relaxed);
        if (current && current != ctx->rate) {
            if (atomic_load_explicit(&framesCaptured, memory_order_relaxed) == 0) {
                atomic_store_explicit(&sampleRate, ctx->rate, memory_order_relaxed);
            } else {
                atomic_store(&mismatchRate, ctx->rate);
                atomic_store(&abortFlag, true);
                return status;
            }
        }
    }
    if (!atomic_load_explicit(&formatReady, memory_order_acquire)) {
        atomic_store(&fmtBits, 32);
        atomic_store(&fmtIsFloat, true);
        atomic_store_explicit(&formatReady, true, memory_order_release);
    }
    if (data && data->mNumberBuffers > 0) {
        uint32_t channels = data->mBuffers[0].mNumberChannels;
        if (channels >= 1 && channels <= 2)
            atomic_store_explicit(&fmtChannels, channels, memory_order_relaxed);
        if (data->mBuffers[0].mDataByteSize && frames) {
            atomic_fetch_add_explicit(&statMatched, 1, memory_order_relaxed);
            captureBuffers(data, frames);
        }
    }
    return status;
}

static OSStatus evTapSetProperty(AudioUnit unit, AudioUnitPropertyID prop, AudioUnitScope scope,
                                 AudioUnitElement element, const void *data, UInt32 size) {
    if (prop == kAudioUnitProperty_SetRenderCallback && data && size >= sizeof(AURenderCallbackStruct)) {
        const AURenderCallbackStruct *original = (const AURenderCallbackStruct *)data;
        if (original->inputProc && originalSetProperty) {
            EVTapContext *ctx = calloc(1, sizeof(*ctx));
            if (ctx) {
                ctx->original = original->inputProc;
                ctx->originalRefCon = original->inputProcRefCon;
                ctx->unit = unit;
                ctx->scope = scope;
                ctx->element = element;
                evTapProbeFormat(ctx, false);

                AURenderCallbackStruct wrapped = { evTapRender, ctx };
                OSStatus status = originalSetProperty(unit, prop, scope, element, &wrapped, sizeof(wrapped));
                if (status == noErr) {
                    atomic_fetch_add_explicit(&tapWrapCount, 1, memory_order_relaxed);
                    atomic_store(&tapLastUnit, (uintptr_t)unit);
                    atomic_store(&tapLastOriginal, (uintptr_t)original->inputProc);
                    EVI("Tap", @"wrapped render callback unit=%p orig=%p rate=%u ch=%u",
                        unit, (void *)original->inputProc, ctx->rate, ctx->channels);
                    return status;
                }
                free(ctx);
            }
        }
    }
    return originalSetProperty ? originalSetProperty(unit, prop, scope, element, data, size)
                               : kAudioUnitErr_Uninitialized;
}

// iOS 15+ binaries use chained fixups. fishhook's name walk expects classic
// bind opcodes and can silently match nothing there, so find the GOT slot by
// value: the address dlsym() returns is exactly what dyld wrote into it.
static BOOL evMakeWritable(void *addr, size_t size) {
    long pageSize = getpagesize();
    vm_address_t page = (vm_address_t)addr & ~(vm_address_t)(pageSize - 1);
    vm_size_t len = (vm_address_t)addr + size - page;
    kern_return_t kr = vm_protect(mach_task_self(), page, len, FALSE,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr == KERN_SUCCESS) return YES;
    return mprotect((void *)page, len, PROT_READ | PROT_WRITE) == 0;
}

static int evPatchPointerSections(const struct mach_header_64 *hdr, intptr_t slide,
                                  void *target, void *replacement) {
    if (!hdr || hdr->magic != MH_MAGIC_64) return 0;
    int patched = 0;
    const struct load_command *cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const void *)cmd;
            for (uint32_t j = 0; j < seg->nsects; j++) {
                const struct section_64 *sect = (const struct section_64 *)(seg + 1) + j;
                uint32_t type = sect->flags & SECTION_TYPE;
                if (type != S_NON_LAZY_SYMBOL_POINTERS && type != S_LAZY_SYMBOL_POINTERS) continue;
                void **slots = (void **)((uintptr_t)slide + sect->addr);
                uint32_t n = (uint32_t)(sect->size / sizeof(void *));
                for (uint32_t k = 0; k < n; k++) {
                    if (slots[k] != target) continue;
                    if (!evMakeWritable(&slots[k], sizeof(void *))) {
                        EVE("Tap", @"cannot make %s.%s writable", seg->segname, sect->sectname);
                        continue;
                    }
                    slots[k] = replacement;
                    patched++;
                    EVI("Tap", @"patched %s.%s slot %p", seg->segname, sect->sectname, &slots[k]);
                }
            }
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
    return patched;
}

static BOOL evTapInstallOnce(void) {
    pthread_mutex_lock(&tapLock);
    int state = atomic_load(&tapState);
    if (state == 1) { pthread_mutex_unlock(&tapLock); return YES; }
    if (state == 2) { pthread_mutex_unlock(&tapLock); return NO; }

    void *target = dlsym(RTLD_DEFAULT, "AudioUnitSetProperty");
    if (!target) {
        @synchronized(evSync()) { tapError = @"AudioUnitSetProperty symbol not found"; }
        atomic_store(&tapState, 2);
        pthread_mutex_unlock(&tapLock);
        return NO;
    }

    // Scan every image: on a normal sideload the slot is in the main
    // executable, while LiveContainer loads the guest app as another image
    // (and its path does not necessarily contain "Spotify.app").
    uint32_t count = _dyld_image_count();
    int patched = 0;
    for (uint32_t i = 0; i < count; i++) {
        patched += evPatchPointerSections((const struct mach_header_64 *)_dyld_get_image_header(i),
                                          _dyld_get_image_vmaddr_slide(i), target, (void *)evTapSetProperty);
    }

    if (patched == 0) {
        NSString *error = [NSString stringWithFormat:
            @"AudioUnitSetProperty GOT slot not found (target=%p)", target];
        @synchronized(evSync()) { tapError = [error copy]; }
        atomic_store(&tapState, 2);
        pthread_mutex_unlock(&tapLock);
        return NO;
    }
    originalSetProperty = (AudioUnitSetPropertyFn)target;
    EVI("Tap", @"patched %d GOT slot(s) for AudioUnitSetProperty", patched);
    atomic_store(&tapState, 1);
    pthread_mutex_unlock(&tapLock);
    return YES;
}

static OSStatus hookedRender(AudioUnit unit, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *time,
                             UInt32 bus, UInt32 frames, AudioBufferList *data) {
    uintptr_t caller = stripPAC(__builtin_return_address(0));
    RenderFunction orig = originalRender;
    OSStatus status = orig ? orig(unit, flags, time, bus, frames, data) : kAudioUnitErr_Uninitialized;
    uint64_t n = atomic_fetch_add_explicit(&statCalls, 1, memory_order_relaxed);
    if (status == noErr && atomic_load_explicit(&capturing, memory_order_relaxed)) {
        if (targetCaller(caller)) {
            atomic_fetch_add_explicit(&statMatched, 1, memory_order_relaxed);
            inspectFormat(unit);
            if (atomic_load_explicit(&formatReady, memory_order_acquire)) {
                if ((n & 511) == 511) recheckRate(unit);
                captureBuffers(data, frames);
            }
        } else {
            atomic_store_explicit(&lastRejectedCaller, caller, memory_order_relaxed);
        }
    }
    return status;
}

#pragma mark - Environment / hook installation

static void evEnvProbe(uint32_t *cs, BOOL *debugged, BOOL *traced, BOOL *mapJit, int *jitErrno) {
    *cs = 0; *debugged = NO; *traced = NO; *mapJit = NO; *jitErrno = 0;
    if (evCsops(getpid(), 0, cs, sizeof(*cs)) == 0) *debugged = (*cs & EV_CS_DEBUGGED) != 0;
    struct kinfo_proc info; memset(&info, 0, sizeof info);
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    size_t sz = sizeof info;
    if (sysctl(mib, 4, &info, &sz, NULL, 0) == 0) *traced = (info.kp_proc.p_flag & P_TRACED) != 0;
    void *p = mmap(NULL, 16384, PROT_READ | PROT_WRITE | PROT_EXEC, MAP_PRIVATE | MAP_ANON | MAP_JIT, -1, 0);
    if (p == MAP_FAILED) { *jitErrno = errno; }
    else { *mapJit = YES; munmap(p, 16384); }
}

static NSString *evHookMarkerPath(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@".evhook_attempt"];
}

static BOOL failHook(NSString *msg) {
    hookError = [msg copy];
    atomic_store(&hookState, 2);
    setLastError(msg);
    EVE("Hook", @"FAILED: %@", msg);
    return NO;
}

static BOOL installInlineHookOnce(void) {
    uint32_t cs; BOOL debugged, traced, mapJit; int jitErrno;
    evEnvProbe(&cs, &debugged, &traced, &mapJit, &jitErrno);
    BOOL jitOK = debugged || traced || mapJit;
    BOOL force = EVSettingBool(@"forceInline", NO);
    EVI("Hook", @"code-signing flags=0x%08x CS_DEBUGGED=%d P_TRACED=%d MAP_JIT=%d(errno %d) => JIT-capable=%d force=%d",
        cs, debugged, traced, mapJit, jitErrno, jitOK, force);

    NSString *marker = evHookMarkerPath();
    if ([[NSFileManager defaultManager] fileExistsAtPath:marker] && !force)
        return failHook(@"A previous inline-hook attempt never finished (the app died inside the hook). Not trying again. "
                        @"Enable JIT, then turn on 'Force inline hook' in Recorder debug to retry.");

    void *target = dlsym(RTLD_DEFAULT, "AudioUnitRender");
    if (!target) return failHook(@"AudioUnitRender symbol not found.");
    MSHookFunctionType ms = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!ms) return failHook(@"MSHookFunction is not available in this process (no Substrate shim).");
    if (!jitOK && !force)
        return failHook(@"No JIT: this process cannot patch code, so the audio hook cannot be installed. "
                        @"Launch LiveContainer with JIT enabled (e.g. via StikDebug) and try again.");

    Dl_info di = {0}; dladdr(target, &di);
    EVI("Hook", @"AudioUnitRender=%p in %s; calling MSHookFunction (crash marker armed)", target, di.dli_fname ?: "?");
    [@"attempt\n" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
    EVLogFlush();                                    // make sure this line survives a crash
    originalRender = NULL;
    ms(target, (void *)hookedRender, (void **)&originalRender);
    [[NSFileManager defaultManager] removeItemAtPath:marker error:nil];

    if (!originalRender)
        return failHook(@"MSHookFunction returned no trampoline (the patch was refused).");
    hookMode = @"inline(MSHookFunction)";
    atomic_store(&hookState, 1);
    EVI("Hook", @"installed via %@, original/trampoline=%p", hookMode, (void *)originalRender);
    return YES;
}

static BOOL installHookOnce(void) {
    int st = atomic_load(&hookState);
    if (st == 1) return YES;
    if (st == 2) {
        setLastError(hookError);
        EVW("Hook", @"hook already failed in this process (%@); not retrying (a retry used to crash the app)", hookError);
        return NO;
    }

    BOOL force = EVSettingBool(@"forceInline", NO);
    if (!force && evTapInstallOnce()) {
        atomic_store(&tapCaptureEnabled, true);
        hookMode = @"callback(got)";
        hookError = nil;
        atomic_store(&hookState, 1);
        setLastError(nil);
        EVI("Hook", @"using render-callback tap; no JIT required");
        return YES;
    }

    NSString *te; @synchronized(evSync()) { te = tapError; }
    if (te.length) EVW("Hook", @"render-callback tap unavailable: %@", te);

    // Inline hooking is only an option when a Substrate shim is present. On a
    // plain sideload it cannot work without JIT and its error used to hide the
    // real (useful) tap error.
    if (dlsym(RTLD_DEFAULT, "MSHookFunction")) {
        if (installInlineHookOnce()) {
            atomic_store(&tapCaptureEnabled, false);
            return YES;
        }
        if (force && evTapInstallOnce()) {
            atomic_store(&tapCaptureEnabled, true);
            hookMode = @"callback(got)";
            hookError = nil;
            atomic_store(&hookState, 1);
            setLastError(nil);
            EVI("Hook", @"inline unavailable; using render-callback tap; no JIT required");
            return YES;
        }
    }
    if (te.length) return failHook(te);
    return NO;
}

static void evLogEnvironment(void) {
    char machine[64] = {0}; size_t sz = sizeof machine;
    sysctlbyname("hw.machine", machine, &sz, NULL, 0);
    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    task_vm_info_data_t vi; mach_msg_type_number_t cnt = TASK_VM_INFO_COUNT;
    double footprintMB = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &cnt) == KERN_SUCCESS
        ? vi.phys_footprint / 1048576.0 : -1;
    EVI("Env", @"device=%s iOS=%@ pid=%d process=%@ bundle=%@ build=%s %s", machine,
        UIDevice.currentDevice.systemVersion, getpid(), NSProcessInfo.processInfo.processName,
        NSBundle.mainBundle.bundleIdentifier, __DATE__, __TIME__);
    EVI("Env", @"free disk=%.1f GB, app memory=%.0f MB, low-power=%d, thermal=%ld",
        [fs[NSFileSystemFreeSize] doubleValue] / 1e9, footprintMB,
        NSProcessInfo.processInfo.isLowPowerModeEnabled, (long)NSProcessInfo.processInfo.thermalState);
    AVAudioSession *s = [AVAudioSession sharedInstance];
    NSMutableArray *outs = [NSMutableArray array];
    for (AVAudioSessionPortDescription *p in s.currentRoute.outputs)
        [outs addObject:[NSString stringWithFormat:@"%@(%@)", p.portName, p.portType]];
    EVI("Env", @"audio session: category=%@ mode=%@ sampleRate=%.0f outputs=%@", s.category, s.mode, s.sampleRate, outs);
}

#pragma mark - Writer thread

static void evPersistMarkers(void) {
    if (!sessionDir) return;
    NSMutableArray *list = [NSMutableArray array];
    @synchronized(evSync()) {
        for (EVMarker *m in markers)
            [list addObject:@{@"frame": @(m.frame), @"partialStart": @(m.partialStart), @"info": m.info ? [m.info dictionary] : @{}}];
    }
    NSDictionary *root = @{@"rate": @(EVCoreSampleRate()), @"startedAt": @([sessionStart timeIntervalSince1970]), @"markers": list};
    NSData *d = [NSJSONSerialization dataWithJSONObject:root options:NSJSONWritingPrettyPrinted error:nil];
    [d writeToURL:[sessionDir URLByAppendingPathComponent:@"markers.json"] atomically:YES];
}

static NSString *evTrackKey(EVTrackInfo *info) {
    if (info.key.length) return info.key;
    if (info.uri.length) return info.uri;
    return [NSString stringWithFormat:@"%@|%@|%.0f", info.title ?: @"", info.artist ?: @"", info.duration];
}

// Download = one track, from the beginning, stopped automatically. The first
// marker is the track we restarted; the next different track (or the expected
// duration, if playback just stops) ends the capture.
static void evDownloadMarker(EVTrackInfo *info) {
    if (!atomic_load(&downloadMode)) return;
    NSString *key = evTrackKey(info);
    BOOL first = NO, next = NO;
    @synchronized(evSync()) {
        if (!downloadKey) { downloadKey = [key copy]; first = YES; }
        else next = ![downloadKey isEqualToString:key];
    }
    uint64_t gen = 0;
    if (first || next) gen = atomic_fetch_add(&downloadGeneration, 1) + 1;
    if (first) {
        double d = info.duration > 0 ? info.duration : 0;
        int64_t delayNs = (int64_t)((d > 0 ? d + 2.5 : 600.0) * NSEC_PER_SEC);
        EVI("Download", @"capturing '%@' (expected %.1fs)", info.title, d);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, delayNs),
                       dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (atomic_load(&downloadMode) && atomic_load(&downloadGeneration) == gen)
                EeveeAudioRecorderStop();
        });
    } else if (next) {
        EVI("Download", @"next track started; stopping");
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            if (atomic_load(&downloadMode)) EeveeAudioRecorderStop();
        });
    }
    (void)gen;
}

static void evOnTrack(EVTrackInfo *info, uint64_t frame, BOOL partial) {
    EVMarker *m = [EVMarker new];
    m.frame = frame; m.info = info; m.partialStart = partial;
    @synchronized(evSync()) { [markers addObject:m]; }
    uint32_t r = EVCoreSampleRate();
    EVI("Meta", @"track marker at frame %llu (%@): '%@' - '%@' [album '%@', #%ld, expected %.3fs, partialStart=%d]",
        (unsigned long long)frame, EVFormatTime((double)frame / r), info.artist, info.title, info.album,
        (long)info.trackNumber, info.duration, partial);
    evPersistMarkers();
    evDownloadMarker(info);
}

static void *writerMain(void *unused) {
    (void)unused;
    float temp[WRITE_CHUNK];
    uint64_t written = 0;
    uint64_t lastStat = evNowMs(), lastHdr = lastStat, lastCaller = lastStat;
    uint64_t prevCalls = 0, prevCaptured = 0, prevFramesRef = 0;
    int silentStreak = 0; bool silenceWarned = false, abortHandled = false;

    for (;;) {
        uint64_t r = atomic_load_explicit(&readIndex, memory_order_relaxed);
        uint64_t w = atomic_load_explicit(&writeIndex, memory_order_acquire);
        if (r < w) {
            uint32_t count = (uint32_t)(w - r);
            if (count > WRITE_CHUNK) count = WRITE_CHUNK;
            uint32_t pos = (uint32_t)(r & (RING_SAMPLES - 1));
            uint32_t first = RING_SAMPLES - pos;
            if (first > count) first = count;
            memcpy(temp, ring + pos, first * sizeof(float));
            if (count > first) memcpy(temp + first, ring, (count - first) * sizeof(float));
            size_t done = fwrite(temp, sizeof(float), count, outputFile);
            if (done < count) {
                if (!abortHandled) {
                    abortHandled = true;
                    setLastError([NSString stringWithFormat:@"Disk write failed (errno %d). Is storage full?", errno]);
                    EVE("Writer", @"fwrite short (%zu/%u), errno=%d - stopping", done, count, errno);
                    atomic_store(&capturing, false);
                    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ EeveeAudioRecorderStop(); });
                }
            }
            written += done * sizeof(float);
            atomic_store_explicit(&readIndex, r + (done ? done : count), memory_order_release);
            if (written > WAV_MAX_BYTES && !abortHandled) {
                abortHandled = true;
                setLastError(@"Recording reached the 4 GB WAV limit and was stopped.");
                EVW("Writer", @"4 GB WAV limit reached - stopping");
                atomic_store(&capturing, false);
                dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ EeveeAudioRecorderStop(); });
            }
        } else if (!atomic_load(&capturing)) {
            break;
        } else {
            usleep(5000);
        }

        uint64_t now = evNowMs();
        if (atomic_load(&abortFlag) && !abortHandled) {
            abortHandled = true;
            uint32_t nr = atomic_load(&mismatchRate);
            setLastError([NSString stringWithFormat:@"Sample rate changed %u -> %u Hz mid-recording (output route changed?). Recording stopped; the audio so far is saved.",
                          EVCoreSampleRate(), nr]);
            EVE("Writer", @"sample rate changed %u -> %u - stopping", EVCoreSampleRate(), nr);
            atomic_store(&capturing, false);
            dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ EeveeAudioRecorderStop(); });
        }
        if (now - lastCaller >= 500) { lastCaller = now; refreshCallerRange(); }
        if (now - lastHdr >= 2000) { lastHdr = now; writeWAVHeader(outputFile, EVCoreSampleRate(), written); }  // file stays playable after a crash
        if (now - lastStat >= 2000) {
            lastStat = now;
            uint64_t calls = atomic_load(&statCalls), cap = atomic_load(&statCaptured), frames = EVCoreFramesCaptured();
            uint32_t pk = atomic_exchange(&peakBits, 0); float peak; memcpy(&peak, &pk, 4);
            double fill = (double)(atomic_load(&writeIndex) - atomic_load(&readIndex)) * 100.0 / RING_SAMPLES;
            double rate = EVCoreSampleRate() ? EVCoreSampleRate() : 44100;
            EVI("Stats", @"calls=%llu(+%llu) matched=%llu captured=%llu(+%llu) dropped=%llu badLayout=%llu | rec=%@ file=%.1fMB ring=%.1f%% peak=%.3f",
                (unsigned long long)calls, (unsigned long long)(calls - prevCalls), (unsigned long long)atomic_load(&statMatched),
                (unsigned long long)cap, (unsigned long long)(cap - prevCaptured), (unsigned long long)atomic_load(&statDropped),
                (unsigned long long)atomic_load(&statBadLayout), EVFormatTime(frames / rate), written / 1048576.0, fill, peak);
            if (calls > prevCalls && frames > prevFramesRef) {
                if (peak <= 0.0f) { if (++silentStreak >= 3 && !silenceWarned) { silenceWarned = true; EVW("Stats", @"audio is arriving but it is digital silence for 6 s+ (muted? DRM? wrong unit?)"); } }
                else silentStreak = 0;
            }
            if (calls > 0 && atomic_load(&statMatched) == 0) {
                uintptr_t a = atomic_load(&lastRejectedCaller); Dl_info di = {0};
                if (a && dladdr((void *)a, &di) && di.dli_fname)
                    EVW("Stats", @"render calls arrive but none match the caller filter; last caller image: %s", di.dli_fname);
            }
            if (atomic_load(&statMatched) > 0 && !atomic_load(&formatReady))
                EVW("Stats", @"format rejected: status=%d id=0x%x flags=0x%x bits=%u ch=%u rate=%u",
                    atomic_load(&lastAsbdStatus), atomic_load(&lastAsbdID), atomic_load(&lastAsbdFlags),
                    atomic_load(&lastAsbdBits), atomic_load(&lastAsbdChannels), atomic_load(&lastAsbdRate));
            prevCalls = calls; prevCaptured = cap; prevFramesRef = frames;
        }
    }

    writeWAVHeader(outputFile, EVCoreSampleRate(), written);
    fclose(outputFile);
    outputFile = NULL;
    writtenFramesTotal = written / 8;
    EVI("Writer", @"closed %@: %llu frames = %@ (%llu bytes)", sessionWav.lastPathComponent,
        (unsigned long long)writtenFramesTotal, EVFormatTime((double)writtenFramesTotal / EVCoreSampleRate()),
        (unsigned long long)written);
    return NULL;
}

#pragma mark - Public API

static BOOL evFail(NSString *msg) {
    setLastError(msg);
    EVE("Core", @"Start failed: %@", msg);
    return NO;
}

static BOOL evStartLocked(void) {
    if (atomic_load(&sessionActive)) return YES;
    setLastError(nil);
    EVI("Core", @"Start requested");
    evLogEnvironment();
    if (!installHookOnce()) return NO;

    NSDictionary *fs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
    if ([fs[NSFileSystemFreeSize] unsignedLongLongValue] < MIN_FREE_BYTES)
        return evFail(@"Less than 300 MB of free storage.");

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateFormat = @"yyyy-MM-dd_HH-mm-ss";
    df.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    NSURL *dir = [EVRecordingsRoot() URLByAppendingPathComponent:[df stringFromDate:[NSDate date]] isDirectory:YES];
    NSError *err = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:&err])
        return evFail([NSString stringWithFormat:@"Cannot create folder: %@", err.localizedDescription]);
    BOOL tapMode = atomic_load(&tapState) == 1 && atomic_load(&tapCaptureEnabled);
    uint32_t startRate = 44100;
    if (tapMode) {
        startRate = atomic_load(&tapRate);
        if (!startRate) startRate = (uint32_t)[AVAudioSession sharedInstance].sampleRate;
        if (startRate < 8000 || startRate > 192000) startRate = 44100;
    }

    NSURL *wav = [dir URLByAppendingPathComponent:@"session.wav"];
    FILE *f = fopen(wav.path.fileSystemRepresentation, "wb");
    if (!f) return evFail([NSString stringWithFormat:@"Cannot open %@ (errno %d)", wav.path, errno]);
    writeWAVHeader(f, startRate, 0);

    sessionDir = dir; sessionWav = wav; sessionStart = [NSDate date];
    outputPath = wav.path; outputFile = f; writtenFramesTotal = 0;
    @synchronized(evSync()) { markers = [NSMutableArray array]; }
    atomic_store(&writeIndex, 0); atomic_store(&readIndex, 0);
    atomic_store(&abortFlag, false);
    if (tapMode) {
        uint32_t channels = atomic_load(&tapChannels);
        atomic_store(&sampleRate, startRate);
        atomic_store(&fmtChannels, channels >= 1 && channels <= 2 ? channels : 2);
        atomic_store(&fmtBits, 32);
        atomic_store(&fmtIsFloat, true);
        atomic_store_explicit(&formatReady, true, memory_order_release);
    } else {
        atomic_store(&formatReady, false);
        atomic_store(&sampleRate, 44100);
    }
    atomic_store(&framesCaptured, 0);
    atomic_store(&statCalls, 0); atomic_store(&statMatched, 0); atomic_store(&statCaptured, 0);
    atomic_store(&statDropped, 0); atomic_store(&statBadLayout, 0); atomic_store(&peakBits, 0);
    refreshCallerRange();
    atomic_store(&capturing, true);
    atomic_store(&sessionActive, true);
    EVI("Core", @"capture mode: %@ (rate %u)", tapMode ? @"render-callback tap" : @"inline", startRate);

    int rc = pthread_create(&writerThread, NULL, writerMain, NULL);
    if (rc != 0) {
        atomic_store(&capturing, false); atomic_store(&sessionActive, false);
        fclose(outputFile); outputFile = NULL;
        return evFail([NSString stringWithFormat:@"Writer thread failed (%d)", rc]);
    }
    threadStarted = true;
    EVMetaStart(^(EVTrackInfo *info, uint64_t frame, BOOL partial) { evOnTrack(info, frame, partial); });
    EVI("Core", @"recording to %@", wav.path);
    return YES;
}

BOOL EeveeAudioRecorderSupported(void) {
    if (evTapInstallOnce()) return YES;
    return dlsym(RTLD_DEFAULT, "MSHookFunction") != NULL;
}

BOOL EeveeAudioRecorderStart(void) {
    pthread_mutex_lock(&ctlLock);
    BOOL ok = evStartLocked();
    pthread_mutex_unlock(&ctlLock);
    evPostState();
    return ok;
}

BOOL EeveeAudioRecorderDownloadCurrentTrack(void) {
    if (EeveeAudioRecorderIsRecording()) {
        setLastError(@"A recording is already running.");
        return NO;
    }
    if (!EeveeAudioRecorderSupported()) {
        setLastError(EeveeAudioRecorderLastError() ?: @"Audio capture is unavailable in this process.");
        return NO;
    }
    if (!EeveePlaybackAvailable()) {
        setLastError(@"Open the Now Playing screen once, then try again.");
        return NO;
    }
    @synchronized(evSync()) { downloadKey = nil; }
    atomic_store(&downloadGeneration, 0);
    atomic_store(&downloadMode, true);

    // Pause -> rewind -> start capture -> play. Capturing before playback
    // resumes keeps the marker at frame 0 instead of a partial first segment.
    dispatch_async(dispatch_get_main_queue(), ^{
        EeveePlaybackPause();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            EeveePlaybackSeekToStart();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!EeveeAudioRecorderStart()) {
                    atomic_store(&downloadMode, false);
                    @synchronized(evSync()) { downloadKey = nil; }
                    EeveePlaybackPlay();
                    return;
                }
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    EeveePlaybackPlay();
                });
            });
        });
    });
    EVI("Download", @"start requested for the current track");
    return YES;
}

void EeveeAudioRecorderStop(void) {
    pthread_mutex_lock(&ctlLock);
    if (!atomic_load(&sessionActive)) { pthread_mutex_unlock(&ctlLock); return; }
    BOOL download = atomic_load(&downloadMode);
    atomic_store(&downloadMode, false);
    atomic_fetch_add(&downloadGeneration, 1);
    @synchronized(evSync()) { downloadKey = nil; }
    EVI("Core", @"Stop requested%@", download ? @" (download)" : @"");
    atomic_store(&capturing, false);
    EVMetaStop();
    if (threadStarted) { pthread_join(writerThread, NULL); threadStarted = false; }
    NSURL *wav = sessionWav;
    uint64_t total = writtenFramesTotal;
    uint32_t rate = EVCoreSampleRate();
    NSArray<EVMarker *> *snapshot; @synchronized(evSync()) { snapshot = [markers copy]; }
    evPersistMarkers();
    atomic_store(&sessionActive, false);
    pthread_mutex_unlock(&ctlLock);
    evPostState();

    if (download) EVSetOneShotExport(@"aac");
    EVI("Core", @"splitting %lu marker(s) over %@", (unsigned long)snapshot.count, EVFormatTime((double)total / rate));
    EVFinalizeSession(wav, rate, snapshot, total, ^(NSArray<NSURL *> *files, NSURL *folder, NSArray<NSDictionary *> *tracks, NSString *error) {
        NSArray<NSURL *> *outFiles = files ?: @[];
        NSArray<NSDictionary *> *outTracks = tracks ?: @[];
        if (download && outTracks.count) {
            NSDictionary *t0 = outTracks.firstObject;
            NSString *base = [t0[@"file"] stringByDeletingPathExtension];
            NSMutableArray<NSURL *> *keep = [NSMutableArray array];
            for (NSURL *u in outFiles)
                if (base.length && [u.lastPathComponent hasPrefix:base]) [keep addObject:u];
            if (keep.count) outFiles = keep;
            outTracks = @[t0];
            // Spotify's IOS_DOCUMENTS local-files source looks at the app's
            // Documents folder. Move the finished file there so the scanner
            // sees exactly one copy (Recordings/ stays for the session data).
            for (NSURL *u in outFiles) {
                if (![u.pathExtension.lowercaseString isEqualToString:@"m4a"]) continue;
                NSURL *docs = [[NSFileManager defaultManager] URLsForDirectory:NSDocumentDirectory
                                                                     inDomains:NSUserDomainMask].firstObject;
                NSURL *dst = [docs URLByAppendingPathComponent:u.lastPathComponent];
                [[NSFileManager defaultManager] removeItemAtURL:dst error:nil];
                if ([[NSFileManager defaultManager] moveItemAtURL:u toURL:dst error:nil]) {
                    NSMutableArray<NSURL *> *adjusted = [outFiles mutableCopy];
                    [adjusted replaceObjectAtIndex:[adjusted indexOfObject:u] withObject:dst];
                    outFiles = adjusted;
                    outputPath = dst.path;
                    EVI("Download", @"moved to %@", dst.path);
                }
                break;
            }
            lastSessionSummary = [NSString stringWithFormat:@"Downloaded '%@'", t0[@"title"] ?: @"track"];
        } else {
            lastSessionSummary = [NSString stringWithFormat:@"%lu track(s) in %@", (unsigned long)outTracks.count, folder.lastPathComponent];
        }
        NSURL *first = outFiles.firstObject;
        if (first) outputPath = first.path;
        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter] postNotificationName:EeveeRecorderDidFinishNotification object:nil
                userInfo:@{@"files": outFiles, @"folder": folder ?: [NSNull null], @"tracks": outTracks,
                           @"error": error ?: @"", @"download": @(download)}];
        });
    });
}

BOOL EeveeAudioRecorderIsRecording(void) { return atomic_load(&sessionActive); }
NSString *EeveeAudioRecorderCurrentPath(void) { return outputPath; }

NSString *EeveeRecorderStatusLine(void) {
    if (atomic_load(&sessionActive) && atomic_load(&downloadMode))
        return [NSString stringWithFormat:@"Downloading %@", EVFormatTime((double)EVCoreFramesCaptured() / EVCoreSampleRate())];
    if (atomic_load(&sessionActive))
        return [NSString stringWithFormat:@"Recording %@", EVFormatTime((double)EVCoreFramesCaptured() / EVCoreSampleRate())];
    NSString *e = EeveeAudioRecorderLastError();
    if (e.length) return [@"Not recording - " stringByAppendingString:e];
    return lastSessionSummary.length ? [@"Idle - last: " stringByAppendingString:lastSessionSummary] : @"Idle";
}

NSArray<NSString *> *EVCoreDebugLines(void) {
    uint32_t cs; BOOL dbg, trc, jit; int je;
    evEnvProbe(&cs, &dbg, &trc, &jit, &je);
    uint32_t rate = EVCoreSampleRate();
    NSMutableArray *l = [NSMutableArray array];
    [l addObject:[NSString stringWithFormat:@"== Core ==\nbuild %s %s | pid %d", __DATE__, __TIME__, getpid()]];
    [l addObject:[NSString stringWithFormat:@"hook: %@ (state %d) %@", hookMode, atomic_load(&hookState), hookError ? [@"| error: " stringByAppendingString:hookError] : @""]];
    [l addObject:[NSString stringWithFormat:@"JIT: CS_DEBUGGED=%d P_TRACED=%d MAP_JIT=%d (cs=0x%08x) force=%d", dbg, trc, jit, cs, EVSettingBool(@"forceInline", NO)]];
    NSString *te; @synchronized(evSync()) { te = tapError; }
    [l addObject:[NSString stringWithFormat:@"tap: state=%d capture=%d wraps=%llu callbacks=%llu rate=%u ch=%u unit=%p orig=%p%@",
        atomic_load(&tapState), atomic_load(&tapCaptureEnabled), (unsigned long long)atomic_load(&tapWrapCount),
        (unsigned long long)atomic_load(&tapCallbackCount), atomic_load(&tapRate), atomic_load(&tapChannels),
        (void *)atomic_load(&tapLastUnit), (void *)atomic_load(&tapLastOriginal),
        te.length ? [@" | error: " stringByAppendingString:te] : @""]];
    [l addObject:[NSString stringWithFormat:@"last error: %@", EeveeAudioRecorderLastError() ?: @"none"]];
    [l addObject:[NSString stringWithFormat:@"recording: %d | session: %@", atomic_load(&sessionActive), sessionDir.lastPathComponent ?: @"-"]];
    [l addObject:[NSString stringWithFormat:@"format: ready=%d rate=%u bits=%u float=%d ch=%u", atomic_load(&formatReady), rate, atomic_load(&fmtBits), atomic_load(&fmtIsFloat), atomic_load(&fmtChannels)]];
    [l addObject:[NSString stringWithFormat:@"calls=%llu matched=%llu captured=%llu dropped=%llu badLayout=%llu frames=%llu (%@)",
        (unsigned long long)atomic_load(&statCalls), (unsigned long long)atomic_load(&statMatched), (unsigned long long)atomic_load(&statCaptured),
        (unsigned long long)atomic_load(&statDropped), (unsigned long long)atomic_load(&statBadLayout),
        (unsigned long long)EVCoreFramesCaptured(), EVFormatTime((double)EVCoreFramesCaptured() / rate)]];
    [l addObject:[NSString stringWithFormat:@"caller filter: %s resolved=%d", 
#ifdef CALLER_FILTER
        CALLER_FILTER,
#else
        "none",
#endif
        atomic_load(&callerEnd) != 0]];
    @synchronized(evSync()) { [l addObject:[NSString stringWithFormat:@"markers: %lu", (unsigned long)markers.count]]; }
    return l;
}

#pragma mark - Audio-driver probe (log only, JIT-free; for finding a hook-free capture point)

static const char *evProbeSels[4] = {"audioDriverWillStartRunning:", "audioDriverDidStartRunning:",
                                     "audioDriverDidStopRunning:", "audioDriverDidClose:"};
static IMP evProbeOrig[4];

static void evProbeDump(id obj, const char *label) {
    if (!obj) { EVI("Probe", @"%s: nil", label); return; }
    Class cls = object_getClass(obj);
    while (cls && cls != [NSObject class]) {
        unsigned n = 0;
        Ivar *iv = class_copyIvarList(cls, &n);
        for (unsigned i = 0; i < n; i++) {
            const char *name = ivar_getName(iv[i]), *enc = ivar_getTypeEncoding(iv[i]);
            NSString *desc = @"?";
            if (enc && enc[0] == '@') { id v = object_getIvar(obj, iv[i]); desc = v ? NSStringFromClass(object_getClass(v)) : @"nil"; }
            else if (enc && enc[0] == '^') { void *p = *(void **)((uint8_t *)(__bridge void *)obj + ivar_getOffset(iv[i])); desc = [NSString stringWithFormat:@"%p", p]; }
            EVI("Probe", @"%s %s.%s type=%s value=%@", label, class_getName(cls), name ?: "?", enc ?: "?", desc);
        }
        free(iv);
        cls = class_getSuperclass(cls);
    }
}

static void evProbeCommon(int idx, id self_, SEL cmd, id arg) {
    EVI("Probe", @"%s (arg=%@)", evProbeSels[idx], arg ? NSStringFromClass(object_getClass(arg)) : @"nil");
    if (idx == 1) { evProbeDump(self_, "self"); if (arg) evProbeDump(arg, "arg"); }
    if (evProbeOrig[idx]) ((void (*)(id, SEL, id))evProbeOrig[idx])(self_, cmd, arg);
}
static void evProbe0(id s, SEL c, id a) { evProbeCommon(0, s, c, a); }
static void evProbe1(id s, SEL c, id a) { evProbeCommon(1, s, c, a); }
static void evProbe2(id s, SEL c, id a) { evProbeCommon(2, s, c, a); }
static void evProbe3(id s, SEL c, id a) { evProbeCommon(3, s, c, a); }

static void evProbeInstall(void) {
    Class cls = NSClassFromString(@"SPTAudioDriverImplementation");
    if (!cls) { EVW("Probe", @"SPTAudioDriverImplementation not found"); return; }
    IMP imps[4] = {(IMP)evProbe0, (IMP)evProbe1, (IMP)evProbe2, (IMP)evProbe3};
    for (int i = 0; i < 4; i++) {
        SEL sel = sel_registerName(evProbeSels[i]);
        Method m = class_getInstanceMethod(cls, sel);
        if (!m) { EVW("Probe", @"%s not found", evProbeSels[i]); continue; }
        IMP inherited = method_getImplementation(m);
        IMP prev = class_replaceMethod(cls, sel, imps[i], method_getTypeEncoding(m));
        evProbeOrig[i] = prev ?: inherited;
        EVI("Probe", @"swizzled %s", evProbeSels[i]);
    }
}

__attribute__((constructor)) static void evCoreInit(void) {
    // Install before Spotify creates its audio unit, otherwise the existing
    // render callback is already in place and cannot be wrapped retroactively.
    evTapInstallOnce();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        EVI("Core", @"recorder loaded: build %s %s pid %d", __DATE__, __TIME__, getpid());
        NSString *te; @synchronized(evSync()) { te = tapError; }
        EVI("Tap", @"early state=%d wraps=%llu%@", atomic_load(&tapState),
            (unsigned long long)atomic_load(&tapWrapCount), te.length ? [@" error: " stringByAppendingString:te] : @"");
        if (EVSettingBool(@"probeDriver", NO)) evProbeInstall();
        EVResumePendingSessions();
    });
}
