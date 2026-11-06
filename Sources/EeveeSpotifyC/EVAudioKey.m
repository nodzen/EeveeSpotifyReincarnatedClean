// EVAudioKey.m - capture the AES stream key, then fetch the track offline.
//
// The player has to decrypt the audio before the demuxer can parse it, so the
// key passes through the process in plain form. Three capture points are
// armed, because the exact one differs between core versions:
//   1. CCCrypt/CCCryptorCreateWithMode - if the core leans on CommonCrypto.
//   2. SPTPlayerMediaManifest / SPTMediaManifestResponse - the manifest that
//      carries the signed CDN URL for the current stream.
//   3. A tap on NSURLSession - last resort for the audio URL.
// Grab then pulls the whole file with Range requests and AES-CTR decrypts it.

#import <Foundation/Foundation.h>
#import <CommonCrypto/CommonCrypto.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach/mach.h>
#import <mach/vm_map.h>
#import <sys/mman.h>
#import <pthread.h>
#import <stdatomic.h>
#import <string.h>
#import <unistd.h>

#import "include/EVAudioKey.h"
#import "EVRecorderInternal.h"

typedef CCCryptorStatus (*EVCreateModeFn)(CCOperation op, CCMode mode, CCAlgorithm alg,
                                          CCPadding padding, const void *iv,
                                          const void *key, size_t keyLength,
                                          const void *tweak, size_t tweakLength,
                                          int numRounds, CCModeOptions options,
                                          CCCryptorRef *cryptorRef);

typedef CCCryptorStatus (*EVCCCryptFn)(CCOperation op, CCAlgorithm alg, CCOptions options,
                                       const void *key, size_t keyLength, const void *iv,
                                       const void *dataIn, size_t dataInLength,
                                       void *dataOut, size_t dataOutAvailable,
                                       size_t *dataOutMoved);

static EVCreateModeFn evOrigCreateMode;
static EVCCCryptFn evOrigCCCrypt;
static atomic_int evHookState;                      // 0 untried, 1 installed, 2 failed
static atomic_int evCCCryptCalls;
static atomic_int evAesSeen;
static atomic_int evCtrSeen;
static pthread_mutex_t evLock = PTHREAD_MUTEX_INITIALIZER;
static NSMutableArray<NSDictionary *> *evKeys;       // newest first, max 8
static NSMutableDictionary *evManifest;
static NSMutableArray<NSString *> *evURLs;           // newest first, max 200
static NSData *evLastManifestData;

#pragma mark - GOT patcher (value-based, chained-fixup safe)

static BOOL evWritable(void *addr, size_t size) {
    long page = getpagesize();
    vm_address_t base = (vm_address_t)addr & ~(vm_address_t)(page - 1);
    vm_size_t len = (vm_address_t)addr + size - base;
    if (vm_protect(mach_task_self(), base, len, FALSE,
                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) return YES;
    return mprotect((void *)base, len, PROT_READ | PROT_WRITE) == 0;
}

static int evPatchSlots(const struct mach_header_64 *hdr, intptr_t slide,
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
                    if (!evWritable(&slots[k], sizeof(void *))) continue;
                    slots[k] = replacement;
                    patched++;
                }
            }
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
    return patched;
}

static int evPatchSymbol(const char *name, void *replacement, void **original) {
    void *target = dlsym(RTLD_DEFAULT, name);
    if (!target) return 0;
    int patched = 0;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        patched += evPatchSlots((const struct mach_header_64 *)_dyld_get_image_header(i),
                                _dyld_get_image_vmaddr_slide(i), target, replacement);
    }
    if (patched && original) *original = target;
    return patched;
}

#pragma mark - CTR

// CTR decrypts by encrypting the keystream, so kCCEncrypt is the correct op.
static NSData *evCTR(NSData *in, NSData *key, NSData *iv) {
    if ((key.length != 16 && key.length != 32) || iv.length != 16 || in.length == 0) return nil;
    CCCryptorRef c = NULL;
    if (CCCryptorCreateWithMode(kCCEncrypt, kCCModeCTR, kCCAlgorithmAES, ccNoPadding,
                                iv.bytes, key.bytes, key.length, NULL, 0, 0,
                                kCCModeOptionCTR_BE, &c) != kCCSuccess || !c) return nil;

    NSMutableData *out = [NSMutableData dataWithLength:in.length + kCCBlockSizeAES128];
    size_t moved = 0, tail = 0;
    CCCryptorStatus st = CCCryptorUpdate(c, in.bytes, in.length, out.mutableBytes, out.length, &moved);
    if (st == kCCSuccess) st = CCCryptorFinal(c, out.mutableBytes + moved, out.length - moved, &tail);
    CCCryptorRelease(c);
    if (st != kCCSuccess) return nil;
    out.length = moved + tail;
    return out;
}

