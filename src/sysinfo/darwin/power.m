#import <Foundation/Foundation.h>
#import <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>
#include <stdlib.h>
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

static bool smc_read_double(io_connect_t conn, const char *key, double *out_val) {
    if (!conn || !key || !out_val) return false;
    SMCKeyData_t input;
    SMCKeyData_t output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));

    input.key = four_char_code(key);
    input.data8 = 9; // cmdReadKeyInfo

    size_t output_size = sizeof(output);
    kern_return_t res = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &output_size);
    if (res != kIOReturnSuccess || output.keyInfo.dataSize == 0) {
        printf("SMC [%s] readKeyInfo failed: res=0x%x, dataSize=%u\n", key, res, output.keyInfo.dataSize);
        return false;
    }

    uint32_t data_size = output.keyInfo.dataSize;
    uint32_t data_type = output.keyInfo.dataType;

    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = four_char_code(key);
    input.keyInfo.dataSize = data_size;
    input.data8 = 5; // cmdReadBytes

    output_size = sizeof(output);
    res = IOConnectCallStructMethod(conn, 2, &input, sizeof(input), &output, &output_size);
    if (res != kIOReturnSuccess) {
        printf("SMC [%s] readBytes failed: res=0x%x\n", key, res);
        return false;
    }

    uint8_t *b = output.bytes;
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
        return true;
    } else if (data_type == four_char_code("fpe2")) {
        *out_val = (double)(((int)b[0] << 6) + ((int)b[1] >> 2));
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
    }
    return false;
}



typedef struct {
    IOReportSubscriptionRef sub;
    CFMutableDictionaryRef subbed_channels;
    CFDictionaryRef prev_samples;
    io_connect_t smc_conn;
} ztop_power_state_t;

