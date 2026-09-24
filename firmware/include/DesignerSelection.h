#pragma once
#include <stdint.h>
#include <string>
#include <vector>
#include <algorithm>
#include <set>

inline uint32_t designerCountdownSeconds(uint32_t remainingMs,uint32_t received,uint32_t now,bool running){
  uint32_t elapsed=running?now-received:0;
  return remainingMs>elapsed?(remainingMs-elapsed+999)/1000:0;
}

// The start page and timed rotation share the same eligibility rule. Manual
// swipes still visit every page, including a flight page reserved for alerts.
inline int designerNextRotation(const std::vector<bool>& included,int current){
  int count=included.size();
  for(int step=1;step<=count;step++){
    int index=(current+step+count)%count;
    if(included[index])return index;
  }
  return -1;
}

inline bool designerInRotation(bool included,bool sky){return included&&!sky;}

struct DesignerAircraft { std::string id; bool inside; std::string callsign; };
// Pure selection policy shared with a host-side check. All time is monotonic milliseconds.
class DesignerSelection {
 public:
  static constexpr uint32_t defaultDuration=3000;
  uint32_t duration=defaultDuration;
  std::string active;
  uint32_t started=0;
  // Remember both identities for this boot, including across publications/outages.
  std::set<std::string> seenAircraft,seenFlights;
  uint32_t ended=0;
  bool cooling=false;
  void dismiss(uint32_t now){active.clear();ended=now;cooling=true;}
  std::string update(const std::vector<DesignerAircraft>& aircraft,uint32_t now,bool blocked,bool fresh=true,uint32_t durationMs=defaultDuration){
    if(!active.empty()){
      auto current=std::find_if(aircraft.begin(),aircraft.end(),[&](const DesignerAircraft &a){return a.id==active&&a.inside;});
      if(blocked||!fresh||now-started>=duration||current==aircraft.end()){
        dismiss(now);return "";
      }
      if(!current->callsign.empty())seenFlights.insert(current->callsign);
      return active;
    }
    // Leave the restored page visible between separate arrivals.
    if(blocked||!fresh||(cooling&&now-ended<defaultDuration))return "";
    for(const auto &a:aircraft){
      bool seen=seenAircraft.count(a.id)||(!a.callsign.empty()&&seenFlights.count(a.callsign));
      if(seen){
        seenAircraft.insert(a.id);
        if(!a.callsign.empty())seenFlights.insert(a.callsign);
      } else if(a.inside&&!a.id.empty()){
        active=a.id;started=now;duration=durationMs;seenAircraft.insert(a.id);
        if(!a.callsign.empty())seenFlights.insert(a.callsign);
        break;
      }
    }
    return active;
  }
};