static BOOL evIsOgg(NSData *data) {
    return data.length >= 4 && memcmp(data.bytes, "OggS", 4) == 0;
}

// Decrypt only the head and look for the Ogg page magic. Cheap enough to try
// every captured key; the full file is decrypted once, with the winner.
static BOOL evKeyMatches(NSData *data, NSData *key, NSData *iv) {
    NSUInteger n = MIN(data.length, 64);
    if (n < 4) return NO;
    NSData *head = evCTR([data subdataWithRange:NSMakeRange(0, n)], key, iv);
    return evIsOgg(head);
}

#pragma mark - capture

static void evCaptureKey(NSData *key, NSData *iv) {
    if (!EeveeAudioRecorderEnabled()) return;
    if (key.length != 16 && key.length != 32) return;
    if (iv.length != 16) iv = [NSMutableData dataWithLength:16];
    NSDictionary *entry = @{ @"key": key, @"iv": iv, @"date": [NSDate date] };

    pthread_mutex_lock(&evLock);
    if (!evKeys) evKeys = [NSMutableArray array];
    [evKeys insertObject:entry atIndex:0];
    if (evKeys.count > 8) [evKeys removeLastObject];
    pthread_mutex_unlock(&evLock);

    // Never log key material: the log can be shared for unrelated bugs.
    EVI("Key", @"captured a %lu-byte AES key", (unsigned long)key.length);
}

static CCCryptorStatus evCreateModeHook(CCOperation op, CCMode mode, CCAlgorithm alg,
                                        CCPadding padding, const void *iv,
                                        const void *key, size_t keyLength,
                                        const void *tweak, size_t tweakLength,
                                        int numRounds, CCModeOptions options,
                                        CCCryptorRef *cryptorRef) {
    if (alg == kCCAlgorithmAES && keyLength == 16) {
        atomic_fetch_add(&evAesSeen, 1);
        if (mode == kCCModeCTR && key && iv) {
            atomic_fetch_add(&evCtrSeen, 1);
            evCaptureKey([NSData dataWithBytes:key length:16], [NSData dataWithBytes:iv length:16]);
        }
    }
    return evOrigCreateMode ? evOrigCreateMode(op, mode, alg, padding, iv, key, keyLength,
                                               tweak, tweakLength, numRounds, options, cryptorRef)
                            : kCCParamError;
}

static CCCryptorStatus evCCCryptHook(CCOperation op, CCAlgorithm alg, CCOptions options,
                                     const void *key, size_t keyLength, const void *iv,
                                     const void *dataIn, size_t dataInLength,
                                     void *dataOut, size_t dataOutAvailable,
                                     size_t *dataOutMoved) {
    atomic_fetch_add(&evCCCryptCalls, 1);
    // One-shot AES with a 16-byte key: the only shape worth logging.
    if (alg == kCCAlgorithmAES && keyLength == 16 && key) {
        atomic_fetch_add(&evAesSeen, 1);
        evCaptureKey([NSData dataWithBytes:key length:16],
                     iv ? [NSData dataWithBytes:iv length:16] : nil);
    }
    return evOrigCCCrypt ? evOrigCCCrypt(op, alg, options, key, keyLength, iv,
                                         dataIn, dataInLength, dataOut, dataOutAvailable, dataOutMoved)
                         : kCCParamError;
}

static void evInstallHooks(void) {
    if (atomic_load(&evHookState) == 1) return;

    int patched = 0;
    patched += evPatchSymbol("CCCryptorCreateWithMode", (void *)evCreateModeHook, (void **)&evOrigCreateMode);
    patched += evPatchSymbol("CCCrypt", (void *)evCCCryptHook, (void **)&evOrigCCCrypt);
    if (!patched) { atomic_store(&evHookState, 2); EVW("Key", @"no crypto GOT slot found"); return; }

    atomic_store(&evHookState, 1);
    EVI("Key", @"crypto hooks installed (%d slot(s))", patched);
}

#pragma mark - manifest / network notes

static void evNoteURL(NSString *url) {
    if (!EeveeAudioRecorderEnabled() || !url.length) return;
    BOOL interesting = [url containsString:@"storage-resolve"] ||
                       [url containsString:@"/audio/"] ||
                       [url containsString:@"spclient"] ||
                       [url containsString:@"manifest"];
    if (!interesting) return;

    pthread_mutex_lock(&evLock);
    if (!evURLs) evURLs = [NSMutableArray array];
    [evURLs insertObject:url atIndex:0];
    if (evURLs.count > 200) [evURLs removeLastObject];
    pthread_mutex_unlock(&evLock);
}

