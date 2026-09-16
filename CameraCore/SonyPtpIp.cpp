#include "SonyPtpIp.hpp"

#include <algorithm>
#include <array>
#include <chrono>
#include <cctype>
#include <cstring>
#include <cstdlib>
#include <thread>

namespace sony {
namespace {
constexpr uint32_t kInitCommandRequest = 1, kInitCommandAck = 2, kInitEventRequest = 3, kInitEventAck = 4, kInitFail = 5;
constexpr uint32_t kOperationRequest = 6, kOperationResponse = 7, kEvent = 8;
constexpr uint32_t kStartData = 9, kData = 10, kEndData = 12;
constexpr uint32_t kProbeRequest = 13, kProbeResponse = 14;
constexpr uint32_t kDataPhaseIn = 1, kDataPhaseOut = 2;

// Sony control codes/values verified against the working ESP32 controller.
constexpr uint16_t kSonyCtrlMovieRec = 0xD2C8;
constexpr uint16_t kSonyCtrlShutterS1 = 0xD2C1;
constexpr uint16_t kSonyCtrlShutterS2 = 0xD2C2;
constexpr uint16_t kSonyCtrlRelativeFocus = 0xD2D1;
constexpr uint32_t kSonyButtonUp = 0x00000001;
constexpr uint32_t kSonyButtonDown = 0x00000002;

// The proven ESP32 controller uses the ASCII prefix "SONYESP2" in the
// first eight bytes and a persistent unique value in the final eight bytes.
// The bridge supplies a persistent UUID string through setClientGuid().
std::array<uint8_t, 16> gClientGuid{0x53,0x4F,0x4E,0x59,0x45,0x53,0x50,0x32};
bool gClientGuidConfigured = false;

int hexNibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

bool parseClientGuidTail(const std::string& text, std::array<uint8_t, 8>& tail) {
    // Accept a normal UUID string:
    // XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX
    // Also accept the same 32 hex digits without separators.
    std::string hex;
    hex.reserve(32);
    for (char c : text) {
        if (std::isxdigit(static_cast<unsigned char>(c))) {
            hex.push_back(c);
        }
    }
    if (hex.size() != 32) return false;

    std::array<uint8_t, 16> bytes{};
    for (size_t i = 0; i < bytes.size(); ++i) {
        const int hi = hexNibble(hex[i * 2]);
        const int lo = hexNibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) return false;
        bytes[i] = static_cast<uint8_t>((hi << 4) | lo);
    }

    std::copy(bytes.begin() + 8, bytes.end(), tail.begin());
    return true;
}

uint32_t le32(const uint8_t* p) { return uint32_t(p[0]) | uint32_t(p[1]) << 8 | uint32_t(p[2]) << 16 | uint32_t(p[3]) << 24; }
uint16_t le16(const uint8_t* p) { return uint16_t(p[0]) | uint16_t(p[1]) << 8; }
bool sameValue(const Value& a, const Value& b) { return a.type == b.type && a.bytes == b.bytes; }
std::vector<uint8_t> ptpInitiatorName(const std::string& text) {
    // PTP/IP InitCommandRequest InitiatorName is UTF-16LE + NUL.
    // It is NOT a PTP dataset string and therefore has no leading UINT8 count.
    Writer out;
    for (unsigned char ch : text) out.u16(ch);
    out.u16(0);
    return out.bytes;
}
}

SonyPtpIp::SonyPtpIp() = default;
SonyPtpIp::~SonyPtpIp() { disconnect(); }

void SonyPtpIp::setClientGuid(const std::string& clientGuid) {
    std::array<uint8_t, 8> tail{};
    if (!parseClientGuidTail(clientGuid, tail)) {
        // Keep the existing fallback behavior if the bridge ever supplies a
        // non-UUID string. Do not corrupt the PTP/IP initiator GUID.
        gClientGuidConfigured = false;
        return;
    }

    gClientGuid = {0x53,0x4F,0x4E,0x59,0x45,0x53,0x50,0x32};
    std::copy(tail.begin(), tail.end(), gClientGuid.begin() + 8);
    gClientGuidConfigured = true;
}

