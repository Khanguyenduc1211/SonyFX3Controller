#pragma once
/*
  libssh2 1.10.0 ESP32 Arduino configuration.
  Crypto backend: ESP-IDF / Arduino-ESP32 bundled mbedTLS.
  Target baseline: Arduino-ESP32 3.3.11 (ESP-IDF 5.5.x).
*/

#define LIBSSH2_MBEDTLS 1
#define LIBSSH2_CLEAR_MEMORY 1
#define LIBSSH2_DH_GEX_NEW 1

#define HAVE_UNISTD_H 1
#define HAVE_INTTYPES_H 1
#define HAVE_STDLIB_H 1
#define HAVE_SYS_SELECT_H 1
#define HAVE_SYS_UIO_H 1
#define HAVE_SYS_SOCKET_H 1
#define HAVE_SYS_IOCTL_H 1
#define HAVE_SYS_TIME_H 1

#define HAVE_LONGLONG 1
#define HAVE_GETTIMEOFDAY 1
#define HAVE_SELECT 1
#define HAVE_SOCKET 1
#define HAVE_STRTOLL 1
#define HAVE_SNPRINTF 1

#define HAVE_O_NONBLOCK 1

#ifndef LIBSSH2_API
#define LIBSSH2_API
#endif

#ifndef PACKAGE
#define PACKAGE "libssh2"
#endif
#ifndef PACKAGE_NAME
#define PACKAGE_NAME "libssh2"
#endif
#ifndef PACKAGE_VERSION
#define PACKAGE_VERSION "1.10.0-esp32-mbedtls3"
#endif
#ifndef VERSION
#define VERSION PACKAGE_VERSION
#endif
