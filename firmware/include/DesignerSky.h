// Shared by the device and the host render check: the actual 640 x 180 artwork.
#pragma once
#include "DesignerSkyFonts.h"

struct DesignerSkyData {
  String callsign,airline,distance,originCode,destinationCode,origin,destination;
  String aircraft,speed,altitude,message;
  float progress=-1;
};

uint16_t skyBlend(uint16_t a,uint16_t b,float t) {
  return rgb(((a>>11)*8)*(1-t)+((b>>11)*8)*t,
             (((a>>5)&63)*4)*(1-t)+(((b>>5)&63)*4)*t,
             ((a&31)*8)*(1-t)+((b&31)*8)*t);
}

void skyText(int x,int y,int w,int h,const String &text,int font,int size,uint16_t color) {
  if(font<4){designerText(x,y,w,h,text,font,size,color);return;}
  int cursor=x;
  for(size_t i=0;i<text.length();){
    uint32_t cp=(uint8_t)text[i++];
    if(cp>=0xC2&&cp<=0xDF&&i<text.length())cp=((cp&31)<<6)|((uint8_t)text[i++]&63);
    else if(cp>=0xE0){while(i<text.length()&&((uint8_t)text[i]&0xC0)==0x80)i++;cp='?';}
    if(cp<32||cp>255)cp='?';
    const SkyGlyph &g=skyGlyphs[((font-4)*3+size-1)*224+cp-32];
    if(cursor+g.advance>x+w)break;
    for(int row=0;row<g.h&&g.y+row<h;row++)for(int col=0;col<g.w;col++){
      int n=row*g.w+col;uint8_t packed=skyCoverage[g.offset+n/2],alpha=n%2?packed&15:packed>>4;
      int px=cursor+g.x+col,py=y+g.y+row;
      if(alpha&&px>=0&&px<640&&py>=0&&py<180)view->drawPixel(px,py,skyBlend(view->getFramebuffer()[py*640+px],color,alpha/15.0f));
    }
    cursor+=g.advance;
  }
}

void skyPlane(float x,float y,float angle,uint16_t color,uint16_t shade,uint16_t glass) {
  const int shape[][2]={{40,0},{31,-4},{5,-5},{-14,-32},{-23,-32},{-14,-5},{-28,-4},{-36,-14},{-42,-14},{-36,0},{-42,14},{-36,14},{-28,4},{-14,5},{-23,32},{-14,32},{5,5},{31,4}};
  float c=cosf(angle),s=sinf(angle);
  auto px=[&](float a,float b){return int(x+a*c-b*s);};
  auto py=[&](float a,float b){return int(y+a*s+b*c);};
  for(int i=0;i<18;i++){
    int j=(i+1)%18;
    view->fillTriangle(x,y,px(shape[i][0],shape[i][1]),py(shape[i][0],shape[i][1]),px(shape[j][0],shape[j][1]),py(shape[j][0],shape[j][1]),i<9?color:shade);
  }
  view->drawLine(px(26,-3),py(26,-3),px(29,0),py(29,0),glass);
  view->drawLine(px(29,0),py(29,0),px(26,3),py(26,3),glass);
  view->drawLine(px(-28,0),py(-28,0),px(18,0),py(18,0),color);
  for(int side:{-1,1})view->drawLine(px(-4,side*12),py(-4,side*12),px(5,side*12),py(5,side*12),shade);
}

void drawDesignerSky(const DesignerSkyData &f,int font,uint16_t bg,uint16_t accent,uint32_t elapsed,bool automatic) {
  const uint16_t white=rgb(240,247,255),muted=skyBlend(bg,white,.66f),line=skyBlend(bg,accent,.22f);
  for(int y=0;y<180;y++)view->drawFastHLine(0,y,640,skyBlend(bg,accent,.075f*sinf(y*3.14159f/180)));
  view->drawFastHLine(20,36,600,line);
  skyText(20,9,150,22,f.callsign.length()?f.callsign:String("Dans le ciel"),font,1,white);
  skyText(174,9,312,22,f.airline,font,1,muted);
  view->fillCircle(508,19,3,skyBlend(bg,accent,.65f+.35f*sinf(elapsed*.006f)));
  skyText(521,9,112,22,f.distance,font,1,white);

  if(f.progress>=0){
    skyText(20,51,151,54,f.originCode,font,3,white);
    skyText(20,105,146,22,f.origin,font,1,muted);
    skyText(497,51,139,54,f.destinationCode,font,3,white);
    skyText(497,105,139,22,f.destination,font,1,muted);
    const float progress=f.progress/100;
    int lastX=172,lastY=107;
    for(int i=1;i<=148;i++){
      float t=i/148.0f;int x=172+296*t,y=107-164*t*(1-t);
      view->drawLine(lastX,lastY+1,x,y+1,line);
      if(t<=progress||((i+int(elapsed/65))%12)<5)view->drawLine(lastX,lastY,x,y,t<=progress?accent:skyBlend(bg,accent,.45f));
      lastX=x;lastY=y;
    }
    view->fillCircle(172,107,3,accent);view->drawCircle(468,107,3,muted);
    float x=172+296*progress,y=107-164*progress*(1-progress);
    // The marker stays at the reported estimate; only its wake and light move.
    view->drawCircle(x,y,25+(elapsed/80)%8,line);
    skyPlane(x,y,atanf((-164+328*progress)/296),white,skyBlend(white,accent,.32f),bg);
    skyText(239,118,230,20,"Trajet estimé",font,1,muted);
  } else {
    skyPlane(140,88,-.13f,f.message.length()?muted:white,skyBlend(bg,accent,.65f),bg);
    skyText(234,53,390,42,f.message.length()?String("Dans le ciel"):String("Trajet indisponible"),font,2,white);
    skyText(234,101,388,24,f.message.length()?f.message:String("Avion détecté dans votre zone"),font,1,muted);
  }
  view->drawFastHLine(20,143,600,line);
  skyText(20,151,f.message.length()?600:267,22,f.aircraft,font,1,muted);
  skyText(305,151,180,22,f.speed,font,1,white);
  skyText(501,151,136,22,f.altitude,font,1,white);
  if(automatic)view->fillRect(0,178,640*(3000-std::min(elapsed,uint32_t(3000)))/3000,2,accent);
}
