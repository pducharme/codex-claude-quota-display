#pragma once
#include <stdint.h>
#include <string>
#include <vector>
#include <algorithm>

struct DesignerAircraft { std::string id; bool inside; };
// Pure selection policy shared with a host-side check. All time is monotonic milliseconds.
class DesignerSelection {
 public:
  std::string active;
  std::vector<std::string> dismissed;
  uint32_t missingAt=0;
  bool missing=false;
  void reset(){active.clear();dismissed.clear();missing=false;}
  void dismiss(){if(!active.empty())dismissed.push_back(active);active.clear();missing=false;}
  std::string update(const std::vector<DesignerAircraft>& aircraft,uint32_t now,bool blocked){
    if(blocked)return "";
    // Keep dismissed flights suppressed for this process lifetime. Bounded to 64 passes;
    // a new identity can still interrupt, but a noisy edge cannot reopen a dismissed pass.
    if(dismissed.size()>64)dismissed.erase(dismissed.begin());
    if(!active.empty()){
      for(const auto &a:aircraft)if(a.id==active){missing=false;return active;}
      if(!missing){missingAt=now;missing=true;}
      if(now-missingAt<15000)return active;
      active.clear();missing=false;
    }
    for(const auto &a:aircraft)if(a.inside&&std::find(dismissed.begin(),dismissed.end(),a.id)==dismissed.end()){active=a.id;break;}
    return active;
  }
};
