#include "Sensors.h"
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>
#include <sys/sysctl.h>
#include <net/if.h>
#include <net/route.h>
#include <spawn.h>
#include <poll.h>
#include <signal.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>
#include <sys/wait.h>

// Foundation's Process costs ~70 ms per launch on this Mac; posix_spawn keeps the
// fixed system netstat call in single-digit milliseconds. No shell, 2 s deadline.
long mp_netstat(char *buffer, size_t capacity) {
    int fds[2];
    if (pipe(fds) != 0) return -1;
    posix_spawn_file_actions_t actions;
    posix_spawn_file_actions_init(&actions);
    posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO);
    posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_addopen(&actions, STDERR_FILENO, "/dev/null", O_WRONLY, 0);
    posix_spawnattr_t attributes;
    posix_spawnattr_init(&attributes);
    posix_spawnattr_setflags(&attributes, POSIX_SPAWN_CLOEXEC_DEFAULT);
    char *argv[] = { "/usr/sbin/netstat", "-ibn", NULL };
    char *envp[] = { "LC_ALL=C", "LANG=C", NULL };
    pid_t pid = 0;
    int spawned = posix_spawn(&pid, argv[0], &actions, &attributes, argv, envp);
    posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    close(fds[1]);
    if (spawned != 0) { close(fds[0]); return -1; }
    struct timespec start, now;
    clock_gettime(CLOCK_MONOTONIC, &start);
    size_t length = 0; int ok = 1;
    for (;;) {
        clock_gettime(CLOCK_MONOTONIC, &now);
        long remaining = 2000 - ((now.tv_sec - start.tv_sec) * 1000 + (now.tv_nsec - start.tv_nsec) / 1000000);
        struct pollfd ready = { fds[0], POLLIN, 0 };
        if (remaining <= 0 || length >= capacity) { ok = 0; break; }
        int polled = poll(&ready, 1, (int)remaining);
        if (polled < 0 && errno == EINTR) continue;
        if (polled <= 0) { ok = 0; break; }
        ssize_t count = read(fds[0], buffer + length, capacity - length);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = 0; break; }
        if (count == 0) break;
        length += (size_t)count;
    }
    close(fds[0]);
    if (!ok) kill(pid, SIGKILL);
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {}
    return ok && WIFEXITED(status) && WEXITSTATUS(status) == 0 ? (long)length : -1;
}

// getifaddrs exposes 32-bit byte counters on macOS, which wrap quickly on
// fast links. NET_RT_IFLIST2 supplies the full 64-bit interface counters.
int mp_network_counters(const char *name, uint64_t *received, uint64_t *sent) {
    unsigned index = if_nametoindex(name);
    if (!index) return 0;
    int mib[6] = { CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, (int)index };
    size_t length = 0;
    if (sysctl(mib, 6, NULL, &length, NULL, 0) != 0 || !length) return 0;
    char *buffer = malloc(length);
    if (!buffer) return 0;
    if (sysctl(mib, 6, buffer, &length, NULL, 0) != 0) { free(buffer); return 0; }
    int found = 0;
    for (size_t offset = 0; offset + sizeof(struct if_msghdr) <= length;) {
        struct if_msghdr *header = (void *)(buffer + offset);
        if (!header->ifm_msglen || offset + header->ifm_msglen > length) break;
        if (header->ifm_type == RTM_IFINFO2 && header->ifm_msglen >= sizeof(struct if_msghdr2)) {
            struct if_msghdr2 *entry = (void *)header;
            if (entry->ifm_index == index) {
                *received = entry->ifm_data.ifi_ibytes;
                *sent = entry->ifm_data.ifi_obytes;
                found = 1; break;
            }
        }
        offset += header->ifm_msglen;
    }
    free(buffer); return found;
}

