// SPDX-License-Identifier: MIT
// AndroidAudio — Minimal CoreAudio AudioServerPlugIn for hosted macOS 27 (xnulinux)
// Streams 48 kHz 16-bit stereo PCM over TCP to Android Termux PulseAudio (192.168.78.1:4714).

#include <CoreAudio/AudioHardware.h>
#include <CoreAudio/AudioServerPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <mach/mach_time.h>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

#define AA_HOST_IP          "192.168.78.1"
#define AA_HOST_PORT        4714
#define AA_SAMPLE_RATE      48000.0
#define AA_CHANNELS         2
#define AA_RING_FRAMES      16384
#define AA_SAFETY_OFFSET    0
#define AA_MIN_IO_FRAMES    128
#define AA_MAX_IO_FRAMES    4096
#define AA_DEF_IO_FRAMES    512

// Object IDs
enum {
    kObjectID_PlugIn        = kAudioObjectPlugInObject, // 1
    kObjectID_Device        = 2,
    kObjectID_Stream_Out    = 3,
    kObjectID_Volume_Out    = 4,
    kObjectID_Mute_Out      = 5
};

#define AA_RING_BYTES (1 << 17) // 131072 bytes (~680 ms at 48kHz s16le stereo)
#define AA_RING_MASK  (AA_RING_BYTES - 1)

static pthread_mutex_t gStateLock = PTHREAD_MUTEX_INITIALIZER;
static uint32_t gRefCount = 0;
static uint32_t gIOActiveCount = 0;
static uint64_t gAnchorHostTime = 0;
static uint64_t gHostTicksPerFrameNum = 1;
static uint64_t gHostTicksPerFrameDen = 1;
static double gHostTicksPerRing = 1.0;

static _Atomic float gVolumeScalar = 1.0f;
static _Atomic uint32_t gMuted = 0;

// Lock-free SPSC PCM ring buffer (bytes of s16le interleaved stereo)
static uint8_t gRing[AA_RING_BYTES];
static _Atomic uint32_t gRingWrite = 0;
static _Atomic uint32_t gRingRead = 0;
static _Atomic int gNetThreadRun = 0;
static _Atomic int gHasSignal = 0;
static pthread_t gNetThread;
static int gNetThreadStarted = 0;

static uint32_t ring_avail_read(void) {
    uint32_t w = atomic_load_explicit(&gRingWrite, memory_order_acquire);
    uint32_t r = atomic_load_explicit(&gRingRead, memory_order_relaxed);
    return w - r;
}

static uint32_t ring_avail_write(void) {
    return AA_RING_BYTES - ring_avail_read();
}

static void ring_push(const uint8_t *src, uint32_t len) {
    uint32_t free_sp = ring_avail_write();
    if (len > free_sp) {
        // Drop oldest data rather than blocking CoreAudio's RT thread
        uint32_t drop = len - free_sp;
        atomic_fetch_add_explicit(&gRingRead, drop, memory_order_release);
    }
    uint32_t w = atomic_load_explicit(&gRingWrite, memory_order_relaxed);
    uint32_t idx = w & AA_RING_MASK;
    uint32_t first = AA_RING_BYTES - idx;
    if (first >= len) {
        memcpy(gRing + idx, src, len);
    } else {
        memcpy(gRing + idx, src, first);
        memcpy(gRing, src + first, len - first);
    }
    atomic_store_explicit(&gRingWrite, w + len, memory_order_release);
}

static uint32_t ring_pop(uint8_t *dst, uint32_t max_len) {
    uint32_t avail = ring_avail_read();
    if (avail == 0) return 0;
    uint32_t n = avail < max_len ? avail : max_len;
    uint32_t r = atomic_load_explicit(&gRingRead, memory_order_relaxed);
    uint32_t idx = r & AA_RING_MASK;
    uint32_t first = AA_RING_BYTES - idx;
    if (first >= n) {
        memcpy(dst, gRing + idx, n);
    } else {
        memcpy(dst, gRing + idx, first);
        memcpy(dst + first, gRing, n - first);
    }
    atomic_store_explicit(&gRingRead, r + n, memory_order_release);
    return n;
}

