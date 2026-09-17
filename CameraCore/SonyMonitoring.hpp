#pragma once

#include "SonyProtocol.hpp"
#include <cstdint>
#include <limits>
#include <string>
#include <vector>

namespace sony {

// Public Camera Remote SDK semantics. The byte layout produced below is
// separately binary-derived from Sony CrSDK 2.02 (Cr_Core + Cr_PTP_IP).
enum class MonitoringDeliveryType : uint16_t {
    jpeg = 1,
};

enum class MonitoringTransportProtocol : uint16_t {
    udp = 1,
    tcp = 2,
};

struct MonitoringDeliverySetting {
    std::string ipAddress;
    uint32_t downTimeMs = 5000; // SDK receiver option; NOT serialized in 0x9230.
    uint32_t videoPort = 0;     // public SDK: 0 -> 55001
    uint32_t metaPort = 0;      // public SDK: 0 -> 55005
    MonitoringDeliveryType type = MonitoringDeliveryType::jpeg;
    uint8_t deliveryImageQualityLevel = 3;
    MonitoringTransportProtocol transportProtocol = MonitoringTransportProtocol::udp;
};

struct MonitoringWireRequest {
    uint32_t operation = 0;
    std::vector<uint8_t> dataOut;
};

inline MonitoringDeliverySetting normalizedMonitoringSetting(MonitoringDeliverySetting setting) {
    if (setting.videoPort == 0) setting.videoPort = kMonitoringDefaultVideoPort;
    if (setting.metaPort == 0) setting.metaPort = kMonitoringDefaultMetaPort;
    return setting;
}

inline bool validateMonitoringSetting(const MonitoringDeliverySetting& input,
                                      std::string& error) {
    const auto setting = normalizedMonitoringSetting(input);
    if (setting.ipAddress.empty()) {
        error = "Sony Monitoring receiver IP address is empty";
        return false;
    }
    if (setting.ipAddress.size() > std::numeric_limits<uint16_t>::max()) {
        error = "Sony Monitoring receiver IP address is too long";
        return false;
    }
    if (setting.videoPort > 65535 || setting.metaPort > 65535) {
        error = "Sony Monitoring UDP/TCP port is outside the 16-bit port range";
        return false;
    }
    // Sony CrSDK rejects using the metadata default as the video port or the
    // video default as the metadata port.
    if (setting.videoPort == kMonitoringDefaultMetaPort) {
        error = "Sony Monitoring video port cannot equal metadata default port 55005";
        return false;
    }
    if (setting.metaPort == kMonitoringDefaultVideoPort) {
        error = "Sony Monitoring metadata port cannot equal video default port 55001";
        return false;
    }
    if (setting.type != MonitoringDeliveryType::jpeg) {
        error = "Sony CrSDK 2.02 public Monitoring delivery type is JPEG";
        return false;
    }
    if (setting.deliveryImageQualityLevel < 1 || setting.deliveryImageQualityLevel > 5) {
        error = "Sony Monitoring image quality level must be in the SDK-supported range 1...5";
        return false;
    }
    if (setting.transportProtocol != MonitoringTransportProtocol::udp &&
        setting.transportProtocol != MonitoringTransportProtocol::tcp) {
        error = "Sony Monitoring transport protocol must be UDP or TCP";
        return false;
    }
    error.clear();
    return true;
}

// Exact CrSDK 2.02 Start dataset reconstructed from LjSDKDevice::DoStartMonitoring.
// Layout, little-endian:
//   u16 settingVersion, u16 0, u32 1,
//   u16 ipLength, ipLength bytes of IP string,
//   u32 videoPort, u32 0, u32 metaPort, u16 deliveryType,
//   [version >= 101: u8 quality, u16 transport].
// downTimeMs is intentionally absent: Sony uses it only for its local receiver.
inline bool buildMonitoringStartRequest(const MonitoringDeliverySetting& input,
                                        uint16_t settingVersion,
                                        MonitoringWireRequest& request,
                                        std::string& error) {
    request = {};
    if (!validateMonitoringSetting(input, error)) return false;

    const auto setting = normalizedMonitoringSetting(input);
    Writer writer;
    writer.u16(settingVersion);
    writer.u16(0);
    writer.u32(1);
    writer.u16(static_cast<uint16_t>(setting.ipAddress.size()));
    writer.bytes.insert(writer.bytes.end(), setting.ipAddress.begin(), setting.ipAddress.end());
    writer.u32(setting.videoPort);
    writer.u32(0);
    writer.u32(settingVersion >= 101 ? setting.metaPort : 0);
    writer.u16(static_cast<uint16_t>(setting.type));
    if (settingVersion >= 101) {
        writer.u8(setting.deliveryImageQualityLevel);
        writer.u16(static_cast<uint16_t>(setting.transportProtocol));
    }

    const size_t expectedSize = setting.ipAddress.size() + (settingVersion >= 101 ? 27u : 24u);
    if (writer.bytes.size() != expectedSize) {
        error = "Internal Sony Monitoring Start serialization size mismatch";
        return false;
    }

    request.operation = kMonitoringWireStart;
    request.dataOut = std::move(writer.bytes);
    error.clear();
    return true;
}

// Exact CrSDK 2.02 Stop dataset reconstructed from LjSDKDevice::DoStopMonitoring:
// u16 settingVersion, u16 0, u32 1, u32 deliveryId.
inline MonitoringWireRequest buildMonitoringStopRequest(uint16_t settingVersion,
                                                        uint32_t deliveryId) {
    Writer writer;
    writer.u16(settingVersion);
    writer.u16(0);
    writer.u32(1);
    writer.u32(deliveryId);

    MonitoringWireRequest request;
    request.operation = kMonitoringWireStop;
    request.dataOut = std::move(writer.bytes);
    return request;
}

} // namespace sony
