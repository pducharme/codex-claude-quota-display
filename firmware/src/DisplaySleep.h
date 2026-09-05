#pragma once

#include <time.h>

struct DisplaySleep {
  bool enabled = false;
  int startMinute = 23 * 60;
  int endMinute = 7 * 60;

  bool valid() const {
    return startMinute >= 0 && startMinute < 1440 && endMinute >= 0 &&
           endMinute < 1440 && startMinute != endMinute;
  }

  bool containsMinute(int minute) const {
    if (!enabled || !valid() || minute < 0 || minute >= 1440) return false;
    return startMinute < endMinute
               ? minute >= startMinute && minute < endMinute
               : minute >= startMinute || minute < endMinute;
  }

  bool asleepAt(time_t now) const {
    if (now < 1700000000) return false;  // Wait for a real clock after power loss.
    struct tm local {};
    return localtime_r(&now, &local) &&
           containsMinute(local.tm_hour * 60 + local.tm_min);
  }
};
