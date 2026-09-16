#pragma once

#include <algorithm>
#include <cstdint>
#include <iomanip>
#include <map>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <vector>

// PTP/IP and Sony SDIO helpers.  All multi-byte fields are little-endian.
// This file intentionally has no networking dependency so it is unit-testable
// on macOS and on-device.
namespace sony {

constexpr uint16_t kPtpOk = 0x2001;
constexpr uint16_t kOpOpenSession = 0x1002;
constexpr uint16_t kOpSdioConnect = 0x9201;
constexpr uint16_t kOpGetExtDeviceInfo = 0x9202;
constexpr uint16_t kOpSetProperty = 0x9205;
constexpr uint16_t kOpSdioControl = 0x9207;
constexpr uint16_t kOpGetAllPropertyInfo = 0x9209;
constexpr uint16_t kOpGetVendorVersion = 0x9216;

constexpr uint16_t kPropRecordState = 0xD21D;
constexpr uint16_t kPropIso = 0xD21E;
constexpr uint16_t kPropExposureMode = 0x500E;
constexpr uint16_t kPropWhiteBalance = 0x5005;
constexpr uint16_t kPropFocusMode = 0x500A;
constexpr uint16_t kPropFocusArea = 0xD22C;
constexpr uint16_t kPropFocusPullEnable = 0xD235;
constexpr uint16_t kCtrlRelativeFocus = 0xD2D1;
constexpr uint16_t kCtrlShutterS1 = 0xD2C1;

constexpr uint16_t kPropFileFormat = 0xD241;
constexpr uint16_t kPropFrameRate = 0xD286;
constexpr uint16_t kPropRecordSetting = 0xD242;
constexpr uint16_t kPropProxyRecording = 0xD109;
constexpr uint16_t kPropProxyFormat = 0xD0D0;
constexpr uint16_t kPropProxyBitrate = 0xD0D1;

constexpr uint16_t kPropCineEiMode = 0xE000;
constexpr uint16_t kPropBaseIso = 0xD020;
constexpr uint16_t kPropEi = 0xD022;
constexpr uint16_t kPropEiReadback = 0xD023;

constexpr uint16_t kDataInt8 = 0x0001;
constexpr uint16_t kDataUInt8 = 0x0002;
constexpr uint16_t kDataInt16 = 0x0003;
constexpr uint16_t kDataUInt16 = 0x0004;
constexpr uint16_t kDataInt32 = 0x0005;
constexpr uint16_t kDataUInt32 = 0x0006;
constexpr uint16_t kDataInt64 = 0x0007;
constexpr uint16_t kDataUInt64 = 0x0008;
constexpr uint16_t kDataString = 0xFFFF;

struct Value {
    uint16_t type = kDataUInt32;
    std::vector<uint8_t> bytes;

    bool empty() const { return bytes.empty(); }

    int64_t signedNumber() const {
        uint64_t number = unsignedNumber();
        switch (bytes.size()) {
        case 1: return static_cast<int8_t>(number);
        case 2: return static_cast<int16_t>(number);
        case 4: return static_cast<int32_t>(number);
        case 8: return static_cast<int64_t>(number);
        default: return 0;
        }
    }

    uint64_t unsignedNumber() const {
        uint64_t out = 0;
        for (size_t i = 0; i < std::min<size_t>(bytes.size(), 8); ++i) out |= uint64_t(bytes[i]) << (i * 8);
        return out;
    }

    static Value number(uint16_t type, int64_t value) {
        const size_t size = scalarSize(type);
        if (!size) throw std::invalid_argument("PTP value is not a scalar");
        Value out; out.type = type; out.bytes.resize(size);
        uint64_t raw = static_cast<uint64_t>(value);
        for (size_t i = 0; i < size; ++i) out.bytes[i] = uint8_t(raw >> (8 * i));
        return out;
    }

