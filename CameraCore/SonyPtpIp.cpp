#include "SonyPtpIp.hpp"

#include <array>
#include <chrono>
#include <cstring>
#include <cstdlib>
#include <thread>

namespace sony {
namespace {
constexpr uint32_t kInitCommandRequest = 1, kInitCommandAck = 2, kInitEventRequest = 3, kInitEventAck = 4;
constexpr uint32_t kOperationRequest = 6, kOperationResponse = 7, kEvent = 8;
constexpr uint32_t kStartData = 9, kData = 10, kEndData = 12;
constexpr uint32_t kProbeRequest = 13, kProbeResponse = 14;
constexpr uint32_t kDataPhaseIn = 1, kDataPhaseOut = 2;

uint32_t le32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t le16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
std::vector<uint8_t> ptpString(const std::string& text) {
    Writer out; const auto count = static_cast<uint8_t>(std::min<size_t>(text.size() + 1, 255)); out.u8(count);
    for (size_t i = 0; i + 1 < count; ++i) out.u16(static_cast<uint8_t>(text[i]));
    if (count) out.u16(0);
    return out.bytes;
}
}

SonyPtpIp::SonyPtpIp() = default;
SonyPtpIp::~SonyPtpIp() { disconnect(); }

ConnectResult SonyPtpIp::connect(const std::string& host, const std::string& username, const std::string& password, const std::string& trustedFingerprint) {
    disconnect(); transport_ = std::make_unique<SSHTransport>();
    const auto verified = transport_->connectAndVerify(host, 22, trustedFingerprint);
    if (!verified.ok) return {false, verified.needsTrust, verified.message, verified.fingerprint};
    const auto authenticated = transport_->authenticatePassword(username, password);
    if (!authenticated.ok) { disconnect(); return {false, false, authenticated.message, verified.fingerprint}; }
    std::string error;
    if (!transport_->openCameraTunnels(error) || !initializePtp(error)) { disconnect(); return {false, false, error, verified.fingerprint}; }
    if (!refresh(error)) emit("Connected, but initial camera state refresh failed: " + error);
    return {true, false, "Connected through verified SSH tunnel", verified.fingerprint};
}

void SonyPtpIp::disconnect() { if (transport_) transport_->close(); transport_.reset(); state_ = {}; transaction_ = 1; connectionId_ = 0; }

bool SonyPtpIp::initializeChannel(bool eventChannel, std::string& error) {
    Writer body;
    if (eventChannel) {
        // Init_Event_Request uses the connection number from Init_Command_Ack.
        body.u32(connectionId_);
    } else {
        // PTP/IP clients must present a unique GUID.  A constant client GUID
        // makes a Sony camera retain/replace a previous session instead of
        // reliably acknowledging a reconnect.
        // Same Sony client GUID layout as the proven ESP32 controller; only
        // its final eight bytes are the unique client identity.
        std::array<uint8_t, 16> guid{0x53,0x4F,0x4E,0x59,0x45,0x53,0x50,0x32};
        arc4random_buf(guid.data() + 8, 8);
        body.append(std::vector<uint8_t>(guid.begin(), guid.end())); body.append(ptpString("SonyFX3Controller")); body.u32(0x00010000);
    }
    if (!writePacket(eventChannel, eventChannel ? kInitEventRequest : kInitCommandRequest, body.bytes, error)) return false;
    Packet reply; if (!readPacket(eventChannel, reply, error)) return false;
    const uint32_t expected = eventChannel ? kInitEventAck : kInitCommandAck;
    if (reply.type != expected) { error = "Unexpected PTP/IP initialization packet"; return false; }
    if (!eventChannel) {
        if (reply.payload.size() < 4) { error = "PTP/IP Init_Command_Ack has no connection number"; return false; }
        connectionId_ = le32(reply.payload.data());
    }
    return true;
}

bool SonyPtpIp::initializePtp(std::string& error) {
    if (!initializeChannel(false, error) || !initializeChannel(true, error)) return false;
    std::vector<uint8_t> ignored;
    // Sony's PTP/IP flow sends OpenSession with transaction ID 0.  Subsequent
    // operations begin at 1. Sending OpenSession as transaction 1 leaves the
    // camera waiting and the tunnel only reports EAGAIN/would-block.
    transaction_ = 0;
    if (!operation(kOpOpenSession, {1}, nullptr, nullptr, error)) return false;
    // Sony PTP3 sequence from CameraRemoteCommand: stages 1, 2, wait until
    // GetExtDeviceInfo returns PTP3 version 0x012C, then stage 3.
    if (!operation(kOpSdioConnect, {1, 0, 0}, nullptr, &ignored, error)) return false;
    if (!operation(kOpSdioConnect, {2, 0, 0}, nullptr, &ignored, error)) return false;
    bool ready = false;
    for (int attempt = 0; attempt < 30; ++attempt) {
        std::vector<uint8_t> info;
        if (operation(kOpGetExtDeviceInfo, {0x012C}, nullptr, &info, error) && info.size() >= 2 && le16(info.data()) == 0x012C) { ready = true; break; }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (!ready) { error = "Sony PTP3 version 0x012C was not returned"; return false; }
    if (!operation(kOpSdioConnect, {3, 0, 0}, nullptr, &ignored, error)) return false;
    std::vector<uint8_t> versionData;
    if (operation(kOpGetVendorVersion, {}, nullptr, &versionData, error) && versionData.size() >= 4) {
        state_.vendorVersion = le32(versionData.data());
        state_.supportsExtendedProperties = state_.vendorVersion >= 310;
    }
    // D25A is a property write (HOST_PC = 1), not an SDIO control command.
    const auto hostPc = Value::number(kDataUInt8, 1);
    if (!operation(kOpSetProperty, {0xD25A, 0}, &hostPc.bytes, nullptr, error)) return false;
    return true;
}

bool SonyPtpIp::writePacket(bool eventChannel, uint32_t type, const std::vector<uint8_t>& payload, std::string& error) {
    Writer packet; packet.u32(static_cast<uint32_t>(payload.size() + 8)); packet.u32(type); packet.append(payload);
    return eventChannel ? transport_->writeEvent(packet.bytes, error) : transport_->writeCommand(packet.bytes, error);
}

bool SonyPtpIp::readPacket(bool eventChannel, Packet& packet, std::string& error) {
    std::array<uint8_t, 8> header{};
    const bool headerRead = eventChannel ? transport_->readEventExact(header.data(), header.size(), 8000, error) : transport_->readCommandExact(header.data(), header.size(), 8000, error);
    if (!headerRead) return false;
    const uint32_t length = le32(header.data());
    if (length < 8 || length > 4 * 1024 * 1024) { error = "Invalid PTP/IP packet length"; return false; }
    packet.type = le32(header.data() + 4); packet.payload.resize(length - 8);
    if (packet.payload.empty()) return true;
    return eventChannel ? transport_->readEventExact(packet.payload.data(), packet.payload.size(), 8000, error) : transport_->readCommandExact(packet.payload.data(), packet.payload.size(), 8000, error);
}

bool SonyPtpIp::sendData(uint32_t transaction, const std::vector<uint8_t>& data, std::string& error) {
    Writer start; start.u32(transaction); start.u64(data.size());
    if (!writePacket(false, kStartData, start.bytes, error)) return false;
    Writer end; end.u32(transaction); end.append(data);
    return writePacket(false, kEndData, end.bytes, error);
}

bool SonyPtpIp::operation(uint16_t opcode, const std::vector<uint32_t>& parameters, const std::vector<uint8_t>* outgoingData, std::vector<uint8_t>* incomingData, std::string& error) {
    if (!transport_ || !transport_->connected()) { error = "Camera is not connected"; return false; }
    const uint32_t tx = transaction_++;
    // PTP/IP DataPhaseInfo is 1 for "no data or data-in" and 2 for data-out.
    // Never send 0 here: OpenSession has no data phase, but still uses value 1.
    // Some responders close the PTP/IP connection when an unsupported/unknown
    // DataPhaseInfo value is received.
    Writer request;
    request.u32(outgoingData ? kDataPhaseOut : kDataPhaseIn);
    request.u16(opcode);
    request.u32(tx);
    for (uint32_t p : parameters) request.u32(p);
    if (!writePacket(false, kOperationRequest, request.bytes, error)) return false;
    if (outgoingData && !sendData(tx, *outgoingData, error)) return false;
    return receiveResponse(tx, incomingData, error);
}

bool SonyPtpIp::receiveResponse(uint32_t transaction, std::vector<uint8_t>* incomingData, std::string& error) {
    if (incomingData) incomingData->clear();
    for (;;) {
        Packet packet; if (!readPacket(false, packet, error)) return false;
        // The camera may probe a quiet PTP/IP command channel. It is a packet
        // exchange, not an operation response; reply before waiting again.
        if (packet.type == kProbeRequest) {
            if (!writePacket(false, kProbeResponse, {}, error)) return false;
            continue;
        }
        if (packet.type == kStartData || packet.type == kData || packet.type == kEndData) {
            if (packet.payload.size() < 4 || le32(packet.payload.data()) != transaction) { error = "PTP/IP data transaction mismatch"; return false; }
            if (incomingData && packet.type != kStartData) incomingData->insert(incomingData->end(), packet.payload.begin() + 4, packet.payload.end());
            continue;
        }
        if (packet.type != kOperationResponse || packet.payload.size() < 6) { error = "Unexpected PTP/IP operation response"; return false; }
        if (le32(packet.payload.data() + 2) != transaction) { error = "PTP/IP response transaction mismatch"; return false; }
        const uint16_t code = le16(packet.payload.data());
        if (code != kPtpOk) { error = "Sony PTP operation failed with " + hex(code, 4); return false; }
        return true;
    }
}

bool SonyPtpIp::refresh(std::string& error) {
    std::vector<uint8_t> dataset;
    const std::vector<uint32_t> parameters = state_.supportsExtendedProperties ? std::vector<uint32_t>{0, 1} : std::vector<uint32_t>{};
    if (!operation(kOpGetAllPropertyInfo, parameters, nullptr, &dataset, error)) return false;
    try { state_.update(parseAllPropertyInfo(dataset)); }
    catch (const std::exception& exception) { error = std::string("Cannot parse camera property data: ") + exception.what(); return false; }
    if (stateCallback_) stateCallback_(state_);
    return true;
}

bool SonyPtpIp::setProperty(uint16_t property, const Value& target, std::string& error) {
    if (!state_.canWrite(property)) { error = "Camera reports this property is unavailable or read-only"; return false; }
    if (!operation(kOpSetProperty, {property, isExtended(property) ? 1u : 0u}, &target.bytes, nullptr, error)) return false;
    return refresh(error);
}

bool SonyPtpIp::control(uint16_t controlCode, const Value& value, std::string& error) {
    if (!operation(kOpSdioControl, {controlCode, isExtended(controlCode) ? 1u : 0u}, &value.bytes, nullptr, error)) return false;
    return true;
}

bool SonyPtpIp::startRecording(std::string& error) { if (!control(kPropRecordState, Value::number(kDataUInt8, 1), error)) return false; return refresh(error); }
bool SonyPtpIp::stopRecording(std::string& error) { if (!control(kPropRecordState, Value::number(kDataUInt8, 0), error)) return false; return refresh(error); }
void SonyPtpIp::emit(const std::string& message) const { if (eventCallback_) eventCallback_(message); }

} // namespace sony
