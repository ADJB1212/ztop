#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
#include <math.h>
#include <mach/mach.h>

typedef struct IOReportSubscriptionRef *IOReportSubscriptionRef;

enum {
    kKtopIOReportFormatInvalid     = 0,
    kKtopIOReportFormatSimple      = 1,
    kKtopIOReportFormatState       = 2,
    kKtopIOReportFormatSimpleArray = 4,
};

enum {
    kKtopIOReportIterOk      = 0,
    kKtopIOReportIterFailed  = 1,
    kKtopIOReportIterSkipped = 2,
};

extern CFMutableDictionaryRef IOReportCopyAllChannels(uint64_t a, uint64_t b);
extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern void IOReportMergeChannels(CFMutableDictionaryRef dst, CFMutableDictionaryRef src, CFTypeRef nullPtr);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *a, CFMutableDictionaryRef desiredChannels, CFMutableDictionaryRef *subbedChannels, uint64_t channelID, CFTypeRef b);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef sub, CFMutableDictionaryRef subbedChannels, CFTypeRef a);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef prev, CFDictionaryRef current, CFTypeRef a);

typedef int (^ioreportiterateblock)(CFDictionaryRef channel);
extern void IOReportIterate(CFDictionaryRef samples, ioreportiterateblock block);

extern CFStringRef IOReportChannelGetGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetSubGroup(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern int IOReportChannelGetFormat(CFDictionaryRef channel);
extern long IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int index);

typedef struct {
    uint32_t key;
    struct {
        uint8_t major;
        uint8_t minor;
        uint8_t build;
        uint8_t reserved;
        uint16_t release;
    } __attribute__((packed)) vers;
    uint16_t pad1;
    struct {
        uint16_t version;
        uint16_t length;
        uint32_t cpuPLimit;
        uint32_t gpuPLimit;
        uint32_t memPLimit;
    } __attribute__((packed)) pLimitData;
    struct {
        uint32_t dataSize;
        uint32_t dataType;
        uint8_t dataAttributes;
    } __attribute__((packed)) keyInfo;
    uint8_t pad2;
    uint16_t padding;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint8_t pad3;
    uint32_t data32;
    uint8_t bytes[32];
} __attribute__((packed)) SMCKeyData_t;

static uint32_t four_char_code(const char *str) {
    if (!str) return 0;
    uint32_t code = 0;
    for (int i = 0; i < 4 && str[i]; i++) {
        code = (code << 8) | (uint8_t)str[i];
    }
    return code;
}

typedef struct {
    uint32_t key_code;
    uint32_t data_size;
    uint32_t data_type;
    bool checked;
    bool valid;
} smc_key_info_cache_t;

#define SMC_KEY_CACHE_MAX 32
static smc_key_info_cache_t s_smc_cache[SMC_KEY_CACHE_MAX];
static size_t s_smc_cache_count = 0;

static smc_key_info_cache_t *get_smc_key_cache_entry(uint32_t key_code) {
    for (size_t i = 0; i < s_smc_cache_count; i++) {
        if (s_smc_cache[i].key_code == key_code) {
            return &s_smc_cache[i];
        }
    }
    if (s_smc_cache_count < SMC_KEY_CACHE_MAX) {
        smc_key_info_cache_t *entry = &s_smc_cache[s_smc_cache_count++];
        entry->key_code = key_code;
        entry->checked = false;
        entry->valid = false;
        return entry;
    }
    return NULL;
}

bool ztop_smc_decode(uint32_t data_type, const uint8_t *bytes, uint32_t size, double *out_val);

static bool smc_read_double(io_connect_t conn, const char *key, double *out_val) {
    if (!conn || !key || !out_val) return false;
    uint32_t key_code = four_char_code(key);
    smc_key_info_cache_t *cached = get_smc_key_cache_entry(key_code);
    if (cached && cached->checked && !cached->valid) {
        return false;
    }

    uint32_t data_size = 0;
    uint32_t data_type = 0;

    if (cached && cached->checked && cached->valid) {
        data_size = cached->data_size;
        data_type = cached->data_type;
    } else {
        SMCKeyData_t input;
        SMCKeyData_t output;
        memset(&input, 0, sizeof(input));
        memset(&output, 0, sizeof(output));

        input.key = key_code;
        input.data8 = 9; // cmdReadKeyInfo

        size_t output_size = sizeof(output);
        kern_return_t res = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &output_size);
        if (res != kIOReturnSuccess || output.result != 0 || output.keyInfo.dataSize == 0 || output.keyInfo.dataSize > 32) {
            if (cached) {
                cached->checked = true;
                cached->valid = false;
            }
            return false;
        }

        data_size = output.keyInfo.dataSize;
        data_type = output.keyInfo.dataType;
        if (cached) {
            cached->checked = true;
            cached->valid = true;
            cached->data_size = data_size;
            cached->data_type = data_type;
        }
    }

    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key_code;
    input.keyInfo.dataSize = data_size;
    input.data8 = 5; // cmdReadBytes

    size_t output_size = sizeof(output);
    kern_return_t res = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &output_size);
    if (res != kIOReturnSuccess || output.result != 0) {
        return false;
    }

    return ztop_smc_decode(data_type, output.bytes, data_size, out_val);
}

