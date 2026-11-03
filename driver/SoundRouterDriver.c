// SoundRouter virtual audio driver (CoreAudio AudioServerPlugIn).
// Publishes N loopback devices (2..16 channels, 48 kHz, float32): whatever is played to a device's output
// comes out of its input. Devices come from /Library/Application Support/SoundRouter/devices.txt
// (line k = device "soundrouter.k" as "name" or "name<TAB>channels", empty line = unused slot, max 8). The file is
// watched: the app rewrites it and devices appear / disappear / get renamed live, without restarting coreaudiod.
// A channel-count change is applied as remove + re-add of that device (clients lose it for ~0.4 s).
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <CoreFoundation/CFPlugInCOM.h>
#include <mach/mach_time.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAXDEV 8
#define RATE 48000.0
#define MAXCH 16
#define RING 65536u      // frames, power of 2
#define ZTS_PERIOD 16384u
#ifndef CONF             // overridable for the headless test harness (tests/drivertest.c)
#define CONF "/Library/Application Support/SoundRouter/devices.txt"
#endif

typedef struct {
    char name[128], uid[32];
    UInt32 started, ch;   // ch: channels per frame (even, 2..MAXCH), fixed while the device is published
    UInt32 act[2];   // stream IsActive: [0]=input [1]=output
    UInt64 anchor;
    _Atomic UInt64 lastWrite;
    float *ring;     // RING * MAXCH floats, allocated once, never freed
} Dev;

static Dev gDev[MAXDEV];
static pthread_mutex_t gMtx = PTHREAD_MUTEX_INITIALIZER;
static Float64 gTicksPerFrame;
static UInt64 gSilenceTicks;
static AudioServerPlugInHostRef gHost;
static UInt32 gRefCount = 1;

// object ids: plugin = 1; device i = 2+3i, input stream = 3+3i, output stream = 4+3i
#define DEVID(i) ((AudioObjectID)(2 + 3 * (i)))
static int idx(AudioObjectID o) { return o < 2 ? -1 : (int)((o - 2) / 3); }
static int role(AudioObjectID o) { return (int)((o - 2) % 3); } // 0 dev, 1 in stream, 2 out stream
// a slot with an empty name is unused (keeps the other devices' UIDs stable when one is deleted)
static Dev *dev(AudioObjectID o) { int i = idx(o); return (o >= 2 && i < MAXDEV && gDev[i].name[0]) ? &gDev[i] : NULL; }

static AudioStreamBasicDescription fmt(UInt32 ch) {
    AudioStreamBasicDescription f = {RATE, kAudioFormatLinearPCM,
        kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked,
        4 * ch, 1, 4 * ch, ch, 32, 0};
    return f;
}

// ---------- property plumbing: one function answers has / size / get ----------
enum { M_HAS, M_SIZE, M_GET };
static OSStatus emit(int m, UInt32 inSize, UInt32 *outSize, void *out, const void *v, UInt32 sz) {
    if (m == M_HAS) return 0;
    *outSize = sz;
    if (m == M_SIZE) return 0;
    if (inSize < sz) return kAudioHardwareBadPropertySizeError;
    memcpy(out, v, sz);
    return 0;
}
static OSStatus emitArr(int m, UInt32 inSize, UInt32 *outSize, void *out, const void *v, UInt32 n, UInt32 es) {
    if (m == M_HAS) return 0;
    if (m == M_SIZE) { *outSize = n * es; return 0; }
    UInt32 k = inSize / es < n ? inSize / es : n;
    *outSize = k * es;
    memcpy(out, v, k * es);
    return 0;
}
static OSStatus emitU32(int m, UInt32 is, UInt32 *os, void *o, UInt32 v) { return emit(m, is, os, o, &v, 4); }
static OSStatus emitStr(int m, UInt32 is, UInt32 *os, void *o, const char *s) {
    if (m != M_GET) return emit(m, is, os, o, NULL, sizeof(CFStringRef));
    if (is < sizeof(CFStringRef)) return kAudioHardwareBadPropertySizeError;   // don't leak the string
    CFStringRef c = CFStringCreateWithCString(NULL, s, kCFStringEncodingUTF8);
    return emit(m, is, os, o, &c, sizeof(CFStringRef));
}

