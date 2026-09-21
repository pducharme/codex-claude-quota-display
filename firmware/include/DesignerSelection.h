#pragma once
#include <stdint.h>
#include <string>
#include <vector>
#include <algorithm>

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

struct DesignerAircraft { std::string id; bool inside; };
struct DesignerDismissal { std::string id; uint32_t absentAt; bool absent; };
// Pure selection policy shared with a host-side check. All time is monotonic milliseconds.
class DesignerSelection {
 public:
  std::string active;
  std::vector<DesignerDismissal> dismissed;
  uint32_t missingAt=0;
  uint32_t lastUpdate=0;
  bool missing=false;
  void reset(){active.clear();dismissed.clear();missing=false;}
  void dismiss(){if(!active.empty())dismissed.push_back({active,0,false});active.clear();missing=false;}
  std::string update(const std::vector<DesignerAircraft>& aircraft,uint32_t now,bool blocked,bool fresh=true){
    // Re-arm the same aircraft only after two minutes of confirmed absence, outside
    // the exit margin. A provider outage or sleep interval cannot prove its departure.
    for(auto it=dismissed.begin();it!=dismissed.end();){
      bool present=std::any_of(aircraft.begin(),aircraft.end(),[&](const DesignerAircraft &a){return a.id==it->id;});
      if(!fresh||present||now-lastUpdate>45000)it->absent=false;
      if(fresh&&!present){
        if(!it->absent){it->absentAt=now;it->absent=true;}
        if(now-it->absentAt>=120000){it=dismissed.erase(it);continue;}
      }
      ++it;
    }
    lastUpdate=now;
    if(dismissed.size()>64)dismissed.erase(dismissed.begin());
    if(blocked)return "";
    if(!active.empty()){
      for(const auto &a:aircraft)if(a.id==active){missing=false;return active;}
      if(!missing){missingAt=now;missing=true;}
      if(now-missingAt<15000)return active;
      active.clear();missing=false;
    }
    for(const auto &a:aircraft)if(a.inside&&std::none_of(dismissed.begin(),dismissed.end(),[&](const DesignerDismissal &d){return d.id==a.id;})){active=a.id;break;}
    return active;
  }
};