    static size_t scalarSize(uint16_t type) {
        switch (type) {
        case kDataInt8: case kDataUInt8: return 1;
        case kDataInt16: case kDataUInt16: return 2;
        case kDataInt32: case kDataUInt32: return 4;
        case kDataInt64: case kDataUInt64: return 8;
        default: return 0;
        }
    }
};

struct PropertyDescriptor {
    uint16_t code = 0;
    uint16_t type = 0;
    bool writable = false;
    bool enabled = false;
    Value factoryDefault;
    Value current;
    uint8_t form = 0;
    std::optional<Value> rangeMinimum;
    std::optional<Value> rangeMaximum;
    std::optional<Value> rangeStep;
    // Sony's PTP3 0x9209 enumeration form contains two lists. Do not merge them.
    std::vector<Value> setValues;
    std::vector<Value> getSetValues;
};

class Reader {
public:
    explicit Reader(const std::vector<uint8_t>& data) : data_(data) {}
    size_t remaining() const { return data_.size() - offset_; }
    size_t offset() const { return offset_; }
    uint8_t u8() { ensure(1); return data_[offset_++]; }
    uint16_t u16() { ensure(2); uint16_t n = uint16_t(data_[offset_]) | (uint16_t(data_[offset_+1]) << 8); offset_ += 2; return n; }
    uint32_t u32() { ensure(4); uint32_t n = 0; for (int i=0;i<4;++i) n |= uint32_t(data_[offset_+i]) << (8*i); offset_ += 4; return n; }
    uint64_t u64() { ensure(8); uint64_t n = 0; for (int i=0;i<8;++i) n |= uint64_t(data_[offset_+i]) << (8*i); offset_ += 8; return n; }
    std::vector<uint8_t> take(size_t count) { ensure(count); std::vector<uint8_t> v(data_.begin()+offset_, data_.begin()+offset_+count); offset_ += count; return v; }
private:
    void ensure(size_t count) const { if (count > remaining()) throw std::runtime_error("truncated PTP dataset"); }
    const std::vector<uint8_t>& data_; size_t offset_ = 0;
};

class Writer {
public:
    void u8(uint8_t n) { bytes.push_back(n); }
    void u16(uint16_t n) { u8(uint8_t(n)); u8(uint8_t(n >> 8)); }
    void u32(uint32_t n) { for (int i=0;i<4;++i) u8(uint8_t(n >> (8*i))); }
    void u64(uint64_t n) { for (int i=0;i<8;++i) u8(uint8_t(n >> (8*i))); }
    void append(const std::vector<uint8_t>& value) { bytes.insert(bytes.end(), value.begin(), value.end()); }
    std::vector<uint8_t> bytes;
};

inline Value readValue(Reader& reader, uint16_t type) {
    Value out; out.type = type;
    const size_t scalar = Value::scalarSize(type);
    if (scalar) { out.bytes = reader.take(scalar); return out; }
    if (type == kDataString) {
        const uint8_t charsIncludingNull = reader.u8();
        out.bytes.push_back(charsIncludingNull);
        if (charsIncludingNull) { auto rest = reader.take(size_t(charsIncludingNull) * 2); out.bytes.insert(out.bytes.end(), rest.begin(), rest.end()); }
        return out;
    }
    // PTP arrays are their scalar type plus 0x4000 and begin with UInt32 count.
    const uint16_t elementType = type & 0x3FFF;
    const size_t elementSize = Value::scalarSize(elementType);
    if ((type & 0x4000) && elementSize) {
        const uint32_t count = reader.u32();
        Writer encoded; encoded.u32(count); encoded.append(reader.take(size_t(count) * elementSize));
        out.bytes = std::move(encoded.bytes); return out;
    }
    throw std::runtime_error("unsupported PTP datatype");
}

inline std::vector<PropertyDescriptor> parseAllPropertyInfo(const std::vector<uint8_t>& dataset) {
    Reader reader(dataset);
    const uint64_t count = reader.u64();
    std::vector<PropertyDescriptor> properties;
    properties.reserve(static_cast<size_t>(std::min<uint64_t>(count, 4096)));
    for (uint64_t i = 0; i < count; ++i) {
        PropertyDescriptor p;
        p.code = reader.u16();
        p.type = reader.u16();
        p.writable = reader.u8() != 0;
        p.enabled = reader.u8() != 0;
        p.factoryDefault = readValue(reader, p.type);
        p.current = readValue(reader, p.type);
        p.form = reader.u8();
        if (p.form == 1) {
            p.rangeMinimum = readValue(reader, p.type);
            p.rangeMaximum = readValue(reader, p.type);
            p.rangeStep = readValue(reader, p.type);
        } else if (p.form == 2) {
            const uint16_t setCount = reader.u16();
            p.setValues.reserve(setCount);
            for (uint16_t j = 0; j < setCount; ++j) p.setValues.push_back(readValue(reader, p.type));
            const uint16_t getSetCount = reader.u16();
            p.getSetValues.reserve(getSetCount);
            for (uint16_t j = 0; j < getSetCount; ++j) p.getSetValues.push_back(readValue(reader, p.type));
        }
        properties.push_back(std::move(p));
    }
    if (reader.remaining() != 0) throw std::runtime_error("unexpected bytes after PTP property dataset");
    return properties;
}

inline std::string hex(uint64_t value, unsigned width = 0) {
    std::ostringstream stream; stream << "0x" << std::uppercase << std::hex << std::setfill('0');
    if (width) stream << std::setw(width); stream << value; return stream.str();
}

inline std::string formatValue(const Value& value) {
    if (value.type == kDataString) return "PTP string";
    if (value.type & 0x4000) return "PTP array";
    const bool isSigned = value.type == kDataInt8 || value.type == kDataInt16 || value.type == kDataInt32 || value.type == kDataInt64;
    return isSigned ? std::to_string(value.signedNumber()) : std::to_string(value.unsignedNumber());
}

inline std::string sha256Fingerprint(const unsigned char* fingerprint, size_t length) {
    std::ostringstream stream;
    for (size_t i = 0; i < length; ++i) {
        if (i) stream << ':';
        stream << std::uppercase << std::hex << std::setw(2) << std::setfill('0') << unsigned(fingerprint[i]);
    }
    return stream.str();
}

} // namespace sony
