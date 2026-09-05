// Run: c++ -std=c++11 -Wall -Wextra -pedantic firmware/test_sleep.cpp -o /tmp/quota-sleep-test && /tmp/quota-sleep-test
#include "src/DisplaySleep.h"
#include <assert.h>
#include <initializer_list>
#include <stdlib.h>

time_t utc(int month, int day, int hour, int minute = 0) {
  struct tm value {};
  value.tm_year = 126;
  value.tm_mon = month - 1;
  value.tm_mday = day;
  value.tm_hour = hour;
  value.tm_min = minute;
  return timegm(&value);
}

int main() {
  DisplaySleep schedule;
  assert(!schedule.containsMinute(0));
  schedule.enabled = true;
  assert(!schedule.asleepAt(0));
  for (int start : {0, 480, 1380}) {
    for (int end : {1, 420, 1020, 1439}) {
      schedule.startMinute = start;
      schedule.endMinute = end;
      for (int minute = 0; minute < 1440; ++minute) {
        assert(schedule.containsMinute(minute) ==
               ((minute - start + 1440) % 1440 < (end - start + 1440) % 1440));
      }
    }
  }
  schedule.startMinute = 1380;
  schedule.endMinute = 420;
  assert(!schedule.containsMinute(1379));
  assert(schedule.containsMinute(1380));
  assert(schedule.containsMinute(419));
  assert(!schedule.containsMinute(420));
  assert(!schedule.containsMinute(-1));
  assert(!schedule.containsMinute(1440));
  setenv("TZ", "EST5EDT,M3.2.0,M11.1.0", 1);
  tzset();
  assert(schedule.asleepAt(utc(3, 8, 6, 59)));  // Before spring's skipped hour.
  assert(schedule.asleepAt(utc(3, 8, 7)));      // After it, still asleep.
  assert(!schedule.asleepAt(utc(3, 8, 11)));   // 07:00 daylight time.
  assert(schedule.asleepAt(utc(11, 1, 5, 30)));
  assert(schedule.asleepAt(utc(11, 1, 6, 30))); // Both occurrences of 01:30.
  assert(!schedule.asleepAt(utc(11, 1, 12)));  // 07:00 standard time.
  schedule.enabled = false;
  assert(!schedule.asleepAt(utc(11, 1, 6)));
  schedule.enabled = true;
  schedule.endMinute = schedule.startMinute;
  assert(!schedule.valid() && !schedule.containsMinute(0));
}
