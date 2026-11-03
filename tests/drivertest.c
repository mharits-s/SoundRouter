// Headless test of the driver's logic (no coreaudiod): devices.txt parsing, live add/remove/rename, channel-count
// change as remove + re-add, per-device formats, loopback through the ring. Built and run by tests/run.sh.
#define CONF "/tmp/sr-drivertest-devices.txt"
#include "../driver/SoundRouterDriver.c"

static int fails, changes, listChanges;
static OSStatus hostChanged(AudioServerPlugInHostRef h, AudioObjectID o, UInt32 n, const AudioObjectPropertyAddress *a) {
    changes++; if (o == kAudioObjectPlugInObject) listChanges++; return 0;
}
static void check(int ok, const char *s) { printf("%s %s\n", ok ? "PASS" : "FAIL", s); fails += !ok; }
static void put(const char *t) { FILE *f = fopen(CONF ".tmp", "w"); fputs(t, f); fclose(f); rename(CONF ".tmp", CONF); usleep(20000); }
static UInt32 nDevs(void) {
    AudioObjectPropertyAddress a = {kAudioPlugInPropertyDeviceList, 0, 0}; UInt32 sz = 0;
    GetSize(gRef, kAudioObjectPlugInObject, 0, &a, 0, NULL, &sz); return sz / 4;
}
static UInt32 chans(int slot, int input) {
    AudioObjectPropertyAddress a = {kAudioStreamPropertyVirtualFormat, 0, 0};
    AudioStreamBasicDescription f = {0}; UInt32 sz = sizeof f;
    if (GetData(gRef, DEVID(slot) + (input ? 1 : 2), 0, &a, 0, NULL, sz, &sz, &f)) return 0;
    AudioStreamRangedDescription r; sz = sizeof r; a.mSelector = kAudioStreamPropertyAvailablePhysicalFormats;
    GetData(gRef, DEVID(slot) + 1, 0, &a, 0, NULL, sz, &sz, &r);
    return r.mFormat.mChannelsPerFrame == f.mChannelsPerFrame ? f.mChannelsPerFrame : 999;
}
static void step(void) { gConfStat.st_mtimespec.tv_nsec ^= 1; pollConf(); }   // force a re-read (mtime granularity)

int main(void) {
    AudioServerPlugInHostInterface host = {0}; host.PropertiesChanged = hostChanged;
    put("SoundRouter\n\tbad\nFour\t4\nOdd\t5\nHuge\t99\n");
    Initialize(gRef, &host);
    check(nDevs() == 4, "4 devices from 5 lines (empty name = unused slot)");
    check(chans(0, 1) == 2 && chans(0, 0) == 2, "line without tab = 2 channels");
    check(chans(1, 1) == 0, "slot 1 (empty name with a tab) is unused");
    check(chans(2, 1) == 4 && chans(2, 0) == 4, "name<TAB>4 = 4 channels in and out (format + available formats)");
    check(chans(3, 1) == 4 && chans(4, 1) == 2, "odd count rounds down to even, out of range = 2");

    // live rename: one PropertiesChanged on the device, no list change
    changes = listChanges = 0; put("Renamed\n\tbad\nFour\t4\nOdd\t5\nHuge\t99\n"); step();
    check(listChanges == 0 && changes == 1 && !strcmp(gDev[0].name, "Renamed"), "rename notifies the device only");

    // channel change: removed first, re-added with the new count on the next poll
    changes = listChanges = 0; put("Renamed\n\tbad\nFour\t8\nOdd\t5\nHuge\t99\n"); step();
    check(listChanges == 1 && nDevs() == 3 && chans(2, 1) == 0, "4 -> 8 channels: device removed first");
    pollConf();   // file unchanged, re-add still pending
    check(listChanges == 2 && nDevs() == 4 && chans(2, 1) == 8, "... and re-added with 8 channels on the next poll");
    changes = listChanges = 0; pollConf();
    check(changes == 0, "no further notifications once settled");

    // format setting accepts only the device's own channel count
    AudioObjectPropertyAddress fa = {kAudioStreamPropertyVirtualFormat, 0, 0};
    AudioStreamBasicDescription f8 = fmt(8), f2 = fmt(2);
    check(SetData(gRef, DEVID(2) + 1, 0, &fa, 0, NULL, sizeof f8, &f8) == 0 &&
          SetData(gRef, DEVID(2) + 1, 0, &fa, 0, NULL, sizeof f2, &f2) != 0, "SetData accepts 8 ch, rejects 2 ch on an 8-ch device");

    // loopback through the ring with 8 interleaved channels
    StartIO(gRef, DEVID(2), 0);
    float out[64 * 8], in[64 * 8] = {0};
    for (int i = 0; i < 64 * 8; i++) out[i] = (float)(i % 8) / 10 + (float)(i / 8) / 1000;
    AudioServerPlugInIOCycleInfo ci = {0}; ci.mOutputTime.mSampleTime = 128; ci.mInputTime.mSampleTime = 128;
    DoIO(gRef, DEVID(2), 0, 0, kAudioServerPlugInIOOperationWriteMix, 64, &ci, out, NULL);
    DoIO(gRef, DEVID(2), 0, 0, kAudioServerPlugInIOOperationReadInput, 64, &ci, in, NULL);
    check(!memcmp(in, out, sizeof out), "8-channel frames come back unchanged (ring stride = channel count)");
    StopIO(gRef, DEVID(2), 0);

    // delete everything -> default device; back to 2 ch
    put(""); step();
    check(nDevs() == 1 && chans(0, 1) == 2 && !strcmp(gDev[0].name, "SoundRouter"), "empty file = one default stereo device");
    unlink(CONF);
    printf(fails ? "DRIVER RESULT: FAILED\n" : "DRIVER RESULT: ALL PASSED\n");
    return fails != 0;
}
