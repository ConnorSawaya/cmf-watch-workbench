//! Bounded watch-native trail-map decoder and renderer. All geometry is from
//! the installed, checksummed pack; no lines are invented between parts.
use crate::pkg::crc32;
use miniz_oxide::inflate::{core::{DecompressorOxide,decompress},TINFLStatus};
pub const MAX:u32=9_200_000;pub const PAGE:usize=16384;
pub trait Read {fn read(&mut self,at:u32,out:&mut [u8])->bool;}
pub fn u32le(b:&[u8],p:usize)->u32{u32::from_le_bytes(b[p..p+4].try_into().unwrap())}
fn u16le(b:&[u8],p:usize)->u16{u16::from_le_bytes(b[p..p+2].try_into().unwrap())}
#[derive(Clone,Copy)]pub struct Header {pub size:u32,pub minx:i32,pub miny:i32,pub w:u32,pub h:u32,pub names:u32,pub n:u32,pub data:u32,pub trails:u32,pub grid:i32}
impl Header {
 pub fn parse(b:&[u8])->Option<Self> {
  if b.len()!=64||&b[..8]!=b"WP2MAP1\0"||u32le(b,8)!=1||crc32(0,&b[..60])!=u32le(b,60)||u32le(b,48)!=8192||u32le(b,52)!=1{return None;}
  let h=Self{size:u32le(b,12),minx:u32le(b,16) as i32,miny:u32le(b,20) as i32,w:u16le(b,24) as u32,h:u16le(b,26) as u32,names:u32le(b,28),n:u32le(b,32),data:u32le(b,36),trails:u32le(b,40),grid:u32le(b,44) as i32};
  if !(64..=MAX).contains(&h.size)||h.w==0||h.h==0||h.w>512||h.h>512||h.n>65535||h.names!=64+h.w*h.h*8||h.data!=h.names+h.n*32||h.data>h.size||![4,8,16].contains(&h.grid)||h.minx.unsigned_abs()>4096||h.miny.unsigned_abs()>4096{return None;}Some(h)
 }
}
pub struct Scratch {pub packed:[u8;16512],pub raw:[u8;PAGE],pub points:[[i16;2];2048],pub cuts:[i16;2048],pub ends:[u16;2048],pub inflate:DecompressorOxide}
struct Cursor<'a>{b:&'a[u8],p:usize}
impl Cursor<'_>{
 fn byte(&mut self)->Option<u8>{let n=*self.b.get(self.p)?;self.p+=1;Some(n)}
 fn uint(&mut self)->Option<u32>{let(mut n,mut shift)=(0u32,0);loop{let v=self.byte()?;if shift>=28&&v>15{return None;}n|=((v&127) as u32)<<shift;if v<128{return Some(n);}shift+=7;if shift>28{return None;}}}
 fn int(&mut self)->Option<i32>{let n=self.uint()?;Some(if n&1==0{(n/2) as i32}else{-((n/2) as i32)-1})}
}
#[derive(Clone,Copy)]pub struct Camera {pub x:i32,pub y:i32,pub scale:i32,pub clip:[i32;4],pub fix:Option<(i32,i32)>,pub overlay:bool}
#[derive(Clone,Copy)]pub struct Info {pub name:[u8;32],pub length:u32,pub distance:u32,pub features:u32}
impl Info {pub fn empty()->Self{Self{name:[0;32],length:0,distance:u32::MAX,features:0}}}
fn line(draw:&mut impl FnMut(i16,i16,u16,u16,u16),mut x:i32,mut y:i32,mut ex:i32,mut ey:i32,color:u16,b:[i32;4]) {
 let code=|x,y|(if x<b[0]{1}else if x>b[2]{2}else{0})|(if y<b[1]{4}else if y>b[3]{8}else{0});
 for _ in 0..8{let a=code(x,y);let z=code(ex,ey);if a|z==0{break;}if a&z!=0{return;}let p=if a!=0{a}else{z};let(nx,ny)=if p&8!=0{(x as i64+(ex-x) as i64*(b[3]-y) as i64/(ey-y) as i64,b[3] as i64)}else if p&4!=0{(x as i64+(ex-x) as i64*(b[1]-y) as i64/(ey-y) as i64,b[1] as i64)}else if p&2!=0{(b[2] as i64,y as i64+(ey-y) as i64*(b[2]-x) as i64/(ex-x) as i64)}else{(b[0] as i64,y as i64+(ey-y) as i64*(b[0]-x) as i64/(ex-x) as i64)};if p==a{x=nx as i32;y=ny as i32;}else{ex=nx as i32;ey=ny as i32;}}
 if code(x,y)|code(ex,ey)!=0{return;}
 let dx=(ex-x).abs();let sx=if x<ex{1}else{-1};let dy=-(ey-y).abs();let sy=if y<ey{1}else{-1};let mut err=dx+dy;let(mut start,mut prev,mut row)=(x,x,y);
 loop{if y!=row{draw(start.min(prev) as i16,row as i16,((prev-start).abs()+1) as u16,1,color);start=x;row=y;}prev=x;if x==ex&&y==ey{draw(start.min(prev) as i16,row as i16,((prev-start).abs()+1) as u16,1,color);break;}let e=2*err;if e>=dy{err+=dy;x+=sx;}if e<=dx{err+=dx;y+=sy;}}
}
fn sqrt(n:u64)->u32{let(mut lo,mut hi)=(0u64,1u64<<32);while lo+1<hi{let m=(lo+hi)/2;if m*m<=n{lo=m}else{hi=m}}lo as u32}
fn ground(y:i32)->i64{let t=(y as i64).abs()*1000/6_378_137;let t2=t*t;let mut term=1_000_000i64;let mut sum=term;for n in 1..=7{term=term*t2/1_000_000/((2*n-1)*(2*n));sum+=term;}1_000_000_000/sum}
pub fn render(r:&mut impl Read,h:Header,s:&mut Scratch,c:Camera,mut draw:impl FnMut(i16,i16,u16,u16,u16))->Result<Info,i32>{
 if !(1..=60000).contains(&c.scale)||c.x.unsigned_abs()>21_000_000||c.y.unsigned_abs()>21_000_000||c.clip[0]<8||c.clip[1]<94||c.clip[2]>457||c.clip[3]>350||c.clip[0]>c.clip[2]||c.clip[1]>c.clip[3]{return Err(-22);}
 let mut info=Info::empty();if c.scale>128{return Ok(info);}
 let minx=((c.x-225*c.scale).div_euclid(8192)-h.minx).clamp(0,h.w as i32);let maxx=((c.x+225*c.scale).div_euclid(8192)-h.minx).clamp(-1,h.w as i32-1);
 let miny=((c.y-126*c.scale).div_euclid(8192)-h.miny).clamp(0,h.h as i32);let maxy=((c.y+131*c.scale).div_euclid(8192)-h.miny).clamp(-1,h.h as i32-1);
 if (maxx-minx+1).max(0)*(maxy-miny+1).max(0)>64{return Ok(info);}
 let mut best=24i64*24;let mut best_name=0u16;
 for cy in miny..=maxy{for cx in minx..=maxx{
  let mut entry=[0;8];if !r.read(64+((cy as u32*h.w+cx as u32)*8),&mut entry){return Err(-5);}
  let(mut at,len)=(u32le(&entry,0),u32le(&entry,4));if len==0{continue;}if at<h.data||at>h.size||len>h.size-at{return Err(-5);}let end=at+len;
  while at<end{
   let mut header=[0;8];if end-at<8||!r.read(at,&mut header){return Err(-5);}let(packed,raw)=(u16le(&header,0) as usize,u16le(&header,2) as usize);let crc=u32le(&header,4);at+=8;
   if packed==0||packed>s.packed.len()||raw>PAGE||packed as u32>end-at||!r.read(at,&mut s.packed[..packed]){return Err(-5);}at+=packed as u32;
   s.inflate.init();let(status,used,n)=decompress(&mut s.inflate,&s.packed[..packed],&mut s.raw[..raw],0,5);
   if status!=TINFLStatus::Done||used!=packed||n!=raw||crc32(0,&s.raw[..raw])!=crc{return Err(-5);}
   let mut offset=0;
   while offset<raw{
    if raw-offset<2{return Err(-5);}let size=u16le(&s.raw,offset) as usize;offset+=2;if size<10||size>raw-offset{return Err(-5);}let b=&s.raw[offset..offset+size];offset+=size;
    let(kind,flags,name,length,closed)=(b[0],b[1],u16le(b,2),u32le(b,4),b[8]!=0);if kind>4||name as u32>=h.n{return Err(-5);}
    if c.overlay&&kind!=0{continue;}
    let mut q=Cursor{b,p:9};let parts=q.uint().ok_or(-5)?;if parts>2048{return Err(-5);}let mut total=0usize;let mut rings=0;
    for _ in 0..parts{
     let count=q.uint().ok_or(-5)? as usize;if count>2048-total{return Err(-5);}let start=total;let(mut px,mut py)=(0i32,0i32);
     for _ in 0..count{
      px=px.checked_add(q.int().ok_or(-5)?).ok_or(-5)?;py=py.checked_add(q.int().ok_or(-5)?).ok_or(-5)?;
      if !(0..=8192/h.grid).contains(&px)||!(0..=8192/h.grid).contains(&py){return Err(-5);}let wx=(cx+h.minx)*8192+px*h.grid;let wy=(cy+h.miny)*8192+py*h.grid;
      let x=233+(wx-c.x)/c.scale;let y=220+(wy-c.y)/c.scale;s.points[total]=[x as i16,y as i16];
      if kind==0&&c.scale<=64{
       let d=(x-233) as i64*(x-233) as i64+(y-220) as i64*(y-220) as i64;
       if d<best{best=d;best_name=name;info.length=length;info.distance=c.fix.map_or(u32::MAX,|(fx,fy)|{let dx=(wx-fx) as i64;let dy=(wy-fy) as i64;(sqrt((dx*dx+dy*dy) as u64) as i64*ground(fy)/1000) as u32});}
      }
      total+=1;
     }
     if !closed&&count>=2{let color=if kind==0{if flags&1!=0{0x8c91}else{0x3409}}else{0x335b};for i in start+1..total{let a=s.points[i-1];let z=s.points[i];line(&mut draw,a[0] as i32,a[1] as i32,z[0] as i32,z[1] as i32,color,c.clip);}}
     if closed&&count>0{s.ends[rings]=total as u16;rings+=1;}
    }
    if q.p!=b.len(){return Err(-5);}
    if closed{
     let color=if kind==4{0x9e3b}else{0xb675};
     for yy in c.clip[1]..=c.clip[3]{let(mut cuts,mut start,mut ring)=(0usize,0usize,0usize);
      for i in 0..total{let a=s.points[i];let is_end=i+1==s.ends[ring] as usize;let ay=a[1] as i32;let j=if is_end{start}else{i+1};if j>=total{return Err(-5);}let z=s.points[j];let by=z[1] as i32;
       if (ay<=yy&&by>yy)||(by<=yy&&ay>yy){if cuts==s.cuts.len(){return Err(-5);}s.cuts[cuts]=(a[0] as i32+(z[0] as i32-a[0] as i32)*(yy-ay)/(by-ay)) as i16;cuts+=1;}if is_end{start=i+1;ring+=1;}
      }
      s.cuts[..cuts].sort_unstable();for pair in s.cuts[..cuts].chunks_exact(2){let left=(pair[0] as i32).max(c.clip[0]);let right=(pair[1] as i32).min(c.clip[2]);if left<=right{draw(left as i16,yy as i16,(right-left+1) as u16,1,color);}}
     }
    }
    info.features=info.features.saturating_add(1);
   }
  }
 }}
 if best<24*24&&best_name!=0{if !r.read(h.names+best_name as u32*32,&mut info.name){return Err(-5);}}
 Ok(info)
}
