// Included after native page drawing routines. Network work stays off the touch loop.
#include <LittleFS.h>
#include "DesignerFonts.h"
#include "DesignerSelection.h"

JsonDocument designerDocument;
uint32_t designerRevision = 0;
uint32_t designerReceived = 0;
uint32_t designerPageStarted = 0;
int designerIndex = 0;
bool designerPinned = false;
bool designerInterrupted = false;
Page designerPreviousPage = Page::Dashboard;
int designerPreviousIndex = 0;
uint32_t designerPreviousElapsed = 0;
String designerFlightID;
DesignerSelection designerSelection;
SemaphoreHandle_t designerMutex = nullptr;
String designerPending;
bool designerActionPending = false;
volatile uint32_t designerReportedRevision = 0;
volatile bool designerReportedSleep = false;
bool designerFS = false;

String designerDeviceID() {
  String id=WiFi.macAddress();id.replace(":","");id.toLowerCase();
  return id;
}

String designerSourceID() {
  uint32_t hash=2166136261UL;
  String source=bridgeHost+"/"+bridgeToken;
  for (size_t i=0;i<source.length();i++) hash=(hash^source[i])*16777619UL;
  return String(hash,HEX);
}

bool designerValid(JsonDocument &doc) {
  if ((doc["version"]|0)!=1 || !doc["revision"].is<uint32_t>() || !doc["pages"].is<JsonArray>()) return false;
  JsonArray pages=doc["pages"];
  if(pages.size()>8 || ((doc["revision"]|0)>0 && pages.size()==0)) return false;
  if ((doc["rotation"]|0)<0 || (doc["rotation"]|0)>600) return false;
  for(JsonObject p:pages) {
    String kind=p["kind"]|"";
    if(kind!="custom"&&kind!="sky"&&kind!="native-quotas"&&kind!="native-weather") return false;
    if(!p["blocks"].is<JsonArray>() || p["blocks"].size()>16) return false;
    for(JsonObject b:p["blocks"].as<JsonArray>()) {
      String type=b["type"]|"";
      if(type!="text"&&type!="value"&&type!="bar"&&type!="button") return false;
      int x=b["x"]|-1,y=b["y"]|-1,w=b["w"]|0,h=b["h"]|0,s=b["size"]|0;
      if(x<0||y<0||w<8||h<8||x+w>640||y+h>180||s<1||s>4) return false;
      if(String(b["text"]|"").length()>400) return false;
    }
  }
  return true;
}

uint16_t designerColor(const char *s,uint16_t fallback) {
  if(!s||strlen(s)!=7||s[0]!='#') return fallback;
  char *end=nullptr; unsigned long value=strtoul(s+1,&end,16);
  if(*end) return fallback;
  return rgb((value>>16)&255,(value>>8)&255,value&255);
}

int designerFont(const char *name) {
  const char *names[]={"pixel","silkscreen","pixelify","terminal","modern","mono"};
  for(int i=0;i<6;i++) if(name&&strcmp(name,names[i])==0) return i;
  return 0;
}

void designerText(int x,int y,int w,int h,const String &s,int font,int scale,uint16_t color) {
  int cursor=x;
  for(size_t i=0;i<s.length();) {
    uint32_t cp=(uint8_t)s[i++];
    if(cp>=0xC2&&cp<=0xDF&&i<s.length()) cp=((cp&31)<<6)|((uint8_t)s[i++]&63);
    else if(cp>=0xE0) {
      if(cp==0xE2&&i+1<s.length()&&(uint8_t)s[i]==0x80&&((uint8_t)s[i+1]==0x98||(uint8_t)s[i+1]==0x99)){i+=2;cp=39;}
      else if(cp==0xE2&&i+1<s.length()&&(uint8_t)s[i]==0x80&&((uint8_t)s[i+1]==0x93||(uint8_t)s[i+1]==0x94)){i+=2;cp=45;}
      else {while(i<s.length()&&((uint8_t)s[i]&0xC0)==0x80)i++;cp='?';}
    }
    if(cp<32||cp>255)cp='?';
    const DesignerGlyph &g=designerFonts[font][cp-32];
    if(cursor+g.width*scale>x+w) break;
    for(int row=0;row<16&&row*scale+scale<=h;row++)
      for(int col=0;col<g.width;col++) if(g.rows[row]&(1UL<<col))view->fillRect(cursor+col*scale,y+row*scale,scale,scale,color);
    cursor+=g.width*scale;
  }
}

