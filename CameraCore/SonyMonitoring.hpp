#pragma once

#include "SonyProtocol.hpp"
#include <cstdint>
#include <string>
#include <vector>

namespace sony {

// Boundary between the public Sony Monitoring API semantics and the private
// on-wire representation used by Cr_PTP_IP/libmonitor_protocol.
//
// IMPORTANT: Camera Remote SDK 2.02 establishes JPEG monitoring, UDP delivery,
// default video/meta ports and Start/Stop semantics.  The adapter binary also
// establishes PTP operation 0x9230.  The exact Data-Out dataset and VERIC UDP
// packet layout are not public API contracts, so this class deliberately does
// not synthesize them.  A monitoring start must remain unavailable until those
// bytes are derived and test-vectored from Sony's implementation.
struct MonitoringDeliverySetting {
    std::string ipAddress;
    uint32_t downTimeMs = 5000;
    uint16_t videoPort = kMonitoringDefaultVideoPort;
    uint16_t metaPort = kMonitoringDefaultMetaPort;
    uint8_t deliveryImageQualityLevel = 3;
};

struct MonitoringWireRequest {
    uint32_t operation = kMonitoringStop;
    std::vector<uint8_t> dataOut;
};

inline bool buildMonitoringStartRequest(const MonitoringDeliverySetting&,
                                        MonitoringWireRequest& request,
                                        std::string& error) {
    request = {};
    error = "Sony Monitoring Start wire dataset is not yet verified; refusing to send guessed 0x9230 payload";
    return false;
}

inline MonitoringWireRequest buildMonitoringStopRequest() {
    MonitoringWireRequest request;
    request.operation = kMonitoringStop;
    // Do not assume Stop has an empty or shared Data-Out dataset until traced.
    return request;
}

} // namespace sony