static int connect_host_audio(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, sizeof(one));
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(AA_HOST_PORT);
    inet_pton(AF_INET, AA_HOST_IP, &addr.sin_addr);

    int rc = connect(fd, (struct sockaddr *)&addr, sizeof(addr));
    if (rc < 0 && errno != EINPROGRESS) {
        close(fd);
        return -1;
    }
    if (rc < 0) {
        struct pollfd pfd = { .fd = fd, .events = POLLOUT };
        int pr = poll(&pfd, 1, 1000);
        int soerr = 0;
        socklen_t slen = sizeof(soerr);
        if (pr <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &soerr, &slen) < 0 || soerr != 0) {
            close(fd);
            return -1;
        }
    }
    fcntl(fd, F_SETFL, flags); // back to blocking with send timeout
    struct timeval tv = { .tv_sec = 2, .tv_usec = 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof(tv));
    return fd;
}

static void *net_sender_main(void *arg) {
    (void)arg;
    uint8_t buf[8192];
    int sock = -1;
    int idle_ms = 0;
    int retry_cooldown_ms = 0;

    while (atomic_load(&gNetThreadRun)) {
        uint32_t n = ring_pop(buf, sizeof(buf));
        if (n == 0) {
            usleep(4000);
            if (retry_cooldown_ms > 0) retry_cooldown_ms -= 4;
            if (sock >= 0) {
                idle_ms += 4;
                if (idle_ms >= 3000) {
                    close(sock);
                    sock = -1;
                    idle_ms = 0;
                }
            }
            continue;
        }

        // Check whether this chunk has any audible samples
        int nonzero = 0;
        const int16_t *s = (const int16_t *)buf;
        uint32_t samples = n / 2;
        for (uint32_t i = 0; i < samples; i++) {
            if (s[i] != 0) { nonzero = 1; break; }
        }
        if (nonzero) {
            idle_ms = 0;
        } else {
            idle_ms += (int)((n * 1000ULL) / (48000ULL * 4ULL));
            if (sock < 0) {
                // Stay disconnected while silent
                continue;
            }
            if (idle_ms >= 3000) {
                close(sock);
                sock = -1;
                idle_ms = 0;
                continue;
            }
        }

        if (sock < 0) {
            if (retry_cooldown_ms > 0) {
                usleep(4000);
                retry_cooldown_ms -= 4;
                continue;
            }
            sock = connect_host_audio();
            if (sock < 0) {
                retry_cooldown_ms = 500;
                continue;
            }
        }

        uint32_t off = 0;
        while (off < n) {
            ssize_t w = send(sock, buf + off, n - off, 0);
            if (w <= 0) {
                close(sock);
                sock = -1;
                retry_cooldown_ms = 500;
                break;
            }
            off += (uint32_t)w;
        }
    }

    if (sock >= 0) close(sock);
    return NULL;
}

static void init_timebase(void) {
    struct mach_timebase_info tb;
    mach_timebase_info(&tb);
    // host_ticks_per_sec = 1e9 * denom / numer
    // host_ticks_per_ring = AA_RING_FRAMES * (1e9 * denom / numer) / AA_SAMPLE_RATE
    gHostTicksPerFrameNum = 1000000000ULL * (uint64_t)tb.denom;
    gHostTicksPerFrameDen = (uint64_t)tb.numer * (uint64_t)AA_SAMPLE_RATE;
    gHostTicksPerRing = ((double)AA_RING_FRAMES * (double)gHostTicksPerFrameNum) / (double)gHostTicksPerFrameDen;
}

// Forward declarations
static AudioServerPlugInDriverInterface gDriverInterface;
static AudioServerPlugInDriverInterface *gDriverInterfacePtr = &gDriverInterface;

static HRESULT AA_QueryInterface(void *inDriver, REFIID inUUID, LPVOID *outInterface) {
    (void)inDriver;
    if (!outInterface) return E_POINTER;
    CFUUIDRef req = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    Boolean match = CFEqual(req, IUnknownUUID) || CFEqual(req, kAudioServerPlugInDriverInterfaceUUID);
    CFRelease(req);
    if (match) {
        gRefCount++;
        *outInterface = &gDriverInterfacePtr;
        return S_OK;
    }
    *outInterface = NULL;
    return E_NOINTERFACE;
}

static ULONG AA_AddRef(void *inDriver) {
    (void)inDriver;
    return ++gRefCount;
}

