#include <cassert>
#include "include/DesignerSelection.h"
int main(){
  assert(designerCountdownSeconds(2500,100,100,true)==3);
  assert(designerCountdownSeconds(2500,100,600,true)==2);
  assert(designerCountdownSeconds(2500,100,1600,true)==1); // advances without another network frame
  assert(designerCountdownSeconds(2500,100,2600,true)==0);
  assert(designerCountdownSeconds(2500,100,9000,false)==3); // paused
  assert(designerCountdownSeconds(2500,0xffffff00UL,0x2e8UL,true)==2); // millis rollover
  assert(designerNextRotation({false,true,true},-1)==1); // excluded first page is not shown on boot/publication
  assert(designerNextRotation({true,false,true},0)==2); // skip flight page in ordinary rotation
  assert(designerNextRotation({true,false,true},2)==0); // wrap around
  assert(designerNextRotation({true,false},0)==0); // only one ordinary page
  assert(designerNextRotation({false,true,false},0)==1); // leave a manually selected excluded page
  assert(designerNextRotation({},0)==-1);
  assert(designerNextRotation({false,false},0)==-1);
  assert(!designerInRotation(true,true)); // even legacy sky pages never rotate
  assert(designerInRotation(true,false));
  assert(!designerInRotation(false,false));
  DesignerSelection s;
  assert(s.update({},0,false).empty());
  assert(s.update({{"A",false,"ACA123"}},90,false).empty());
  assert(s.update({{"A",true,"ACA123"}},100,false)=="A");
  assert(s.update({{"A",true,"ACA123"},{"B",true,"BAW42"}},3099,false)=="A");
  assert(s.update({{"A",true,"ACA123"},{"B",true,"BAW42"}},3100,false).empty());
  assert(s.update({{"B",true,"BAW42"}},3101,false).empty()); // restored page remains visible
  assert(s.update({{"B",true,"BAW42"}},6100,false)=="B");
  s.dismiss(6200);
  assert(s.update({{"B",true,"BAW42"}},20000,false).empty());
  assert(s.update({{"A",true,"CHANGED"}},300000,false).empty()); // same aircraft, new callsign
  assert(s.update({{"C",true,"ACA123"}},300001,false).empty()); // same flight, different aircraft ID
  assert(s.update({{"C",true,""}},300002,false).empty()); // alias remains remembered
  assert(s.update({{"D",true,""}},300003,true).empty()); // pinned / sleeping / manual page
  assert(s.update({{"D",true,""}},300004,false)=="D"); // empty callsigns do not collapse unrelated aircraft
  assert(s.update({{"D",false,""}},300005,false).empty()); // exit radius: immediate, no outer margin
  assert(s.update({{"E",true,"NEW"}},304000,false)=="E");
  assert(s.update({},304001,false).empty()); // no empty notification page or stale grace period
  assert(s.update({{"F",true,"FRESH"}},308000,false,false).empty());
  assert(s.update({{"F",true,"FRESH"}},308001,false)=="F");
  assert(s.update({{"F",true,"FRESH"}},308002,false,false).empty()); // outage releases immediately
  assert(s.update({{"F",true,"FRESH"}},500000,false).empty()); // outage/absence never re-arms
  s.dismiss(500001); // publication also preserves previously shown identities
  assert(s.update({{"A",true,"ACA123"}},600000,false).empty());
  DesignerSelection rollover;
  assert(rollover.update({{"W",true,""}},0xffffff00UL,false)=="W");
  assert(rollover.update({{"W",true,""}},uint32_t(0xffffff00UL+2999),false)=="W");
  assert(rollover.update({{"W",true,""}},uint32_t(0xffffff00UL+3000),false).empty());
  assert(rollover.update({{"X",true,""}},uint32_t(0xffffff00UL+6000),false)=="X");
  for(uint32_t duration:{100UL,500UL,1000UL,10000UL,86400000UL}){
    DesignerSelection configured;
    uint32_t start=0xffffff00UL;
    assert(configured.update({{"A",true,"TEST"}},start,false,true,duration)=="A");
    assert(configured.duration==duration);
    assert(configured.update({{"A",true,"TEST"}},start+duration-1,false)=="A");
    assert(configured.update({{"A",true,"TEST"}},start+duration,false).empty());
    assert(configured.update({{"A",true,"TEST"}},start+duration+4000,false).empty());
  }
}