JsonObject designerFlight() {
  JsonArray flights=designerDocument["flight"]["flights"].as<JsonArray>();
  for(JsonObject f:flights) if(String(f["id"]|"")==designerFlightID) return f;
  if(designerInterrupted)return JsonObject();
  for(JsonObject f:flights) if(f["inside"]|false) return f;
  return JsonObject();
}

void drawDesigner() {
  JsonArray pages=designerDocument["pages"].as<JsonArray>();
  if(pages.size()==0){drawDashboard();return;}
  if(designerIndex<0||designerIndex>=(int)pages.size())designerIndex=0;
  JsonObject p=pages[designerIndex];
  String kind=p["kind"]|"";
  if(kind=="native-quotas"){drawDashboard();if(!displaySleeping)designerReportedRevision=designerRevision;return;}
  if(kind=="native-weather"){drawWeatherPage();if(!displaySleeping)designerReportedRevision=designerRevision;return;}
  uint16_t bg=designerColor(p["background"],COLOR_BG),accent=designerColor(p["accent"],COLOR_CODEX);
  int font=designerFont(p["font"]);
  view->fillScreen(bg);
  if(kind=="sky") {
    JsonObject f=designerFlight();
    if(f.isNull()||millis()-designerReceived>45000) {
      String status=designerDocument["flight"]["status"]|"unavailable";
      designerText(20,24,600,32,"Dans le ciel",font,2,accent);
      designerText(20,90,600,24,status=="disabled"?"Choisissez votre zone dans Companion":status=="ok"?"Aucun avion detecte dans la zone":"Donnees de vol indisponibles",font,1,COLOR_TEXT);
    } else {
      designerText(18,12,360,20,String(f["callsign"]|"Vol")+" "+String(f["airline"]|""),font,1,COLOR_MUTED);
      String distance=String(f["distance"].as<float>(),1)+" km";
      designerText(490,12,135,20,distance,font,1,COLOR_MUTED);
      if(!f["progress"].isNull()) {
        designerText(18,55,140,40,String(f["origin_code"]|""),font,2,COLOR_TEXT);
        designerText(18,101,145,20,String(f["origin"]|""),font,1,COLOR_MUTED);
        designerText(520,55,115,40,String(f["destination_code"]|""),font,2,COLOR_TEXT);
        designerText(520,101,115,20,String(f["destination"]|""),font,1,COLOR_MUTED);
        int px=165,py=111;
        for(int i=1;i<=60;i++){float t=i/60.0f;int x=165+310*t,y=111-194*t*(1-t);view->drawLine(px,py,x,y,accent);px=x;py=y;}
        float t=constrain(f["progress"].as<float>(),0,100)/100.0f;
        int x=165+310*t,y=111-194*t*(1-t);
        view->fillRect(x-12,y-2,24,4,accent);view->fillTriangle(x+5,y,x-5,y-12,x-1,y,accent);view->fillTriangle(x+5,y,x-5,y+12,x-1,y,accent);view->fillTriangle(x-8,y,x-14,y-6,x-12,y,accent);view->fillTriangle(x-8,y,x-14,y+6,x-12,y,accent);
        designerText(222,112,275,20,"Trajet estime",font,1,COLOR_MUTED);
      } else designerText(20,70,600,32,"Trajet indisponible",font,2,COLOR_TEXT);
      designerText(18,150,235,22,String(f["aircraft"]|"Appareil inconnu"),font,1,COLOR_TEXT);
      designerText(280,150,160,22,f["speed"].isNull()?"--":String(f["speed"].as<int>())+" km/h",font,1,COLOR_TEXT);
      designerText(493,150,143,22,f["altitude"].isNull()?"--":String(f["altitude"].as<int>())+" m",font,1,COLOR_TEXT);
    }
  } else {
    for(JsonObject b:p["blocks"].as<JsonArray>()) {
      int x=b["x"],y=b["y"],w=b["w"],h=b["h"],scale=b["size"];
      String type=b["type"]|"";
      if(type=="bar") {
        view->fillRect(x,y,w,h,COLOR_TRACK);
        if(!b["value"].isNull())view->fillRect(x,y,w*constrain(b["value"].as<int>(),0,100)/100,h,accent);
        else designerText(x+3,y,w-6,h,"--",font,1,COLOR_MUTED);
      } else {
        if(type=="button"){view->fillRect(x,y,w,h,COLOR_TRACK);x+=8;w-=16;y+=max(0,(h-16*scale)/2);}
        designerText(x,y,w,h,String(b["text"]|""),font,scale,type=="value"?accent:COLOR_TEXT);
      }
    }
  }
  if(!designerReceived||millis()-designerReceived>30000){view->fillRect(0,0,640,18,bg);designerText(8,1,622,16,"Hors ligne - anciennes valeurs",0,1,COLOR_AMBER);}
  if(designerPinned)view->fillCircle(633,5,3,COLOR_AMBER);
  present();
  if(!displaySleeping)designerReportedRevision=designerRevision;
}