ConnectResult SonyPtpIp::connect(const std::string& host,
                                    const std::string& username,
                                    const std::string& password,
                                    const std::string& trustedFingerprint) {
    disconnect();
    transport_ = std::make_unique<SSHTransport>();

    const auto verified = transport_->connectAndVerify(host, 22, trustedFingerprint);
    if (!verified.ok)
        return {false, verified.needsTrust, verified.message, verified.fingerprint};

    const auto authenticated = transport_->authenticatePassword(username, password);
    if (!authenticated.ok) {
        disconnect();
        return {false, false, authenticated.message, verified.fingerprint};
    }

    std::string error;
    if (!transport_->openCameraTunnels(error) || !initializePtp(error)) {
        disconnect();
        return {false, false, error, verified.fingerprint};
    }

    // Do not announce CAMERA READY until the same 0x9209 state path used by
    // every control is actually parsable. This catches protocol/parser drift
    // immediately instead of showing a connected-but-dead UI.
    bool stateReady = false;
    std::string stateError;
    for (int attempt = 0; attempt < 3; ++attempt) {
        stateError.clear();
        if (refresh(stateError)) {
            stateReady = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(150));
    }

    if (!stateReady) {
        disconnect();
        return {false, false,
                "PTP3 connected, but Sony 0x9209 state sync failed: " + stateError,
                verified.fingerprint};
    }

    return {true, false, "CAMERA READY - Sony PTP3 state synchronized", verified.fingerprint};
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
        if (gClientGuidConfigured) {
            guid = gClientGuid;
        } else {
            // Fallback only if setClientGuid() was not supplied a valid UUID.
            arc4random_buf(guid.data() + 8, 8);
        }
        body.append(std::vector<uint8_t>(guid.begin(), guid.end()));
        body.append(ptpInitiatorName("SonyFX3Controller"));
        body.u32(0x00010000);
    }
    if (!writePacket(eventChannel, eventChannel ? kInitEventRequest : kInitCommandRequest, body.bytes, error)) return false;
    Packet reply; if (!readPacket(eventChannel, reply, error)) return false;
    const uint32_t expected = eventChannel ? kInitEventAck : kInitCommandAck;
    if (reply.type == kInitFail) {
        const uint32_t reason = reply.payload.size() >= 4 ? le32(reply.payload.data()) : 0;
        error = "Camera rejected PTP/IP initialization (reason " + std::to_string(reason) + ")";
        return false;
    }
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

    // Working ESP32 flow:
    // OpenSession transaction=0, then normal transactions start at 1.
    transaction_ = 0;
    if (!operation(kOpOpenSession, {1}, nullptr, nullptr, error)) return false;

    if (!operation(kOpSdioConnect, {1, 0, 0}, nullptr, &ignored, error)) return false;
    if (!operation(kOpSdioConnect, {2, 0, 0}, nullptr, &ignored, error)) return false;

    bool ready = false;
    for (int attempt = 0; attempt < 30; ++attempt) {
        std::vector<uint8_t> info;
        if (operation(kOpGetExtDeviceInfo, {0x012C}, nullptr, &info, error) &&
            info.size() >= 2 && le16(info.data()) == 0x012C) {
            ready = true;
            break;
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(100));
    }
    if (!ready) {
        error = "Sony PTP3 version 0x012C was not returned";
        return false;
    }

    if (!operation(kOpSdioConnect, {3, 0, 0}, nullptr, &ignored, error)) return false;

    // Sony 0x9216 is firmware-dependent: the version can be returned either
    // in a data payload OR in OperationResponse Param1. The working ESP32
    // accepts both. Do the same here.
    std::vector<uint8_t> versionData;
    std::vector<uint32_t> versionResponseParameters;
    std::string versionError;
    if (operation(kOpGetVendorVersion, {}, nullptr, &versionData, versionError,
                  &versionResponseParameters)) {
        uint32_t version = 0;
        if (versionData.size() >= 4) version = le32(versionData.data());
        else if (versionData.size() >= 2) version = le16(versionData.data());
        else if (versionData.size() >= 1) version = versionData[0];
        if (version == 0 && !versionResponseParameters.empty())
            version = versionResponseParameters[0];

        state_.vendorVersion = version;
        state_.supportsExtendedProperties = version >= 310;
    } else {
        // Match ESP32 behavior: 0x9216 being unavailable is not fatal to the
        // normal non-extended control path.
        state_.vendorVersion = 0;
        state_.supportsExtendedProperties = false;
        emit("VendorCodeVersion unavailable; extended properties disabled: " + versionError);
    }

    // Enter Sony HOST PC control mode only after PTP3 is ready.
    const auto hostPc = Value::number(kDataUInt8, 1);
    if (!operation(kOpSetProperty, {0xD25A}, &hostPc.bytes, nullptr, error)) return false;

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