static NSString *evLastCDNURL(void) {
    pthread_mutex_lock(&evLock);
    NSString *found = nil;
    for (NSString *u in evURLs) {
        if ([u containsString:@"storage-resolve"]) { found = u; break; }
    }
    pthread_mutex_unlock(&evLock);
    return found;
}

static void evNoteManifest(NSString *field, id value) {
    if (!value) return;
    if ([value respondsToSelector:@selector(absoluteString)]) value = [value absoluteString];
    if (![value isKindOfClass:NSString.class]) return;

    pthread_mutex_lock(&evLock);
    if (!evManifest) evManifest = [NSMutableDictionary dictionary];
    evManifest[field] = value;
    pthread_mutex_unlock(&evLock);
}

static IMP evOrigSetURL, evOrigSetFileID, evOrigSetEncryption;
static IMP evOrigSetManifestURL, evOrigSetManifestData;

static void evSetURL(id self, SEL _cmd, id value) {
    evNoteManifest(@"url", value);
    if (evOrigSetURL) ((void (*)(id, SEL, id))evOrigSetURL)(self, _cmd, value);
}
static void evSetFileID(id self, SEL _cmd, id value) {
    evNoteManifest(@"fileID", value);
    if (evOrigSetFileID) ((void (*)(id, SEL, id))evOrigSetFileID)(self, _cmd, value);
}
static void evSetEncryption(id self, SEL _cmd, id value) {
    evNoteManifest(@"encryption", value);
    if (evOrigSetEncryption) ((void (*)(id, SEL, id))evOrigSetEncryption)(self, _cmd, value);
}
static void evSetManifestURL(id self, SEL _cmd, id value) {
    if ([value isKindOfClass:NSString.class]) evNoteURL(value);
    if (evOrigSetManifestURL) ((void (*)(id, SEL, id))evOrigSetManifestURL)(self, _cmd, value);
}
static void evSetManifestData(id self, SEL _cmd, id value) {
    if ([value isKindOfClass:NSData.class] && [value length] > 0) {
        pthread_mutex_lock(&evLock);
        evLastManifestData = [value copy];
        pthread_mutex_unlock(&evLock);
        EVI("Key", @"manifest data: %lu bytes", (unsigned long)[value length]);
    }
    if (evOrigSetManifestData) ((void (*)(id, SEL, id))evOrigSetManifestData)(self, _cmd, value);
}

// NSURLSession tap. The core hides its HTTP client, so this catches whatever
// the app itself requests; a miss here just means the URL stays unknown.
typedef NSURLSessionDataTask *(*EVTaskBlockFn)(id, SEL, NSURLRequest *,
                                               void (^)(NSData *, NSURLResponse *, NSError *));
typedef NSURLSessionDataTask *(*EVTaskDelegateFn)(id, SEL, NSURLRequest *, id);
typedef NSURLSessionDownloadTask *(*EVTaskURLFn)(id, SEL, NSURLRequest *,
                                                 void (^)(NSURL *, NSURLResponse *, NSError *));

static EVTaskBlockFn evOrigDataTaskBlock;
static EVTaskDelegateFn evOrigDataTaskDelegate;
static EVTaskURLFn evOrigDownloadTaskBlock;

static NSURLSessionDataTask *evDataTaskBlock(id self, SEL _cmd, NSURLRequest *req,
                                             void (^handler)(NSData *, NSURLResponse *, NSError *)) {
    evNoteURL(req.URL.absoluteString);
    return evOrigDataTaskBlock(self, _cmd, req, handler);
}
static NSURLSessionDataTask *evDataTaskDelegate(id self, SEL _cmd, NSURLRequest *req, id delegate) {
    evNoteURL(req.URL.absoluteString);
    return evOrigDataTaskDelegate(self, _cmd, req, delegate);
}
static NSURLSessionDownloadTask *evDownloadTaskBlock(id self, SEL _cmd, NSURLRequest *req,
                                                     void (^handler)(NSURL *, NSURLResponse *, NSError *)) {
    evNoteURL(req.URL.absoluteString);
    return evOrigDownloadTaskBlock(self, _cmd, req, handler);
}

