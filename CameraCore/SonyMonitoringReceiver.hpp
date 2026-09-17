#pragma once

#include <cstdint>
#include <mutex>
#include <optional>
#include <vector>

namespace sony {

// Latest-frame mailbox used by the future Sony push receiver.  It intentionally
// never queues historical JPEGs: UI/decode consumers get the newest complete
// frame and stale frames are discarded, keeping latency bounded.
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
