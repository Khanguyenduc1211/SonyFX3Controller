#include "SonyMonitoring.hpp"
#include "SonyMonitoringReceiver.hpp"
#include <cassert>
#include <string>

using namespace sony;

int main() {
    MonitoringDeliverySetting setting;
    setting.ipAddress = "192.0.2.10";
    assert(setting.videoPort == 55001);
    assert(setting.metaPort == 55005);

    MonitoringWireRequest request;
    std::string error;
    assert(!buildMonitoringStartRequest(setting, request, error));
    assert(request.dataOut.empty());
    assert(!error.empty());

    SonyMonitoringReceiver receiver;
    receiver.publishCompleteJpeg(10, {0xFF, 0xD8, 0x10, 0xFF, 0xD9});
    receiver.publishCompleteJpeg(9, {0xFF, 0xD8, 0x09, 0xFF, 0xD9});
    auto frame = receiver.takeLatest();
    assert(frame && frame->sequence == 10);

    receiver.publishCompleteJpeg(11, {0xFF, 0xD8, 0x11, 0xFF, 0xD9});
    receiver.publishCompleteJpeg(12, {0xFF, 0xD8, 0x12, 0xFF, 0xD9});
    frame = receiver.takeLatest();
    assert(frame && frame->sequence == 12);
    return 0;
}