bool ztop_smc_decode(uint32_t data_type, const uint8_t *b, uint32_t size, double *out_val) {
    if (!b || !out_val || size > 32) return false;
    uint32_t required = 2;
    if (data_type == four_char_code("ui8 ") || data_type == four_char_code("si8 ")) required = 1;
    else if (data_type == four_char_code("ui32") || data_type == four_char_code("flt ")) required = 4;
    else if (data_type == four_char_code("ioft")) required = 8;
    if (size < required) return false;
    if (data_type == four_char_code("ui8 ")) {
        *out_val = (double)b[0];
        return true;
    } else if (data_type == four_char_code("ui16")) {
        *out_val = (double)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
        return true;
    } else if (data_type == four_char_code("ui32")) {
        *out_val = (double)(((uint32_t)b[0] << 24) | ((uint32_t)b[1] << 16) | ((uint32_t)b[2] << 8) | (uint32_t)b[3]);
        return true;
    } else if (data_type == four_char_code("flt ")) {
        float f = 0.0f;
        memcpy(&f, b, sizeof(float));
        *out_val = (double)f;
        return isfinite(*out_val);
    } else if (data_type == four_char_code("fpe2")) {
        *out_val = (double)(((uint16_t)b[0] << 8) | b[1]) / 4.0;
        return true;
    } else if (data_type == four_char_code("sp78")) {
        int16_t val = (int16_t)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
        *out_val = (double)val / 256.0;
        return true;
    } else if (data_type == four_char_code("sp87")) {
        int16_t val = (int16_t)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
        *out_val = (double)val / 128.0;
        return true;
    } else if (data_type == four_char_code("si16")) {
        int16_t val = (int16_t)(((uint16_t)b[0] << 8) | (uint16_t)b[1]);
        *out_val = (double)val;
        return true;
    } else if (data_type == four_char_code("si8 ")) {
        *out_val = (double)((int8_t)b[0]);
        return true;
    } else if (data_type == four_char_code("ioft")) {
        uint64_t bits = 0;
        for (unsigned i = 0; i < 8; i++) bits |= (uint64_t)b[i] << (8 * i);
        int64_t raw;
        memcpy(&raw, &bits, sizeof(raw));
        *out_val = (double)raw / 65536.0;
        return true;
    }
    return false;
}



typedef struct {
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed_channels;
    io_connect_t smc_conn;
} ztop_power_state_t;

typedef struct {
    uint64_t rails[4];
    uint64_t gpu_nanojoules;
    double soc_watts;
    uint32_t rail_mask;
    uint32_t gpu_valid;
    uint32_t soc_valid;
    uint32_t rail_sources;
} ztop_power_reading_t;

void *ztop_power_init(void) {
    ztop_power_state_t *state = (ztop_power_state_t *)calloc(1, sizeof(ztop_power_state_t));
    if (!state) return NULL;

    @autoreleasepool {
        CFMutableDictionaryRef energy = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
        CFMutableDictionaryRef pmp = IOReportCopyChannelsInGroup(CFSTR("PMP"), CFSTR("Energy Counters"), 0, 0, 0);

        CFMutableDictionaryRef channels = NULL;
        if (energy && pmp) {
            IOReportMergeChannels(energy, pmp, NULL);
            channels = energy;
            CFRelease(pmp);
        } else if (energy) {
            channels = energy;
        } else if (pmp) {
            channels = pmp;
        }

        if (channels) {
            CFMutableDictionaryRef subbed = NULL;
            IOReportSubscriptionRef sub = IOReportCreateSubscription(NULL, channels, &subbed, 0, NULL);
            CFRelease(channels);

            if (sub && subbed) {
                state->sub = sub;
                state->subbed_channels = subbed;
            } else {
                if (sub) CFRelease((CFTypeRef)sub);
                if (subbed) CFRelease(subbed);
            }
        }

        CFMutableDictionaryRef matching = IOServiceMatching("AppleSMC");
        if (matching) {
            io_iterator_t iterator = 0;
            if (IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == kIOReturnSuccess) {
                io_object_t device = IOIteratorNext(iterator);
                IOObjectRelease(iterator);
                if (device != 0) {
                    IOServiceOpen(device, mach_task_self(), 0, &state->smc_conn);
                    IOObjectRelease(device);
                }
            }
        }
    }

    if (!state->sub && !state->smc_conn) {
        free(state);
        return NULL;
    }

    return state;
}

