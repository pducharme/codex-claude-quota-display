#pragma once

#include <cctype>
#include <cstring>

inline bool validHost(const char *value) {
  size_t length = strlen(value);
  if (length < 3 || length > 120) return false;
  const char *colon = strchr(value, ':');
  size_t hostnameLength = colon ? static_cast<size_t>(colon - value) : length;
  if (!hostnameLength || value[0] == '.' || value[0] == '-' ||
      value[hostnameLength - 1] == '.' || value[hostnameLength - 1] == '-') return false;
  for (size_t i = 0; i < hostnameLength; ++i) {
    unsigned char c = value[i];
    if (!(std::isalnum(c) || c == '.' || c == '-')) return false;
  }
  if (!colon) return true;
  unsigned port = 0;
  if (!colon[1]) return false;
  for (const char *p = colon + 1; *p; ++p) {
    if (*p < '0' || *p > '9') return false;
    port = port * 10 + (*p - '0');
    if (port > 65535) return false;
  }
  return port > 0;
}

inline bool validToken(const char *value) {
  size_t length = strlen(value);
  if (length < 16 || length > 128) return false;
  for (size_t i = 0; i < length; ++i) {
    unsigned char c = value[i];
    if (c <= 32 || c >= 127) return false;
  }
  return true;
}
