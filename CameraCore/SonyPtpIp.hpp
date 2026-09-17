#pragma once

#include "SSHTransport.hpp"
#include "SonyCameraState.hpp"
#include "SonyMonitoring.hpp"

#include <functional>
#include <memory>

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
    void setClientGuid(const std::string& clientGuid);
    ConnectResult connect(const std::string& host, const std::string& username, const std::string& password,
                          const std::string& trustedFingerprint);
    void disconnect();
    bool isConnected() const { return transport_ && transport_->connected(); }
    const CameraState& state() const { return state_; }
    void setStateCallback(StateCallback callback) { stateCallback_ = std::move(callback); }
    void setEventCallback(EventCallback callback) { eventCallback_ = std::move(callback); }

    bool refresh(std::string& error);
    bool serviceEvents(std::string& error);
    bool fetchLiveViewJpeg(std::vector<uint8_t>& jpeg, std::string& error);
    bool setProperty(uint16_t property, const Value& target, std::string& error);
    bool control(uint16_t controlCode, const Value& value, std::string& error);
    bool startRecording(std::string& error);
    bool stopRecording(std::string& error);

    // The caller MUST bind/start its VERIC receiver before Start. Sony CrSDK
    // starts the local receiver first and only then sends 0x9230 Start.
    bool startMonitoring(const MonitoringDeliverySetting& setting, std::string& error) {
        if (monitoringActive_) {
            error.clear();
            return true;
        }
        if (!transport_ || !transport_->connected()) {
            error = "Camera is not connected";
            return false;
        }

        const auto* versionProperty = state_.property(kPropMonitoringSettingVersion);
        if (!versionProperty || !versionProperty->enabled || versionProperty->current.empty()) {
            error = "Sony MonitoringSettingVersion E09D is unavailable in this camera mode";
            return false;
        }
        const uint64_t rawVersion = versionProperty->current.unsignedNumber();
        if (rawVersion > 0xFFFFu) {
            error = "Sony MonitoringSettingVersion does not fit the SDK 2.02 wire field";
            return false;
        }

        MonitoringWireRequest request;
        if (!buildMonitoringStartRequest(setting, static_cast<uint16_t>(rawVersion), request, error))
            return false;

        std::vector<uint32_t> responseParameters;
        if (!operation(kOpControlMonitoring, {request.operation}, &request.dataOut,
                       nullptr, error, &responseParameters))
            return false;

        // CrSDK stores OperationResponse Param1 as the Monitoring delivery ID.
        if (responseParameters.empty()) {
            error = "Sony Monitoring Start succeeded without a delivery ID";
            return false;
        }

        monitoringSettingVersion_ = static_cast<uint16_t>(rawVersion);
        monitoringDeliveryId_ = responseParameters.front();
        monitoringActive_ = true;
        error.clear();
        return true;
    }

    bool stopMonitoring(std::string& error) {
        if (!monitoringActive_) {
            error.clear();
            return true;
        }
        const auto request = buildMonitoringStopRequest(monitoringSettingVersion_, monitoringDeliveryId_);
        if (!operation(kOpControlMonitoring, {request.operation}, &request.dataOut,
                       nullptr, error, nullptr))
            return false;
        monitoringActive_ = false;
        monitoringDeliveryId_ = 0;
        monitoringSettingVersion_ = 0;
        error.clear();
        return true;
    }

    bool monitoringActive() const { return monitoringActive_; }
    uint32_t monitoringDeliveryId() const { return monitoringDeliveryId_; }

private:
    struct Packet { uint32_t type = 0; std::vector<uint8_t> payload; };
    bool initializePtp(std::string& error);
    bool initializeChannel(bool eventChannel, std::string& error);
    bool operation(uint16_t opcode, const std::vector<uint32_t>& parameters,
                   const std::vector<uint8_t>* outgoingData, std::vector<uint8_t>* incomingData,
                   std::string& error, std::vector<uint32_t>* responseParameters = nullptr);
    bool readPacket(bool eventChannel, Packet& packet, std::string& error);
    bool writePacket(bool eventChannel, uint32_t type, const std::vector<uint8_t>& payload, std::string& error);
    bool sendData(uint32_t transaction, const std::vector<uint8_t>& data, std::string& error);
    bool receiveResponse(uint32_t transaction, std::vector<uint8_t>* incomingData, std::string& error,
                         std::vector<uint32_t>* responseParameters = nullptr);
    bool verifyProperty(uint16_t property, const Value& target, std::string& error);
    bool verifyRecordState(RecordState expected, std::string& error);
    bool isExtended(uint16_t code) const { return code >= 0xE000 && state_.supportsExtendedProperties; }
    void emit(const std::string& message) const;

    std::unique_ptr<SSHTransport> transport_;
    CameraState state_;
    uint32_t transaction_ = 1;
    uint32_t connectionId_ = 0;
    uint16_t monitoringSettingVersion_ = 0;
    uint32_t monitoringDeliveryId_ = 0;
    bool monitoringActive_ = false;
    StateCallback stateCallback_;
    EventCallback eventCallback_;
};

} // namespace sony
