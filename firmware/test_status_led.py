"""Run with python3 firmware/test_status_led.py (requires a C++ compiler)."""
from pathlib import Path
import subprocess
import tempfile

source = (Path(__file__).parent / "src/main.cpp").read_text()
function = source[source.index("bool disableStatusLed() {"):source.index("void setupDisplay() {")]
check = r"""
#include <cassert>
#include <cstdint>
#include <vector>
struct {
  int value = 0, error = 0, count = 1, writes = 0;
  std::vector<uint8_t> bytes;
  void beginTransmission(uint8_t address) { assert(address == 0x6A); bytes.clear(); }
  void write(uint8_t byte) { bytes.push_back(byte); }
  int endTransmission(bool stop = true) {
    assert(bytes[0] == 0x07);
    if (!stop) return error == 1;
    assert(bytes.size() == 2);
    ++writes;
    if (error == 2) return 1;
    value = bytes[1];
    return 0;
  }
  int requestFrom(uint8_t address, uint8_t size) {
    assert(address == 0x6A && size == 1); return count;
  }
  int read() { return value; }
} Wire;
""" + function + r"""
int main() {
  for (int value = 0; value < 256; ++value) {
    Wire.value = value;
    assert(disableStatusLed());
    assert((Wire.value & 0x70) == 0x40);
    assert((Wire.value & 0x8F) == (value & 0x8F));
  }
  Wire.writes = 0; Wire.error = 1;
  assert(!disableStatusLed() && Wire.writes == 0);
  Wire.error = 0; Wire.count = 0;
  assert(!disableStatusLed() && Wire.writes == 0);
  Wire.count = 1; Wire.error = 2;
  assert(!disableStatusLed());
}
"""
with tempfile.TemporaryDirectory() as directory:
    cpp = Path(directory) / "check.cpp"
    binary = Path(directory) / "check"
    cpp.write_text(check)
    subprocess.run(["c++", "-std=c++11", str(cpp), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
print("Status LED: register preservation and I2C failures passed")
