#pragma once

#include "SonyProtocol.hpp"

#include <chrono>
#include <map>
#include <string>

namespace sony {

enum class RecordState : uint32_t { stopped = 0, recording = 1, unable = 2, unknown = 0xFFFFFFFF };

struct CameraState {
    std::map<uint16_t, PropertyDescriptor> properties;
    RecordState recordState = RecordState::unknown;
    uint32_t vendorVersion = 0;
    bool supportsExtendedProperties = false;
    std::chrono::steady_clock::time_point lastRefresh{};

    const PropertyDescriptor* property(uint16_t code) const {
        auto it = properties.find(code);
        return it == properties.end() ? nullptr : &it->second;
    }
    bool canWrite(uint16_t code) const {
        const auto* p = property(code);
        return p && p->writable && p->enabled;
    }
    void update(const std::vector<PropertyDescriptor>& parsed) {
        properties.clear();
        for (const auto& item : parsed) properties[item.code] = item;
        if (const auto* record = property(kPropRecordState)) recordState = static_cast<RecordState>(record->current.unsignedNumber());
        lastRefresh = std::chrono::steady_clock::now();
    }
};

} // namespace sony
