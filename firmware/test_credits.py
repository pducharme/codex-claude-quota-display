"""Run after pio run: python3 firmware/test_credits.py (requires a C++ compiler)."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).parent
source = (root / "src/main.cpp").read_text()
types = source[source.index("struct Window {"):source.index("struct BankedResets {")]
available = source[source.index("bool providerAvailable("):source.index("constexpr int providerCardWidth(")]
functions = source[source.index("Window jsonWindow("):source.index("void readBankedResets(")]
check = r"""
#include <ArduinoJson.h>
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <ctime>
#include <string>
struct String : std::string {
  using std::string::string;
  using std::string::operator=;
  String(const std::string &value) : std::string(value) {}
  String(double value, int decimals) {
    char text[64]; snprintf(text, sizeof(text), "%.*f", decimals, value); assign(text);
  }
};
int constrain(int value, int low, int high) { return std::max(low, std::min(high, value)); }
""" + types + available + functions + r"""
int main() {
  JsonDocument document;
  assert(!deserializeJson(document, R"({"codex":{"status":"error","credits":{"balance":12345.67},
    "api_credits":{"currency":"USD","status":"ok","monthly":95.18,"monthly_granted":96,"expires_at":1795965002}}})"));
  Provider provider;
  auto read = [&]() { readProvider(document.as<JsonObjectConst>(), "codex", provider); };
  read();
  assert(provider.creditLines[0] == "CREDITS OPENAI: 12345.67");
  assert(provider.creditLines[1] == "API: 0.82$ / 96.00$ (USD) - exp. 29/11");
  JsonObject credits = document["codex"]["api_credits"];
  credits["monthly"] = 96;
  read(); assert(provider.creditLines[1] == "API: 0.00$ / 96.00$ (USD) - exp. 29/11");
  credits["monthly"] = 0;
  read(); assert(provider.creditLines[1] == "API: 96.00$ / 96.00$ (USD) - exp. 29/11");
  for (const char *invalid : {"null", "-1", "97", "true", "\"95.18\""}) {
    JsonDocument value; assert(!deserializeJson(value, invalid));
    credits["monthly"].set(value.as<JsonVariantConst>());
    read(); assert(provider.creditLines[1] == "API: -- / 96.00$ (USD) - exp. 29/11");
  }
  credits["monthly"] = 0;
  credits["monthly_granted"] = 500;
  credits["status"] = "stale";
  read();
  assert(!provider.creditsStale[0] && provider.creditsStale[1]);
  assert(provider.creditLines[1] == "~ API: 500.00$ / 500.00$ (USD) - exp. 29/11");
  assert(provider.creditLines[1].length() <= (310 - 24) / 6);
  document["codex"].remove("credits");
  read(); assert(providerAvailable(provider));
  credits["currency"] = "CAD";
  read(); assert(provider.creditLines[1] == "API: -- (USD)");
  assert(!providerAvailable(provider));
  document["codex"].remove("api_credits");
  read(); assert(provider.creditLines[1] == "API: -- (USD)");
  assert(!provider.creditsStale[0] && !provider.creditsStale[1]);
  assert(!deserializeJson(document, R"({"claude":{"credits":{"status":"stale","purchased":0,
    "monthly":199.18,"monthly_granted":200,"expires_at":1795651200}}})"));
  readProvider(document.as<JsonObjectConst>(), "claude", provider);
  assert(provider.creditLines[0] == "~ API ACHETES: 0.00$ (USD)");
  assert(provider.creditLines[1] == "~ UTILISE: 0.82$ / 200.00$ (USD) - exp. 26/11");
  assert(provider.creditsStale[0] && provider.creditsStale[1]);
}
"""
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / "check.cpp"
    binary = Path(directory) / "check"
    cpp.write_text(check)
    subprocess.run(["c++", "-std=c++11", "-I", str(root / ".pio/libdeps/quota_display/ArduinoJson/src"),
                    str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("Credits: separate USD grants, invalid balances, freshness and compact width passed")