void designerNetwork(void *) {
  const String id=designerDeviceID();
  for(;;) {
    if(WiFi.status()==WL_CONNECTED) {
      bool action=false;
      if(xSemaphoreTake(designerMutex,pdMS_TO_TICKS(20))){action=designerActionPending;designerActionPending=false;xSemaphoreGive(designerMutex);}
      if(action){HTTPClient http;http.setConnectTimeout(1500);http.setTimeout(2000);if(http.begin("http://"+bridgeHost+"/v1/designer/action")){http.addHeader("Authorization","Bearer "+bridgeToken);http.addHeader("Content-Type","application/json");int code=http.POST("{\"device\":\""+id+"\",\"action\":\"focus.toggle\"}");Serial.printf("Designer action: %d\n",code);http.end();}}
      HTTPClient http;http.setConnectTimeout(1500);http.setTimeout(2000);
      if(http.begin("http://"+bridgeHost+"/v1/designer/frame?device="+id+"&applied="+String(designerReportedRevision)+"&sleeping="+(designerReportedSleep?"1":"0"))) {
        http.addHeader("Authorization","Bearer "+bridgeToken);
        int status=http.GET();int length=http.getSize();
        if(status==200&&length>0&&length<=32768) {
          String body=http.getString();
          if(body.length()==(size_t)length&&xSemaphoreTake(designerMutex,pdMS_TO_TICKS(20))){designerPending=body;xSemaphoreGive(designerMutex);}
        }
        http.end();
      }
    }
    vTaskDelay(pdMS_TO_TICKS(2000));
  }
}

void designerCache(const String &body) {
  if(!designerFS)return;
  File f=LittleFS.open("/designer.tmp","w");if(!f)return;
  String source=designerSourceID()+"\n";
  bool ok=f.print(source)==source.length()&&f.print(body)==body.length();f.close();
  if(!ok){LittleFS.remove("/designer.tmp");return;}
  LittleFS.remove("/designer.prev");
  if(LittleFS.exists("/designer.json"))LittleFS.rename("/designer.json","/designer.prev");
  LittleFS.rename("/designer.tmp","/designer.json");
}

void startDesigner() {
  designerFS=LittleFS.begin(true);
  if(designerFS)for(const char *name:{"/designer.json","/designer.prev"}) {
    File f=LittleFS.open(name,"r");if(!f)continue;
    if(f.size()>32800||f.readStringUntil('\n')!=designerSourceID()){f.close();continue;}
    JsonDocument cached;auto error=deserializeJson(cached,f);f.close();
    if(error==DeserializationError::Ok&&designerValid(cached)){
      designerDocument=cached;designerRevision=cached["revision"]|0;
      designerDocument["flight"].clear();
      if(designerDocument["pages"].size())currentPage=Page::Designed;
      break;
    }
  }
  designerPageStarted=millis();
  designerMutex=xSemaphoreCreateMutex();
  if(designerMutex)xTaskCreate(designerNetwork,"designer",8192,nullptr,1,nullptr);
}

void designerRestore() {
  currentPage=designerPreviousPage;designerIndex=designerPreviousIndex;
  designerPageStarted=millis()-designerPreviousElapsed;
  designerInterrupted=false;designerFlightID="";designerPinned=false;
}

void designerManualExit() {
  if(designerInterrupted){designerSelection.dismiss();designerRestore();}
}

