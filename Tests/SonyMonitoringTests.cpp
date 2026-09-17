#include "SonyMonitoring.hpp"
#include "SonyMonitoringReceiver.hpp"
#include <array>
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
    invalid = setting;
    invalid.deliveryImageQualityLevel = 4;
    assert(!buildMonitoringStartRequest(invalid, 101, request, error));

    std::array<uint8_t, VericHeader::kSize> packet{};
    packet[0]='V'; packet[1]='E'; packet[2]='R'; packet[3]='I'; packet[4]='C';
    packet[5]=0xFE; packet[6]=0x12; packet[7]=0xFD;
    packet[8]=0x01; packet[9]=0x23; packet[10]=0x45; packet[11]=0x67;
    packet[12]=0x89; packet[13]=0xAB; packet[14]=0xCD; packet[15]=0xEF;
    packet[18]=0x12; packet[19]=0x34;
    packet[20]=0x10; packet[21]=0x20; packet[22]=0x30; packet[23]=0x40;
    packet[24]=0x56; packet[25]=0x78;
    packet[26]=0x9A; packet[27]=0xBC;
    packet[32]=0x01; packet[39]=0x08;
    packet[40]=0x11; packet[47]=0x18;
    packet[56]=0xFA; packet[57]=0xFB; packet[58]=0xFC;
    VericHeader header;
    assert(parseVericHeader(packet.data(), packet.size(), header));
    assert(header.field05 == static_cast<int8_t>(0xFE));
    assert(header.field06 == 0x12);
    assert(header.field08 == 0x01234567u);
    assert(header.field12 == 0x89ABCDEFu);
    assert(header.field18 == 0x1234u);
    assert(header.field20 == 0x10203040u);
    assert(header.field24 == 0x5678u);
    assert(header.field26 == 0x9ABCu);
    assert(!parseVericHeader(packet.data(), VericHeader::kSize - 1, header));
    packet[0] = 'X';
    assert(!parseVericHeader(packet.data(), packet.size(), header));

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