bool SonyPtpIp::serviceEvents(std::string& error) {
    error.clear();
    if (!transport_ || !transport_->connected()) {
        error = "Camera is not connected";
        return false;
    }

    bool stateChanged = false;
    int drained = 0;
    while (drained < 16 && transport_->eventReadable()) {
        Packet packet;
        if (!readPacket(true, packet, error)) return false;
        ++drained;

        if (packet.type == kProbeRequest) {
            if (!writePacket(true, kProbeResponse, {}, error)) return false;
            continue;
        }
        if (packet.type == kProbeResponse) continue;
        if (packet.type == kEvent) {
            stateChanged = true;
            continue;
        }
    }

    if (!stateChanged) return true;

    std::string refreshError;
    if (!refresh(refreshError)) {
        error = "Sony event received, but 0x9209 state refresh failed: " + refreshError;
        return false;
    }
    return true;
}

bool SonyPtpIp::sendData(uint32_t transaction, const std::vector<uint8_t>& data, std::string& error) {
    Writer start; start.u32(transaction); start.u64(data.size());
    if (!writePacket(false, kStartData, start.bytes, error)) return false;
    Writer end; end.u32(transaction); end.append(data);
    return writePacket(false, kEndData, end.bytes, error);
}

bool SonyPtpIp::operation(uint16_t opcode, const std::vector<uint32_t>& parameters, const std::vector<uint8_t>* outgoingData, std::vector<uint8_t>* incomingData, std::string& error, std::vector<uint32_t>* responseParameters) {
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
    return receiveResponse(tx, incomingData, error, responseParameters);
}