// AppleSMC user-client wire format. Only read operations are exposed.
typedef struct {
    uint32_t key;
    uint8_t version[6];
    uint8_t pad[2];
    uint32_t limits[4];
    uint32_t size, type;
    uint8_t attributes, padding[3];
    uint8_t result, status, command, alignment;
    uint32_t index;
    uint8_t bytes[32];
} Packet;
_Static_assert(sizeof(Packet) == 80, "SMC packet ABI");
static uint32_t code(const char *s) {
    return (uint32_t)(uint8_t)s[0]<<24 | (uint32_t)(uint8_t)s[1]<<16 |
           (uint32_t)(uint8_t)s[2]<<8 | (uint8_t)s[3];
}
static int call(uint32_t c, Packet *in, Packet *out) {
    size_t size = sizeof(*out);
    memset(out, 0, size);
    return IOConnectCallStructMethod(c, 2, in, sizeof(*in), out, &size) == KERN_SUCCESS && !out->result;
}
uint32_t mp_smc_open(void) {
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return 0;
    io_connect_t connection = 0;
    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, &connection);
    IOObjectRelease(service);
    return result == KERN_SUCCESS ? connection : 0;
}
void mp_smc_close(uint32_t c) { if (c) IOServiceClose(c); }
int mp_smc_key(uint32_t c, uint32_t index, char *key) {
    Packet in = {0}, out;
    in.command = 8; in.index = index;
    if (!call(c, &in, &out)) return 0;
    for (int i=0; i<4; i++) key[i] = (char)(out.key >> (24-8*i));
    key[4]=0; return 1;
}
// Key type and size never change while the connection is open; callers cache them
// so each periodic read is one IOKit round trip instead of two.
int mp_smc_info(uint32_t c, const char *key, uint32_t *type, uint32_t *size) {
    if (!c || strlen(key)!=4) return 0;
    Packet in = {0}, info;
    in.key=code(key); in.command=9;
    if (!call(c, &in, &info) || info.size==0 || info.size>32) return 0;
    *type=info.type; *size=info.size; return 1;
}
int mp_smc_read_info(uint32_t c, const char *key, uint32_t type, uint32_t size, double *value) {
    if (!c || strlen(key)!=4 || size==0 || size>32) return 0;
    Packet in = {0}, out;
    in.key=code(key); in.size=size; in.command=5;
    if (!call(c, &in, &out)) return 0;
    uint8_t *b=out.bytes;
    uint16_t u=((uint16_t)b[0]<<8)|b[1];
    if (type==code("flt ") && size==4) {
        float f; memcpy(&f, b, 4); *value=f;
    } else if (type==code("sp78")) *value=(int16_t)u/256.0;
    else if (type==code("fpe2")) *value=u/4.0;
    else if (type==code("ui8 ")) *value=b[0];
    else if (type==code("ui16")) *value=u;
    else if (type==code("ui32")) *value=(uint32_t)b[0]<<24|(uint32_t)b[1]<<16|(uint32_t)b[2]<<8|b[3];
    else return 0;
    return isfinite(*value);
}
int mp_smc_read(uint32_t c, const char *key, double *value) {
    uint32_t type, size;
    return mp_smc_info(c, key, &type, &size) && mp_smc_read_info(c, key, type, size, value);
}

// AppleCLPC energy counters (macOS 27). The IOReport "Energy Model" channels still exist but
// stop updating without a private entitlement; CLPC keeps aggregate CPU/GPU/ANE energy in nJ
// under opaque report IDs. The per-driver key table and descriptor layout follow macmon
// (github.com/vladkens/macmon), extracted from macOS 27.0 / 27.0.1. Read-only.
// macmon: Copyright (c) 2024 vladkens, MIT License.
typedef struct IOReportSubscription *IOReportSubscriptionRef;
extern IOReportSubscriptionRef IOReportCreateSubscription(void *, CFMutableDictionaryRef, CFMutableDictionaryRef *, uint64_t, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef, CFMutableDictionaryRef, CFTypeRef);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef, CFDictionaryRef, CFTypeRef);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef, int32_t);
extern uint64_t IOReportChannelGetChannelID(CFDictionaryRef);

