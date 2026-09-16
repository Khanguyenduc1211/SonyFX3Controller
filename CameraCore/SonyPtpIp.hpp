#pragma once

#include "SSHTransport.hpp"
#include "SonyCameraState.hpp"

#include <functional>
#include <memory>
#include <array>

namespace sony {

struct ConnectResult {
    bool ok = false;
    bool needsTrust = false;
    std::string message;
    std::string fingerprint;
};

class SonyPtpIp {
public:
    using StateCallback = std::function<void(const CameraState&)>;
    using EventCallback = std::function<void(const std::string&)>;

    SonyPtpIp();
    ~SonyPtpIp();
    ConnectResult connect(const std::string& host, const std::string& username, const std::string& password,
                          const std::string& trustedFingerprint);
    void disconnect();
    bool isConnected() const { return transport_ && transport_->connected(); }
    const CameraState& state() const { return state_; }
    void setStateCallback(StateCallback callback) { stateCallback_ = std::move(callback); }
    void setEventCallback(EventCallback callback) { eventCallback_ = std::move(callback); }
    void setClientGuid(const std::string& uuidText);

    bool refresh(std::string& error);
    bool setProperty(uint16_t property, const Value& target, std::string& error);
    bool control(uint16_t controlCode, const Value& value, std::string& error);
    bool startRecording(std::string& error);
    bool stopRecording(std::string& error);

private:
    struct Packet { uint32_t type = 0; std::vector<uint8_t> payload; };
    bool initializePtp(std::string& error);
    bool initializeChannel(bool eventChannel, std::string& error);
    bool operation(uint16_t opcode, const std::vector<uint32_t>& parameters,
                   const std::vector<uint8_t>* outgoingData, std::vector<uint8_t>* incomingData, std::string& error);
    bool readPacket(bool eventChannel, Packet& packet, std::string& error);
    bool writePacket(bool eventChannel, uint32_t type, const std::vector<uint8_t>& payload, std::string& error);
    bool sendData(uint32_t transaction, const std::vector<uint8_t>& data, std::string& error);
    bool receiveResponse(uint32_t transaction, std::vector<uint8_t>* incomingData, std::string& error);
    bool isExtended(uint16_t code) const { return code >= 0xE000 && state_.supportsExtendedProperties; }
    void emit(const std::string& message) const;

    std::unique_ptr<SSHTransport> transport_;
    CameraState state_;
    uint32_t transaction_ = 1;
    uint32_t connectionId_ = 0;
    std::array<uint8_t, 16> clientGuid_{0x53,0x4F,0x4E,0x59,0x49,0x4F,0x53,0x31};
    StateCallback stateCallback_;
    EventCallback eventCallback_;
};

} // namespace sony