bool SonyPtpIp::receiveResponse(uint32_t transaction,
                                std::vector<uint8_t>* incomingData,
                                std::string& error,
                                std::vector<uint32_t>* responseParameters) {
    if (incomingData) incomingData->clear();
    if (responseParameters) responseParameters->clear();

    for (;;) {
        Packet packet;
        if (!readPacket(false, packet, error)) return false;

        if (packet.type == kProbeRequest) {
            if (!writePacket(false, kProbeResponse, {}, error)) return false;
            continue;
        }

        if (packet.type == kProbeResponse) {
            continue;
        }

        if (packet.type == kStartData || packet.type == kData || packet.type == kEndData) {
            if (packet.payload.size() < 4 ||
                le32(packet.payload.data()) != transaction) {
                error = "PTP/IP data transaction mismatch";
                return false;
            }

            // StartData carries tx + UINT64 totalLength only.
            // Data/EndData carry tx + actual data bytes.
            if (incomingData && packet.type != kStartData) {
                incomingData->insert(incomingData->end(),
                                     packet.payload.begin() + 4,
                                     packet.payload.end());
            }
            continue;
        }

        // Do not let an unrelated event/probe packet permanently desynchronize
        // the command transaction parser. The working ESP32 consumes unrelated
        // packets and keeps waiting for this transaction's response.
        if (packet.type != kOperationResponse) {
            continue;
        }

        if (packet.payload.size() < 6) {
            error = "Truncated PTP/IP operation response";
            return false;
        }

        if (le32(packet.payload.data() + 2) != transaction) {
            error = "PTP/IP response transaction mismatch";
            return false;
        }

        const uint16_t code = le16(packet.payload.data());

        if (responseParameters) {
            const size_t parameterBytes = packet.payload.size() - 6;
            const size_t parameterCount = std::min<size_t>(5, parameterBytes / 4);
            for (size_t i = 0; i < parameterCount; ++i) {
                responseParameters->push_back(le32(packet.payload.data() + 6 + i * 4));
            }
        }

        if (code != kPtpOk) {
            error = "Sony PTP operation failed with " + hex(code, 4);
            return false;
        }
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

bool SonyPtpIp::verifyProperty(uint16_t property, const Value& target, std::string& error) {
    const uint16_t readbackProperty =
        property == kPropFocusPositionSetting ? kPropFocusPositionCurrent : property;

    std::string lastRefreshError;
    for (int attempt = 0; attempt < 4; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(attempt == 0 ? 280 : 120));

        std::string refreshError;
        if (!refresh(refreshError)) {
            lastRefreshError = refreshError;
            continue;
        }

        const auto* current = state_.property(readbackProperty);
        if (current && sameValue(current->current, target)) return true;
    }

    const auto* current = state_.property(readbackProperty);
    error = "Sony accepted property write, but camera readback did not match";
    if (current) {
        error += " (requested " + formatValue(target) +
                 ", camera " + formatValue(current->current) + ")";
    } else {
        error += " (readback property " + hex(readbackProperty, 4) + " unavailable)";
    }
    if (!lastRefreshError.empty()) error += "; last refresh error: " + lastRefreshError;
    return false;
}

bool SonyPtpIp::verifyRecordState(RecordState expected, std::string& error) {
    std::string lastRefreshError;
    for (int attempt = 0; attempt < 4; ++attempt) {
        std::this_thread::sleep_for(std::chrono::milliseconds(attempt == 0 ? 180 : 120));

        std::string refreshError;
        if (!refresh(refreshError)) {
            lastRefreshError = refreshError;
            continue;
        }
        if (state_.recordState == expected) return true;
    }

    error = "Sony accepted REC control, but D21D readback did not reach the requested state";
    if (!lastRefreshError.empty()) error += "; last refresh error: " + lastRefreshError;
    return false;
}

bool SonyPtpIp::setProperty(uint16_t property, const Value& target, std::string& error) {
    if (!state_.canWrite(property)) {
        error = "Camera reports this property is unavailable or read-only";
        return false;
    }

    std::vector<uint32_t> parameters{property};
    if (isExtended(property)) parameters.push_back(1u);

    if (!operation(kOpSetProperty, parameters, &target.bytes, nullptr, error)) return false;
    return verifyProperty(property, target, error);
}

bool SonyPtpIp::control(uint16_t controlCode, const Value& value, std::string& error) {
    // 0x9207 has exactly one operation parameter: the Sony control code.
    // The control value itself is the Data-Out payload. Payload width matters.
    Value encoded = value;
    const int64_t numeric = value.signedNumber();

    switch (controlCode) {
        case kSonyCtrlMovieRec:
        case kSonyCtrlShutterS2:
            // Working ESP32 REC/S2 path sends UINT32.
            encoded = Value::number(kDataUInt32, numeric);
            break;

        case kSonyCtrlShutterS1:
            // Focus-page S1 hold uses a 2-byte DOWN/UP value.
            encoded = Value::number(kDataUInt16, numeric);
            break;

        case kSonyCtrlRelativeFocus:
            // D2D1 is signed relative focus: +/-1, +/-3, +/-7.
            encoded = Value::number(kDataInt16, numeric);
            break;

        default:
            // For any future control not explicitly mapped, preserve the
            // caller-provided datatype instead of silently forcing INT16.
            break;
    }

    return operation(kOpSdioControl, {controlCode}, &encoded.bytes, nullptr, error);
}

bool SonyPtpIp::startRecording(std::string& error) {
    if (!control(kSonyCtrlMovieRec, Value::number(kDataUInt32, kSonyButtonDown), error)) return false;
    return verifyRecordState(RecordState::recording, error);
}

bool SonyPtpIp::stopRecording(std::string& error) {
    if (!control(kSonyCtrlMovieRec, Value::number(kDataUInt32, kSonyButtonUp), error)) return false;
    return verifyRecordState(RecordState::stopped, error);
}
void SonyPtpIp::emit(const std::string& message) const { if (eventCallback_) eventCallback_(message); }

} // namespace sony
