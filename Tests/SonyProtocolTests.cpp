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
    std::cout << "SonyProtocolTests passed\n";
}