static void evSwizzle(Class cls, const char *name, IMP imp, IMP *orig, BOOL *ok) {
    SEL sel = sel_registerName(name);
    Method m = class_getInstanceMethod(cls, sel);
    if (!m) { if (ok) *ok = NO; return; }
    if (orig) *orig = method_getImplementation(m);
    class_replaceMethod(cls, sel, imp, method_getTypeEncoding(m));
}

static void evInstallManifestHook(int attempt) {
    Class player = NSClassFromString(@"SPTPlayerMediaManifest");
    Class response = NSClassFromString(@"SPTMediaManifestResponse");
    if (!player && !response) {
        if (attempt < 120) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                evInstallManifestHook(attempt + 1);
            });
        }
        return;
    }
    if (player) {
        evSwizzle(player, "setURL:", (IMP)evSetURL, &evOrigSetURL, NULL);
        evSwizzle(player, "setFileID:", (IMP)evSetFileID, &evOrigSetFileID, NULL);
        evSwizzle(player, "setEncryption:", (IMP)evSetEncryption, &evOrigSetEncryption, NULL);
    }
    if (response) {
        evSwizzle(response, "setManifestURL:", (IMP)evSetManifestURL, &evOrigSetManifestURL, NULL);
        evSwizzle(response, "setManifestData:", (IMP)evSetManifestData, &evOrigSetManifestData, NULL);
    }
    EVI("Key", @"manifest hooks: player=%@ response=%@", player ? @"yes" : @"no",
        response ? @"yes" : @"no");
}

static void evInstallNetworkTap(void) {
    Class cls = NSClassFromString(@"NSURLSession");
    if (!cls) return;
    evSwizzle(cls, "dataTaskWithRequest:completionHandler:", (IMP)evDataTaskBlock, (IMP *)&evOrigDataTaskBlock, NULL);
    evSwizzle(cls, "dataTaskWithRequest:delegate:", (IMP)evDataTaskDelegate, (IMP *)&evOrigDataTaskDelegate, NULL);
    evSwizzle(cls, "downloadTaskWithRequest:completionHandler:", (IMP)evDownloadTaskBlock, (IMP *)&evOrigDownloadTaskBlock, NULL);
}

// The download module builds one file streamer per played track and hands it
// the signed CDN URL. Capturing that call gives the URL and the live streamer,
// the object able to fetch arbitrary byte ranges with the app's own auth.
static void evNoteStreamerURL(id self, SEL _cmd, id url, id playbackId, id sessionId) {
    if ([url respondsToSelector:@selector(absoluteString)]) url = [url absoluteString];
    if ([url isKindOfClass:NSString.class]) {
        evNoteURL(url);
        evNoteManifest(@"streamerURL", url);
        EVI("Key", @"captured the current streamer URL");
    }
}

// Decrypted audio has to reach the demuxer as a plain Ogg. If it arrives as
// NSData here, the whole file can be pulled through this path later.
static IMP evOrigDataReaderInit;

static id evDataReaderInit(id self, SEL _cmd, NSData *data) {
    if ([data isKindOfClass:NSData.class] && data.length >= 4) {
        BOOL ogg = memcmp(data.bytes, "OggS", 4) == 0;
        EVI("Key", @"demuxer data %lu bytes, ogg=%d", (unsigned long)data.length, ogg);
    }
    return ((id (*)(id, SEL, id))evOrigDataReaderInit)(self, _cmd, data);
}

static void evInstallStreamerHooks(void) {
    Class factory = NSClassFromString(@"_TtC28ContentDelivery_DownloadImpl23FileStreamerFactoryImpl");
    if (factory) {
        evSwizzle(factory, "createFileStreamerWithUrl:playbackId:sessionId:",
                  (IMP)evNoteStreamerURL, NULL, NULL);
    }
    Class reader = NSClassFromString(@"SPTMediaDemuxerDataReader");
    if (reader) {
        evSwizzle(reader, "initWithData:", (IMP)evDataReaderInit, &evOrigDataReaderInit, NULL);
    }
    EVI("Key", @"streamer hooks: factory=%@ reader=%@",
        factory ? @"yes" : @"no", reader ? @"yes" : @"no");
}

#pragma mark - hand-rolled AES (the core does not use CommonCrypto for audio)

// Spotify's core carries its own AES: one S-box table in __TEXT and an
// unrolled ARMv8 aese/aesmc loop. There is no CommonCrypto call to hook for
// audio, so the key is taken where the schedule is built. The table is found
// first, then the routine that references it - that routine receives
// (context, key bytes, key length) and is hooked with MSHookFunction.
typedef void (*EVKeyExpandFn)(void *ctx, const uint8_t *key, uint32_t keyLength);