typedef struct {
    double soc_watts;
    double cpu_watts;
    double gpu_watts;
    double ane_watts;
    double dram_watts;
    int32_t is_valid;
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
                state->prev_samples = IOReportCreateSamples(sub, subbed, NULL);
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

ztop_power_reading_t ztop_power_sample(void *handle, double elapsed_seconds) {
    ztop_power_reading_t result = {0.0, 0.0, 0.0, 0.0, 0.0, 0};
    if (!handle) return result;
    ztop_power_state_t *state = (ztop_power_state_t *)handle;

    @autoreleasepool {
        if (state->sub && state->subbed_channels) {
            CFDictionaryRef current = IOReportCreateSamples(state->sub, state->subbed_channels, NULL);
            if (current) {
                if (!state->prev_samples || elapsed_seconds <= 0.0001) {
                    if (state->prev_samples) CFRelease(state->prev_samples);
                    state->prev_samples = current;
                } else {
                    CFDictionaryRef delta = IOReportCreateSamplesDelta(state->prev_samples, current, NULL);
                    CFRelease(state->prev_samples);
                    state->prev_samples = current;

                    if (delta) {
                        __block double cpu_w = 0.0, gpu_w = 0.0, ane_w = 0.0, dram_w = 0.0;
                        __block double ecpu_w = 0.0, pcpu_w = 0.0;
                        __block double pmp_ecpu = 0.0, pmp_pcpu = 0.0, pmp_gpu = 0.0, pmp_ane = 0.0, pmp_dram = 0.0;
                        __block bool saw_em_ane = false;

                        IOReportIterate(delta, ^(CFDictionaryRef channel) {
                            if (IOReportChannelGetFormat(channel) != kKtopIOReportFormatSimple) {
                                return (int)kKtopIOReportIterOk;
                            }
                            CFStringRef group_ref = IOReportChannelGetGroup(channel);
                            CFStringRef name_ref = IOReportChannelGetChannelName(channel);
                            if (!group_ref || !name_ref) return (int)kKtopIOReportIterOk;

                            char group[128] = {0};
                            char name[128] = {0};
                            CFStringGetCString(group_ref, group, sizeof(group), kCFStringEncodingUTF8);
                            CFStringGetCString(name_ref, name, sizeof(name), kCFStringEncodingUTF8);

                            long raw_val = IOReportSimpleGetIntegerValue(channel, 0);
                            double watts = ((double)raw_val / elapsed_seconds) / 1000.0;

                            if (strcmp(group, "Energy Model") == 0) {
                                if (strcmp(name, "CPU Energy") == 0) {
                                    cpu_w += watts;
                                } else {
                                    size_t len = strlen(name);
                                    if (len >= 4 && strcmp(name + len - 4, "_CPU") == 0) {
                                        if (strncmp(name, "EACC", 4) == 0) ecpu_w += watts;
                                        else if (strncmp(name, "PACC", 4) == 0) pcpu_w += watts;
                                    } else if (strncmp(name, "GPU", 3) == 0 && strcmp(name, "GPU Energy") != 0) {
                                        gpu_w += watts;
                                    } else if (strncmp(name, "ANE", 3) == 0) {
                                        ane_w += watts;
                                        saw_em_ane = true;
                                    } else if (strncmp(name, "DRAM", 4) == 0) {
                                        dram_w += watts;
                                    }
                                }
                            } else if (strcmp(group, "PMP") == 0) {
                                CFStringRef sub_ref = IOReportChannelGetSubGroup(channel);
                                char subgroup[128] = {0};
                                if (sub_ref) {
                                    CFStringGetCString(sub_ref, subgroup, sizeof(subgroup), kCFStringEncodingUTF8);
                                }
                                if (strcmp(subgroup, "Energy Counters") == 0) {
                                    if (strcmp(name, "ANE") == 0) pmp_ane += watts;
                                    else if (strcmp(name, "GPU") == 0 || strcmp(name, "GPU SRAM") == 0) pmp_gpu += watts;
                                    else if (strcmp(name, "DRAM") == 0) pmp_dram += watts;
                                    else if (strcmp(name, "ECPU") == 0) pmp_ecpu += watts;
                                    else if (strcmp(name, "PCPU") == 0) pmp_pcpu += watts;
                                }
                            }
                            return (int)kKtopIOReportIterOk;
                        });

                        CFRelease(delta);

                        if (!saw_em_ane) {
                            ane_w = pmp_ane;
                            gpu_w = pmp_gpu;
                            dram_w = pmp_dram;
                            ecpu_w = pmp_ecpu;
                            pcpu_w = pmp_pcpu;
                            if (cpu_w == 0.0) cpu_w = pmp_ecpu + pmp_pcpu;
                        }
                        if (cpu_w == 0.0 && (ecpu_w > 0.0 || pcpu_w > 0.0)) {
                            cpu_w = ecpu_w + pcpu_w;
                        }

                        result.cpu_watts = cpu_w;
                        result.gpu_watts = gpu_w;
                        result.ane_watts = ane_w;
                        result.dram_watts = dram_w;
                        result.soc_watts = cpu_w + gpu_w + ane_w + dram_w;
                        result.is_valid = 1;
                    }
                }
            }
        }

        if (state->smc_conn != 0) {
            double pstr = 0.0, pzc0 = 0.0;
            if (smc_read_double(state->smc_conn, "PSTR", &pstr) && pstr > 0.0) {
                result.soc_watts = pstr;
                result.is_valid = 1;
            }
            if ((result.cpu_watts == 0.0 || !result.is_valid) && smc_read_double(state->smc_conn, "PZC0", &pzc0) && pzc0 > 0.0) {
                result.cpu_watts = pzc0;
                result.is_valid = 1;
            }
        }
    }

    return result;
}

void ztop_power_deinit(void *handle) {
    if (!handle) return;
    ztop_power_state_t *state = (ztop_power_state_t *)handle;
    @autoreleasepool {
        if (state->prev_samples) CFRelease(state->prev_samples);
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