static ULONG AA_Release(void *inDriver) {
    (void)inDriver;
    if (gRefCount > 0) gRefCount--;
    return gRefCount;
}

static OSStatus AA_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    (void)inDriver; (void)inHost;
    init_timebase();
    if (!gNetThreadStarted) {
        atomic_store(&gNetThreadRun, 1);
        if (pthread_create(&gNetThread, NULL, net_sender_main, NULL) == 0) {
            gNetThreadStarted = 1;
        }
    }
    return kAudioHardwareNoError;
}

static OSStatus AA_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                const AudioServerPlugInClientInfo *inClientInfo, AudioObjectID *outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AA_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AA_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus AA_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      const AudioServerPlugInClientInfo *inClientInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientInfo;
    return kAudioHardwareNoError;
}

static OSStatus AA_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                    UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static OSStatus AA_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                  UInt64 inChangeAction, void *inChangeInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inChangeAction; (void)inChangeInfo;
    return kAudioHardwareNoError;
}

static void fill_stream_asbd(AudioStreamBasicDescription *asbd) {
    memset(asbd, 0, sizeof(*asbd));
    asbd->mSampleRate = AA_SAMPLE_RATE;
    asbd->mFormatID = kAudioFormatLinearPCM;
    asbd->mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    asbd->mBytesPerPacket = sizeof(float) * AA_CHANNELS;
    asbd->mFramesPerPacket = 1;
    asbd->mBytesPerFrame = sizeof(float) * AA_CHANNELS;
    asbd->mChannelsPerFrame = AA_CHANNELS;
    asbd->mBitsPerChannel = 32;
}

static float scalar_to_db(float s) {
    if (s <= 0.0001f) return -60.0f;
    if (s >= 1.0f) return 0.0f;
    return 20.0f * log10f(s);
}

static float db_to_scalar(float db) {
    if (db <= -60.0f) return 0.0f;
    if (db >= 0.0f) return 1.0f;
    return powf(10.0f, db / 20.0f);
}

static Boolean AA_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                              const AudioObjectPropertyAddress *inAddress) {
    (void)inDriver; (void)inClientProcessID;
    if (!inAddress) return false;
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope = inAddress->mScope;

    if (inObjectID == kObjectID_PlugIn) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
            case kAudioPlugInPropertyTranslateUIDToDevice:
            case kAudioPlugInPropertyResourceBundle:
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioObjectPropertyOwnedObjects:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyRelatedDevices:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertyStreams:
            case kAudioObjectPropertyControlList:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyNominalSampleRate:
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyPreferredChannelsForStereo:
            case kAudioDevicePropertyPreferredChannelLayout:
            case kAudioDevicePropertyBufferFrameSize:
            case kAudioDevicePropertyBufferFrameSizeRange:
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kObjectID_Stream_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kObjectID_Volume_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyDecibelRange:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                return true;
            default:
                return false;
        }
    }

    if (inObjectID == kObjectID_Mute_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
            case kAudioObjectPropertyOwner:
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioBooleanControlPropertyValue:
                return true;
            default:
                return false;
        }
    }

    (void)scope;
    return false;
}

static OSStatus AA_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                      const AudioObjectPropertyAddress *inAddress, Boolean *outIsSettable) {
    (void)inDriver; (void)inClientProcessID;
    if (!inAddress || !outIsSettable) return kAudioHardwareIllegalOperationError;
    *outIsSettable = false;
    AudioObjectPropertySelector sel = inAddress->mSelector;
    if (inObjectID == kObjectID_Volume_Out &&
        (sel == kAudioLevelControlPropertyScalarValue || sel == kAudioLevelControlPropertyDecibelValue)) {
        *outIsSettable = true;
    } else if (inObjectID == kObjectID_Mute_Out && sel == kAudioBooleanControlPropertyValue) {
        *outIsSettable = true;
    } else if (inObjectID == kObjectID_Device &&
               (sel == kAudioDevicePropertyNominalSampleRate || sel == kAudioDevicePropertyBufferFrameSize)) {
        *outIsSettable = true;
    }
    return kAudioHardwareNoError;
}

