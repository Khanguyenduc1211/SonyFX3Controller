#include "SonyProtocol.hpp"
#include "SonyMonitoring.hpp"
#include "SonyMonitoringReceiver.hpp"
#include <cassert>
#include <iostream>

using namespace sony;
int main() {
    Writer data; data.u64(1); data.u16(0xD241); data.u16(kDataUInt8); data.u8(1); data.u8(1); data.u8(0); data.u8(1); data.u8(2); data.u16(2); data.u8(0); data.u8(1); data.u16(3); data.u8(0); data.u8(1); data.u8(2);
    auto parsed = parseAllPropertyInfo(data.bytes);
    assert(parsed.size() == 1 && parsed[0].code == 0xD241);
    assert(parsed[0].setValues.size() == 2 && parsed[0].getSetValues.size() == 3);
    assert(parsed[0].current.unsignedNumber() == 1);
    assert(Value::number(kDataInt16, -7).signedNumber() == -7);
    assert(formatValue(Value::number(kDataUInt32, 24000)) == "24000");

    static_assert(kOpControlMonitoring == 0x9230);
    static_assert(kMonitoringStop == 0);
    static_assert(kMonitoringStart == 1);
    static_assert(kMonitoringDefaultVideoPort == 55001);
    static_assert(kMonitoringDefaultMetaPort == 55005);

    MonitoringDeliverySetting setting;
    setting.ipAddress = "192.0.2.1";
    MonitoringWireRequest request;
    std::string monitoringError;
    assert(!buildMonitoringStartRequest(setting, request, monitoringError));
    assert(!monitoringError.empty());

    SonyMonitoringReceiver receiver;
    receiver.publishCompleteJpeg(1, {0x00, 0x01, 0x02, 0x03});
    assert(!receiver.takeLatest().has_value());
    receiver.publishCompleteJpeg(1, {0xFF, 0xD8, 0x01, 0xFF, 0xD9});
    receiver.publishCompleteJpeg(2, {0xFF, 0xD8, 0x02, 0xFF, 0xD9});
    auto latest = receiver.takeLatest();
    assert(latest && latest->sequence == 2 && latest->jpeg[2] == 0x02);
    assert(!receiver.takeLatest().has_value());

    std::cout << "SonyProtocolTests passed\n";
}
