#include <cassert>
#include <string>
#include "src/ConfigurationValidation.h"

int main() {
  for (const char *host : {"192.168.1.20:8788", "mac.local:8788", "mac", "mac:65535"})
    assert(validHost(host));
  for (const char *host : {"", ":8788", "mac:", "mac:0", "mac:65536", "mac:999999999999",
                           "mac:abc", "mac:80:90", "http://mac:8788", "mac/path", "mac?x=1",
                           "mac\r\nX-Test:1", "<script>", "-mac", "mac."})
    assert(!validHost(host));
  assert(!validHost(std::string(121, 'a').c_str()));
  assert(validToken(std::string(16, 'a').c_str()));
  assert(validToken(std::string(128, 'a').c_str()));
  assert(!validToken(std::string(15, 'a').c_str()));
  assert(!validToken(std::string(129, 'a').c_str()));
  assert(!validToken("0123456789abcdef\r\nX-Test: 1"));
  assert(!validToken("0123456789abc def"));
}
