#include "SonyProtocol.hpp"
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

    // Camera Remote SDK 2.02 / Cr_PTP_IP monitoring facts established before
    // enabling the transport path.  Payload serialization intentionally has no
    // guessed test vector yet.
    static_assert(kOpControlMonitoring == 0x9230);
    static_assert(kMonitoringStop == 0);
    static_assert(kMonitoringStart == 1);
    static_assert(kMonitoringDefaultVideoPort == 55001);
    static_assert(kMonitoringDefaultMetaPort == 55005);

    std::cout << "SonyProtocolTests passed\n";
}