static OSStatus AA_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                       const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                       const void *inQualifierData, UInt32 *outDataSize) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!inAddress || !outDataSize) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope = inAddress->mScope;

    if (inObjectID == kObjectID_PlugIn) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
            case kAudioPlugInPropertyTranslateUIDToDevice:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
            case kAudioPlugInPropertyResourceBundle:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
            case kAudioDevicePropertyRelatedDevices:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
            case kAudioObjectPropertyManufacturer:
            case kAudioDevicePropertyDeviceUID:
            case kAudioDevicePropertyModelUID:
                *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
                if (scope == kAudioObjectPropertyScopeInput) { *outDataSize = 0; }
                else { *outDataSize = 3 * sizeof(AudioObjectID); }
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (scope == kAudioObjectPropertyScopeInput) { *outDataSize = 0; }
                else { *outDataSize = sizeof(AudioObjectID); }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                if (scope == kAudioObjectPropertyScopeInput) { *outDataSize = 0; }
                else { *outDataSize = 2 * sizeof(AudioObjectID); }
                return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
            case kAudioDevicePropertyClockDomain:
            case kAudioDevicePropertyDeviceIsAlive:
            case kAudioDevicePropertyDeviceIsRunning:
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            case kAudioDevicePropertyLatency:
            case kAudioDevicePropertySafetyOffset:
            case kAudioDevicePropertyIsHidden:
            case kAudioDevicePropertyZeroTimeStampPeriod:
            case kAudioDevicePropertyBufferFrameSize:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyNominalSampleRate:
                *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates:
            case kAudioDevicePropertyBufferFrameSizeRange:
                *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo:
                *outDataSize = 2 * sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelLayout:
                *outDataSize = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions[2]);
                return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Stream_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
            case kAudioStreamPropertyDirection:
            case kAudioStreamPropertyTerminalType:
            case kAudioStreamPropertyStartingChannel:
            case kAudioStreamPropertyLatency:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                *outDataSize = sizeof(AudioStreamBasicDescription); return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats:
                *outDataSize = sizeof(AudioStreamRangedDescription); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Volume_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioLevelControlPropertyScalarValue:
            case kAudioLevelControlPropertyDecibelValue:
            case kAudioLevelControlPropertyConvertScalarToDecibels:
            case kAudioLevelControlPropertyConvertDecibelsToScalar:
                *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
            case kAudioLevelControlPropertyDecibelRange:
                *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Mute_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
            case kAudioObjectPropertyClass:
                *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioControlPropertyScope:
            case kAudioControlPropertyElement:
            case kAudioBooleanControlPropertyValue:
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus AA_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, UInt32 *outDataSize, void *outData) {
    (void)inDriver; (void)inClientProcessID;
    if (!inAddress || !outDataSize || !outData) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertySelector sel = inAddress->mSelector;
    AudioObjectPropertyScope scope = inAddress->mScope;

    if (inObjectID == kObjectID_PlugIn) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioPlugInClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kAudioObjectUnknown; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef *)outData = CFSTR("Debian GPU"); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioPlugInPropertyResourceBundle:
                *(CFStringRef *)outData = CFSTR(""); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwnedObjects:
            case kAudioPlugInPropertyDeviceList:
                *(AudioObjectID *)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioPlugInPropertyTranslateUIDToDevice: {
                AudioObjectID outID = kAudioObjectUnknown;
                if (inQualifierDataSize >= sizeof(CFStringRef) && inQualifierData) {
                    CFStringRef uid = *(const CFStringRef *)inQualifierData;
                    if (uid && CFStringCompare(uid, CFSTR("AndroidAudio_Device"), 0) == kCFCompareEqualTo) {
                        outID = kObjectID_Device;
                    }
                }
                *(AudioObjectID *)outData = outID;
                *outDataSize = sizeof(AudioObjectID);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Device) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioDeviceClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kObjectID_PlugIn; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioObjectPropertyName:
                *(CFStringRef *)outData = CFSTR("Android AAudio Speakers"); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioObjectPropertyManufacturer:
                *(CFStringRef *)outData = CFSTR("Debian GPU"); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceUID:
                *(CFStringRef *)outData = CFSTR("AndroidAudio_Device"); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyModelUID:
                *(CFStringRef *)outData = CFSTR("AndroidAudio_Model"); *outDataSize = sizeof(CFStringRef); return kAudioHardwareNoError;
            case kAudioDevicePropertyTransportType:
                *(UInt32 *)outData = kAudioDeviceTransportTypeVirtual; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyRelatedDevices:
                *(AudioObjectID *)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioDevicePropertyClockDomain:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsAlive:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceIsRunning:
                pthread_mutex_lock(&gStateLock);
                *(UInt32 *)outData = (gIOActiveCount > 0) ? 1 : 0;
                pthread_mutex_unlock(&gStateLock);
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
                *(UInt32 *)outData = (scope == kAudioObjectPropertyScopeInput) ? 0 : 1;
                *outDataSize = sizeof(UInt32);
                return kAudioHardwareNoError;
            case kAudioDevicePropertyLatency:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertySafetyOffset:
                *(UInt32 *)outData = AA_SAFETY_OFFSET; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyIsHidden:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyZeroTimeStampPeriod:
                *(UInt32 *)outData = AA_RING_FRAMES; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyBufferFrameSize:
                *(UInt32 *)outData = AA_DEF_IO_FRAMES; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioDevicePropertyBufferFrameSizeRange: {
                AudioValueRange r = { AA_MIN_IO_FRAMES, AA_MAX_IO_FRAMES };
                *(AudioValueRange *)outData = r; *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyNominalSampleRate:
                *(Float64 *)outData = AA_SAMPLE_RATE; *outDataSize = sizeof(Float64); return kAudioHardwareNoError;
            case kAudioDevicePropertyAvailableNominalSampleRates: {
                AudioValueRange r = { AA_SAMPLE_RATE, AA_SAMPLE_RATE };
                *(AudioValueRange *)outData = r; *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            }
            case kAudioObjectPropertyOwnedObjects:
                if (scope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = 0;
                } else {
                    AudioObjectID objs[3] = { kObjectID_Stream_Out, kObjectID_Volume_Out, kObjectID_Mute_Out };
                    UInt32 n = inDataSize / sizeof(AudioObjectID);
                    if (n > 3) n = 3;
                    memcpy(outData, objs, n * sizeof(AudioObjectID));
                    *outDataSize = n * sizeof(AudioObjectID);
                }
                return kAudioHardwareNoError;
            case kAudioDevicePropertyStreams:
                if (scope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = 0;
                } else {
                    *(AudioObjectID *)outData = kObjectID_Stream_Out;
                    *outDataSize = sizeof(AudioObjectID);
                }
                return kAudioHardwareNoError;
            case kAudioObjectPropertyControlList:
                if (scope == kAudioObjectPropertyScopeInput) {
                    *outDataSize = 0;
                } else {
                    AudioObjectID ctrls[2] = { kObjectID_Volume_Out, kObjectID_Mute_Out };
                    UInt32 n = inDataSize / sizeof(AudioObjectID);
                    if (n > 2) n = 2;
                    memcpy(outData, ctrls, n * sizeof(AudioObjectID));
                    *outDataSize = n * sizeof(AudioObjectID);
                }
                return kAudioHardwareNoError;
            case kAudioDevicePropertyPreferredChannelsForStereo: {
                UInt32 ch[2] = { 1, 2 };
                memcpy(outData, ch, sizeof(ch));
                *outDataSize = sizeof(ch);
                return kAudioHardwareNoError;
            }
            case kAudioDevicePropertyPreferredChannelLayout: {
                UInt32 sz = (UInt32)offsetof(AudioChannelLayout, mChannelDescriptions[2]);
                if (inDataSize < sz) return kAudioHardwareBadPropertySizeError;
                AudioChannelLayout *cl = (AudioChannelLayout *)outData;
                memset(cl, 0, sz);
                cl->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
                cl->mNumberChannelDescriptions = 2;
                cl->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
                cl->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
                *outDataSize = sz;
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Stream_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioObjectClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioStreamClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioStreamPropertyIsActive:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyDirection:
                *(UInt32 *)outData = 0; // 0 = output
                *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyTerminalType:
                *(UInt32 *)outData = kAudioStreamTerminalTypeSpeaker; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyStartingChannel:
                *(UInt32 *)outData = 1; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyLatency:
                *(UInt32 *)outData = 0; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioStreamPropertyVirtualFormat:
            case kAudioStreamPropertyPhysicalFormat:
                fill_stream_asbd((AudioStreamBasicDescription *)outData);
                *outDataSize = sizeof(AudioStreamBasicDescription);
                return kAudioHardwareNoError;
            case kAudioStreamPropertyAvailableVirtualFormats:
            case kAudioStreamPropertyAvailablePhysicalFormats: {
                AudioStreamRangedDescription d;
                fill_stream_asbd(&d.mFormat);
                d.mSampleRateRange.mMinimum = AA_SAMPLE_RATE;
                d.mSampleRateRange.mMaximum = AA_SAMPLE_RATE;
                *(AudioStreamRangedDescription *)outData = d;
                *outDataSize = sizeof(AudioStreamRangedDescription);
                return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Volume_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioLevelControlClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioVolumeControlClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioControlPropertyScope:
                *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeOutput; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioControlPropertyElement:
                *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioLevelControlPropertyScalarValue:
                *(Float32 *)outData = atomic_load(&gVolumeScalar); *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
            case kAudioLevelControlPropertyDecibelValue:
                *(Float32 *)outData = scalar_to_db(atomic_load(&gVolumeScalar)); *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
            case kAudioLevelControlPropertyDecibelRange: {
                AudioValueRange r = { -60.0, 0.0 };
                *(AudioValueRange *)outData = r; *outDataSize = sizeof(AudioValueRange); return kAudioHardwareNoError;
            }
            case kAudioLevelControlPropertyConvertScalarToDecibels: {
                Float32 v = *(Float32 *)outData;
                *(Float32 *)outData = scalar_to_db(v); *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
            }
            case kAudioLevelControlPropertyConvertDecibelsToScalar: {
                Float32 v = *(Float32 *)outData;
                *(Float32 *)outData = db_to_scalar(v); *outDataSize = sizeof(Float32); return kAudioHardwareNoError;
            }
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    if (inObjectID == kObjectID_Mute_Out) {
        switch (sel) {
            case kAudioObjectPropertyBaseClass:
                *(AudioClassID *)outData = kAudioBooleanControlClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyClass:
                *(AudioClassID *)outData = kAudioMuteControlClassID; *outDataSize = sizeof(AudioClassID); return kAudioHardwareNoError;
            case kAudioObjectPropertyOwner:
                *(AudioObjectID *)outData = kObjectID_Device; *outDataSize = sizeof(AudioObjectID); return kAudioHardwareNoError;
            case kAudioControlPropertyScope:
                *(AudioObjectPropertyScope *)outData = kAudioObjectPropertyScopeOutput; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioControlPropertyElement:
                *(AudioObjectPropertyElement *)outData = kAudioObjectPropertyElementMain; *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            case kAudioBooleanControlPropertyValue:
                *(UInt32 *)outData = atomic_load(&gMuted); *outDataSize = sizeof(UInt32); return kAudioHardwareNoError;
            default:
                return kAudioHardwareUnknownPropertyError;
        }
    }

    return kAudioHardwareBadObjectError;
}

static OSStatus AA_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                                   const AudioObjectPropertyAddress *inAddress, UInt32 inQualifierDataSize,
                                   const void *inQualifierData, UInt32 inDataSize, const void *inData) {
    (void)inDriver; (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (!inAddress || !inData) return kAudioHardwareIllegalOperationError;
    AudioObjectPropertySelector sel = inAddress->mSelector;

    if (inObjectID == kObjectID_Volume_Out && inDataSize >= sizeof(Float32)) {
        Float32 v = *(const Float32 *)inData;
        if (sel == kAudioLevelControlPropertyScalarValue) {
            if (v < 0.0f) v = 0.0f;
            if (v > 1.0f) v = 1.0f;
            atomic_store(&gVolumeScalar, v);
            return kAudioHardwareNoError;
        }
        if (sel == kAudioLevelControlPropertyDecibelValue) {
            atomic_store(&gVolumeScalar, db_to_scalar(v));
            return kAudioHardwareNoError;
        }
    } else if (inObjectID == kObjectID_Mute_Out && sel == kAudioBooleanControlPropertyValue && inDataSize >= sizeof(UInt32)) {
        atomic_store(&gMuted, (*(const UInt32 *)inData) ? 1 : 0);
        return kAudioHardwareNoError;
    } else if (inObjectID == kObjectID_Device && (sel == kAudioDevicePropertyNominalSampleRate || sel == kAudioDevicePropertyBufferFrameSize)) {
        return kAudioHardwareNoError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus AA_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    if (gIOActiveCount == 0) {
        gAnchorHostTime = mach_absolute_time();
        atomic_store(&gRingWrite, 0);
        atomic_store(&gRingRead, 0);
    }
    gIOActiveCount++;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus AA_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gStateLock);
    if (gIOActiveCount > 0) gIOActiveCount--;
    pthread_mutex_unlock(&gStateLock);
    return kAudioHardwareNoError;
}

static OSStatus AA_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    Float64 *outSampleTime, UInt64 *outHostTime, UInt64 *outSeed) {
    (void)inDriver; (void)inClientID;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    uint64_t now = mach_absolute_time();
    uint64_t elapsed = (now >= gAnchorHostTime) ? (now - gAnchorHostTime) : 0;
    uint64_t periods = (uint64_t)((double)elapsed / gHostTicksPerRing);
    *outSampleTime = (Float64)(periods * (uint64_t)AA_RING_FRAMES);
    *outHostTime = gAnchorHostTime + (uint64_t)((double)periods * gHostTicksPerRing);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus AA_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                     UInt32 inOperationID, Boolean *outWillDo, Boolean *outWillDoInPlace) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID;
    if (inOperationID == kAudioServerPlugInIOOperationWriteMix) {
        *outWillDo = true;
        *outWillDoInPlace = true;
    } else {
        *outWillDo = false;
        *outWillDoInPlace = true;
    }
    return kAudioHardwareNoError;
}