static EVKeyExpandFn evOrigKeyExpand;
static atomic_int evKeyExpCalls;
static void *evKeyExpandAddr;

static const uint8_t kAesSboxHead[16] = {
    0x63, 0x7c, 0x77, 0x7b, 0xf2, 0x6b, 0x6f, 0xc5,
    0x30, 0x01, 0x67, 0x2b, 0xfe, 0xd7, 0xab, 0x76
};

static const struct mach_header_64 *evMainHeader(void) {
    return (const struct mach_header_64 *)_dyld_get_image_header(0);
}

// Locate the S-box: it is the only copy of that byte sequence in __TEXT.
static uintptr_t evFindSbox(void) {
    const struct mach_header_64 *hdr = evMainHeader();
    if (!hdr) return 0;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const void *)cmd;
            if (strcmp(seg->segname, "__TEXT") != 0) { cmd = (const void *)((uintptr_t)cmd + cmd->cmdsize); continue; }
            const uint8_t *base = (const uint8_t *)((uintptr_t)slide + seg->vmaddr);
            size_t len = seg->vmsize;
            for (size_t off = 0; off + sizeof(kAesSboxHead) <= len; off += 4) {
                if (memcmp(base + off, kAesSboxHead, sizeof(kAesSboxHead)) == 0) {
                    return (uintptr_t)base + off;
                }
            }
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
    return 0;
}

static int32_t evSx(uint32_t v, int bits) {
    uint32_t m = 1u << (bits - 1);
    return (int32_t)((v ^ m) - m);
}

// Walk __TEXT for ADRP+ADD pairs that materialise the S-box address. Both hits
// in this build live inside the key schedule; the routine start is the
// instruction after the previous RET.
static uintptr_t evFindKeyExpand(uintptr_t sbox) {
    const struct mach_header_64 *hdr = evMainHeader();
    if (!hdr || !sbox) return 0;
    intptr_t slide = _dyld_get_image_vmaddr_slide(0);
    const struct load_command *cmd = (const struct load_command *)(hdr + 1);
    for (uint32_t i = 0; i < hdr->ncmds; i++) {
        if (cmd->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const void *)cmd;
            if (strcmp(seg->segname, "__TEXT") != 0) { cmd = (const void *)((uintptr_t)cmd + cmd->cmdsize); continue; }
            uintptr_t base = (uintptr_t)slide + seg->vmaddr;
            uintptr_t end = base + seg->vmsize;

            for (uintptr_t p = base; p + 32 < end; p += 4) {
                uint32_t w = *(const uint32_t *)p;
                if ((w & 0x9F000000) != 0x90000000) continue;         // ADRP
                uint32_t immlo = (w >> 29) & 3, immhi = (w >> 5) & 0x7FFFF;
                uint32_t rd = w & 31;
                int64_t imm = (int64_t)evSx((immhi << 2) | immlo, 21) << 12;
                if (((p & ~(uintptr_t)0xfff) + (uintptr_t)imm) != (sbox & ~(uintptr_t)0xfff)) continue;

                // The following ADD must complete the address, not just touch the page.
                for (int k = 1; k <= 6; k++) {
                    uint32_t w2 = *(const uint32_t *)(p + 4 * k);
                    if ((w2 & 0xFF800000) != 0x91000000) continue;     // ADD (imm)
                    if (((w2 >> 5) & 31) != rd) continue;
                    uintptr_t target = (uintptr_t)evSx((uint32_t)((w2 >> 10) & 0xfff), 12);
                    if ((p & ~(uintptr_t)0xfff) + (uintptr_t)imm + target != sbox) break;

                    // Back up to the enclosing function start.
                    uintptr_t q = p;
                    while (q > base + 4 && *(const uint32_t *)(q - 4) != 0xd65f03c0) q -= 4;  // RET
                    if (q <= base + 4) break;
                    return q;
                }
            }
        }
        cmd = (const struct load_command *)((uintptr_t)cmd + cmd->cmdsize);
    }
    return 0;
}

static void evKeyExpandHook(void *ctx, const uint8_t *key, uint32_t keyLength) {
    atomic_fetch_add(&evKeyExpCalls, 1);
    if (key && (keyLength == 16 || keyLength == 32)) {
        EVI("Key", @"schedule %u-byte key", keyLength);
        evCaptureKey([NSData dataWithBytes:key length:keyLength],
                     [NSMutableData dataWithLength:16]);   // CTR counter starts at zero
    }
    if (evOrigKeyExpand) evOrigKeyExpand(ctx, key, keyLength);
}

typedef void (*MSHookFunctionType)(void *, void *, void **);

