#include "SSHTransport.hpp"
#include "SonyProtocol.hpp"

#include <libssh2.h>

#include <arpa/inet.h>
#include <cerrno>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <netdb.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <unistd.h>

namespace sony {
namespace {
void keyboardInteractivePasswordCallback(const char*, int, const char*, int,
                                         int promptCount,
                                         const LIBSSH2_USERAUTH_KBDINT_PROMPT* prompts,
                                         LIBSSH2_USERAUTH_KBDINT_RESPONSE* responses,
                                         void** abstract) {
    auto* password = abstract ? static_cast<std::string*>(*abstract) : nullptr;
    if (!password) return;

    // Sony exposes the Access Authentication password as a hidden
    // keyboard-interactive challenge. Do not answer echo-enabled prompts.
    for (int i = 0; i < promptCount; ++i) {
        responses[i].text = nullptr;
        responses[i].length = 0;
        if (!prompts || prompts[i].echo != 0 || password->empty()) continue;

        const size_t length = password->size();
        char* reply = static_cast<char*>(std::malloc(length + 1));
        if (!reply) continue;
        std::memcpy(reply, password->data(), length);
        reply[length] = '\0';
        responses[i].text = reply;
        responses[i].length = static_cast<unsigned int>(length);
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

    // libssh2's non-blocking API requires its underlying TCP socket to be
    // non-blocking as well. The ESP32 controller does this before handshake.
    const int socketFlags = fcntl(socket_, F_GETFL, 0);
    if (socketFlags < 0 || fcntl(socket_, F_SETFL, socketFlags | O_NONBLOCK) != 0) {
        close(); return {false, false, "Cannot configure non-blocking SSH socket", {}};
    }

    session_ = libssh2_session_init_ex(nullptr, nullptr, nullptr, &keyboardPassword_);
    if (!session_) { close(); return {false, false, "Cannot create SSH session", {}}; }
    libssh2_session_set_blocking(session_, 0);
    libssh2_session_set_timeout(session_, 8000);
    // Sony's SSH service uses this cipher in the documented controller flow.
    if (libssh2_session_method_pref(session_, LIBSSH2_METHOD_CRYPT_CS, "aes128-ctr") != 0 ||
        libssh2_session_method_pref(session_, LIBSSH2_METHOD_CRYPT_SC, "aes128-ctr") != 0) {
        close(); return {false, false, "Camera SSH cipher aes128-ctr could not be selected", {}};
    }
    int handshake = LIBSSH2_ERROR_EAGAIN;
    while (handshake == LIBSSH2_ERROR_EAGAIN) {
        handshake = libssh2_session_handshake(session_, socket_);
        if (handshake == LIBSSH2_ERROR_EAGAIN) { std::string ignored; if (!waitSocket(true, 10000, ignored)) { close(); return {false, false, "SSH handshake timed out", {}}; } }
    }
    if (handshake != 0) {
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
    if (username.empty()) return {false, false, "Sony access username is empty", {}};
    if (password.empty()) return {false, false, "Sony access password is empty", {}};

    const char* methods = nullptr;
    for (;;) {
        methods = libssh2_userauth_list(session_, username.c_str(),
                                        static_cast<unsigned int>(username.size()));
        if (methods) break;
        if (libssh2_userauth_authenticated(session_))
            return {true, false, "SSH server accepted authentication", {}};

        const int rc = libssh2_session_last_errno(session_);
        if (rc != LIBSSH2_ERROR_EAGAIN)
            return {false, false, "Unable to query SSH authentication methods: " + lastSshError(), {}};

        std::string waitError;
        if (!waitSocket(true, 10000, waitError))
            return {false, false, "SSH authentication-method query failed: " + waitError, {}};
    }

    const std::string advertisedMethods = methods;
    const bool canPassword = advertisedMethods.find("password") != std::string::npos;
    const bool canKeyboard = advertisedMethods.find("keyboard-interactive") != std::string::npos;

    std::string passwordFailure = "not advertised";
    if (canPassword) {
        for (;;) {
            const int rc = libssh2_userauth_password_ex(
                session_,
                username.c_str(), static_cast<unsigned int>(username.size()),
                password.c_str(), static_cast<unsigned int>(password.size()),
                nullptr);

            if (rc == 0)
                return {true, false, "SSH password authentication completed", {}};

            if (rc != LIBSSH2_ERROR_EAGAIN) {
                passwordFailure = lastSshError();
                break;
            }

            std::string waitError;
            if (!waitSocket(true, 10000, waitError))
                return {false, false, "SSH password authentication transport wait failed: " + waitError, {}};
        }
    }

    std::string keyboardFailure = "not advertised";
    if (canKeyboard) {
        keyboardPassword_ = password;
        for (;;) {
            const int rc = libssh2_userauth_keyboard_interactive_ex(
                session_,
                username.c_str(), static_cast<unsigned int>(username.size()),
                keyboardInteractivePasswordCallback);

            if (rc == 0) {
                keyboardPassword_.clear();
                return {true, false, "SSH keyboard-interactive authentication completed", {}};
            }

            if (rc != LIBSSH2_ERROR_EAGAIN) {
                keyboardFailure = lastSshError();
                break;
            }

            std::string waitError;
            if (!waitSocket(true, 10000, waitError)) {
                keyboardPassword_.clear();
                return {false, false, "SSH keyboard-interactive transport wait failed: " + waitError, {}};
            }
        }
        keyboardPassword_.clear();
    }

    if (!canPassword && !canKeyboard) {
        return {false, false,
                "Camera SSH server does not advertise password/keyboard-interactive auth. Offered methods: " +
                    advertisedMethods,
                {}};
    }

    return {false, false,
            "Camera rejected SSH credentials. Offered methods: " + advertisedMethods +
                ". Password: " + passwordFailure +
                "; keyboard-interactive: " + keyboardFailure,
            {}};
}

bool SSHTransport::openCameraTunnels(std::string& error) {
    if (!session_) { error = "SSH session is not authenticated"; return false; }
    // Use libssh2's canonical direct-tcpip helper, matching the working
    // controller path: SSH -> localhost:15740 inside the camera.
    for (;;) {
        commandChannel_ = libssh2_channel_direct_tcpip(session_, "localhost", 15740);
        if (commandChannel_) break;
        if (libssh2_session_last_errno(session_) != LIBSSH2_ERROR_EAGAIN) {
            error = "Cannot open SSH command tunnel to camera localhost:15740: " + lastSshError();
            return false;
        }
        std::string waitError;
        if (!waitSocket(false, 10000, waitError)) {
            error = "SSH command tunnel wait failed: " + waitError;
            return false;
        }
    }
    for (;;) {
        eventChannel_ = libssh2_channel_direct_tcpip(session_, "localhost", 15740);
        if (eventChannel_) break;
        if (libssh2_session_last_errno(session_) != LIBSSH2_ERROR_EAGAIN) {
            error = "Cannot open SSH event tunnel to camera localhost:15740: " + lastSshError();
            return false;
        }
        std::string waitError;
        if (!waitSocket(false, 10000, waitError)) {
            error = "SSH event tunnel wait failed: " + waitError;
            return false;
        }
    }
    return true;
}

bool SSHTransport::waitSocket(bool read, uint32_t timeoutMilliseconds, std::string& error) const {
    (void)read; // libssh2_session_block_directions() is authoritative.
    if (socket_ < 0 || !session_) { error = "SSH socket/session is closed"; return false; }

    const int directions = libssh2_session_block_directions(session_);

    // libssh2 can transiently return EAGAIN with no block direction.
    // Do not wait on an arbitrarily chosen read/write side in that state;
    // retry after a tiny delay, matching the proven controller behavior.
    if (directions == 0) {
        usleep(1000);
        return true;
    }

    fd_set readable, writable;
    FD_ZERO(&readable);
    FD_ZERO(&writable);
    if (directions & LIBSSH2_SESSION_BLOCK_INBOUND) FD_SET(socket_, &readable);
    if (directions & LIBSSH2_SESSION_BLOCK_OUTBOUND) FD_SET(socket_, &writable);

    timeval timeout{};
    timeout.tv_sec = timeoutMilliseconds / 1000;
    timeout.tv_usec = (timeoutMilliseconds % 1000) * 1000;

    int result;
    do {
        result = select(socket_ + 1, &readable, &writable, nullptr, &timeout);
    } while (result < 0 && errno == EINTR);

    if (result > 0) return true;
    if (result == 0) {
        error = "SSH socket wait timed out";
        return false;
    }
    error = std::string("SSH socket wait failed: ") + strerror(errno);
    return false;
}

bool SSHTransport::writeChannel(_LIBSSH2_CHANNEL* channel, const std::vector<uint8_t>& bytes, std::string& error) {
    if (!channel) { error = "SSH tunnel is closed"; return false; }
    size_t offset = 0;
    while (offset < bytes.size()) {
        const ssize_t written = libssh2_channel_write(
            channel,
            reinterpret_cast<const char*>(bytes.data() + offset),
            bytes.size() - offset);

        if (written > 0) {
            offset += static_cast<size_t>(written);
            continue;
        }

        if (written == LIBSSH2_ERROR_EAGAIN || written == 0) {
            std::string waitError;
            if (waitSocket(false, 5000, waitError)) continue;
            error = "SSH tunnel write wait failed: " + waitError;
            return false;
        }

        error = "SSH tunnel write failed (rc=" + std::to_string(written) + "): " + lastSshError();
        return false;
    }
    return true;
}

bool SSHTransport::readChannelExact(_LIBSSH2_CHANNEL* channel, uint8_t* destination, size_t count, uint32_t timeoutMilliseconds, std::string& error) {
    if (!channel) { error = "SSH tunnel is closed"; return false; }
    size_t offset = 0;
    while (offset < count) {
        const ssize_t received = libssh2_channel_read(
            channel,
            reinterpret_cast<char*>(destination + offset),
            count - offset);

        if (received > 0) {
            offset += static_cast<size_t>(received);
            continue;
        }

        if (libssh2_channel_eof(channel)) {
            error = "SSH tunnel closed by camera";
            return false;
        }

        if (received == LIBSSH2_ERROR_EAGAIN || received == 0) {
            std::string waitError;
            if (waitSocket(true, timeoutMilliseconds, waitError)) continue;
            error = "SSH tunnel read wait failed: " + waitError;
            return false;
        }

        error = "SSH tunnel read failed (rc=" + std::to_string(received) + "): " + lastSshError();
        return false;
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
