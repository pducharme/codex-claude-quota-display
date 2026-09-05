#include <Arduino.h>
#include <esp_system.h>
#include <ArduinoJson.h>
#include <DNSServer.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <WebServer.h>
#include <WiFi.h>
#include <Wire.h>
#include <sys/time.h>
#include "DisplaySleep.h"
#include "Arduino_GFX_Library.h"
#include "Arduino_AXS15231.h"

namespace {

constexpr int LCD_WIDTH = 180;
constexpr int LCD_HEIGHT = 640;
constexpr int VIEW_WIDTH = 640;
constexpr int VIEW_HEIGHT = 180;
constexpr int TFT_CS = 12;
constexpr int TFT_SCLK = 17;
constexpr int TFT_SDIO0 = 13;
constexpr int TFT_SDIO1 = 18;
constexpr int TFT_SDIO2 = 21;
constexpr int TFT_SDIO3 = 14;
constexpr int TFT_RST = 16;
constexpr int TFT_BL = 1;
constexpr int BOOT_BUTTON = 0;
constexpr int TOUCH_SCL = 10;
constexpr int TOUCH_SDA = 15;
constexpr int TOUCH_INT = 11;
// The current T-Display S3 Long revision uses a CST3530 programmed at 0x58.
constexpr uint8_t TOUCH_ADDRESS = 0x58;
constexpr uint32_t TOUCH_READ_COMMAND = 0xD0070000;
constexpr uint32_t TOUCH_CLEAR_COMMAND = 0xD00002AB;
constexpr int BACKLIGHT = 185;
constexpr uint32_t LCD_RESTART_MS = 30UL * 60UL * 1000UL;
constexpr uint32_t REFRESH_MS = 10UL * 1000UL;
constexpr uint32_t RETRY_MS = 30UL * 1000UL;
constexpr int CONTENT_TOP = 4;
constexpr int PANEL_HEIGHT = 172;
constexpr int SWIPE_START_Y = 28;
constexpr int SWIPE_TRIGGER = 24;
constexpr int SWIPE_MAX = 46;

// Hardware calibration knob: set false if the enclosure is mounted the other way.
constexpr bool ROTATE_CLOCKWISE = false;

Arduino_DataBus *bus = new Arduino_ESP32QSPI(
    TFT_CS, TFT_SCLK, TFT_SDIO0, TFT_SDIO1, TFT_SDIO2, TFT_SDIO3);
class RestartableAXS15231 : public Arduino_AXS15231 {
 public:
  using Arduino_AXS15231::Arduino_AXS15231;

