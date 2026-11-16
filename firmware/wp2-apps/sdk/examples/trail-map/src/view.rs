use crate::model::Model;
include!("font-data.rs");
const FONT:&[u8]=include_bytes!("font-data.bin");
pub const PAPER:u16=rgb(243,242,235);
const INK:u16=rgb(28,39,37);
const SECONDARY:u16=rgb(92,106,102);
const LIVE:u16=rgb(12,114,203);
const CACHED:u16=rgb(168,104,16);
pub const fn rgb(r:u16,g:u16,b:u16)->u16 {(r>>3)<<11|(g>>2)<<5|(b>>3)}
pub trait Surface {fn rect(&mut self,x:i32,y:i32,w:i32,h:i32,c:u16);fn offline(&mut self,_m:&Model,_clip:Bounds,_overlay:bool)->Option<[u8;40]>{None}}
static TRAIL_INFO:[core::sync::atomic::AtomicU32;10]=[const{core::sync::atomic::AtomicU32::new(0)};10];
#[derive(Clone,Copy,Debug,PartialEq)]
pub struct Bounds {pub x:i32,pub y:i32,pub r:i32,pub b:i32}
pub const MAP:Bounds=Bounds{x:8,y:94,r:457,b:350};
impl Bounds {
 fn intersection(self,o:Self)->Option<Self> {let b=Self{x:self.x.max(o.x),y:self.y.max(o.y),r:self.r.min(o.r),b:self.b.min(o.b)};(b.x<=b.r&&b.y<=b.b).then_some(b)}
 fn union(self,o:Self)->Self {Self{x:self.x.min(o.x),y:self.y.min(o.y),r:self.r.max(o.r),b:self.b.max(o.b)}}
 fn fill(self,s:&mut impl Surface,c:u16) {s.rect(self.x,self.y,self.r-self.x+1,self.b-self.y+1,c);}
}
fn blend(fg:u16,bg:u16,a:u8)->u16 {let a=a as u32;let z=3-a;let r=(((fg>>11) as u32*a+(bg>>11) as u32*z)/3) as u16;let g=((((fg>>5)&63) as u32*a+((bg>>5)&63) as u32*z)/3) as u16;let b=(((fg&31) as u32*a+(bg&31) as u32*z)/3) as u16;r<<11|g<<5|b}
fn glyph(c:u8,size:usize)->(u16,u8,u8,u8) {GLYPHS[size*95+(c.clamp(32,126)-32) as usize]}
pub fn width(text:&str,size:usize)->i32 {text.bytes().map(|c|glyph(c,size).3 as i32).sum()}
pub fn text(s:&mut impl Surface,mut x:i32,y:i32,t:&str,size:usize,color:u16) {
 for c in t.bytes() {let (off,w,h,advance)=glyph(c,size);let off=off as usize;let w=w as usize;
  let at=|i:usize|(FONT[off+i/4]>>(6-2*(i%4)))&3;
  for row in 0..h as usize {let mut col=0;while col<w {let a=at(row*w+col);let start=col;col+=1;while col<w&&at(row*w+col)==a {col+=1;}if a>0 {s.rect(x+start as i32,y+row as i32,(col-start) as i32,1,blend(color,PAPER,a));}}}
  x+=advance as i32;
 }
}
fn centre(s:&mut impl Surface,y:i32,t:&str,size:usize,c:u16) {text(s,233-width(t,size)/2,y,t,size,c);}
fn code(x:i32,y:i32,b:Bounds)->u8 {(if x<b.x {1}else if x>b.r {2}else{0})|(if y<b.y {4}else if y>b.b {8}else{0})}
// Clip once, then merge horizontal pixel runs. No offscreen Bresenham walks.
pub fn line(s:&mut impl Surface,mut x:i32,mut y:i32,mut ex:i32,mut ey:i32,c:u16,b:Bounds) {
 for _ in 0..8 {
  let a=code(x,y,b);let z=code(ex,ey,b);if a|z==0 {break;}if a&z!=0 {return;}
  let p=if a!=0 {a}else{z};let (nx,ny)=if p&8!=0 {(x as i64+(ex-x) as i64*(b.b-y) as i64/(ey-y) as i64,b.b as i64)}else if p&4!=0 {(x as i64+(ex-x) as i64*(b.y-y) as i64/(ey-y) as i64,b.y as i64)}else if p&2!=0 {(b.r as i64,y as i64+(ey-y) as i64*(b.r-x) as i64/(ex-x) as i64)}else{(b.x as i64,y as i64+(ey-y) as i64*(b.x-x) as i64/(ex-x) as i64)};
  if p==a {x=nx as i32;y=ny as i32;}else{ex=nx as i32;ey=ny as i32;}
 }
 if code(x,y,b)|code(ex,ey,b)!=0 {return;}
 let dx=(ex-x).abs();let sx=if x<ex {1}else{-1};let dy=-(ey-y).abs();let sy=if y<ey {1}else{-1};let mut err=dx+dy;
 let (mut start,mut prev,mut row)=(x,x,y);
 loop {
  if y!=row {s.rect(start.min(prev),row,(prev-start).abs()+2,2,c);start=x;row=y;}prev=x;
  if x==ex&&y==ey {s.rect(start.min(prev),row,(prev-start).abs()+2,2,c);break;}
  let e=2*err;if e>=dy {err+=dy;x+=sx;}if e<=dx {err+=dx;y+=sy;}
 }
}
fn disk(s:&mut impl Surface,x:i32,y:i32,r:i32,c:u16,clip:Bounds) {for dy in -r..=r {let mut dx=r;while dx*dx+dy*dy>r*r {dx-=1;}if let Some(b)=(Bounds{x:x-dx,y:y+dy,r:x+dx,b:y+dy}).intersection(clip) {b.fill(s,c);}}}
pub fn marker_bounds(m:&Model)->Option<Bounds> {let f=m.fix?;let (x,y)=m.point(f.x,f.y);(Bounds{x:x-12,y:y-12,r:x+12,b:y+12}).intersection(MAP)}
struct Clipped<'a,S:Surface> {surface:&'a mut S,clip:Bounds}
impl<S:Surface> Surface for Clipped<'_,S> {fn rect(&mut self,x:i32,y:i32,w:i32,h:i32,c:u16) {if let Some(b)=(Bounds{x,y,r:x+w-1,b:y+h-1}).intersection(self.clip) {self.surface.rect(b.x,b.y,b.r-b.x+1,b.b-b.y+1,c);}}}
pub fn map(surface:&mut impl Surface,m:&Model,now:u32,clip:Bounds) {
 let Some(clip)=clip.intersection(MAP) else{return;};let mut limited=Clipped{surface,clip};let s=&mut limited;clip.fill(s,crate::raster::PALETTE[0]);let covered=raster_bounds(m).is_some_and(|b|b.x<=clip.x&&b.y<=clip.y&&b.r>=clip.r&&b.b>=clip.b);if m.offline||!covered {crate::states::draw(s,m,clip);}
 if covered{raster_map(s,m,clip);}
 let native=if m.offline{s.surface.offline(m,clip,covered)}else{None};for(i,b)in native.unwrap_or([0;40]).chunks_exact(4).enumerate(){TRAIL_INFO[i].store(u32::from_le_bytes(b.try_into().unwrap()),core::sync::atomic::Ordering::Relaxed);}
 if native.is_none()&&!covered{raster_map(s,m,clip);}
 if native.is_none()&&raster_bounds(m).is_none()&&m.scale<1500 {centre(s,205,"Map detail loading",0,INK);centre(s,231,"Keep Companion open",0,SECONDARY);}
 for (px,py,_) in m.places.iter(){let(x,y)=m.point(px,py);if x>=MAP.x&&x<=MAP.r&&y>=MAP.y&&y<=MAP.b{disk(s,x,y,6,PAPER,clip);disk(s,x,y,4,crate::raster::PALETTE[13],clip);}}
 if let Some(f)=m.fix {let (x,y)=m.point(f.x,f.y);if x>=MAP.x&&x<=MAP.r&&y>=MAP.y&&y<=MAP.b {
  let color=if f.fresh(now) {LIVE}else{CACHED};disk(s,x,y,10,PAPER,clip);disk(s,x,y,7,color,clip);if !f.fresh(now) {disk(s,x,y,4,PAPER,clip);}
 }}
 scale_bar(s,m);
}
// A nearby cached image is a fast preview. Beyond 2x zoom use the vector
// overview, rather than decoding an entire tiny stamp or huge blurry image.
fn raster_bounds(m:&Model)->Option<Bounds> {
 let r=&m.raster;if !r.valid||m.scale>r.scale*2||r.scale>m.scale*2 {return None;}
 let (vx,vy)=m.viewport();let x=233+(r.x-vx-r.scale*225)/m.scale;let y=220+(r.y-vy-r.scale*126)/m.scale;
 let b=Bounds{x,y,r:x+450*r.scale/m.scale-1,b:y+257*r.scale/m.scale-1};b.intersection(MAP)?;Some(b)
}
fn raster_map(s:&mut impl Surface,m:&Model,clip:Bounds) {
 let Some(bounds)=raster_bounds(m) else{return;};let Some(clip)=bounds.intersection(clip) else{return;};let r=&m.raster;let native=r.scale==m.scale;
 // Hardware divisions, one y transform per row, and no work past the clip.
 // Merge adjacent literal pixels before drawing: dense packed artwork must
 // not turn a solid scanline into hundreds of separate framebuffer calls.
 let mut pixel=0i32;let mut last_row=-1;let (mut y,mut bottom)=(0,0);let mut pending:Option<(Bounds,u16)>=None;
 for (index,count) in r.runs() {let color=crate::raster::PALETTE[index as usize];let mut count=count as i32;
  while count>0 {let row=pixel/450;let col=pixel%450;let n=count.min(450-col);
   if row!=last_row {last_row=row;y=bounds.y+if native {row}else{row*r.scale/m.scale};bottom=if native {y}else{bounds.y+(row+1)*r.scale/m.scale-1};}
   if y>clip.b {if let Some((b,c))=pending {b.fill(s,c);}return;}
   if bottom>=clip.y&&bottom>=y {
    let x=bounds.x+if native {col}else{col*r.scale/m.scale};let right=if native {x+n-1}else{bounds.x+(col+n)*r.scale/m.scale-1};
    if let Some(b)=(Bounds{x,y,r:right,b:bottom}).intersection(clip) {
     if let Some((ref mut p,c))=pending {if c==color&&p.y==b.y&&p.b==b.b&&p.r+1==b.x {p.r=b.r;}else{p.fill(s,c);pending=Some((b,color));}}else{pending=Some((b,color));}
    }
   }
   pixel+=n;count-=n;
  }
 }
 if let Some((b,c))=pending {b.fill(s,c);}
}
// Web Mercator ground correction: sech(y/R), evaluated once per redraw in fixed point.
pub fn ground_factor(y:i32)->i64 {let t=(y as i64).abs()*1000/6_378_137;let t2=t*t;let mut term=1_000_000i64;let mut sum=term;for n in 1..=7 {term=term*t2/1_000_000/((2*n-1)*(2*n));sum+=term;}1_000_000_000/sum}
pub fn scale_measure(m:&Model)->(i32,u32,bool) {
 let factor=ground_factor(m.viewport().1);let max_feet=100i64*m.scale as i64*factor*3281/1_000_000;
 let miles=max_feet>=2640;let choices:&[u32]=if miles {&[2640,5280,10560,26400,52800,105600,264000,528000,1056000,2640000,5280000,10560000]}else{&[1,2,5,10,20,50,100,200,500,1000,2000]};
 let feet=*choices.iter().rev().find(|&&f|f as i64<=max_feet).unwrap_or(&1);
 let px=(feet as i64*1_000_000/(m.scale as i64*factor*3281)).clamp(1,110) as i32;(px,feet,miles)
}
fn scale_bar(s:&mut impl Surface,m:&Model) {let (px,feet,miles)=scale_measure(m);let mut label=Label::new();if miles {if feet==2640 {label.add("0.5");}else{label.number(feet/5280);}label.add(" mi");}else{label.number(feet);label.add(" ft");}let x=300;let y=316;s.rect(x-5,y-3,px.max(width(label.value(),0))+12,35,PAPER);text(s,x,y,label.value(),0,INK);s.rect(x,y+25,px,2,INK);s.rect(x,y+21,2,6,INK);s.rect(x+px-2,y+21,2,6,INK);}
struct Label {bytes:[u8;64],len:usize}
impl Label {
 fn new()->Self {Self{bytes:[0;64],len:0}}
 fn add(&mut self,s:&str) {for b in s.bytes() {if self.len<64 {self.bytes[self.len]=b;self.len+=1;}}}
 fn number(&mut self,mut n:u32) {let mut b=[0u8;10];let mut i=10;loop{i-=1;b[i]=b'0'+(n%10) as u8;n/=10;if n==0 {break;}}self.add(core::str::from_utf8(&b[i..]).unwrap_or("?"));}
 fn distance(&mut self,m:u32){let feet=(m as u64*3281/1000) as u32;if feet<5280{self.number(feet);self.add(" ft");}else{let tenths=(feet as u64*10/5280) as u32;self.number(tenths/10);self.add(".");self.number(tenths%10);self.add(" mi");}}
 fn value(&self)->&str {core::str::from_utf8(&self.bytes[..self.len]).unwrap_or("")}
}
fn satellite(s:&mut impl Surface,x:i32,y:i32,color:u16) {
 let b=Bounds{x:0,y:0,r:465,b:465};
 for (a,z,c,d) in [(0,8,8,0),(8,0,16,8),(16,8,8,16),(8,16,0,8),(-9,12,-2,5),(-9,12,-2,19),(-2,19,5,12),(11,-6,18,-13),(18,-13,25,-6),(25,-6,18,1)] {line(s,x+a/2,y+z/2,x+c/2,y+d/2,color,b);}
 for (a,z,c,d) in [(18,13,21,14),(21,14,23,17),(21,10,25,12),(25,12,27,16)] {line(s,x+a/2,y+z/2,x+c/2,y+d/2,color,b);}
}
fn satellites(s:&mut impl Surface,m:&Model,now:u32,y:i32){
 let mut sats=Label::new();
 if let Some(n)=m.fix.filter(|f|f.fresh(now)).and_then(|f|f.satellites) {sats.number(n as u32);}else{sats.add("--");}
 let w=width(sats.value(),0);let x=233-(w+29)/2;satellite(s,x+5,y+9,SECONDARY);text(s,x+29,y,sats.value(),0,SECONDARY);
}
pub fn status(s:&mut impl Surface,m:&Model,now:u32) {
 s.rect(38,354,390,112,PAPER);
 let p=m.progress;if p.visible(now){let title=if p.phase==3{"Map saved"}else if p.phase==4{"Download paused"}else if p.waiting(now){"Waiting for phone"}else if p.phase==2{"Saving map"}else{"Downloading map"};centre(s,360,title,0,INK);s.rect(109,387,248,6,crate::raster::PALETTE[2]);s.rect(109,387,(248*p.percent()/100) as i32,6,LIVE);let mut d=Label::new();d.number(p.percent());d.add("%   ");for(i,n)in [p.done,p.total].into_iter().enumerate(){if i==1{d.add(" / ");}if p.total>=1_000_000{d.number(n/1_000_000);d.add(".");d.number(n%1_000_000/100_000);}else{d.number(n/1000);}}d.add(if p.total>=1_000_000{" MB"}else{" KB"});centre(s,407,d.value(),0,SECONDARY);satellites(s,m,now,433);return;}
 satellites(s,m,now,360);
 let mut info=Label::new();let color=if let Some(f)=m.fix {if f.fresh(now) {if f.watch {info.add("Watch GPS");}else{info.add("Phone location  ~");info.number(((f.accuracy as u32)*328+50)/100);info.add(" ft");}LIVE}else{info.add("Last known");let age=f.age(now);if age<u32::MAX/2 {info.add("  ");if age<60 {info.number(age);info.add("s ago");}else if age<3600 {info.number(age/60);info.add("m ago");}else{info.number(age/3600);info.add("h ago");}}CACHED}}else{info.add(if m.gps_on{"Finding watch GPS"}else{"Waiting for location"});SECONDARY};
 centre(s,390,info.value(),0,color);
 let mut trail=[0;40];for(i,w)in TRAIL_INFO.iter().enumerate(){trail[i*4..i*4+4].copy_from_slice(&w.load(core::sync::atomic::Ordering::Relaxed).to_le_bytes());}let length=crate::model::u32le(&trail,32);
 let near=m.places.iter().filter(|(x,y,_)|{let(x,y)=m.point(*x,*y);(x-233).abs()<24&&(y-220).abs()<24}).min_by_key(|(x,y,_)|{let(x,y)=m.point(*x,*y);(x-233).abs()+(y-220).abs()});
 if let Some((x,y,name))=near{centre(s,414,name,0,INK);let mut d=Label::new();d.add("Saved place");if let Some(f)=m.fix{let dx=(x-f.x) as i64;let dy=(y-f.y) as i64;let meters=(((dx*dx+dy*dy) as u64).isqrt() as i64*ground_factor(f.y)/1000) as u32;d.add(" / ");d.distance(meters);}centre(s,436,d.value(),0,SECONDARY);}else if m.offline&&length>0 {let mut n=trail[..32].iter().position(|b|*b==0).unwrap_or(32);while n>0&&width(core::str::from_utf8(&trail[..n]).unwrap_or(""),0)>210{n-=1;}let name=if n==0{"Trail section"}else{core::str::from_utf8(&trail[..n]).unwrap_or("Trail section")};centre(s,414,name,0,INK);let mut detail=Label::new();detail.distance(length);let distance=crate::model::u32le(&trail,36);if distance!=u32::MAX{detail.add(" / ");detail.distance(distance);detail.add(" away");}centre(s,436,detail.value(),0,SECONDARY);}
}
pub fn full(s:&mut impl Surface,m:&Model,now:u32) {
 s.rect(0,0,466,466,PAPER);centre(s,27,"Trail Map",2,INK);
 if m.scale>=1500 {centre(s,61,"United States / CA detail",0,SECONDARY);}else if m.len>0 {let label=&m.data[16..48];let mut n=label.iter().position(|x|*x==0).unwrap_or(32);while width(core::str::from_utf8(&label[..n]).unwrap_or("Saved area"),0)>190 {n-=1;}centre(s,61,core::str::from_utf8(&label[..n]).unwrap_or("Saved area"),0,SECONDARY);}else{centre(s,61,"United States offline",0,SECONDARY);}
 map(s,m,now,MAP);status(s,m,now);
}
pub fn position_update(s:&mut impl Surface,m:&Model,now:u32,old:Option<Bounds>) {
 let b=match (old,marker_bounds(m)) {(Some(a),Some(b))=>Some(a.union(b)),(a,b)=>a.or(b)};if let Some(b)=b {map(s,m,now,b);}status(s,m,now);
}
#[cfg(test)] mod tests {
 use super::*;
 struct Fb {px:Vec<u16>,calls:usize}
 impl Surface for Fb {fn rect(&mut self,x:i32,y:i32,w:i32,h:i32,c:u16) {self.calls+=1;for yy in y.max(0)..(y+h).min(466) {for xx in x.max(0)..(x+w).min(466) {self.px[(yy*466+xx) as usize]=c;}}}}
 #[test] fn raster_preview_has_no_holes_at_fractional_zoom_and_clips_work() {
  let mut m=Model::new();m.scale=8;let (x,y)=m.viewport();m.raster.x=x;m.raster.y=y;m.raster.scale=8;m.raster.valid=true;
  let mut bytes=vec![0];for row in 0..257 {let color=if row%2==0 {5}else{7};bytes.extend([color<<4|15,255,color<<4|15,163]);}
  m.raster.fixture(&bytes);assert!(crate::raster::valid(&bytes));
  for scale in [4,6,8,12,16] {
   m.scale=scale;let b=raster_bounds(&m).unwrap();let clipped=b.intersection(MAP).unwrap();let mut f=Fb{px:vec![0;466*466],calls:0};raster_map(&mut f,&m,MAP);
   for yy in clipped.y..=clipped.b {let row=((yy-b.y+1)*scale+7)/8-1;let expected=crate::raster::PALETTE[if row%2==0 {5}else{7}];for xx in clipped.x..=clipped.r {assert_eq!(f.px[(yy*466+xx) as usize],expected,"scale {scale}, row {yy}");}}
  }
  m.scale=8;let mut f=Fb{px:vec![0;466*466],calls:0};map(&mut f,&m,0,Bounds{x:200,y:180,r:229,b:199});assert!(f.calls<=22,"partial raster should not redraw state polygons: {}",f.calls);
  m.scale=32;assert!(raster_bounds(&m).is_none());
 }
 #[test] fn metadata_does_not_draw_unconnected_wire_segments() {
  let mut a=Model::new();a.data[..4].copy_from_slice(b"TM02");a.data[14..16].copy_from_slice(&8u16.to_le_bytes());a.len=48;a.scale=8;
  let mut f=Fb{px:vec![0;466*466],calls:0};map(&mut f,&a,0,MAP);
  // Header metadata may be received long before artwork. Its segment count
  // must have no influence on the picture; no line-only fallback exists.
  a.data[12..14].copy_from_slice(&400u16.to_le_bytes());let mut g=Fb{px:vec![0;466*466],calls:0};map(&mut g,&a,0,MAP);assert_eq!(f.px,g.px);
 }
 #[test] fn clipped_lines_are_bounded_and_batched() {let mut f=Fb{px:vec![0;466*466],calls:0};line(&mut f,-100_000,220,100_000,220,INK,MAP);assert_eq!(f.calls,1);assert!(f.px[220*466+233]!=0);}
 #[test] fn partial_position_redraw_matches_full_frame() {
  let mut m=Model::new();m.data[..4].copy_from_slice(b"TM01");m.data[14]=8;m.restore(48);
  m.accept(b"TM\x01\x04\0\0\0\0\0\0\0\0\x0a\0",0);let mut f=Fb{px:vec![0;466*466],calls:0};full(&mut f,&m,0);let old=marker_bounds(&m);
  m.fix.as_mut().unwrap().x=80;position_update(&mut f,&m,0,old);let mut other=Fb{px:vec![0;466*466],calls:0};full(&mut other,&m,0);assert_eq!(f.px,other.px);
 }
}
#[cfg(test)] mod scale_tests {
 use super::*;
 #[test] fn scale_is_ground_distance_and_tracks_zoom() {assert_eq!(ground_factor(0),1000);assert!((790..810).contains(&ground_factor(4_400_000)));let mut m=Model::new();m.scale=8;m.pan_y=6_500_000;let (p,f,_)=scale_measure(&m);assert!(p>0&&p<=110);assert_eq!(f,2000);m.scale=1;assert_eq!(scale_measure(&m).1,200);}
}
