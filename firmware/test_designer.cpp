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
}
