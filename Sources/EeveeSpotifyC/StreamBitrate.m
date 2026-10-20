// StreamBitrate.m - captures the bitrate of the audio stream Spotify is playing.
//
// SPTMediaDemuxerAudioTrackMetadataImpl carries the indicatedBitrate of the
// current audio track. The class is exposed to the Objective-C runtime, so a
// plain method replacement is enough (no JIT). getter and setter are both
// hooked: whichever Spotify calls first gives us the value.

#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import <stdlib.h>
#import "EVRecorderInternal.h"

static _Atomic(uint32_t) evStreamBitrate;
static IMP evOrigGetBitrate, evOrigSetBitrate;
static BOOL evBitrateHooked;

uint32_t EVStreamBitrate(void) { return atomic_load_explicit(&evStreamBitrate, memory_order_relaxed); }

static void evStoreBitrate(uint32_t v) {
    if (!v) return;
    uint32_t old = atomic_exchange(&evStreamBitrate, v);
    if (old != v) EVI("Bitrate", @"stream bitrate %u bps (%u kbps)", v, v / 1000);
}

static uint32_t evGetBitrate(id self, SEL _cmd) {
    uint32_t v = evOrigGetBitrate ? ((uint32_t (*)(id, SEL))evOrigGetBitrate)(self, _cmd) : 0;
    evStoreBitrate(v);
    return v;
}

static void evSetBitrate(id self, SEL _cmd, uint32_t v) {
    evStoreBitrate(v);
    if (evOrigSetBitrate) ((void (*)(id, SEL, uint32_t))evOrigSetBitrate)(self, _cmd, v);
}

static void evInstallBitrateHook(int attempt) {
    if (evBitrateHooked) return;
    Class cls = NSClassFromString(@"SPTMediaDemuxerAudioTrackMetadataImpl");
    if (!cls) {
        if (attempt >= 120) { EVW("Bitrate", @"SPTMediaDemuxerAudioTrackMetadataImpl never appeared"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
            evInstallBitrateHook(attempt + 1);
        });
        return;
    }
    BOOL hooked = NO;
    Method get = class_getInstanceMethod(cls, sel_registerName("indicatedBitrate"));
    if (get && method_getNumberOfArguments(get) == 2) {
        char *ret = method_copyReturnType(get);
        BOOL ok = ret && (ret[0] == 'I' || ret[0] == 'L' || ret[0] == 'S' || ret[0] == 'Q');
        free(ret);
        if (ok) {
            evOrigGetBitrate = method_getImplementation(get);
            class_replaceMethod(cls, method_getName(get), (IMP)evGetBitrate, method_getTypeEncoding(get));
            hooked = YES;
            EVI("Bitrate", @"hooked -indicatedBitrate");
        }
    }
    Method set = class_getInstanceMethod(cls, sel_registerName("setIndicatedBitrate:"));
    if (set && method_getNumberOfArguments(set) == 3) {
        char *ret = method_copyReturnType(set);
        BOOL ok = ret && ret[0] == 'v';
        free(ret);
        if (ok) {
            evOrigSetBitrate = method_getImplementation(set);
            class_replaceMethod(cls, method_getName(set), (IMP)evSetBitrate, method_getTypeEncoding(set));
            hooked = YES;
            EVI("Bitrate", @"hooked -setIndicatedBitrate:");
        }
    }
    if (!hooked) {
        if (attempt < 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                evInstallBitrateHook(attempt + 1);
            });
        } else {
            EVW("Bitrate", @"bitrate methods missing or unexpected");
        }
        return;
    }
    evBitrateHooked = YES;
}

__attribute__((constructor)) static void evBitrateInit(void) {
    dispatch_async(dispatch_get_main_queue(), ^{ evInstallBitrateHook(0); });
}
