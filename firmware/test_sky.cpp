// Run: c++ -std=c++11 firmware/test_sky.cpp -o /tmp/test-sky && /tmp/test-sky
// Optional output folder argument writes 640 x 180 PPM previews.
#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdint>
#include <fstream>
#include <string>
#include <vector>
using String=std::string;
uint16_t rgb(uint8_t r,uint8_t g,uint8_t b){return ((r&248)<<8)|((g&252)<<3)|(b>>3);}
struct Canvas {
 std::vector<uint16_t> pixels=std::vector<uint16_t>(640*180);
 uint16_t* getFramebuffer(){return pixels.data();}
 void drawPixel(int x,int y,uint16_t c){pixel(x,y,c);}
 void pixel(int x,int y,uint16_t c){if(x>=0&&x<640&&y>=0&&y<180)pixels[y*640+x]=c;}
 void fillRect(int x,int y,int w,int h,uint16_t c){for(int j=y;j<y+h;j++)for(int i=x;i<x+w;i++)pixel(i,j,c);}
 void drawFastHLine(int x,int y,int w,uint16_t c){fillRect(x,y,w,1,c);}
 void drawLine(int x,int y,int ex,int ey,uint16_t c){int dx=abs(ex-x),sx=x<ex?1:-1,dy=-abs(ey-y),sy=y<ey?1:-1,err=dx+dy;for(;;){pixel(x,y,c);if(x==ex&&y==ey)break;int e=2*err;if(e>=dy){err+=dy;x+=sx;}if(e<=dx){err+=dx;y+=sy;}}}
 void fillCircle(int x,int y,int r,uint16_t c){for(int j=-r;j<=r;j++)for(int i=-r;i<=r;i++)if(i*i+j*j<=r*r)pixel(x+i,y+j,c);}
 void drawCircle(int x,int y,int r,uint16_t c){for(float a=0;a<6.284f;a+=.01f)pixel(x+roundf(r*cosf(a)),y+roundf(r*sinf(a)),c);}
 void fillTriangle(int ax,int ay,int bx,int by,int cx,int cy,uint16_t c){auto cross=[](int x,int y,int a,int b,int c,int d){return (x-c)*(b-d)-(a-c)*(y-d);};for(int y=std::min({ay,by,cy});y<=std::max({ay,by,cy});y++)for(int x=std::min({ax,bx,cx});x<=std::max({ax,bx,cx});x++){int a=cross(x,y,ax,ay,bx,by),b=cross(x,y,bx,by,cx,cy),d=cross(x,y,cx,cy,ax,ay);if(!((a<0||b<0||d<0)&&(a>0||b>0||d>0)))pixel(x,y,c);}}
 void save(const std::string& path){std::ofstream f(path,std::ios::binary);f<<"P6\n640 180\n255\n";for(auto p:pixels){char rgb[3]={char((p>>11)*255/31),char(((p>>5)&63)*255/63),char((p&31)*255/31)};f.write(rgb,3);}}
} canvas;
auto view=&canvas;
// The smooth-font checks exercise the real flight renderer without an ESP32.
void designerText(int,int,int,int,const String&,int,int,uint16_t){assert(false);}
#include "include/DesignerSky.h"
int main(int argc,char **argv){
 const std::string output=argc>1?argv[1]:"";
 DesignerSkyData f;
 f.callsign="ACA870";f.airline="Air Canada";f.distance="À 4,2 km";
 f.originCode="YUL";f.destinationCode="CDG";f.origin="Montréal";f.destination="Paris";f.progress=46;
 f.aircraft="Airbus A330-300";f.speed="870 km/h";f.altitude="10 700 m";
 for(auto t:{0,1500,2900}){drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),t,true);if(output.length())canvas.save(output+"/flight-"+std::to_string(t)+".ppm");}
 f.progress=-1;drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),1500,true);if(output.length())canvas.save(output+"/unknown.ppm");
 f=DesignerSkyData{};f.message="Aucun avion détecté dans la zone";f.aircraft="Balayez pour revenir aux autres pages";
 drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),1500,false);if(output.length())canvas.save(output+"/manual-empty.ppm");
 // The empty-state footer must render its final words beyond the aircraft column.
 bool finalWords=false;
 for(int y=151;y<175;y++)for(int x=330;x<460;x++)if((canvas.pixels[y*640+x]>>11)>12)finalWords=true;
 assert(finalWords);
 // Accents use a distinct glyph, not an ASCII substitution or replacement box.
 canvas.fillRect(0,0,640,180,0);skyText(0,0,100,24,"é",4,1,65535);auto accented=canvas.pixels;
 canvas.fillRect(0,0,640,180,0);skyText(0,0,100,24,"e",4,1,65535);assert(accented!=canvas.pixels);
 // Duration strip ends at 3 seconds, including without another network frame.
 drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),1500,true);assert(canvas.pixels[178*640]==rgb(56,189,248));
 drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),3000,true);assert(canvas.pixels[178*640]!=rgb(56,189,248));
 drawDesignerSky(f,4,rgb(8,19,34),rgb(56,189,248),43200000,true,86400000);
 assert(canvas.pixels[178*640+319]==rgb(56,189,248));
 assert(canvas.pixels[178*640+321]!=rgb(56,189,248)); // 24-hour durations cannot overflow the width
}