static void evInstallAESHook(void) {
    uintptr_t sbox = evFindSbox();
    if (!sbox) { EVW("Key", @"AES sbox not found"); return; }
    uintptr_t fn = evFindKeyExpand(sbox);
    if (!fn) { EVW("Key", @"AES key schedule not found"); return; }
    evKeyExpandAddr = (void *)fn;
    EVI("Key", @"AES sbox=%p schedule=%p", (void *)sbox, (void *)fn);

    MSHookFunctionType ms = (MSHookFunctionType)dlsym(RTLD_DEFAULT, "MSHookFunction");
    if (!ms) { EVW("Key", @"MSHookFunction unavailable; schedule hook skipped"); return; }
    ms((void *)fn, (void *)evKeyExpandHook, (void **)&evOrigKeyExpand);
    if (!evOrigKeyExpand) { EVW("Key", @"schedule hook refused"); evKeyExpandAddr = NULL; return; }
    EVI("Key", @"AES schedule hook installed");
}

#pragma mark - download

static const NSUInteger kChunk = 2 * 1024 * 1024;
static const NSUInteger kMaxBytes = 256 * 1024 * 1024;

static void evFetchAll(NSURL *url, void (^done)(NSData *data, NSString *error)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSMutableData *buffer = [NSMutableData data];
        NSUInteger offset = 0;

        while (YES) {
            if (buffer.length > kMaxBytes) { done(nil, @"file too large"); return; }

            NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
            [req setValue:[NSString stringWithFormat:@"bytes=%lu-%lu", (unsigned long)offset,
                           (unsigned long)(offset + kChunk - 1)] forHTTPHeaderField:@"Range"];
            req.timeoutInterval = 30;

            __block NSData *chunk = nil;
            __block NSInteger code = 0;
            __block NSString *failure = nil;
            dispatch_semaphore_t sem = dispatch_semaphore_create(0);
            [[NSURLSession.sharedSession dataTaskWithRequest:req
                                           completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
                chunk = data;
                code = [(NSHTTPURLResponse *)resp statusCode];
                failure = err.localizedDescription;
                dispatch_semaphore_signal(sem);
            }] resume];

            if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC)) != 0) {
                done(nil, @"request timed out");
                return;
            }
            if (failure) { done(nil, failure); return; }
            if (code != 200 && code != 206) { done(nil, [NSString stringWithFormat:@"http %ld", (long)code]); return; }
            if (!chunk.length) { done(buffer, nil); return; }

            [buffer appendData:chunk];
            // 200 means the server ignored Range and sent the whole file.
            if (code == 200 || chunk.length < kChunk) { done(buffer, nil); return; }
            offset += chunk.length;
        }
    });
}

static NSString *evFileName(NSDictionary *manifest) {
    NSString *id = manifest[@"fileID"];
    if (!id.length) id = [NSString stringWithFormat:@"track-%lld", (long long)NSDate.date.timeIntervalSince1970];
    NSMutableString *safe = [NSMutableString stringWithCapacity:id.length];
    for (NSUInteger i = 0; i < id.length; i++) {
        unichar c = [id characterAtIndex:i];
        BOOL ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_';
        [safe appendFormat:@"%C", (unichar)(ok ? c : (unichar)'-')];
    }
    return [safe stringByAppendingPathExtension:@"ogg"];
}

static NSURL *evStreamsDir(void) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"Streams"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    return [NSURL fileURLWithPath:dir];
}