static const struct { const char *bundle; uint32_t cpu, gpu, ane; } clpc_keys[] = {
    { "com.apple.driver.AppleT6000CLPCv3", 0x47479059, 0x4519bf1e, 0x9aaa17f8 },
    { "com.apple.driver.AppleT6002CLPC",   0xb501816b, 0x9e2c3e8b, 0x14d5a574 },
    { "com.apple.driver.AppleT6020CLPC",   0xe301cd75, 0x8f34cc7a, 0x7415fb0f },
    { "com.apple.driver.AppleT6022CLPC",   0x76f5fd21, 0x90624499, 0x3c097307 },
    { "com.apple.driver.AppleT6030CLPC",   0xbe03a01a, 0x472d6c9c, 0xb8990c38 },
    { "com.apple.driver.AppleT6031CLPC",   0xd81e0084, 0x1085f98b, 0x313a3be1 },
    { "com.apple.driver.AppleT6032CLPC",   0xf4a21308, 0x85e80513, 0x63dc8e25 },
    { "com.apple.driver.AppleT6041CLPC",   0x263cf1f0, 0x22e4cf59, 0x7849fb5c },
    { "com.apple.driver.AppleT6050CLPC",   0xd3ab60bb, 0x27cd4ce5, 0x8c0f1c59 },
    { "com.apple.driver.AppleT6050dCLPC",  0x18b3010e, 0xedeca11a, 0x188bd883 },
    { "com.apple.driver.AppleT8103CLPCv3", 0x2cdd31f2, 0x21becf42, 0x0667fb81 },
    { "com.apple.driver.AppleT8112CLPC",   0xb5435137, 0x638d9d52, 0xea089c36 },
    { "com.apple.driver.AppleT8122CLPC",   0x54b51c99, 0xce2dd9dc, 0x960afe2f },
    { "com.apple.driver.AppleT8132CLPC",   0x4a854d94, 0x3b3e3b79, 0x1ff4a9ec },
    { "com.apple.driver.AppleT8140CLPC",   0x9bf54436, 0xef70589c, 0x569d941b },
    { "com.apple.driver.AppleT8142CLPC",   0x43708744, 0x6a010933, 0xbc5efdf0 },
    { "com.apple.driver.AppleT8152CLPC",   0x485d4bfc, 0x11784654, 0x9380c6bb },
};
static const uint32_t clpc_index[3] = { 16, 25, 24 }; // cpu, gpu, ane table indices on macOS 27

static IOReportSubscriptionRef power_subscription;
static CFMutableDictionaryRef power_channels;
static CFDictionaryRef power_previous;
static uint32_t power_keys[8][3];
static int power_key_count;

