#pragma once

#include <array>
#include <cstdint>
#include <mutex>
#include <optional>
#include <vector>

namespace sony {

// Sony libmonitor_protocol 2.02 binary-derived VERIC facts:
// - every packet starts with ASCII "VERIC"
// - the transport header is exactly 64 bytes (PacketAnalyser advances
//   PacketDataInfo offset by +64 and length by -64)
// - multi-byte header fields parsed by PacketAnalyser are network/big-endian.
// Field semantics below remain intentionally unnamed until every member is
// mapped; this parser only exposes offsets that are actually consumed by Sony.
struct VericHeader {
    static constexpr size_t kSize = 64;

    int8_t field05 = 0;
    uint8_t field06 = 0;
    int8_t field07 = 0;
    uint32_t field08 = 0;
    uint32_t field12 = 0;
    uint8_t field16 = 0;
    int8_t field17 = 0;
    uint16_t field18 = 0;
    uint32_t field20 = 0;
    uint16_t field24 = 0;
    uint16_t field26 = 0;
    uint64_t field32 = 0;
    uint64_t field40 = 0;
    int8_t field56 = 0;
    int8_t field57 = 0;
    int8_t field58 = 0;
};

inline uint16_t vericBE16(const uint8_t* p) {
    return (uint16_t(p[0]) << 8) | uint16_t(p[1]);
}

inline uint32_t vericBE32(const uint8_t* p) {
    return (uint32_t(p[0]) << 24) | (uint32_t(p[1]) << 16) |
           (uint32_t(p[2]) << 8) | uint32_t(p[3]);
}

inline uint64_t vericBE64(const uint8_t* p) {
    return (uint64_t(vericBE32(p)) << 32) | vericBE32(p + 4);
}

inline bool parseVericHeader(const uint8_t* bytes, size_t size, VericHeader& out) {
    if (!bytes || size < VericHeader::kSize) return false;
    static constexpr std::array<uint8_t, 5> magic{{'V','E','R','I','C'}};
    for (size_t i = 0; i < magic.size(); ++i) {
        if (bytes[i] != magic[i]) return false;
    }

    out.field05 = static_cast<int8_t>(bytes[5]);
    out.field06 = bytes[6];
    out.field07 = static_cast<int8_t>(bytes[7]);
    out.field08 = vericBE32(bytes + 8);
    out.field12 = vericBE32(bytes + 12);
    out.field16 = bytes[16];
    out.field17 = static_cast<int8_t>(bytes[17]);
    out.field18 = vericBE16(bytes + 18);
    out.field20 = vericBE32(bytes + 20);
    out.field24 = vericBE16(bytes + 24);
    out.field26 = vericBE16(bytes + 26);
    out.field32 = vericBE64(bytes + 32);
    out.field40 = vericBE64(bytes + 40);
    out.field56 = static_cast<int8_t>(bytes[56]);
    out.field57 = static_cast<int8_t>(bytes[57]);
    out.field58 = static_cast<int8_t>(bytes[58]);
    return true;
}

// Latest-frame mailbox. It never queues historical JPEGs: a slow UI/decode
// consumer always receives the newest complete frame, bounding display latency.
class SonyMonitoringReceiver {
public:
    struct Frame {
        uint64_t sequence = 0;
        std::vector<uint8_t> jpeg;
    };

    void publishCompleteJpeg(uint64_t sequence, std::vector<uint8_t> jpeg) {
        if (jpeg.size() < 4 || jpeg[0] != 0xFF || jpeg[1] != 0xD8) return;
        std::lock_guard<std::mutex> lock(mutex_);
        if (latest_ && sequence <= latest_->sequence) return;
        latest_ = Frame{sequence, std::move(jpeg)};
    }

    std::optional<Frame> takeLatest() {
        std::lock_guard<std::mutex> lock(mutex_);
        if (!latest_) return std::nullopt;
        auto frame = std::move(latest_);
        latest_.reset();
        return frame;
    }

private:
    std::mutex mutex_;
    std::optional<Frame> latest_;
};

} // namespace sony