void EVAudioKeyGrabCurrent(void (^done)(BOOL ok, NSString *text, NSURL *file)) {
    void (^finish)(BOOL, NSString *, NSURL *) = ^(BOOL ok, NSString *text, NSURL *file) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(ok, text ?: @"", file); });
    };

    pthread_mutex_lock(&evLock);
    NSDictionary *manifest = [evManifest copy];
    pthread_mutex_unlock(&evLock);

    NSString *urlString = manifest[@"url"];
    if (!urlString.length) urlString = evLastCDNURL();
    if (!urlString.length) {
        finish(NO, @"No URL yet — play a track and check diagnostics.", nil);
        return;
    }

    NSURL *url = [NSURL URLWithString:urlString];
    if (!url || !url.scheme) { finish(NO, @"No absolute URL in the manifest.", nil); return; }

    NSArray<NSDictionary *> *keys = EVAudioKeyRecent();
    EVI("Key", @"grab from %@ (%lu key(s) known)", url.host ?: @"?", (unsigned long)keys.count);

    evFetchAll(url, ^(NSData *data, NSString *error) {
        if (!data) { finish(NO, error, nil); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            NSData *plain = nil;
            NSString *how = nil;

            if (evIsOgg(data)) {
                plain = data;                     // unencrypted stream, or already plain
                how = @"plain";
            }
            for (NSDictionary *k in keys) {
                if (plain) break;
                if (evKeyMatches(data, k[@"key"], k[@"iv"])) {
                    plain = evCTR(data, k[@"key"], k[@"iv"]);
                    how = @"key";
                }
            }
            if (!plain) {
                finish(NO, [NSString stringWithFormat:
                            @"No captured key matched (%lu bytes fetched, %lu keys).",
                            (unsigned long)data.length, (unsigned long)keys.count], nil);
                return;
            }

            NSURL *dest = [evStreamsDir() URLByAppendingPathComponent:evFileName(manifest)];
            NSError *werr = nil;
            if (![plain writeToURL:dest options:NSDataWritingAtomic error:&werr]) {
                finish(NO, werr.localizedDescription ?: @"write failed", nil);
                return;
            }
            EVI("Key", @"saved %@ (%.1f MiB, %@)", dest.lastPathComponent,
                plain.length / 1048576.0, how);
            finish(YES, [NSString stringWithFormat:@"%.1f MiB • %@ • Documents/Streams",
                         plain.length / 1048576.0, how], dest);
        });
    });
}

#pragma mark - diagnostics

static NSString *evHex(NSData *data) {
    if (!data.length) return @"-";
    NSMutableString *s = [NSMutableString stringWithCapacity:data.length * 2];
    const uint8_t *b = data.bytes;
    for (NSUInteger i = 0; i < data.length; i++) [s appendFormat:@"%02x", b[i]];
    return s;
}

static void evCollectKeyStores(NSString *root, NSMutableString *out, NSURL *dest,
                               NSUInteger depth, NSUInteger *scanned) {
    if (depth > 4 || *scanned > 3000) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray<NSString *> *names = [fm contentsOfDirectoryAtPath:root error:nil];
    for (NSString *name in names) {
        NSString *path = [root stringByAppendingPathComponent:name];
        BOOL dir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&dir]) continue;
        if (dir) {
            evCollectKeyStores(path, out, dest, depth + 1, scanned);
            continue;
        }
        if (++(*scanned) > 3000) return;

        NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
        unsigned long long size = attrs.fileSize;
        NSString *lower = name.lowercaseString;
        BOOL keyish = [lower containsString:@"key"] || [lower containsString:@"store"];

        // Head sniff: a plaintext Ogg cache would make keys irrelevant.
        NSString *head = @"";
        if (size >= 4) {
            NSFileHandle *fh = [NSFileHandle fileHandleForReadingAtPath:path];
            NSData *bytes = [fh readDataOfLength:8];
            [fh closeFile];
            if (bytes.length) {
                NSMutableString *hex = [NSMutableString string];
                for (NSUInteger i = 0; i < bytes.length; i++) [hex appendFormat:@"%02x", ((const uint8_t *)bytes.bytes)[i]];
                head = hex;
                if (bytes.length >= 4 && memcmp(bytes.bytes, "OggS", 4) == 0) head = [head stringByAppendingString:@"  <<< PLAIN OGG"];
            }
        }

        if (keyish || [head containsString:@"PLAIN OGG"] || size > 200000) {
            [out appendFormat:@"%@  %llu  %@\n", path, size, head];
        }
        if (keyish && size > 0 && size <= 256 * 1024) {
            [fm createDirectoryAtURL:dest withIntermediateDirectories:YES attributes:nil error:nil];
            NSString *flat = [NSString stringWithFormat:@"%@-%@", @(size), name];
            [fm copyItemAtPath:path toPath:[dest URLByAppendingPathComponent:flat].path error:nil];
        }
    }
}