ztop_power_reading_t ztop_power_sample(void *handle) {
    ztop_power_reading_t result = {0};
    if (!handle) return result;
    ztop_power_state_t *state = (ztop_power_state_t *)handle;

    @autoreleasepool {
        if (state->sub && state->subbed_channels) {
            CFDictionaryRef current = IOReportCreateSamples(state->sub, state->subbed_channels, NULL);
            if (current) {
                uint64_t em_values[4] = {0}, pmp_values[4] = {0};
                uint64_t *em = em_values, *pmp = pmp_values;
                __block uint64_t clusters = 0;
                __block uint32_t em_mask = 0, pmp_mask = 0;
                __block bool saw_clusters = false;
                __block uint64_t gpu_nj = 0;
                __block bool gpu_valid = false;
                IOReportIterate(current, ^(CFDictionaryRef channel) {
                    if (IOReportChannelGetFormat(channel) != kKtopIOReportFormatSimple) return (int)kKtopIOReportIterOk;
                    CFStringRef group_ref = IOReportChannelGetGroup(channel);
                    CFStringRef name_ref = IOReportChannelGetChannelName(channel);
                    if (!group_ref || !name_ref) return (int)kKtopIOReportIterOk;
                    char group[128] = {0}, name[128] = {0};
                    if (!CFStringGetCString(group_ref, group, sizeof(group), kCFStringEncodingUTF8) ||
                        !CFStringGetCString(name_ref, name, sizeof(name), kCFStringEncodingUTF8)) return (int)kKtopIOReportIterOk;
                    long raw = IOReportSimpleGetIntegerValue(channel, 0);
                    if (raw < 0) return (int)kKtopIOReportIterOk;
                    uint64_t energy = (uint64_t)raw;
                    int domain = -1;
                    if (strcmp(group, "Energy Model") == 0) {
                        if (strcmp(name, "GPU Energy") == 0) {
                            gpu_nj += energy;
                            gpu_valid = true;
                        } else if (strcmp(name, "CPU Energy") == 0) domain = 0;
                        else {
                            size_t len = strlen(name);
                            if (len >= 4 && strcmp(name + len - 4, "_CPU") == 0 &&
                                (strncmp(name, "EACC", 4) == 0 || strncmp(name, "PACC", 4) == 0)) {
                                clusters += energy;
                                saw_clusters = true;
                            } else if (strncmp(name, "GPU", 3) == 0) domain = 1;
                            else if (strncmp(name, "ANE", 3) == 0) domain = 2;
                            else if (strncmp(name, "DRAM", 4) == 0) domain = 3;
                        }
                        if (domain >= 0) {
                            em[domain] += energy;
                            em_mask |= 1u << domain;
                        }
                    } else if (strcmp(group, "PMP") == 0) {
                        CFStringRef sub_ref = IOReportChannelGetSubGroup(channel);
                        char subgroup[128] = {0};
                        if (sub_ref) CFStringGetCString(sub_ref, subgroup, sizeof(subgroup), kCFStringEncodingUTF8);
                        if (strcmp(subgroup, "Energy Counters") == 0) {
                            if (strcmp(name, "ECPU") == 0 || strcmp(name, "PCPU") == 0) domain = 0;
                            else if (strcmp(name, "GPU") == 0 || strcmp(name, "GPU SRAM") == 0) domain = 1;
                            else if (strcmp(name, "ANE") == 0) domain = 2;
                            else if (strcmp(name, "DRAM") == 0) domain = 3;
                            if (domain >= 0) {
                                pmp[domain] += energy;
                                pmp_mask |= 1u << domain;
                            }
                        }
                    }
                    return (int)kKtopIOReportIterOk;
                });
                CFRelease(current);
                if (!(em_mask & 1) && saw_clusters) {
                    em[0] = clusters;
                    em_mask |= 1;
                }
                for (unsigned i = 0; i < 4; i++) {
                    uint32_t bit = 1u << i;
                    if (em_mask & bit) {
                        result.rails[i] = em[i];
                        result.rail_mask |= bit;
                        result.rail_sources |= bit;
                    } else if (pmp_mask & bit) {
                        result.rails[i] = pmp[i];
                        result.rail_mask |= bit;
                    }
                }
                result.gpu_nanojoules = gpu_nj;
                result.gpu_valid = gpu_valid;
            }
        }
        double pstr = 0;
        if (smc_read_double(state->smc_conn, "PSTR", &pstr) && pstr >= 0 && isfinite(pstr)) {
            result.soc_watts = pstr;
            result.soc_valid = 1;
        }
    }
    return result;
}
void ztop_power_deinit(void *handle) {
    if (!handle) return;
    ztop_power_state_t *state = (ztop_power_state_t *)handle;
    @autoreleasepool {
        if (state->subbed_channels) CFRelease(state->subbed_channels);
        if (state->sub) CFRelease((CFTypeRef)state->sub);
        if (state->smc_conn != 0) IOServiceClose(state->smc_conn);
    }
    free(state);
}

double ztop_smc_read_temperature(void *handle, const char *key) {
    if (!handle || !key) return 0.0;
    ztop_power_state_t *state = (ztop_power_state_t *)handle;
    if (state->smc_conn == 0) return 0.0;
    double val = 0.0;
    if (smc_read_double(state->smc_conn, key, &val)) {
        if (val > 5.0 && val < 130.0) return val;
    }
    return 0.0;
}