  void restart() {
    tftInit();
    _currentX = -1;
    _currentY = -1;
    _currentW = 0;
    _currentH = 0;
    setRotation(0);
    setAddrWindow(0, 0, LCD_WIDTH, LCD_HEIGHT);
  }
};
RestartableAXS15231 *panel =
    new RestartableAXS15231(bus, TFT_RST, 0, false, LCD_WIDTH, LCD_HEIGHT);
Arduino_Canvas *view = new Arduino_Canvas(VIEW_WIDTH, VIEW_HEIGHT, nullptr);
uint16_t *rotated = nullptr;
uint16_t *transitionFrom = nullptr;
bool suppressPresent = false;
bool displaySleeping = false;
DisplaySleep sleepSchedule;
String sleepTimezone = "UTC0";
String savedSleep;
void updateDisplaySleep();

Preferences preferences;
WebServer web(80);
DNSServer dns;

String wifiSsid;
String wifiPassword;
String bridgeHost;
String bridgeToken;
String weatherCity = "Sherbrooke";
uint32_t lastFetchMillis = 0;
uint32_t serverEpochAtFetch = 0;
uint32_t nextFetchMillis = 0;
uint32_t nextLcdRestartMillis = 0;
bool online = false;
bool displayCodex = true;
bool displayClaude = true;
bool bridgeRefreshActive = false;
uint32_t bridgeRefreshGeneration = 0;
bool swipeTracking = false;
int swipeStartX = 0;
int swipeStartY = 0;
int swipeCurrentX = 0;
int swipeCurrentY = 0;
int swipePull = 0;
uint32_t lastTouchMillis = 0;

enum class Page { Dashboard, CodexDetail, Weather };
Page currentPage = Page::Dashboard;

struct Window {
  bool available = false;
  int used = 0;
  uint32_t resetAt = 0;
};

struct Provider {
  String status = "loading";
  String plan = "--";
  Window fiveHour;
  Window weekly;
  Window fableWeekly;
};

struct BankedResets {
  int availableCount = 0;
  int expirationCount = 0;
  uint32_t expiresAt[4] = {};
  String expiresLocal[4];
};

struct ForecastDay {
  String day;
  float minimum = 0;
  float maximum = 0;
  int code = -1;
};

struct Weather {
  String status = "loading";
  String city;
  String region;
  String condition;
  float temperature = 0;
  float apparentTemperature = 0;
  int code = -1;
  int forecastCount = 0;
  ForecastDay forecast[5];
  bool available = false;
};

Provider codex;
Provider claude;
BankedResets bankedResets;
Weather weather;

uint16_t rgb(uint8_t red, uint8_t green, uint8_t blue) {
  return static_cast<uint16_t>(((red & 0xF8) << 8) |
                               ((green & 0xFC) << 3) | (blue >> 3));
}

const uint16_t COLOR_BG = rgb(7, 10, 18);
const uint16_t COLOR_CELL = rgb(19, 27, 43);
const uint16_t COLOR_CODEX_PANEL = rgb(8, 29, 48);
const uint16_t COLOR_CLAUDE_PANEL = rgb(43, 24, 21);
const uint16_t COLOR_TRACK = rgb(35, 46, 66);
const uint16_t COLOR_TEXT = rgb(230, 237, 245);
const uint16_t COLOR_MUTED = rgb(124, 141, 164);
const uint16_t COLOR_CODEX = rgb(56, 189, 248);
const uint16_t COLOR_CLAUDE = rgb(217, 119, 87);
const uint16_t COLOR_GREEN = rgb(52, 211, 153);
const uint16_t COLOR_AMBER = rgb(251, 191, 36);
const uint16_t COLOR_RED = rgb(248, 113, 113);

void present() {
  if (suppressPresent || displaySleeping) return;
  uint16_t *source = view->getFramebuffer();
  if (!source || !rotated) return;

  for (int y = 0; y < VIEW_HEIGHT; ++y) {
    for (int x = 0; x < VIEW_WIDTH; ++x) {
      if (ROTATE_CLOCKWISE) {
        rotated[(VIEW_WIDTH - 1 - x) * LCD_WIDTH + y] =
            source[y * VIEW_WIDTH + x];
      } else {
        rotated[x * LCD_WIDTH + (LCD_WIDTH - 1 - y)] =
            source[y * VIEW_WIDTH + x];
      }
    }
  }
  panel->draw16bitRGBBitmap(0, 0, rotated, LCD_WIDTH, LCD_HEIGHT);
}

void presentSlide(const uint16_t *outgoing, const uint16_t *incoming,
                  int offset, bool forward) {
  if (displaySleeping || !outgoing || !incoming || !rotated) return;
  for (int y = 0; y < VIEW_HEIGHT; ++y) {
    for (int x = 0; x < VIEW_WIDTH; ++x) {
      int sourceX;
      const uint16_t *source;
      if (forward) {
        bool showOutgoing = x < VIEW_WIDTH - offset;
        source = showOutgoing ? outgoing : incoming;
        sourceX = showOutgoing ? x + offset : x - (VIEW_WIDTH - offset);
      } else {
        bool showIncoming = x < offset;
        source = showIncoming ? incoming : outgoing;
        sourceX = showIncoming ? x + (VIEW_WIDTH - offset) : x - offset;
      }
      uint16_t color = source[y * VIEW_WIDTH + sourceX];
      if (ROTATE_CLOCKWISE) {
        rotated[(VIEW_WIDTH - 1 - x) * LCD_WIDTH + y] = color;
      } else {
        rotated[x * LCD_WIDTH + (LCD_WIDTH - 1 - y)] = color;
      }
    }
  }
  panel->draw16bitRGBBitmap(0, 0, rotated, LCD_WIDTH, LCD_HEIGHT);
}

void text(int x, int y, const String &value, uint16_t color, uint8_t size = 1) {
  view->setTextSize(size);
  view->setTextColor(color);
  view->setCursor(x, y);
  view->print(value);
}

void centeredText(int y, const String &value, uint16_t color,
                  uint8_t size = 1) {
  int width = value.length() * 6 * size;
  text((VIEW_WIDTH - width) / 2, y, value, color, size);
}

String countdown(uint32_t resetAt) {
  if (!resetAt || !serverEpochAtFetch) return "--";
  uint32_t nowEpoch =
      serverEpochAtFetch + ((millis() - lastFetchMillis) / 1000UL);
  if (resetAt <= nowEpoch) return "MAINT.";
  uint32_t seconds = resetAt - nowEpoch;
  uint32_t days = seconds / 86400UL;
  uint32_t hours = (seconds % 86400UL) / 3600UL;
  uint32_t minutes = (seconds % 3600UL) / 60UL;
  char buffer[16];
  if (days) {
    snprintf(buffer, sizeof(buffer), "%luj %02luh",
             static_cast<unsigned long>(days),
             static_cast<unsigned long>(hours));
  } else if (hours) {
    snprintf(buffer, sizeof(buffer), "%luh %02lum",
             static_cast<unsigned long>(hours),
             static_cast<unsigned long>(minutes));
  } else {
    snprintf(buffer, sizeof(buffer), "%lum",
             static_cast<unsigned long>(minutes));
  }
  return String(buffer);
}

uint16_t quotaColor(int remaining) {
  if (remaining <= 20) return COLOR_RED;
  if (remaining <= 50) return COLOR_AMBER;
  return COLOR_GREEN;
}

int expectedRemainingPercent(const Window &window, uint32_t durationSeconds) {
  if (!window.resetAt || !serverEpochAtFetch || !durationSeconds) return -1;
  uint32_t nowEpoch =
      serverEpochAtFetch + ((millis() - lastFetchMillis) / 1000UL);
  if (window.resetAt <= nowEpoch) return 0;
  uint32_t remaining = window.resetAt - nowEpoch;
  return min(100, static_cast<int>((remaining * 100ULL) / durationSeconds));
}

void drawTimeSegments(int x, int y, int width, const Window &window,
                      uint32_t durationSeconds, int count, uint16_t accent) {
  constexpr int gap = 3;
  constexpr int height = 4;
  int segmentWidth = (width - (count - 1) * gap) / count;
  int expected = expectedRemainingPercent(window, durationSeconds);
  int filled = max(0, expected) * count;
  for (int index = 0; index < count; ++index) {
    int segmentX = x + index * (segmentWidth + gap);
    view->fillRoundRect(segmentX, y, segmentWidth, height, 2, COLOR_TRACK);
    if (expected < 0) continue;
    int fraction = min(100, max(0, filled - index * 100));
    if (fraction > 0) {
      view->fillRoundRect(segmentX, y, segmentWidth * fraction / 100,
                          height, 2, accent);
    }
  }
}

void drawQuotaCell(int x, int y, int width, const char *label,
                   const Window &window, uint16_t accent,
                   uint32_t durationSeconds, int segmentCount) {
  view->fillRoundRect(x, y, width, 101, 8, COLOR_CELL);
  text(x + 9, y + 7, label, COLOR_MUTED, 1);
  if (!window.available) {
    text(x + 9, y + 30, "--", COLOR_MUTED, 3);
    text(x + 55, y + 37, "NON FOURNI", COLOR_MUTED, 1);
    view->fillRoundRect(x + 9, y + 68, width - 18, 8, 4, COLOR_TRACK);
    drawTimeSegments(x + 9, y + 79, width - 18, window,
                     durationSeconds, segmentCount, accent);
    return;
  }

  int remaining = 100 - window.used;
  char percentage[8];
  snprintf(percentage, sizeof(percentage), "%d%%", remaining);
  text(x + 9, y + 27, percentage, quotaColor(remaining), 3);
  text(x + width - 40, y + 38, "LIBRE", COLOR_MUTED, 1);

  int barWidth = width - 18;
  int fill = (barWidth * remaining) / 100;
  view->fillRoundRect(x + 9, y + 68, barWidth, 8, 4, COLOR_TRACK);
  if (fill > 0) {
    view->fillRoundRect(x + 9, y + 68, fill, 8, 4,
                        remaining > 50 ? accent : quotaColor(remaining));
  }
  drawTimeSegments(x + 9, y + 79, barWidth, window,
                   durationSeconds, segmentCount, accent);
  text(x + 9, y + 89, "RESET " + countdown(window.resetAt), COLOR_MUTED, 1);
}

void drawCompactQuota(int x, int y, int width, const char *label,
                      const Window &window, uint16_t accent) {
  text(x, y, label, COLOR_MUTED, 1);
  if (!window.available) {
    text(x + 43, y, "--", COLOR_MUTED, 1);
    return;
  }

  int remaining = 100 - window.used;
  char percentage[8];
  snprintf(percentage, sizeof(percentage), "%d%%", remaining);
  text(x + 43, y, percentage, quotaColor(remaining), 1);

  constexpr int labelWidth = 82;
  int barWidth = width - labelWidth;
  int fill = (barWidth * remaining) / 100;
  view->fillRoundRect(x + labelWidth, y, barWidth, 7, 3, COLOR_TRACK);
  if (fill > 0) {
    view->fillRoundRect(x + labelWidth, y, fill, 7, 3,
                        remaining > 50 ? accent : quotaColor(remaining));
  }
}

void drawCompactResets(int x, int y) {
  char count[8];
  snprintf(count, sizeof(count), "%d", bankedResets.availableCount);
  text(x, y, "RESETS:", COLOR_MUTED, 1);
  text(x + 43, y, count, COLOR_CODEX, 1);

  int visible = min(bankedResets.availableCount, 4);
  for (int index = 0; index < visible; ++index) {
    view->fillRoundRect(x + 62 + index * 14, y, 10, 7, 3, COLOR_CODEX);
  }
  if (bankedResets.expirationCount) {
    text(x + 128, y,
         "EXP. " + countdown(bankedResets.expiresAt[0]), COLOR_MUTED, 1);
  }
}

void drawCodexLogo(int x, int y, int pulse) {
  int radius = 4 + pulse;
  const int petals[][2] = {
      {0, -6}, {5, -3}, {5, 3}, {0, 6}, {-5, 3}, {-5, -3}};
  for (const auto &petal : petals) {
    view->fillCircle(x + petal[0], y + petal[1], radius, COLOR_CODEX);
  }
  view->fillCircle(x, y, radius + 1, COLOR_CODEX);
  view->drawLine(x - 5, y - 4, x - 2, y, COLOR_BG);
  view->drawLine(x - 2, y, x - 5, y + 4, COLOR_BG);
  view->drawFastHLine(x + 1, y + 4, 6, COLOR_BG);
}

void drawClaudeMascot(int x, int y, int frame) {
  int bob = frame & 1;
  int top = y - 8 - bob;
  view->fillRect(x - 10, top, 20, 13, COLOR_CLAUDE);
  view->fillRect(x - 15, top + 5, 5, 5, COLOR_CLAUDE);
  view->fillRect(x + 10, top + 5, 5, 5, COLOR_CLAUDE);
  view->fillRect(x - 6, top + 3, 3, 3, COLOR_BG);
  view->fillRect(x + 4, top + 3, 3, 3, COLOR_BG);

  int feet = top + 13;
  view->fillRect(x - 9, feet, 3, 6 - bob, COLOR_CLAUDE);
  view->fillRect(x - 4, feet, 3, 5 + bob, COLOR_CLAUDE);
  view->fillRect(x + 3, feet, 3, 5 + bob, COLOR_CLAUDE);
  view->fillRect(x + 8, feet, 3, 6 - bob, COLOR_CLAUDE);
}

bool providerAvailable(const Provider &provider) {
  return provider.status != "error" || provider.fiveHour.available ||
         provider.weekly.available || provider.fableWeekly.available;
}

constexpr int providerCardWidth(bool codexVisible, bool claudeVisible) {
  return codexVisible && claudeVisible ? 310 : 626;
}
static_assert(providerCardWidth(true, true) == 310);
static_assert(providerCardWidth(true, false) == 626);

void displayedProviders(bool &showCodex, bool &showClaude) {
  showCodex = displayCodex && providerAvailable(codex);
  showClaude = displayClaude && providerAvailable(claude);
  if (!showCodex && !showClaude) {
    showCodex = displayCodex;
    showClaude = displayClaude;
  }
  if (!showCodex && !showClaude) showCodex = showClaude = true;
}

void drawProviderCard(int x, int width, const char *name,
                      const Provider &provider,
                      uint16_t panelColor, uint16_t accent, bool codexLogo,
                      int frame) {
  constexpr int y = CONTENT_TOP;
  int cellWidth = (width - 32) / 2;

  view->fillRoundRect(x, y, width, PANEL_HEIGHT, 11, panelColor);
  view->fillRoundRect(x, y, width, 4, 2, accent);
  int pulse = frame & 1;
  if (codexLogo) {
    drawCodexLogo(x + 22, y + 21, pulse);
  } else {
    drawClaudeMascot(x + 22, y + 21, frame);
  }
  text(x + 44, y + 12, name, COLOR_TEXT, 2);
  int planX = x + 52 + strlen(name) * 12;
  int planWidth = provider.plan.length() * 6 + 12;
  view->fillRoundRect(planX, y + 11, planWidth, 16, 7, COLOR_CELL);
  text(planX + 6, y + 15, provider.plan, accent, 1);

  uint16_t providerStatus =
      !online ? COLOR_RED :
      provider.status == "ok" ? COLOR_GREEN :
      provider.status == "stale" ? COLOR_AMBER : COLOR_RED;
  view->fillCircle(x + width - 19, y + 19, 4, providerStatus);

  drawQuotaCell(x + 12, y + 39, cellWidth, "5 HEURES",
                provider.fiveHour, accent, 5UL * 3600UL, 5);
  drawQuotaCell(x + 20 + cellWidth, y + 39, cellWidth, "SEMAINE",
                provider.weekly, accent, 7UL * 24UL * 3600UL, 7);
  if (codexLogo) {
    drawCompactResets(x + 12, y + 151);
  } else {
    drawCompactQuota(x + 12, y + 151, width - 24, "FABLE:",
                     provider.fableWeekly, accent);
  }
}

void drawSpinner(int x, int y, int frame) {
  const int outerX[] = {0, 4, 6, 4, 0, -4, -6, -4};
  const int outerY[] = {-6, -4, 0, 4, 6, 4, 0, -4};
  for (int index = 0; index < 8; ++index) {
    int age = (index - frame) & 7;
    uint16_t color =
        age == 0 ? COLOR_CODEX : age <= 2 ? COLOR_MUTED : COLOR_TRACK;
    view->drawLine(x + outerX[index] / 2, y + outerY[index] / 2,
                   x + outerX[index], y + outerY[index], color);
  }
}

void drawGesture(int pull, bool refreshing, int frame) {
  if (!refreshing && pull < 4) return;
  int drop = refreshing ? 0 : min(pull / 5, 8);
  view->fillRoundRect(305, 3 + drop, 30, 18, 9, COLOR_BG);
  if (!refreshing && pull >= SWIPE_TRIGGER) {
    view->drawCircle(320, 12 + drop, 9, COLOR_GREEN);
  }
  drawSpinner(320, 12 + drop, refreshing ? frame : pull / 4);
}

void drawPageDots(int active);

void drawDashboard(int pull = 0, bool refreshing = false, int frame = 0) {
  view->fillScreen(COLOR_BG);
  bool showCodex;
  bool showClaude;
  displayedProviders(showCodex, showClaude);
  int width = providerCardWidth(showCodex, showClaude);
  if (showCodex) {
    drawProviderCard(7, width, "CODEX", codex, COLOR_CODEX_PANEL,
                     COLOR_CODEX, true, frame);
  }
  if (showClaude) {
    drawProviderCard(showCodex ? 323 : 7, width, "CLAUDE", claude,
                     COLOR_CLAUDE_PANEL, COLOR_CLAUDE, false, frame);
  }
  drawPageDots(0);
  drawGesture(pull, refreshing, frame);
  present();
}

void drawPageDots(int active) {
  for (int index = 0; index < 2; ++index) {
    view->fillCircle(315 + index * 10, 171, index == active ? 3 : 2,
                     index == active ? COLOR_TEXT : COLOR_TRACK);
  }
}

void drawCodexDetail(int pull = 0, bool refreshing = false, int frame = 0) {
  constexpr int top = CONTENT_TOP;
  view->fillScreen(COLOR_BG);
  view->fillRoundRect(7, top, 626, PANEL_HEIGHT, 11, COLOR_CODEX_PANEL);
  view->fillRoundRect(7, top, 626, 4, 2, COLOR_CODEX);
  drawCodexLogo(31, top + 23, frame & 1);
  text(53, top + 13, "BANKED RESETS", COLOR_TEXT, 2);
  text(500, top + 15, "TOUCHER: RETOUR", COLOR_MUTED, 1);

  char count[8];
  snprintf(count, sizeof(count), "%d", bankedResets.availableCount);
  text(34, top + 53, count, COLOR_CODEX, 5);
  text(35, top + 104, "DISPONIBLES", COLOR_MUTED, 1);

  if (!bankedResets.availableCount) {
    text(172, top + 68, "AUCUN RESET EN BANQUE", COLOR_MUTED, 2);
  } else {
    for (int index = 0; index < bankedResets.expirationCount; ++index) {
      int y = top + 46 + index * 24;
      char label[8];
      snprintf(label, sizeof(label), "#%d", index + 1);
      text(172, y, label, COLOR_CODEX, 2);
      text(208, y + 1, bankedResets.expiresLocal[index], COLOR_TEXT, 1);
      text(355, y + 1, "DANS " + countdown(bankedResets.expiresAt[index]),
           COLOR_MUTED, 1);
    }
  }
  drawGesture(pull, refreshing, frame);
  present();
}

void drawWeatherIcon(int x, int y, int code, int frame) {
  int pulse = frame & 1;
  if (code == 0 || code == 1) {
    view->fillCircle(x, y, 20 + pulse, COLOR_AMBER);
    for (int offset = -34; offset <= 34; offset += 68) {
      view->drawFastHLine(x + offset, y, 12, COLOR_AMBER);
      view->drawFastVLine(x, y + offset, 12, COLOR_AMBER);
    }
    view->drawLine(x - 28, y - 28, x - 20, y - 20, COLOR_AMBER);
    view->drawLine(x + 28, y - 28, x + 20, y - 20, COLOR_AMBER);
    view->drawLine(x - 28, y + 28, x - 20, y + 20, COLOR_AMBER);
    view->drawLine(x + 28, y + 28, x + 20, y + 20, COLOR_AMBER);
    return;
  }

  uint16_t cloud = rgb(185, 199, 218);
  view->fillCircle(x - 18, y, 17, cloud);
  view->fillCircle(x + 3, y - 9, 23, cloud);
  view->fillCircle(x + 27, y, 16, cloud);
  view->fillRoundRect(x - 34, y, 76, 24, 10, cloud);

  if ((51 <= code && code <= 67) || (80 <= code && code <= 82) ||
      (95 <= code && code <= 99)) {
    for (int drop = 0; drop < 3; ++drop) {
      int dropX = x - 20 + drop * 20;
      int dropY = y + 31 + ((frame + drop) & 1) * 4;
      view->drawLine(dropX, dropY, dropX - 4, dropY + 8, COLOR_CODEX);
    }
  } else if ((71 <= code && code <= 77) ||
             (85 <= code && code <= 86)) {
    for (int flake = 0; flake < 3; ++flake) {
      view->fillCircle(x - 20 + flake * 20,
                       y + 35 + ((frame + flake) & 1) * 3,
                       3, COLOR_TEXT);
    }
  }
}

void drawMiniWeatherIcon(int x, int y, int code, int frame) {
  if (code == 0 || code == 1) {
    view->fillCircle(x, y, 6 + (frame & 1), COLOR_AMBER);
    view->drawFastHLine(x - 11, y, 5, COLOR_AMBER);
    view->drawFastHLine(x + 7, y, 5, COLOR_AMBER);
    view->drawFastVLine(x, y - 11, 5, COLOR_AMBER);
    view->drawFastVLine(x, y + 7, 5, COLOR_AMBER);
    return;
  }

  uint16_t cloud = rgb(185, 199, 218);
  view->fillCircle(x - 5, y, 5, cloud);
  view->fillCircle(x + 2, y - 3, 7, cloud);
  view->fillCircle(x + 8, y, 5, cloud);
  view->fillRect(x - 9, y, 21, 7, cloud);
  if ((51 <= code && code <= 67) || (80 <= code && code <= 82) ||
      (95 <= code && code <= 99)) {
    view->drawLine(x - 4, y + 9, x - 6, y + 13, COLOR_CODEX);
    view->drawLine(x + 5, y + 9, x + 3, y + 13, COLOR_CODEX);
  } else if ((71 <= code && code <= 77) ||
             (85 <= code && code <= 86)) {
    view->fillCircle(x - 4, y + 11, 2, COLOR_TEXT);
    view->fillCircle(x + 5, y + 11, 2, COLOR_TEXT);
  }
}

void drawWeatherPage(int pull = 0, bool refreshing = false, int frame = 0) {
  constexpr int top = CONTENT_TOP;
  uint16_t weatherPanel =
      weather.code == 0 ? rgb(12, 36, 66) : rgb(24, 34, 52);
  view->fillScreen(COLOR_BG);
  view->fillRoundRect(7, top, 626, PANEL_HEIGHT, 11, weatherPanel);
  view->fillRoundRect(7, top, 626, 4, 2, COLOR_CODEX);

  if (!weather.available) {
    text(25, top + 24, weatherCity, COLOR_TEXT, 2);
    text(25, top + 71, "METEO INDISPONIBLE", COLOR_MUTED, 3);
    text(25, top + 115, "VERIFIER LA VILLE DANS LA CONFIGURATION",
         COLOR_MUTED, 1);
  } else {
    String location = weather.city;
    if (weather.region.length()) location += ", " + weather.region;
    text(24, top + 10, location, COLOR_TEXT, 2);
    text(24, top + 34, weather.condition, COLOR_CODEX, 2);
    text(24, top + 53, "MAINTENANT", COLOR_MUTED, 1);

    int temperature = static_cast<int>(
        weather.temperature + (weather.temperature >= 0 ? 0.5 : -0.5));
    char value[8];
    snprintf(value, sizeof(value), "%d", temperature);
    text(24, top + 65, value, COLOR_TEXT, 5);
    int valueWidth = strlen(value) * 30;
    view->drawCircle(29 + valueWidth, top + 69, 4, COLOR_TEXT);
    text(39 + valueWidth, top + 71, "C", COLOR_TEXT, 3);
    drawWeatherIcon(206, top + 64, weather.code, frame);

    int apparentTemperature = static_cast<int>(
        weather.apparentTemperature +
        (weather.apparentTemperature >= 0 ? 0.5 : -0.5));
    String feelsLike = "RESSENTI " + String(apparentTemperature);
    text(24, top + 122, feelsLike, COLOR_MUTED, 1);
    int feelsLikeWidth = feelsLike.length() * 6;
    view->drawCircle(28 + feelsLikeWidth, top + 123, 2, COLOR_MUTED);
    text(34 + feelsLikeWidth, top + 122, "C", COLOR_MUTED, 1);

    view->fillRoundRect(273, top + 10, 345, 132, 9, COLOR_CELL);
    for (int index = 0; index < weather.forecastCount; ++index) {
      int columnX = 281 + index * 66;
      const ForecastDay &day = weather.forecast[index];
      int dayWidth = day.day.length() * 6;
      text(columnX + (58 - dayWidth) / 2, top + 19, day.day,
           COLOR_MUTED, 1);
      drawMiniWeatherIcon(columnX + 29, top + 54, day.code, frame + index);
      char maximum[8];
      char minimum[8];
      snprintf(maximum, sizeof(maximum), "%.0f", day.maximum);
      snprintf(minimum, sizeof(minimum), "%.0f", day.minimum);
      int maxWidth = strlen(maximum) * 12;
      int minWidth = strlen(minimum) * 6;
      text(columnX + (58 - maxWidth) / 2, top + 81, maximum,
           COLOR_TEXT, 2);
      text(columnX + (58 - minWidth) / 2, top + 107, minimum,
           COLOR_MUTED, 1);
      if (index < 4) {
        view->drawFastVLine(columnX + 62, top + 19, 103, COLOR_TRACK);
      }
    }
  }
  drawPageDots(1);
  drawGesture(pull, refreshing, frame);
  present();
}

void drawCurrentPage(int pull = 0, bool refreshing = false, int frame = 0) {
  updateDisplaySleep();
  if (displaySleeping) return;
  if (currentPage == Page::CodexDetail) {
    drawCodexDetail(pull, refreshing, frame);
  } else if (currentPage == Page::Weather) {
    drawWeatherPage(pull, refreshing, frame);
  } else {
    drawDashboard(pull, refreshing, frame);
  }
}

void animatePageTransition(Page nextPage, bool forward) {
  if (nextPage == currentPage) return;
  uint16_t *incoming = view->getFramebuffer();
  if (!transitionFrom || !incoming) {
    currentPage = nextPage;
    drawCurrentPage();
    return;
  }

  memcpy(transitionFrom, incoming,
         VIEW_WIDTH * VIEW_HEIGHT * sizeof(uint16_t));
  currentPage = nextPage;
  suppressPresent = true;
  drawCurrentPage();
  suppressPresent = false;

  for (int frame = 1; frame <= 5; ++frame) {
    float progress = frame / 5.0f;
    float eased = progress * progress * (3.0f - 2.0f * progress);
    presentSlide(transitionFrom, incoming,
                 static_cast<int>(VIEW_WIDTH * eased), forward);
    delay(8);
  }
  present();
}

void drawMessage(const String &title, const String &line1,
                 const String &line2 = "", const String &line3 = "") {
  view->fillScreen(COLOR_BG);
  text(24, 24, title, COLOR_CODEX, 3);
  text(24, 76, line1, COLOR_TEXT, 2);
  if (line2.length()) text(24, 108, line2, COLOR_MUTED, 2);
  if (line3.length()) text(24, 140, line3, COLOR_MUTED, 1);
  present();
}

bool validHost(const String &value) {
  if (value.length() < 3 || value.length() > 120) return false;
  for (size_t i = 0; i < value.length(); ++i) {
    char c = value[i];
    if (!(isalnum(static_cast<unsigned char>(c)) || c == '.' || c == '-' ||
          c == ':')) {
      return false;
    }
  }
  return true;
}

void saveConfiguration() {
  String ssid = web.arg("ssid");
  String password = web.arg("password");
  String host = web.arg("host");
  String token = web.arg("token");
  String city = web.arg("city");
  ssid.trim();
  host.trim();
  token.trim();
  city.trim();

  if (ssid.length() < 1 || ssid.length() > 32 || password.length() > 64 ||
      !validHost(host) || token.length() < 16 || token.length() > 128 ||
      city.length() < 1 || city.length() > 80) {
    web.send(400, "text/plain; charset=utf-8",
             "Configuration invalide. Verifiez les champs.");
    return;
  }

  preferences.begin("quota", false);
  preferences.putString("ssid", ssid);
  preferences.putString("password", password);
  preferences.putString("host", host);
  preferences.putString("token", token);
  preferences.putString("city", city);
  preferences.end();
  web.send(200, "text/html; charset=utf-8",
           "<h1>Configuration enregistree</h1><p>L'ecran redemarre.</p>");
  delay(750);
  ESP.restart();
}

String setupPage() {
  return R"HTML(
<!doctype html><html lang="fr"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Quota Display</title>
<style>
body{font:16px system-ui;background:#07101d;color:#e6edf5;max-width:32rem;margin:2rem auto;padding:0 1rem}
label{display:block;margin:1rem 0 .35rem}input{box-sizing:border-box;width:100%;padding:.8rem;border:1px solid #334155;border-radius:.5rem;background:#111827;color:white}
button{margin-top:1.4rem;padding:.85rem 1.2rem;border:0;border-radius:.5rem;background:#38bdf8;color:#07101d;font-weight:700}
</style></head><body><h1>AI Quota Display</h1>
<form method="post" action="/save">
<label>Nom du Wi-Fi</label><input name="ssid" maxlength="32" required>
<label>Mot de passe Wi-Fi</label><input name="password" type="password" maxlength="64">
<label>Pont Mac (adresse:port)</label><input name="host" placeholder="192.168.1.20:8788" required>
<label>Jeton du pont</label><input name="token" type="password" maxlength="128" required>
<label>Ville pour la meteo</label><input name="city" value="Sherbrooke" maxlength="80" required>
<button type="submit">Enregistrer et redemarrer</button>
</form></body></html>
)HTML";
}

[[noreturn]] void startSetupPortal() {
  uint32_t suffixValue = static_cast<uint32_t>(ESP.getEfuseMac());
  char suffix[7];
  snprintf(suffix, sizeof(suffix), "%06lX",
           static_cast<unsigned long>(suffixValue & 0xFFFFFF));
  String accessPoint = "QuotaDisplay-" + String(suffix);
  String password = "QD" + String(suffix);

  WiFi.disconnect(true);
  WiFi.mode(WIFI_AP);
  WiFi.softAP(accessPoint.c_str(), password.c_str());
  dns.start(53, "*", WiFi.softAPIP());
  web.on("/", HTTP_GET, [] { web.send(200, "text/html", setupPage()); });
  web.on("/save", HTTP_POST, saveConfiguration);
  web.onNotFound([] {
    web.sendHeader("Location", "http://192.168.4.1/", true);
    web.send(302, "text/plain", "");
  });
  web.begin();
  Serial.printf("Setup AP: %s / %s / http://192.168.4.1\n",
                accessPoint.c_str(), password.c_str());

  drawMessage("CONFIGURATION", accessPoint, "Mot de passe: " + password,
              "Ouvrir http://192.168.4.1");
  uint32_t lastPortalLog = millis();
  while (true) {
    dns.processNextRequest();
    web.handleClient();
    if (millis() - lastPortalLog >= 5000) {
      lastPortalLog = millis();
      Serial.println("Setup portal active");
    }
    delay(2);
  }
}

void readSleepSchedule(JsonVariantConst value, bool persist) {
  DisplaySleep next;
  String timezone = "UTC0";
  if (!value.isNull()) {
    if (!value["enabled"].is<bool>() || !value["start_minute"].is<int>() ||
        !value["end_minute"].is<int>() || !value["tz"].is<const char *>()) return;
    next.enabled = value["enabled"].as<bool>();
    next.startMinute = value["start_minute"].as<int>();
    next.endMinute = value["end_minute"].as<int>();
    timezone = value["tz"].as<String>();
    if (!next.valid() || timezone.isEmpty() || timezone.length() > 128) return;
  }
  String serialized;
  serializeJson(value, serialized);
  if (serialized == savedSleep) return;
  sleepSchedule = next;
  sleepTimezone = timezone;
  setenv("TZ", sleepTimezone.c_str(), 1);
  tzset();
  if (persist) {
    preferences.begin("quota", false);
    size_t written = preferences.putString("sleep", serialized);
    preferences.end();
    if (!written) {
      Serial.println("Sleep schedule persistence failed; will retry");
      return;
    }
  }
  savedSleep = serialized;
  Serial.printf("Sleep schedule: enabled=%s start=%d end=%d tz=%s\n",
                sleepSchedule.enabled ? "yes" : "no", sleepSchedule.startMinute,
                sleepSchedule.endMinute, sleepTimezone.c_str());
}

bool loadConfiguration() {
  preferences.begin("quota", true);
  wifiSsid = preferences.getString("ssid");
  wifiPassword = preferences.getString("password");
  bridgeHost = preferences.getString("host");
  bridgeToken = preferences.getString("token");
  weatherCity =
      preferences.isKey("city") ? preferences.getString("city") : "Sherbrooke";
  String saved = preferences.getString("sleep");
  preferences.end();
  JsonDocument schedule;
  if (deserializeJson(schedule, saved) == DeserializationError::Ok) {
    readSleepSchedule(schedule.as<JsonVariantConst>(), false);
  }
  return wifiSsid.length() && validHost(bridgeHost) &&
         bridgeToken.length() >= 16;
}

void clearConfigurationIfRequested() {
  pinMode(BOOT_BUTTON, INPUT_PULLUP);
  if (digitalRead(BOOT_BUTTON) != LOW) return;
  drawMessage("REINITIALISER?", "Garder BOOT appuye", "pendant 3 secondes");
  uint32_t started = millis();
  while (digitalRead(BOOT_BUTTON) == LOW && millis() - started < 3000) {
    delay(20);
  }
  if (millis() - started >= 3000) {
    preferences.begin("quota", false);
    preferences.clear();
    preferences.end();
    drawMessage("CONFIG EFFACEE", "Redemarrage...");
    delay(800);
    ESP.restart();
  }
}

bool connectWifi() {
  WiFi.mode(WIFI_STA);
  WiFi.begin(wifiSsid.c_str(), wifiPassword.c_str());
  drawMessage("CONNEXION WIFI", wifiSsid, "Patientez...");
  uint32_t started = millis();
  while (WiFi.status() != WL_CONNECTED && millis() - started < 20000) {
    delay(250);
  }
  if (WiFi.status() == WL_CONNECTED) {
    Serial.printf("Wi-Fi connected: %s\n", WiFi.localIP().toString().c_str());
  }
  return WiFi.status() == WL_CONNECTED;
}

Window jsonWindow(JsonVariantConst value) {
  Window window;
  if (!value.is<JsonObjectConst>() ||
      !value["used_percent"].is<int>()) {
    return window;
  }
  window.available = true;
  window.used = constrain(value["used_percent"].as<int>(), 0, 100);
  if (value["resets_at"].is<uint32_t>()) {
    window.resetAt = value["resets_at"].as<uint32_t>();
  }
  return window;
}

void readProvider(JsonObjectConst providers, const char *name,
                  Provider &provider) {
  JsonObjectConst source = providers[name].as<JsonObjectConst>();
  if (source.isNull()) return;
  provider.status = source["status"] | "error";
  provider.plan = source["plan"] | "--";
  provider.fiveHour = jsonWindow(source["five_hour"]);
  provider.weekly = jsonWindow(source["weekly"]);
  provider.fableWeekly = jsonWindow(source["fable_weekly"]);
}

void readBankedResets(JsonObjectConst codexSource) {
  JsonObjectConst source =
      codexSource["banked_resets"].as<JsonObjectConst>();
  bankedResets = BankedResets{};
  if (source.isNull()) return;
  bankedResets.availableCount = source["available_count"] | 0;
  JsonArrayConst expirations = source["expirations"].as<JsonArrayConst>();
  for (JsonObjectConst expiration : expirations) {
    if (bankedResets.expirationCount >= 4) break;
    int index = bankedResets.expirationCount++;
    bankedResets.expiresAt[index] = expiration["expires_at"] | 0;
    bankedResets.expiresLocal[index] =
        expiration["expires_local"] | "";
  }
}

bool fetchQuotas() {
  if (WiFi.status() != WL_CONNECTED) {
    online = false;
    return false;
  }

  HTTPClient http;
  String url = "http://" + bridgeHost + "/v1/quotas";
  http.setConnectTimeout(5000);
  http.setTimeout(10000);
  if (!http.begin(url)) {
    online = false;
    return false;
  }
  http.addHeader("Authorization", "Bearer " + bridgeToken);
  int status = http.GET();
  if (status != HTTP_CODE_OK) {
    Serial.printf("Quota bridge HTTP error: %d\n", status);
    http.end();
    online = false;
    return false;
  }

  String body = http.getString();
  http.end();
  JsonDocument document;
  if (deserializeJson(document, body) != DeserializationError::Ok ||
      document["version"].as<int>() != 1 ||
      !document["server_time"].is<uint32_t>()) {
    online = false;
    return false;
  }

  JsonObjectConst providers = document["providers"].as<JsonObjectConst>();
  if (providers.isNull()) {
    online = false;
    return false;
  }
  JsonObjectConst refresh = document["refresh"].as<JsonObjectConst>();
  if (!refresh.isNull()) {
    bridgeRefreshActive = refresh["active"] | false;
    bridgeRefreshGeneration = refresh["generation"] | 0;
  }
  JsonObjectConst display = document["display"].as<JsonObjectConst>();
  static String lastDisplaySettings;
  String displaySettings;
  serializeJson(document["display"], displaySettings);
  if (displaySettings != lastDisplaySettings) {
    Serial.printf("Display settings from %s: %s\n", bridgeHost.c_str(), displaySettings.c_str());
    lastDisplaySettings = displaySettings;
  }
  if (!display.isNull() && display["codex"].is<bool>() &&
      display["claude"].is<bool>()) {
    bool nextCodex = display["codex"].as<bool>();
    bool nextClaude = display["claude"].as<bool>();
    if (nextCodex || nextClaude) {
      displayCodex = nextCodex;
      displayClaude = nextClaude;
      if (!displayCodex && currentPage == Page::CodexDetail) {
        currentPage = Page::Dashboard;
      }
    }
  }
  readProvider(providers, "codex", codex);
  readProvider(providers, "claude", claude);
  readBankedResets(providers["codex"].as<JsonObjectConst>());
  serverEpochAtFetch = document["server_time"].as<uint32_t>();
  if (serverEpochAtFetch >= 1700000000) {
    struct timeval now {static_cast<time_t>(serverEpochAtFetch), 0};
    settimeofday(&now, nullptr);
  }
  if (!display["sleep"].isUnbound()) {
    readSleepSchedule(display["sleep"], true);
  }
  updateDisplaySleep();
  lastFetchMillis = millis();
  online = true;
  struct tm local {};
  time_t now = time(nullptr);
  localtime_r(&now, &local);
  Serial.printf("Quota data refreshed: uptime=%lus reset=%d clock=%02d:%02d sleep=%s\n",
                static_cast<unsigned long>(millis() / 1000UL),
                static_cast<int>(esp_reset_reason()), local.tm_hour, local.tm_min,
                displaySleeping ? "yes" : "no");
  return true;
}

String urlEncode(const String &value) {
  const char hex[] = "0123456789ABCDEF";
  String encoded;
  encoded.reserve(value.length() * 3);
  for (size_t index = 0; index < value.length(); ++index) {
    uint8_t character = static_cast<uint8_t>(value[index]);
    if (isalnum(character) || character == '-' || character == '_' ||
        character == '.' || character == '~') {
      encoded += static_cast<char>(character);
    } else {
      encoded += '%';
      encoded += hex[character >> 4];
      encoded += hex[character & 0x0F];
    }
  }
  return encoded;
}

bool fetchWeather() {
  if (WiFi.status() != WL_CONNECTED || !weatherCity.length()) return false;

  HTTPClient http;
  String url =
      "http://" + bridgeHost + "/v1/weather?city=" + urlEncode(weatherCity);
  http.setConnectTimeout(5000);
  http.setTimeout(12000);
  if (!http.begin(url)) return false;
  http.addHeader("Authorization", "Bearer " + bridgeToken);
  int status = http.GET();
  if (status != HTTP_CODE_OK) {
    http.end();
    weather.status = weather.available ? "stale" : "error";
    return false;
  }

  String body = http.getString();
  http.end();
  JsonDocument document;
  if (deserializeJson(document, body) != DeserializationError::Ok ||
      document["version"].as<int>() != 1) {
    weather.status = weather.available ? "stale" : "error";
    return false;
  }
  JsonObjectConst source = document["weather"].as<JsonObjectConst>();
  String sourceStatus = source["status"] | "error";
  if (source.isNull() || sourceStatus == "error") {
    weather.status = weather.available ? "stale" : "error";
    return false;
  }

  weather.status = sourceStatus;
  weather.city = source["city"] | weatherCity;
  weather.region = source["region"] | "";
  weather.condition = source["condition"] | "VARIABLE";
  weather.temperature = source["temperature_c"] | 0.0;
  weather.apparentTemperature =
      source["apparent_temperature_c"] | weather.temperature;
  weather.code = source["weather_code"] | -1;
  weather.forecastCount = 0;
  for (JsonObjectConst day : source["forecast"].as<JsonArrayConst>()) {
    if (weather.forecastCount >= 5) break;
    ForecastDay &forecast = weather.forecast[weather.forecastCount++];
    forecast.day = day["day"] | "---";
    forecast.minimum = day["minimum_c"] | 0.0;
    forecast.maximum = day["maximum_c"] | 0.0;
    forecast.code = day["weather_code"] | -1;
  }
  weather.available = true;
  Serial.println("Weather data refreshed");
  return true;
}

bool fetchAll() {
  bool quotas = fetchQuotas();
  fetchWeather();
  return quotas;
}

bool startRemoteRefresh() {
  if (WiFi.status() != WL_CONNECTED) return false;
  HTTPClient http;
  String url = "http://" + bridgeHost + "/v1/refresh";
  http.setConnectTimeout(5000);
  http.setTimeout(10000);
  if (!http.begin(url)) return false;
  http.addHeader("Authorization", "Bearer " + bridgeToken);
  http.addHeader("Content-Type", "application/json");
  int status = http.POST("");
  String body = http.getString();
  http.end();
  if (status != 202) {
    Serial.printf("Refresh bridge HTTP error: %d\n", status);
    return false;
  }

  JsonDocument document;
  if (deserializeJson(document, body) == DeserializationError::Ok) {
    JsonObjectConst refresh = document["refresh"].as<JsonObjectConst>();
    bridgeRefreshActive = refresh["active"] | true;
    bridgeRefreshGeneration =
        refresh["generation"] | bridgeRefreshGeneration;
  }
  Serial.println("Forced Codex + Claude refresh started");
  return true;
}

bool touchCommand(uint32_t command, uint8_t *response = nullptr,
                  size_t responseSize = 0) {
  uint8_t request[] = {
      static_cast<uint8_t>(command >> 24),
      static_cast<uint8_t>(command >> 16),
      static_cast<uint8_t>(command >> 8),
      static_cast<uint8_t>(command),
  };
  Wire.beginTransmission(TOUCH_ADDRESS);
  Wire.write(request, sizeof(request));
  if (Wire.endTransmission() != 0) return false;
  if (!response) return true;
  if (Wire.requestFrom(TOUCH_ADDRESS,
                       static_cast<uint8_t>(responseSize)) != responseSize) {
    while (Wire.available()) Wire.read();
    return false;
  }
  return Wire.readBytes(response, responseSize) == responseSize;
}

bool readTouchPoint(int &logicalX, int &logicalY) {
  uint8_t buffer[32] = {};
  if (!touchCommand(TOUCH_READ_COMMAND, buffer, sizeof(buffer))) return false;

  bool valid = buffer[2] == 0xFF;
  uint8_t pointCount = buffer[3] & 0x0F;
  uint8_t keyCount = buffer[3] >> 4;
  if (!valid || pointCount == 0 || pointCount > 5) {
    touchCommand(TOUCH_CLEAR_COMMAND);
    return false;
  }

  int pointOffset = keyCount * 5;
  int pointEnd = pointOffset + 8;
  int checksumEnd = 4 + (keyCount + pointCount) * 5;
  if (pointEnd >= static_cast<int>(sizeof(buffer)) ||
      checksumEnd > static_cast<int>(sizeof(buffer))) {
    touchCommand(TOUCH_CLEAR_COMMAND);
    return false;
  }

  uint16_t checksum = 0x55;
  for (int index = 4; index < checksumEnd; ++index) {
    checksum += buffer[index];
  }
  uint16_t expectedChecksum = buffer[0] | (buffer[1] << 8);
  uint8_t event = buffer[pointEnd] >> 4;
  int nativeX =
      buffer[pointOffset + 4] | ((buffer[pointOffset + 7] & 0x0F) << 8);
  int nativeY =
      buffer[pointOffset + 5] | ((buffer[pointOffset + 7] & 0xF0) << 4);
  touchCommand(TOUCH_CLEAR_COMMAND);
  if (checksum != expectedChecksum || event == 0) return false;

  if (ROTATE_CLOCKWISE) {
    logicalX = VIEW_WIDTH - 1 - constrain(nativeY, 0, VIEW_WIDTH - 1);
    logicalY = constrain(nativeX, 0, VIEW_HEIGHT - 1);
  } else {
    logicalX = constrain(nativeY, 0, VIEW_WIDTH - 1);
    logicalY = VIEW_HEIGHT - 1 - constrain(nativeX, 0, VIEW_HEIGHT - 1);
  }
  return true;
}

uint8_t probeI2C(uint8_t address) {
  Wire.beginTransmission(address);
  return Wire.endTransmission();
}

void animateGestureRefresh() {
  for (int pull = swipePull; pull <= SWIPE_MAX; pull += 6) {
    drawCurrentPage(pull, false);
    delay(18);
  }
  for (int frame = 0; frame < 5; ++frame) {
    drawCurrentPage(SWIPE_MAX, true, frame);
    delay(55);
  }

  uint32_t startingGeneration = bridgeRefreshGeneration;
  bool started = startRemoteRefresh();
  bool fetched = false;
  int spinnerFrame = 5;
  if (started) {
    uint32_t deadline = millis() + 55000;
    while (static_cast<int32_t>(millis() - deadline) < 0) {
      drawCurrentPage(SWIPE_MAX, true, spinnerFrame);
      if ((spinnerFrame & 7) == 0 && fetchQuotas() &&
          !bridgeRefreshActive &&
          bridgeRefreshGeneration != startingGeneration) {
        fetched = true;
        break;
      }
      ++spinnerFrame;
      delay(70);
    }
    fetchWeather();
    Serial.printf("Forced refresh completed: %s\n",
                  fetched ? "yes" : "timeout");
  } else {
    fetched = fetchAll();
  }
  nextFetchMillis = millis() + (fetched ? REFRESH_MS : RETRY_MS);

  for (int frame = 0; frame < 4; ++frame) {
    drawCurrentPage(SWIPE_MAX, true, spinnerFrame++);
    delay(55);
  }
  for (int pull = SWIPE_MAX; pull >= 0; pull -= 7) {
    drawCurrentPage(pull, false);
    delay(18);
  }
  drawCurrentPage();
}

void handleTouch() {
  static uint32_t nextPoll = 0;
  if (static_cast<int32_t>(millis() - nextPoll) < 0) return;
  nextPoll = millis() + 25;

  int x = 0;
  int y = 0;
  bool pressed = readTouchPoint(x, y);
  if (pressed) {
    lastTouchMillis = millis();
    if (!swipeTracking) {
      swipeTracking = true;
      swipeStartX = x;
      swipeStartY = y;
      swipeCurrentX = x;
      swipeCurrentY = y;
      swipePull = 0;
      Serial.printf("Touch started: x=%d y=%d\n", x, y);
    }
    swipeCurrentX = x;
    swipeCurrentY = y;
    int deltaX = swipeCurrentX - swipeStartX;
    int deltaY = swipeCurrentY - swipeStartY;
    if (swipeStartY <= SWIPE_START_Y && deltaY > abs(deltaX)) {
      int nextPull = constrain(y - swipeStartY, 0, SWIPE_MAX);
      if (abs(nextPull - swipePull) >= 2) {
        swipePull = nextPull;
        drawCurrentPage(swipePull);
      }
    }
    return;
  }

  if (!swipeTracking) return;
  if (millis() - lastTouchMillis < 60) return;
  int deltaX = swipeCurrentX - swipeStartX;
  int deltaY = swipeCurrentY - swipeStartY;
  bool shouldRefresh =
      swipeStartY <= SWIPE_START_Y && swipePull >= SWIPE_TRIGGER &&
      deltaY > abs(deltaX);
  bool horizontal =
      abs(deltaX) >= 50 && abs(deltaX) > abs(deltaY);
  bool tap = abs(deltaX) < 12 && abs(deltaY) < 12;
  Serial.printf("Touch released: dx=%d dy=%d refresh=%s\n", deltaX, deltaY,
                shouldRefresh ? "yes" : "no");
  swipeTracking = false;
  if (shouldRefresh) {
    animateGestureRefresh();
  } else if (horizontal) {
    Page nextPage = deltaX < 0 ? Page::Weather : Page::Dashboard;
    animatePageTransition(nextPage, deltaX < 0);
  } else if (tap) {
    if (currentPage == Page::Dashboard && swipeStartY >= CONTENT_TOP) {
      bool showCodex;
      bool showClaude;
      displayedProviders(showCodex, showClaude);
      if (showCodex && (!showClaude || swipeStartX < 317)) {
        animatePageTransition(Page::CodexDetail, true);
      }
    } else if (currentPage == Page::CodexDetail) {
      animatePageTransition(Page::Dashboard, false);
    } else {
      drawCurrentPage();
    }
  } else {
    for (int pull = swipePull; pull >= 0; pull -= 7) {
      drawCurrentPage(pull);
      delay(12);
    }
    drawCurrentPage();
  }
  swipePull = 0;
}

void setupDisplay() {
  pinMode(TFT_BL, OUTPUT);
  pinMode(TFT_RST, OUTPUT);
  pinMode(TOUCH_INT, INPUT_PULLUP);
  ledcSetup(1, 2000, 8);
  ledcAttachPin(TFT_BL, 1);
  ledcWrite(1, 0);

  digitalWrite(TFT_RST, HIGH);
  delay(2);
  digitalWrite(TFT_RST, LOW);
  delay(100);
  digitalWrite(TFT_RST, HIGH);
  delay(2);
  Wire.begin(TOUCH_SDA, TOUCH_SCL, 100000);
  Wire.setTimeOut(20);

  if (!panel->begin(32000000) || !view->begin(GFX_SKIP_OUTPUT_BEGIN)) {
    while (true) delay(1000);
  }
  rotated = static_cast<uint16_t *>(
      ps_malloc(LCD_WIDTH * LCD_HEIGHT * sizeof(uint16_t)));
  if (!rotated) {
    while (true) delay(1000);
  }
  transitionFrom = static_cast<uint16_t *>(
      ps_malloc(VIEW_WIDTH * VIEW_HEIGHT * sizeof(uint16_t)));
  view->fillScreen(COLOR_BG);
  present();
  ledcWrite(1, BACKLIGHT);

  Serial.printf("CST3530 touch controller: %s\n",
                probeI2C(TOUCH_ADDRESS) == 0 ? "ready" : "not found");
}

void restartDisplay() {
  if (displaySleeping) return;
  Serial.println("LCD restart started");
  ledcWrite(1, 0);
  panel->restart();
  drawCurrentPage();
  ledcWrite(1, BACKLIGHT);
  Serial.println("LCD restart completed");
}

void updateDisplaySleep() {
  bool sleeping = sleepSchedule.asleepAt(time(nullptr));
  if (sleeping == displaySleeping) return;
  displaySleeping = sleeping;
  swipeTracking = false;
  swipePull = 0;
  if (sleeping) {
    ledcWrite(1, 0);
    panel->displayOff();
    Serial.println("LCD scheduled sleep");
  } else {
    // Reuse the panel recovery path to repaint before restoring the backlight.
    restartDisplay();
    nextLcdRestartMillis = millis() + LCD_RESTART_MS;
    Serial.println("LCD scheduled wake");
  }
}

}  // namespace

void setup() {
  Serial.begin(115200);
  Serial.printf("Boot reset reason: %d\n", static_cast<int>(esp_reset_reason()));
  setupDisplay();
  clearConfigurationIfRequested();

  if (!loadConfiguration()) startSetupPortal();
  configTzTime(sleepTimezone.c_str(), "pool.ntp.org", "time.nist.gov");
  if (!connectWifi()) startSetupPortal();

  drawMessage("SYNCHRONISATION", "Lecture des quotas...");
  bool fetched = fetchAll();
  nextFetchMillis = millis() + (fetched ? REFRESH_MS : RETRY_MS);
  drawCurrentPage();
  nextLcdRestartMillis = millis() + LCD_RESTART_MS;
}

void loop() {
  updateDisplaySleep();
  if (WiFi.status() != WL_CONNECTED) {
    online = false;
    WiFi.reconnect();
  }

  if (!displaySleeping) handleTouch();

  if (!displaySleeping && !swipeTracking &&
      static_cast<int32_t>(millis() - nextLcdRestartMillis) >= 0) {
    restartDisplay();
    nextLcdRestartMillis = millis() + LCD_RESTART_MS;
  }

  if (!swipeTracking &&
      static_cast<int32_t>(millis() - nextFetchMillis) >= 0) {
    bool fetched = fetchAll();
    nextFetchMillis = millis() + (fetched ? REFRESH_MS : RETRY_MS);
    drawCurrentPage();
  }

  static uint32_t lastAnimation = 0;
  static int animationFrame = 0;
  if (!displaySleeping && !swipeTracking && millis() - lastAnimation >= 900) {
    lastAnimation = millis();
    drawCurrentPage(0, false, ++animationFrame);
  }
  delay(25);
}
