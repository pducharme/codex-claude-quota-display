#include <cassert>
#include "include/DesignerSelection.h"
int main(){
  DesignerSelection s;
  assert(s.update({{"A",true}},100,false)=="A");
  assert(s.update({{"A",false},{"B",true}},1000,false)=="A"); // outer margin retains current flight
  assert(s.update({{"B",true}},2000,false)=="A");
  assert(s.update({{"B",true}},18000,false)=="B");
  s.dismiss();assert(s.update({{"B",true}},19000,false).empty());
  assert(s.update({{"C",true}},20000,true).empty()); // pinned page
  assert(s.update({{"C",true}},21000,false)=="C");
  assert(s.update({},22000,false)=="C");
  assert(s.update({},38000,false).empty()); // lost data releases screen
  s.reset();assert(s.update({{"D",false}},39000,false).empty());
  assert(s.update({{"A",true}},40000,false)=="A");
  s.dismiss();
  for(uint32_t t=41000;t<300000;t+=10000)assert(s.update({},t,false,false).empty());
  assert(s.update({{"A",true}},300000,false).empty()); // outage did not re-arm
  for(uint32_t t=310000;t<=430000;t+=10000)s.update({},t,false,true);
  assert(s.update({{"A",true}},431000,false)=="A"); // a later pass may interrupt
  s.dismiss();
  s.update({},440000,false,true);
  s.update({},700000,false,true); // long sleep is not confirmed absence
  assert(s.update({{"A",true}},701000,false).empty());
  s.reset();
  s.update({{"W",true}},0xffff0000UL,false);s.dismiss();
  for(uint32_t elapsed=0;elapsed<=120000;elapsed+=10000)s.update({},0xffff0000UL+elapsed,false);
  assert(s.update({{"W",true}},uint32_t(0xffff0000UL+121000),false)=="W"); // millis rollover
}