static CFNumberRef number64(int64_t value) { return CFNumberCreate(NULL, kCFNumberSInt64Type, &value); }
static CFMutableDictionaryRef clpc_channel(uint64_t driver, uint64_t id, CFStringRef name) {
    // IOReportTypes.h: simple integer, power category, one element; unit nJ.
    CFNumberRef idn = number64((int64_t)id), type = number64(1 | (2LL << 16) | (1LL << 32));
    CFNumberRef unit = number64((3LL << 56) | (118LL << 32)), drv = number64((int64_t)driver);
    const void *legendValues[] = { idn, type, name };
    CFArrayRef legend = CFArrayCreate(NULL, legendValues, 3, &kCFTypeArrayCallBacks);
    const void *infoKeys[] = { CFSTR("IOReportChannelUnit") }, *infoValues[] = { unit };
    CFDictionaryRef info = CFDictionaryCreate(NULL, infoKeys, infoValues, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    const void *keys[] = { CFSTR("DriverID"), CFSTR("DriverName"), CFSTR("IOReportGroupName"), CFSTR("IOReportSubGroupName"), CFSTR("IOReportChannelInfo"), CFSTR("LegendChannel") };
    const void *values[] = { drv, CFSTR("AppleCLPC"), CFSTR("CLPC"), CFSTR("Energy Counters"), info, legend };
    CFMutableDictionaryRef channel = CFDictionaryCreateMutable(NULL, 6, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    for (int i = 0; i < 6; i++) CFDictionarySetValue(channel, keys[i], values[i]);
    CFRelease(idn); CFRelease(type); CFRelease(unit); CFRelease(drv); CFRelease(legend); CFRelease(info);
    return channel;
}

void mp_power_close(void) {
    if (power_previous) CFRelease(power_previous);
    if (power_channels) CFRelease(power_channels);
    if (power_subscription) CFRelease(power_subscription);
    power_previous = NULL; power_channels = NULL; power_subscription = NULL; power_key_count = 0;
}

int mp_power_open(void) {
    mp_power_close();
    char version[32] = ""; size_t length = sizeof(version);
    if (sysctlbyname("kern.osproductversion", version, &length, NULL, 0) != 0 || strncmp(version, "27.", 3) != 0) return 0;
    io_iterator_t iterator = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) != KERN_SUCCESS) return 0;
    CFMutableArrayRef selected = CFArrayCreateMutable(NULL, 0, &kCFTypeArrayCallBacks);
    io_object_t service;
    while ((service = IOIteratorNext(iterator)) && power_key_count < 8) {
        uint64_t driver = 0;
        CFTypeRef bundle = IORegistryEntryCreateCFProperty(service, CFSTR("CFBundleIdentifier"), NULL, 0);
        char name[96] = "";
        if (bundle && CFGetTypeID(bundle) == CFStringGetTypeID()) CFStringGetCString(bundle, name, sizeof(name), kCFStringEncodingUTF8);
        if (bundle) CFRelease(bundle);
        int found = IORegistryEntryGetRegistryEntryID(service, &driver) == KERN_SUCCESS;
        IOObjectRelease(service);
        for (size_t k = 0; found && k < sizeof(clpc_keys) / sizeof(clpc_keys[0]); k++) {
            if (strcmp(name, clpc_keys[k].bundle) != 0) continue;
            uint32_t ids[3] = { clpc_keys[k].cpu, clpc_keys[k].gpu, clpc_keys[k].ane };
            CFStringRef labels[3] = { CFSTR("CPU Energy"), CFSTR("GPU Energy"), CFSTR("ANE") };
            for (int i = 0; i < 3; i++) {
                CFMutableDictionaryRef channel = clpc_channel(driver, ((uint64_t)clpc_index[i] << 32) | ids[i], labels[i]);
                CFArrayAppendValue(selected, channel); CFRelease(channel);
                power_keys[power_key_count][i] = ids[i];
            }
            power_key_count++;
        }
    }
    IOObjectRelease(iterator);
    if (!power_key_count) { CFRelease(selected); return 0; }
    power_channels = CFDictionaryCreateMutable(NULL, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFDictionarySetValue(power_channels, CFSTR("IOReportChannels"), selected);
    CFRelease(selected);
    CFMutableDictionaryRef subscribed = NULL;
    power_subscription = IOReportCreateSubscription(NULL, power_channels, &subscribed, 0, NULL);
    if (!power_subscription || !subscribed) { mp_power_close(); return 0; }
    CFRelease(power_channels); power_channels = subscribed;
    power_previous = IOReportCreateSamples(power_subscription, power_channels, NULL);
    if (!power_previous) { mp_power_close(); return 0; }
    return 1;
}

// Joules used since the previous call; the first call after open only primes the baseline.
int mp_power_sample(double *cpu, double *gpu, double *ane) {
    *cpu = *gpu = *ane = 0;
    if (!power_subscription || !power_previous) return 0;
    CFDictionaryRef current = IOReportCreateSamples(power_subscription, power_channels, NULL);
    if (!current) return 0;
    CFDictionaryRef delta = IOReportCreateSamplesDelta(power_previous, current, NULL);
    CFRelease(power_previous); power_previous = current;
    if (!delta) return 0;
    CFArrayRef items = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
    double *targets[3] = { cpu, gpu, ane };
    int matched = 0;
    for (CFIndex i = 0; items && i < CFArrayGetCount(items); i++) {
        CFDictionaryRef item = CFArrayGetValueAtIndex(items, i);
        uint32_t id = (uint32_t)IOReportChannelGetChannelID(item);
        int64_t nanojoules = IOReportSimpleGetIntegerValue(item, 0);
        for (int d = 0; d < power_key_count; d++) for (int k = 0; k < 3; k++) {
            if (id == power_keys[d][k] && nanojoules >= 0) { *targets[k] += nanojoules / 1e9; matched++; }
        }
    }
    CFRelease(delta);
    return matched > 0;
}
