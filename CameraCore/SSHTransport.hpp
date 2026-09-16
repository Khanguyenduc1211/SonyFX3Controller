#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct _LIBSSH2_SESSION;
struct _LIBSSH2_CHANNEL;

namespace sony {

struct SSHResult {
    bool ok = false;
    bool needsTrust = false;
    std::string message;
    std::string fingerprint;
};

// The only network path used by this app.  Camera PTP/IP is carried in two
// SSH direct-tcpip channels to localhost:15740; no raw connection to 15740 is
// ever opened from the phone.
class SSHTransport {
public:
    SSHTransport();
    ~SSHTransport();
    SSHTransport(const SSHTransport&) = delete;
    SSHTransport& operator=(const SSHTransport&) = delete;

    SSHResult connectAndVerify(const std::string& host, uint16_t port,
                               const std::string& expectedFingerprint);
    SSHResult authenticatePassword(const std::string& username, const std::string& password);
    bool openCameraTunnels(std::string& error);
    bool writeCommand(const std::vector<uint8_t>& bytes, std::string& error);
    bool writeEvent(const std::vector<uint8_t>& bytes, std::string& error);
    bool readCommandExact(uint8_t* destination, size_t count, uint32_t timeoutMilliseconds, std::string& error);
    bool readEventExact(uint8_t* destination, size_t count, uint32_t timeoutMilliseconds, std::string& error);
    bool connected() const { return session_ != nullptr; }
    void close();

private:
    bool writeChannel(_LIBSSH2_CHANNEL* channel, const std::vector<uint8_t>& bytes, std::string& error);
    bool readChannelExact(_LIBSSH2_CHANNEL* channel, uint8_t* destination, size_t count, uint32_t timeoutMilliseconds, std::string& error);
    bool waitSocket(bool read, uint32_t timeoutMilliseconds, std::string& error) const;
    std::string lastSshError() const;

    int socket_ = -1;
    _LIBSSH2_SESSION* session_ = nullptr;
    _LIBSSH2_CHANNEL* commandChannel_ = nullptr;
    _LIBSSH2_CHANNEL* eventChannel_ = nullptr;
    // Passed to libssh2_session_init_ex as the keyboard-interactive callback
    // context; it must remain alive while the session exists.
    std::string keyboardPassword_;
};

} // namespace sony