static OSStatus prop(int m, AudioObjectID obj, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q,
                     UInt32 is, UInt32 *os, void *o) {
    UInt32 sel = a->mSelector, scope = a->mScope;
    if (obj == kAudioObjectPlugInObject) {
        AudioObjectID ids[MAXDEV]; UInt32 nIds = 0;
        for (int i = 0; i < MAXDEV; i++) if (gDev[i].name[0]) ids[nIds++] = DEVID(i);
        switch (sel) {
        case kAudioObjectPropertyBaseClass: return emitU32(m, is, os, o, kAudioObjectClassID);
        case kAudioObjectPropertyClass: return emitU32(m, is, os, o, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner: return emitU32(m, is, os, o, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer: return emitStr(m, is, os, o, "SoundRouter");
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList: return emitArr(m, is, os, o, ids, nIds, 4);
        case kAudioPlugInPropertyResourceBundle: return emitStr(m, is, os, o, "");
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            AudioObjectID r = kAudioObjectUnknown;
            if (m == M_GET && q && qs == sizeof(CFStringRef)) {
                char buf[64] = {0};
                CFStringGetCString(*(CFStringRef *)q, buf, sizeof buf, kCFStringEncodingUTF8);
                for (int i = 0; i < MAXDEV; i++) if (gDev[i].name[0] && !strcmp(buf, gDev[i].uid)) r = DEVID(i);
            }
            return emitU32(m, is, os, o, r);
        }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    Dev *d = dev(obj);
    if (!d) return kAudioHardwareBadObjectError;
    int i = idx(obj);
    if (role(obj) == 0) {
        AudioObjectID in = DEVID(i) + 1, outS = DEVID(i) + 2, both[2] = {in, outS};
        switch (sel) {
        case kAudioObjectPropertyBaseClass: return emitU32(m, is, os, o, kAudioObjectClassID);
        case kAudioObjectPropertyClass: return emitU32(m, is, os, o, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner: return emitU32(m, is, os, o, kAudioObjectPlugInObject);
        case kAudioObjectPropertyName: {   // the watcher thread may rename it concurrently
            char nm[128]; pthread_mutex_lock(&gMtx); memcpy(nm, d->name, sizeof nm); pthread_mutex_unlock(&gMtx);
            return emitStr(m, is, os, o, nm); }
        case kAudioObjectPropertyManufacturer: return emitStr(m, is, os, o, "SoundRouter");
        case kAudioDevicePropertyDeviceUID: return emitStr(m, is, os, o, d->uid);
        case kAudioDevicePropertyModelUID: return emitStr(m, is, os, o, "SoundRouterModel");
        case kAudioDevicePropertyTransportType: return emitU32(m, is, os, o, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices: { AudioObjectID s = obj; return emitArr(m, is, os, o, &s, 1, 4); }
        case kAudioDevicePropertyClockDomain: return emitU32(m, is, os, o, 0);
        case kAudioDevicePropertyDeviceIsAlive: return emitU32(m, is, os, o, 1);
        case kAudioDevicePropertyDeviceIsRunning: return emitU32(m, is, os, o, d->started > 0);
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice: return emitU32(m, is, os, o, 1);
        case kAudioDevicePropertyLatency:
        case kAudioDevicePropertySafetyOffset: return emitU32(m, is, os, o, 0);
        case kAudioDevicePropertyIsHidden: return emitU32(m, is, os, o, 0);
        case kAudioDevicePropertyZeroTimeStampPeriod: return emitU32(m, is, os, o, ZTS_PERIOD);
        case kAudioObjectPropertyOwnedObjects: return emitArr(m, is, os, o, both, 2, 4);
        case kAudioDevicePropertyStreams:
            if (scope == kAudioObjectPropertyScopeInput) return emitArr(m, is, os, o, &in, 1, 4);
            if (scope == kAudioObjectPropertyScopeOutput) return emitArr(m, is, os, o, &outS, 1, 4);
            return emitArr(m, is, os, o, both, 2, 4);
        case kAudioObjectPropertyControlList: return emitArr(m, is, os, o, NULL, 0, 4);
        case kAudioDevicePropertyNominalSampleRate: { Float64 r = RATE; return emit(m, is, os, o, &r, 8); }
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            AudioValueRange r = {RATE, RATE}; return emitArr(m, is, os, o, &r, 1, sizeof r); }
        case kAudioDevicePropertyPreferredChannelsForStereo: { UInt32 c[2] = {1, 2}; return emitArr(m, is, os, o, c, 2, 4); }
        }
        return kAudioHardwareUnknownPropertyError;
    }
    // streams
    switch (sel) {
    case kAudioObjectPropertyBaseClass: return emitU32(m, is, os, o, kAudioObjectClassID);
    case kAudioObjectPropertyClass: return emitU32(m, is, os, o, kAudioStreamClassID);
    case kAudioObjectPropertyOwner: return emitU32(m, is, os, o, DEVID(i));
    case kAudioObjectPropertyOwnedObjects: return emitArr(m, is, os, o, NULL, 0, 4);
    case kAudioStreamPropertyIsActive: return emitU32(m, is, os, o, d->act[role(obj) - 1]);
    case kAudioStreamPropertyDirection: return emitU32(m, is, os, o, role(obj) == 1 ? 1 : 0);
    case kAudioStreamPropertyTerminalType:
        return emitU32(m, is, os, o, role(obj) == 1 ? kAudioStreamTerminalTypeLine : kAudioStreamTerminalTypeLine);
    case kAudioStreamPropertyStartingChannel: return emitU32(m, is, os, o, 1);
    case kAudioStreamPropertyLatency: return emitU32(m, is, os, o, 0);
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat: { AudioStreamBasicDescription f = fmt(d->ch); return emit(m, is, os, o, &f, sizeof f); }
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription r = {fmt(d->ch), {RATE, RATE}}; return emitArr(m, is, os, o, &r, 1, sizeof r); }
    }
    return kAudioHardwareUnknownPropertyError;
}

// ---------- driver interface ----------
static HRESULT QI(void *d, REFIID iid, LPVOID *out);
static ULONG AddRef(void *d) { return ++gRefCount; }
static ULONG Release(void *d) { return --gRefCount; }

// ---------- device list from CONF, reloaded live ----------
typedef struct { char name[MAXDEV][128]; UInt32 ch[MAXDEV]; } Names;
static void parseConf(Names *out) {
    memset(out, 0, sizeof *out);
    FILE *f = fopen(CONF, "r");
    char line[160];
    int n = 0, used = 0;
    while (f && n < MAXDEV && fgets(line, sizeof line, f)) {
        line[strcspn(line, "\r\n")] = 0;
        char *tab = strchr(line, '\t');
        int ch = tab ? atoi(tab + 1) : 2;
        if (tab) *tab = 0;
        out->ch[n] = ch >= 2 && ch <= MAXCH ? (UInt32)(ch & ~1) : 2;   // even 2..16, anything else = stereo
        strncpy(out->name[n], line, 127);
        used |= line[0] != 0;
        n++;
    }
    if (f) fclose(f);
    if (!used) { strcpy(out->name[0], "SoundRouter"); out->ch[0] = 2; }   // missing/empty file: one default device
}
// Rings are allocated once (for MAXCH channels) and never freed, so an IO cycle racing with a removal never
// touches freed memory. A device whose channel count changes is removed now and re-added (with the new count) by a
// later call, after the HAL has seen it disappear: a published device's format never changes under a client.
// Returns 1 when such a re-add is still pending.
static int applyConf(Names *nn, int notify) {
    int listChanged = 0, renamed[MAXDEV] = {0}, pending = 0;
    pthread_mutex_lock(&gMtx);
    for (int i = 0; i < MAXDEV; i++) {
        Dev *d = &gDev[i];
        int was = d->name[0] != 0, now = nn->name[i][0] != 0;
        if (now && !d->ring) d->ring = calloc(RING * MAXCH, sizeof(float));
        if (now && !d->ring) { nn->name[i][0] = 0; now = 0; }
        if (was && now && d->ch != nn->ch[i]) { now = 0; pending = 1; }   // step 1 of a channel change: remove
        if (now && !was) { memset(d->ring, 0, RING * MAXCH * sizeof(float)); d->started = 0; d->act[0] = d->act[1] = 1; d->ch = nn->ch[i]; }
        if (was != now) listChanged = 1;
        else if (now && strcmp(d->name, nn->name[i])) renamed[i] = 1;
        if (now) memcpy(d->name, nn->name[i], sizeof d->name); else d->name[0] = 0;
    }
    pthread_mutex_unlock(&gMtx);
    if (!notify || !gHost) return pending;
    if (listChanged) {
        AudioObjectPropertyAddress a[2] = {{kAudioPlugInPropertyDeviceList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
                                           {kAudioObjectPropertyOwnedObjects, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        gHost->PropertiesChanged(gHost, kAudioObjectPlugInObject, 2, a);
    }
    for (int i = 0; i < MAXDEV; i++) if (renamed[i]) {
        AudioObjectPropertyAddress a = {kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        gHost->PropertiesChanged(gHost, DEVID(i), 1, &a);
    }
    return pending;
}
static struct stat gConfStat;
static int sameFile(const struct stat *a, const struct stat *b) {
    return a->st_ino == b->st_ino && a->st_size == b->st_size && a->st_mtimespec.tv_sec == b->st_mtimespec.tv_sec &&
           a->st_mtimespec.tv_nsec == b->st_mtimespec.tv_nsec;
}
static int gPending;   // a channel change waits for its re-add
static void pollConf(void) {   // one watcher step
    struct stat st;
    if (stat(CONF, &st) != 0) memset(&st, 0, sizeof st);   // deleted file -> default device
    if (sameFile(&st, &gConfStat) && !gPending) return;
    gConfStat = st;
    Names nn; parseConf(&nn); gPending = applyConf(&nn, 1);
}
static void *watchConf(void *x) {   // ponytail: 400 ms stat() poll; a dispatch vnode source if latency ever matters
    for (;;) { usleep(400000); pollConf(); }
    return NULL;
}

static OSStatus Initialize(AudioServerPlugInDriverRef r, AudioServerPlugInHostRef h) {
    gHost = h;
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    Float64 ticksPerSec = 1e9 * tb.denom / tb.numer;
    gTicksPerFrame = ticksPerSec / RATE;
    gSilenceTicks = (UInt64)(ticksPerSec * 0.25);
    for (int i = 0; i < MAXDEV; i++) snprintf(gDev[i].uid, sizeof gDev[i].uid, "soundrouter.%d", i);
    if (stat(CONF, &gConfStat) != 0) memset(&gConfStat, 0, sizeof gConfStat);   // stat before reading: no change is missed
    Names nn; parseConf(&nn); applyConf(&nn, 0);
    pthread_t t; pthread_create(&t, NULL, watchConf, NULL); pthread_detach(t);
    return 0;
}
static OSStatus CreateDevice(AudioServerPlugInDriverRef r, CFDictionaryRef d, const AudioServerPlugInClientInfo *c, AudioObjectID *o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus DestroyDevice(AudioServerPlugInDriverRef r, AudioObjectID o) { return kAudioHardwareUnsupportedOperationError; }
static OSStatus AddClient(AudioServerPlugInDriverRef r, AudioObjectID o, const AudioServerPlugInClientInfo *c) { return 0; }
static OSStatus PerformChange(AudioServerPlugInDriverRef r, AudioObjectID o, UInt64 a, void *i) { return 0; }

static Boolean HasProperty(AudioServerPlugInDriverRef r, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a) {
    return prop(M_HAS, o, a, 0, NULL, 0, NULL, NULL) == 0;
}
static OSStatus IsSettable(AudioServerPlugInDriverRef r, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, Boolean *s) {
    OSStatus e = prop(M_HAS, o, a, 0, NULL, 0, NULL, NULL);
    if (e) return e;
    *s = a->mSelector == kAudioDevicePropertyNominalSampleRate || a->mSelector == kAudioStreamPropertyVirtualFormat ||
         a->mSelector == kAudioStreamPropertyPhysicalFormat || a->mSelector == kAudioStreamPropertyIsActive;
    return 0;
}
static OSStatus GetSize(AudioServerPlugInDriverRef r, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 *sz) {
    return prop(M_SIZE, o, a, qs, q, 0, sz, NULL);
}
static OSStatus GetData(AudioServerPlugInDriverRef r, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 is, UInt32 *os, void *out) {
    return prop(M_GET, o, a, qs, q, is, os, out);
}
// Only the device's own 48 kHz float format exists, so "setting" it is a no-op that succeeds when it matches.
static OSStatus SetData(AudioServerPlugInDriverRef r, AudioObjectID o, pid_t p, const AudioObjectPropertyAddress *a, UInt32 qs, const void *q, UInt32 sz, const void *data) {
    if (a->mSelector == kAudioStreamPropertyIsActive && sz == 4 && dev(o) && role(o) > 0) { dev(o)->act[role(o) - 1] = *(const UInt32 *)data ? 1 : 0; return 0; }
    if (a->mSelector == kAudioDevicePropertyNominalSampleRate && sz == 8) return *(const Float64 *)data == RATE ? 0 : kAudioDeviceUnsupportedFormatError;
    if ((a->mSelector == kAudioStreamPropertyVirtualFormat || a->mSelector == kAudioStreamPropertyPhysicalFormat) && sz == sizeof(AudioStreamBasicDescription)) {
        const AudioStreamBasicDescription *f = data;
        return (f->mSampleRate == RATE && dev(o) && f->mChannelsPerFrame == dev(o)->ch && f->mFormatID == kAudioFormatLinearPCM) ? 0 : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus StartIO(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c) {
    Dev *d = dev(o); if (!d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMtx);
    if (d->started++ == 0) {
        d->anchor = mach_absolute_time();
        memset(d->ring, 0, RING * MAXCH * sizeof(float));   // sample time restarts at 0: don't leak the previous session's audio
        atomic_store(&d->lastWrite, 0);
    }
    pthread_mutex_unlock(&gMtx);
    return 0;
}
static OSStatus StopIO(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c) {
    Dev *d = dev(o); if (!d) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gMtx);
    if (d->started) d->started--;
    pthread_mutex_unlock(&gMtx);
    return 0;
}
static OSStatus GetZTS(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c, Float64 *st, UInt64 *ht, UInt64 *seed) {
    Dev *d = dev(o); if (!d) return kAudioHardwareBadObjectError;
    UInt64 per = (UInt64)(gTicksPerFrame * ZTS_PERIOD);
    UInt64 n = (mach_absolute_time() - d->anchor) / per;
    *st = (Float64)(n * ZTS_PERIOD);
    *ht = d->anchor + n * per;
    *seed = 1;
    return 0;
}
static OSStatus WillDo(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c, UInt32 op, Boolean *will, Boolean *inPlace) {
    *will = op == kAudioServerPlugInIOOperationReadInput || op == kAudioServerPlugInIOOperationWriteMix;
    *inPlace = true;
    return 0;
}
static OSStatus BeginIO(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { return 0; }
static OSStatus EndIO(AudioServerPlugInDriverRef r, AudioObjectID o, UInt32 c, UInt32 op, UInt32 n, const AudioServerPlugInIOCycleInfo *i) { return 0; }

static OSStatus DoIO(AudioServerPlugInDriverRef r, AudioObjectID o, AudioObjectID stream, UInt32 c, UInt32 op, UInt32 n,
                     const AudioServerPlugInIOCycleInfo *ci, void *buf, void *buf2) {
    Dev *d = dev(o); if (!d) return kAudioHardwareBadObjectError;
    float *b = buf;
    UInt32 ch = d->ch;   // ring stride = the device's channel count (rings hold MAXCH, so any ch <= MAXCH stays in bounds)
    if (op == kAudioServerPlugInIOOperationWriteMix) {
        UInt64 s = (UInt64)(SInt64)ci->mOutputTime.mSampleTime;   // via SInt64: a negative double -> UInt64 cast is UB
        for (UInt32 f = 0; f < n; f++) memcpy(&d->ring[((s + f) & (RING - 1)) * ch], &b[f * ch], ch * sizeof(float));
        atomic_store(&d->lastWrite, mach_absolute_time());
    } else if (op == kAudioServerPlugInIOOperationReadInput) {
        UInt64 s = (UInt64)(SInt64)ci->mInputTime.mSampleTime;
        // nobody writing for a while -> silence instead of replaying stale ring contents
        if (mach_absolute_time() - atomic_load(&d->lastWrite) > gSilenceTicks) memset(b, 0, n * ch * sizeof(float));
        else for (UInt32 f = 0; f < n; f++) memcpy(&b[f * ch], &d->ring[((s + f) & (RING - 1)) * ch], ch * sizeof(float));
    }
    return 0;
}

static AudioServerPlugInDriverInterface gIface = {
    NULL, QI, AddRef, Release, Initialize, CreateDevice, DestroyDevice, AddClient, AddClient /*RemoveDeviceClient*/,
    PerformChange, PerformChange /*Abort*/, HasProperty, IsSettable, GetSize, GetData, SetData,
    StartIO, StopIO, GetZTS, WillDo, BeginIO, DoIO, EndIO};
static AudioServerPlugInDriverInterface *gIfacePtr = &gIface;
static AudioServerPlugInDriverRef gRef = &gIfacePtr;

static HRESULT QI(void *d, REFIID iid, LPVOID *out) {
    CFUUIDRef u = CFUUIDCreateFromUUIDBytes(NULL, iid);
    Boolean ok = CFEqual(u, IUnknownUUID) || CFEqual(u, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(u);
    if (!ok) { *out = NULL; return E_NOINTERFACE; }
    gRefCount++;
    *out = gRef;
    return 0;
}

void *SoundRouterFactory(CFAllocatorRef alloc, CFUUIDRef type) {
    return CFEqual(type, kAudioServerPlugInTypeUUID) ? gRef : NULL;
}