void EVAudioKeyExportDiagnostics(void (^done)(NSURL *folder, NSString *summary)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDateFormatter *fmt = [NSDateFormatter new];
        fmt.dateFormat = @"yyyyMMdd-HHmmss";
        NSString *name = [NSString stringWithFormat:@"diag-%@", [fmt stringFromDate:NSDate.date]];
        NSURL *dir = [evStreamsDir() URLByAppendingPathComponent:name];
        NSFileManager *fm = [NSFileManager defaultManager];
        [fm createDirectoryAtURL:dir withIntermediateDirectories:YES attributes:nil error:nil];

        NSMutableString *log = [NSMutableString string];

        pthread_mutex_lock(&evLock);
        NSArray *urls = [evURLs copy];
        NSData *manifestData = evLastManifestData;
        NSDictionary *manifest = [evManifest copy];
        pthread_mutex_unlock(&evLock);

        [log appendFormat:@"hooks: state=%d aes=%d ctr=%d ccrypt=%d\n",
             atomic_load(&evHookState), atomic_load(&evAesSeen),
             atomic_load(&evCtrSeen), atomic_load(&evCCCryptCalls)];
        [log appendFormat:@"manifest: %@\n\n", manifest ?: @{}];
        [log appendString:@"== urls ==\n"];
        for (NSString *u in urls) [log appendFormat:@"%@\n", u];

        [log appendString:@"\n== keys ==\n"];
        for (NSDictionary *k in EVAudioKeyRecent()) {
            [log appendFormat:@"%@ %@\n", evHex(k[@"key"]), evHex(k[@"iv"])];
        }

        if (manifestData) [manifestData writeToURL:[dir URLByAppendingPathComponent:@"manifest.bin"] atomically:YES];

        NSMutableString *stores = [NSMutableString string];
        NSURL *keyDir = [dir URLByAppendingPathComponent:@"keystore"];
        NSUInteger scanned = 0;
        evCollectKeyStores(NSHomeDirectory(), stores, keyDir, 0, &scanned);
        [log appendFormat:@"\n== files (scanned %lu) ==\n%@", (unsigned long)scanned, stores];

        NSString *logPath = [dir URLByAppendingPathComponent:@"report.txt"].path;
        [log writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];

        NSString *summary = [NSString stringWithFormat:@"%lu URL(s), %lu key(s), %lu B manifest",
                             (unsigned long)urls.count, (unsigned long)EVAudioKeyRecent().count,
                             (unsigned long)manifestData.length];
        dispatch_async(dispatch_get_main_queue(), ^{ if (done) done(dir, summary); });
    });
}

#pragma mark - public

NSArray<NSDictionary *> *EVAudioKeyRecent(void) {
    pthread_mutex_lock(&evLock);
    NSArray *copy = evKeys ? [evKeys copy] : @[];
    pthread_mutex_unlock(&evLock);
    return copy;
}

NSDictionary *EVAudioKeyCurrentManifest(void) {
    pthread_mutex_lock(&evLock);
    NSDictionary *copy = [evManifest copy];
    pthread_mutex_unlock(&evLock);
    return copy ?: @{};
}

NSArray<NSString *> *EVAudioKeyDebugLines(void) {
    NSMutableArray *lines = [NSMutableArray array];
    int state = atomic_load(&evHookState);
    NSArray *keys = EVAudioKeyRecent();
    NSDictionary *m = EVAudioKeyCurrentManifest();

    NSString *last = nil;
    NSString *streamer = m[@"streamerURL"];
    pthread_mutex_lock(&evLock);
    last = evURLs.firstObject;
    NSUInteger urlCount = evURLs.count;
    pthread_mutex_unlock(&evLock);

    [lines addObject:[NSString stringWithFormat:@"key hook: %@ (aes=%d ctr=%d ccrypt=%d schedule=%d%@)",
                      state == 1 ? @"installed" : (state == 2 ? @"FAILED" : @"pending"),
                      atomic_load(&evAesSeen), atomic_load(&evCtrSeen), atomic_load(&evCCCryptCalls),
                      atomic_load(&evKeyExpCalls),
                      evKeyExpandAddr ? @"" : @" no-schedule"]];
    [lines addObject:[NSString stringWithFormat:@"keys captured: %lu", (unsigned long)keys.count]];
    [lines addObject:[NSString stringWithFormat:@"manifest: %@ %@", m[@"fileID"] ?: @"-", m[@"encryption"] ?: @"-"]];
    if (streamer) [lines addObject:[NSString stringWithFormat:@"streamer: %@", streamer]];
    [lines addObject:[NSString stringWithFormat:@"urls seen: %lu", (unsigned long)urlCount]];
    if (last) [lines addObject:[NSString stringWithFormat:@"  %@", last]];
    return lines;
}

static atomic_int evAuxHooksInstalled;

void EVAudioKeySetEnabled(BOOL enabled) {
    if (!enabled || atomic_exchange(&evAuxHooksInstalled, 1)) return;
    evInstallHooks();
    dispatch_async(dispatch_get_main_queue(), ^{
        evInstallNetworkTap();
        evInstallManifestHook(0);
        evInstallStreamerHooks();
        evInstallAESHook();
    });
}

__attribute__((constructor)) static void evAudioKeyInit(void) {
    EVAudioKeySetEnabled(EeveeAudioRecorderEnabled());
}
