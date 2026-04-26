#import <Foundation/Foundation.h>
#import <CoreWLAN/CWChannel.h>
#import <CoreWLAN/CWInterface.h>
#import <CoreWLAN/CWWiFiClient.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

struct ztop_wifi_snapshot_raw {
    size_t ssid_len;
    int64_t phy_mode;
    int64_t channel_band;
};

struct ztop_wifi_snapshot_raw ztop_read_wifi_snapshot(char *ssid_buf, size_t ssid_buf_len) {
    struct ztop_wifi_snapshot_raw result = {0, 0, 0};

    if (ssid_buf != NULL && ssid_buf_len > 0) {
        ssid_buf[0] = '\0';
    }

    @autoreleasepool {
        CWWiFiClient *client = [CWWiFiClient sharedWiFiClient];
        if (client == nil) {
            return result;
        }

        CWInterface *interface = [client interface];
        if (interface == nil) {
            return result;
        }

        result.phy_mode = (int64_t)[interface activePHYMode];

        CWChannel *channel = [interface wlanChannel];
        if (channel != nil) {
            result.channel_band = (int64_t)[channel channelBand];
        }

        NSString *ssid = [interface ssid];
        if (ssid == nil || ssid_buf == NULL || ssid_buf_len == 0) {
            return result;
        }

        const char *utf8 = [ssid UTF8String];
        if (utf8 == NULL) {
            return result;
        }

        const size_t max_len = ssid_buf_len - 1;
        const size_t ssid_len = strnlen(utf8, max_len);
        memcpy(ssid_buf, utf8, ssid_len);
        ssid_buf[ssid_len] = '\0';
        result.ssid_len = ssid_len;
    }

    return result;
}
