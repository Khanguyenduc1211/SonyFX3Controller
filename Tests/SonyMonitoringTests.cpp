#include "SonyMonitoring.hpp"
#include "SonyMonitoringReceiver.hpp"
#include <cassert>
#include <cstdint>
#include <string>
#include <vector>

using namespace sony;

int main() {
    MonitoringDeliverySetting setting;
    setting.ipAddress = "192.0.2.10";
    assert(setting.videoPort == 0);
    assert(setting.metaPort == 0);
    const auto normalized = normalizedMonitoringSetting(setting);
    assert(normalized.videoPort == 55001);
    assert(normalized.metaPort == 55005);

    MonitoringWireRequest request;
    std::string error;
    assert(buildMonitoringStartRequest(setting, 101, request, error));
    assert(error.empty());
    assert(request.operation == kMonitoringWireStart);
    const std::vector<uint8_t> expectedStartV101 = {
        0x65,0x00, 0x00,0x00, 0x01,0x00,0x00,0x00,
        0x0A,0x00,
        '1','9','2','.','0','.','2','.','1','0',
        0xD9,0xD6,0x00,0x00,
        0x00,0x00,0x00,0x00,
        0xDD,0xD6,0x00,0x00,
        0x01,0x00,
        0x03,
        0x01,0x00
    };
    assert(request.dataOut == expectedStartV101);
    assert(request.dataOut.size() == 37);

    assert(buildMonitoringStartRequest(setting, 100, request, error));
    assert(request.operation == kMonitoringWireStart);
    const std::vector<uint8_t> expectedStartV100 = {
        0x64,0x00, 0x00,0x00, 0x01,0x00,0x00,0x00,
        0x0A,0x00,
        '1','9','2','.','0','.','2','.','1','0',
        0xD9,0xD6,0x00,0x00,
        0x00,0x00,0x00,0x00,
        0x00,0x00,0x00,0x00,
        0x01,0x00
    };
    assert(request.dataOut == expectedStartV100);
    assert(request.dataOut.size() == 34);

    const uint32_t deliveryId = 0x12345678;
    request = buildMonitoringStopRequest(101, deliveryId);
    assert(request.operation == kMonitoringWireStop);
    const std::vector<uint8_t> expectedStop = {
        0x65,0x00, 0x00,0x00, 0x01,0x00,0x00,0x00,
        0x78,0x56,0x34,0x12
    };
    assert(request.dataOut == expectedStop);

    MonitoringDeliverySetting invalid = setting;
    invalid.videoPort = 55005;
    assert(!buildMonitoringStartRequest(invalid, 101, request, error));

    SonyMonitoringReceiver receiver;
    receiver.publishCompleteJpeg(10, {0xFF,0xD8,0x10,0xFF,0xD9});
    receiver.publishCompleteJpeg(9, {0xFF,0xD8,0x09,0xFF,0xD9});
    auto frame = receiver.takeLatest();
    assert(frame && frame->sequence == 10);

    receiver.publishCompleteJpeg(11, {0xFF,0xD8,0x11,0xFF,0xD9});
    receiver.publishCompleteJpeg(12, {0xFF,0xD8,0x12,0xFF,0xD9});
    frame = receiver.takeLatest();
    assert(frame && frame->sequence == 12);
    return 0;
}