void designerNavigate(int direction) {
  if(designerInterrupted){
    if(direction>0){
      JsonArray flights=designerDocument["flight"]["flights"].as<JsonArray>();
      int found=-1;for(size_t i=0;i<flights.size();i++)if(String(flights[i]["id"]|"")==designerFlightID)found=i;
      for(size_t step=1;step<flights.size();step++){
        JsonObject next=flights[(found+step)%flights.size()];
        if(next["inside"]|false){designerFlightID=next["id"].as<String>();designerSelection.active=designerFlightID.c_str();return;}
      }
    }
    designerManualExit();return;
  }
  int count=designerDocument["pages"].size();
  if(!count)return;
  currentPage=Page::Designed;designerPinned=false;
  designerIndex=(designerIndex+direction+count)%count;designerPageStarted=millis();
}

void designerTap(int x,int y) {
  JsonObject p=designerDocument["pages"][designerIndex];
  if(String(p["kind"]|"")=="native-quotas"){
    bool c,a;displayedProviders(c,a);
    if(c&&(!a||x<317)){currentPage=Page::CodexDetail;return;}
  }
  for(JsonObject b:p["blocks"].as<JsonArray>()) {
    if(String(b["type"]|"")=="button"&&String(b["action"]|"")=="focus.toggle"&&x>=b["x"].as<int>()&&y>=b["y"].as<int>()&&x<b["x"].as<int>()+b["w"].as<int>()&&y<b["y"].as<int>()+b["h"].as<int>()) {
      if(xSemaphoreTake(designerMutex,pdMS_TO_TICKS(10))){designerActionPending=true;xSemaphoreGive(designerMutex);}return;
    }
  }
  designerPinned=!designerPinned;
}

void updateDesigner() {
  const uint32_t now=millis();designerReportedSleep=displaySleeping;
  String body;
  if(designerMutex&&xSemaphoreTake(designerMutex,0)){body=designerPending;designerPending="";xSemaphoreGive(designerMutex);}
  if(body.length()){
    JsonDocument next;
    if(deserializeJson(next,body)==DeserializationError::Ok&&designerValid(next)){
      uint32_t revision=next["revision"]|0;
      bool changed=revision!=designerRevision;
      designerDocument=next;designerReceived=now;
      if(changed){designerRevision=revision;designerCache(body);designerIndex=0;designerPinned=false;designerInterrupted=false;designerSelection.reset();designerPageStarted=now;if(currentPage!=Page::Settings)currentPage=designerDocument["pages"].size()?Page::Designed:Page::Dashboard;Serial.printf("Designer revision applied: %u\n",revision);}
    }
  }
  int skyIndex=-1;int i=0;for(JsonObject p:designerDocument["pages"].as<JsonArray>()){if(String(p["kind"]|"")=="sky")skyIndex=i;i++;}
  bool allowed=(designerDocument["auto_sky"]|false)&&skyIndex>=0&&!displaySleeping&&currentPage!=Page::Settings;
  if(designerInterrupted&&!allowed)designerRestore();
  if(!allowed||swipeTracking||now-lastTouchMillis<5000){return;}
  std::vector<DesignerAircraft> aircraft;
  if(designerReceived&&now-designerReceived<45000&&String(designerDocument["flight"]["status"]|"")=="ok")
    for(JsonObject f:designerDocument["flight"]["flights"].as<JsonArray>()) aircraft.push_back({std::string(f["id"]|""),f["inside"]|false});
  std::string selected=designerSelection.update(aircraft,now,designerPinned&&!designerInterrupted);
  if(!selected.empty()) {
    if(!designerInterrupted){designerPreviousPage=currentPage;designerPreviousIndex=designerIndex;designerPreviousElapsed=now-designerPageStarted;designerInterrupted=true;}
    designerFlightID=selected.c_str();currentPage=Page::Designed;designerIndex=skyIndex;
  } else if(designerInterrupted)designerRestore();
}

void rotateDesigner() {
  uint32_t interval=(designerDocument["rotation"]|0)*1000UL;
  if(interval&&!designerInterrupted&&!designerPinned&&!swipeTracking&&!displaySleeping&&currentPage==Page::Designed&&millis()-lastTouchMillis>5000&&millis()-designerPageStarted>=interval)designerNavigate(1);
}