static OSStatus AA_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                    UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static OSStatus AA_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID,
                                 UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                 const AudioServerPlugInIOCycleInfo *inIOCycleInfo, void *ioMainBuffer, void *ioSecondaryBuffer) {
    (void)inDriver; (void)inDeviceObjectID; (void)inStreamObjectID; (void)inClientID; (void)inIOCycleInfo; (void)ioSecondaryBuffer;
    if (inOperationID != kAudioServerPlugInIOOperationWriteMix || !ioMainBuffer || inIOBufferFrameSize == 0) {
        return kAudioHardwareNoError;
    }

    float vol = atomic_load_explicit(&gMuted, memory_order_relaxed) ? 0.0f : atomic_load_explicit(&gVolumeScalar, memory_order_relaxed);
    const float *inF = (const float *)ioMainBuffer;
    int16_t pcm[AA_MAX_IO_FRAMES * AA_CHANNELS];
    UInt32 frames = inIOBufferFrameSize;
    if (frames > AA_MAX_IO_FRAMES) frames = AA_MAX_IO_FRAMES;
    UInt32 samples = frames * AA_CHANNELS;

    if (vol <= 0.0001f) {
        memset(pcm, 0, samples * sizeof(int16_t));
    } else {
        for (UInt32 i = 0; i < samples; i++) {
            float s = inF[i] * vol;
            if (s > 1.0f) s = 1.0f;
            else if (s < -1.0f) s = -1.0f;
            pcm[i] = (int16_t)(s * 32767.0f);
        }
    }
    ring_push((const uint8_t *)pcm, samples * (uint32_t)sizeof(int16_t));
    (void)gHasSignal;
    return kAudioHardwareNoError;
}

static OSStatus AA_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID,
                                  UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo *inIOCycleInfo) {
    (void)inDriver; (void)inDeviceObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    return kAudioHardwareNoError;
}

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    AA_QueryInterface,
    AA_AddRef,
    AA_Release,
    AA_Initialize,
    AA_CreateDevice,
    AA_DestroyDevice,
    AA_AddDeviceClient,
    AA_RemoveDeviceClient,
    AA_PerformDeviceConfigurationChange,
    AA_AbortDeviceConfigurationChange,
    AA_HasProperty,
    AA_IsPropertySettable,
    AA_GetPropertyDataSize,
    AA_GetPropertyData,
    AA_SetPropertyData,
    AA_StartIO,
    AA_StopIO,
    AA_GetZeroTimeStamp,
    AA_WillDoIOOperation,
    AA_BeginIOOperation,
    AA_DoIOOperation,
    AA_EndIOOperation
};

__attribute__((visibility("default")))
void *AndroidAudio_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) {
        gRefCount++;
        return &gDriverInterfacePtr;
    }
    return NULL;
}
