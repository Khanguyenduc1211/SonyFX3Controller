#include "SSHTransport.hpp"
#include "SonyProtocol.hpp"

#include <libssh2.h>

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

namespace sony {
namespace {
void keyboardInteractivePasswordCallback(const char*, int, const char*, int,
                                         int promptCount,
                                         const LIBSSH2_USERAUTH_KBDINT_PROMPT*,
                                         LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses,
                                         void** abstract) {
    auto* password = abstract ? static_cast<std::string*>(*abstract) : nullptr;
    if (!password) return;
    // Sony's keyboard-interactive prompt is answered with the same password
    // entered by the user. libssh2 owns and frees response text after use.
    for (int i = 0; i < promptCount; ++i) {
        responses[i].length = static_cast<unsigned int>(password->size());
        responses[i].text = static_cast<char*>(std::malloc(password->size()));
        if (responses[i].text && !password->empty()) std::memcpy(responses[i].text, password->data(), password->size());
    }
}
}

SSHTransport::SSHTransport() { libssh2_init(0); }
SSHTransport::~SSHTransport() { close(); libssh2_exit(); }

SSHResult SSHTransport::connectAndVerify(const std::string& host, uint16_t port, const std::string& expectedFingerprint) {
    close();
    addrinfo hints{}; hints.ai_family = AF_UNSPEC; hints.ai_socktype = SOCK_STREAM;
    addrinfo* addresses = nullptr;
    const std::string portText = std::to_string(port);
    if (getaddrinfo(host.c_str(), portText.c_str(), &hints, &addresses) != 0) return {false, false, "Cannot resolve camera address", {}};
    for (addrinfo* address = addresses; address; address = address->ai_next) {
        socket_ = socket(address->ai_family, address->ai_socktype, address->ai_protocol);
        if (socket_ < 0) continue;
        if (::connect(socket_, address->ai_addr, address->ai_addrlen) == 0) break;
        ::close(socket_); socket_ = -1;
    }
    freeaddrinfo(addresses);
    if (socket_ < 0) return {false, false, "Cannot connect to camera SSH service on port 22", {}};

    session_ = libssh2_session_init_ex(nullptr, nullptr, nullptr, &keyboardPassword_);
    if (!session_) { close(); return {false, false, "Cannot create SSH session", {}}; }
    libssh2_session_set_blocking(session_, 1);
    if (libssh2_session_handshake(session_, socket_) != 0) {
        const auto message = lastSshError(); close(); return {false, false, "SSH handshake failed: " + message, {}};
    }
    const auto* raw = reinterpret_cast<const unsigned char*>(libssh2_hostkey_hash(session_, LIBSSH2_HOSTKEY_HASH_SHA256));
    if (!raw) { close(); return {false, false, "Camera did not provide an SSH SHA-256 fingerprint", {}}; }
    const std::string actual = sha256Fingerprint(raw, 32);
    if (expectedFingerprint.empty()) { close(); return {false, true, "Trust this camera fingerprint before sending credentials", actual}; }
    if (actual != expectedFingerprint) { close(); return {false, false, "SSH fingerprint changed. Authentication was blocked.", actual}; }
    return {true, false, "SSH host identity verified", actual};
}

SSHResult SSHTransport::authenticatePassword(const std::string& username, const std::string& password) {
    if (!session_) return {false, false, "SSH session is not connected", {}};
    const char* methods = libssh2_userauth_list(session_, username.c_str(), static_cast<unsigned int>(username.size()));
    const std::string advertisedMethods = methods ? methods : "(camera did not report methods)";
    if (libssh2_userauth_password_ex(session_, username.c_str(), static_cast<unsigned int>(username.size()), password.c_str(), static_cast<unsigned int>(password.size()), nullptr) == 0)
        return {true, false, "SSH password authentication completed", {}};

    const std::string passwordFailure = lastSshError();
    // Some Sony firmware advertises only keyboard-interactive authentication.
    // This is still password authentication; it is not a shell login or a
    // protocol fallback. The host key was verified before this point.
    keyboardPassword_ = password;
    const int keyboardResult = libssh2_userauth_keyboard_interactive_ex(
        session_, username.c_str(), static_cast<unsigned int>(username.size()), keyboardInteractivePasswordCallback);
    keyboardPassword_.clear();
    if (keyboardResult == 0) return {true, false, "SSH keyboard-interactive authentication completed", {}};
    return {false, false, "Camera rejected SSH credentials. Offered methods: " + advertisedMethods + ". Password: " + passwordFailure + "; keyboard-interactive: " + lastSshError(), {}};
}

bool SSHTransport::openCameraTunnels(std::string& error) {
    if (!session_) { error = "SSH session is not authenticated"; return false; }
    commandChannel_ = libssh2_channel_direct_tcpip_ex(session_, "localhost", 15740, "127.0.0.1", 0);
    if (!commandChannel_) { error = "Cannot open SSH command tunnel to camera localhost:15740: " + lastSshError(); return false; }
    eventChannel_ = libssh2_channel_direct_tcpip_ex(session_, "localhost", 15740, "127.0.0.1", 0);
    if (!eventChannel_) { error = "Cannot open SSH event tunnel to camera localhost:15740: " + lastSshError(); return false; }
    return true;
}

bool SSHTransport::waitSocket(bool read, uint32_t timeoutMilliseconds, std::string& error) const {
    if (socket_ < 0) { error = "SSH socket is closed"; return false; }
    fd_set fds; FD_ZERO(&fds); FD_SET(socket_, &fds);
    timeval timeout{}; timeout.tv_sec = timeoutMilliseconds / 1000; timeout.tv_usec = (timeoutMilliseconds % 1000) * 1000;
    const int result = select(socket_ + 1, read ? &fds : nullptr, read ? nullptr : &fds, nullptr, &timeout);
    if (result > 0) return true;
    error = result == 0 ? "SSH tunnel timed out" : std::string("Socket wait failed: ") + strerror(errno);
    return false;
}

bool SSHTransport::writeChannel(_LIBSSH2_CHANNEL* channel, const std::vector<uint8_t>& bytes, std::string& error) {
    if (!channel) { error = "SSH tunnel is closed"; return false; }
    size_t offset = 0;
    while (offset < bytes.size()) {
        const ssize_t written = libssh2_channel_write(channel, reinterpret_cast<const char*>(bytes.data() + offset), bytes.size() - offset);
        if (written > 0) { offset += static_cast<size_t>(written); continue; }
        if (written == LIBSSH2_ERROR_EAGAIN && waitSocket(false, 5000, error)) continue;
        error = "SSH tunnel write failed: " + lastSshError(); return false;
    }
    return true;
}

bool SSHTransport::readChannelExact(_LIBSSH2_CHANNEL* channel, uint8_t* destination, size_t count, uint32_t timeoutMilliseconds, std::string& error) {
    if (!channel) { error = "SSH tunnel is closed"; return false; }
    size_t offset = 0;
    while (offset < count) {
        const ssize_t received = libssh2_channel_read(channel, reinterpret_cast<char*>(destination + offset), count - offset);
        if (received > 0) { offset += static_cast<size_t>(received); continue; }
        if (received == LIBSSH2_ERROR_EAGAIN && waitSocket(true, timeoutMilliseconds, error)) continue;
        error = "SSH tunnel read failed: " + lastSshError(); return false;
    }
    return true;
}

bool SSHTransport::writeCommand(const std::vector<uint8_t>& bytes, std::string& error) { return writeChannel(commandChannel_, bytes, error); }
bool SSHTransport::writeEvent(const std::vector<uint8_t>& bytes, std::string& error) { return writeChannel(eventChannel_, bytes, error); }
bool SSHTransport::readCommandExact(uint8_t* d, size_t n, uint32_t t, std::string& e) { return readChannelExact(commandChannel_, d, n, t, e); }
bool SSHTransport::readEventExact(uint8_t* d, size_t n, uint32_t t, std::string& e) { return readChannelExact(eventChannel_, d, n, t, e); }

std::string SSHTransport::lastSshError() const {
    if (!session_) return "no SSH session";
    char* message = nullptr; int length = 0; libssh2_session_last_error(session_, &message, &length, 0);
    return message && length > 0 ? std::string(message, static_cast<size_t>(length)) : "unknown libssh2 error";
}

void SSHTransport::close() {
    if (commandChannel_) { libssh2_channel_close(commandChannel_); libssh2_channel_free(commandChannel_); commandChannel_ = nullptr; }
    if (eventChannel_) { libssh2_channel_close(eventChannel_); libssh2_channel_free(eventChannel_); eventChannel_ = nullptr; }
    if (session_) { libssh2_session_disconnect(session_, "SonyFX3Controller disconnect"); libssh2_session_free(session_); session_ = nullptr; }
    if (socket_ >= 0) { ::close(socket_); socket_ = -1; }
}

} // namespace sony
