//! Bounded watch-native trail-map decoder and renderer. All geometry is from
//! the installed, checksummed pack; no lines are invented between parts.
use crate::pkg::crc32;
use miniz_oxide::inflate::{core::{DecompressorOxide,decompress},TINFLStatus};
pub const MAX:u32=9_200_000;pub const PAGE:usize=16384;
pub trait Read {fn read(&mut self,at:u32,out:&mut [u8])->bool;}
pub fn u32le(b:&[u8],p:usize)->u32{u32::from_le_bytes(b[p..p+4].try_into().unwrap())}
fn u16le(b:&[u8],p:usize)->u16{u16::from_le_bytes(b[p..p+2].try_into().unwrap())}
#[derive(Clone,Copy)]pub struct Header {pub size:u32,pub minx:i32,pub miny:i32,pub w:u32,pub h:u32,pub names:u32,pub n:u32,pub data:u32,pub trails:u32,pub grid:i32,pub codec:u32}
impl Header {
 pub fn parse(b:&[u8])->Option<Self> {
  if b.len()!=64||&b[..8]!=b"WP2MAP1\0"||u32le(b,8)!=1||crc32(0,&b[..60])!=u32le(b,60)||u32le(b,48)!=8192||![1,2].contains(&u32le(b,52)){return None;}
  let h=Self{size:u32le(b,12),minx:u32le(b,16) as i32,miny:u32le(b,20) as i32,w:u16le(b,24) as u32,h:u16le(b,26) as u32,names:u32le(b,28),n:u32le(b,32),data:u32le(b,36),trails:u32le(b,40),grid:u32le(b,44) as i32,codec:u32le(b,52)};
  if !(64..=MAX).contains(&h.size)||h.w==0||h.h==0||h.w>512||h.h>512||h.n>65535||h.names!=64+h.w*h.h*8||h.data!=h.names+h.n*32||h.data>h.size||![4,8,16].contains(&h.grid)||h.minx.unsigned_abs()>4096||h.miny.unsigned_abs()>4096{return None;}Some(h)
 }
}
#[derive(Clone,Copy)]pub struct Label{pub x:i16,pub y:i16,pub name:[u8;32]}
pub struct Scratch {pub packed:[u8;16512],pub raw:[u8;PAGE],pub points:[[i16;2];2048],pub cuts:[i16;2048],pub ends:[u16;2048],pub inflate:DecompressorOxide,pages:[[u8;PAGE];32],page_at:[u32;32],page_crc:[u32;32],page_len:[u16;32],page_age:[u32;32],indexed:[bool;32],boxes:[[[u16;4];1366];32],clock:u32,pub labels:[Label;12],pub label_count:usize,names:[[u8;32];16],name_id:[u16;16],name_next:usize}
impl Scratch {
 fn name(&mut self,r:&mut impl Read,h:Header,id:u16)->Result<[u8;32],i32>{
  if let Some(i)=self.name_id.iter().position(|&n|n==id){return Ok(self.names[i]);}
  let i=self.name_next%16;self.name_next=self.name_next.wrapping_add(1);let mut text=[0;32];if !r.read(h.names+id as u32*32,&mut text){return Err(-5);}self.names[i]=text;self.name_id[i]=id;Ok(text)
 }
 pub fn clear_pages(&mut self){self.page_len.fill(0);self.name_id.fill(0);self.label_count=0;}}
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
 s.label_count=0;let mut info=Info::empty();if c.scale>128{return Ok(info);}
 let left=c.x+(c.clip[0]-233)*c.scale;let right=c.x+(c.clip[2]-233)*c.scale;let top=c.y+(c.clip[1]-220)*c.scale;let bottom=c.y+(c.clip[3]-220)*c.scale;
 let minx=((left).div_euclid(8192)-h.minx).clamp(0,h.w as i32);let maxx=((right).div_euclid(8192)-h.minx).clamp(-1,h.w as i32-1);
 let miny=((top).div_euclid(8192)-h.miny).clamp(0,h.h as i32);let maxy=((bottom).div_euclid(8192)-h.miny).clamp(-1,h.h as i32-1);
 if (maxx-minx+1).max(0)*(maxy-miny+1).max(0)>64{return Ok(info);}
 let mut best=24i64*24;let mut best_name=0u16;
 for cy in miny..=maxy{for cx in minx..=maxx{
  let mut entry=[0;8];if !r.read(64+((cy as u32*h.w+cx as u32)*8),&mut entry){return Err(-5);}
  let(mut at,len)=(u32le(&entry,0),u32le(&entry,4));if len==0{continue;}if at<h.data||at>h.size||len>h.size-at{return Err(-5);}let end=at+len;
  while at<end{
   let header_len=if h.codec==2{20}else{8};let mut header=[0;20];if end-at<header_len as u32||!r.read(at,&mut header[..header_len]){return Err(-5);}
   let(packed,raw)=(u16le(&header,0) as usize,u16le(&header,2) as usize);let crc=u32le(&header,4);at+=header_len as u32;
   if packed==0||packed>s.packed.len()||raw==0||raw>PAGE||packed as u32>end-at{return Err(-5);}let body_at=at;at+=packed as u32;
   if h.codec==2 {
    let origin_x=(cx+h.minx)*8192;let origin_y=(cy+h.miny)*8192;
    let bounds=[u16le(&header,8) as i32,u16le(&header,10) as i32,u16le(&header,12) as i32,u16le(&header,14) as i32];
    if bounds[0]>bounds[2]||bounds[1]>bounds[3]||bounds[2]>8192/h.grid||bounds[3]>8192/h.grid{return Err(-5);}
    let lo=u16le(&header,16) as i32;let hi=u16le(&header,18) as i32;if lo<1||hi<lo||hi>60000{return Err(-5);}
    if c.scale<lo||c.scale>hi||origin_x+bounds[2]*h.grid<left||origin_x+bounds[0]*h.grid>right||origin_y+bounds[3]*h.grid<top||origin_y+bounds[1]*h.grid>bottom{continue;}
   }
   s.clock=s.clock.wrapping_add(1);
   let cache_i;if let Some(i)=(0..32).find(|&i|s.page_len[i] as usize==raw&&s.page_at[i]==body_at&&s.page_crc[i]==crc){s.raw[..raw].copy_from_slice(&s.pages[i][..raw]);s.page_age[i]=s.clock;cache_i=i;}
   else {
    if !r.read(body_at,&mut s.packed[..packed]){return Err(-5);}
    s.inflate.init();let(status,used,n)=decompress(&mut s.inflate,&s.packed[..packed],&mut s.raw[..raw],0,5);
    if status!=TINFLStatus::Done||used!=packed||n!=raw||crc32(0,&s.raw[..raw])!=crc{return Err(-5);}
    let i=(0..32).find(|&i|s.page_len[i]==0).unwrap_or_else(||(0..32).max_by_key(|&i|s.clock.wrapping_sub(s.page_age[i])).unwrap());
    s.pages[i][..raw].copy_from_slice(&s.raw[..raw]);s.page_at[i]=body_at;s.page_crc[i]=crc;s.page_len[i]=raw as u16;s.page_age[i]=s.clock;s.indexed[i]=false;cache_i=i;
   }
   let mut offset=0;let mut record_index=0;
   while offset<raw{
    if raw-offset<2{return Err(-5);}let size=u16le(&s.raw,offset) as usize;offset+=2;if size<10||size>raw-offset{return Err(-5);}let b=&s.raw[offset..offset+size];offset+=size;
    let(kind,flags,name,length,closed)=(b[0],b[1],u16le(b,2),u32le(b,4),b[8]!=0);if kind>4||b[8]>1||name as u32>=h.n{return Err(-5);}
    let index=record_index;record_index+=1;
    if c.overlay&&kind!=0{continue;}
    let origin_x=(cx+h.minx)*8192;let origin_y=(cy+h.miny)*8192;
    if s.indexed[cache_i]{let b=s.boxes[cache_i][index];if origin_x+b[2] as i32*h.grid<left||origin_x+b[0] as i32*h.grid>right||origin_y+b[3] as i32*h.grid<top||origin_y+b[1] as i32*h.grid>bottom{continue;}}
    let mut bounds=[u16::MAX,u16::MAX,0,0];
    let mut q=Cursor{b,p:9};let parts=q.uint().ok_or(-5)?;if parts>2048{return Err(-5);}let mut total=0usize;let mut encoded=0usize;let mut rings=0;let mut label_point=None;let mut label_distance=i64::MAX;
    for _ in 0..parts{
     let count=q.uint().ok_or(-5)? as usize;encoded=encoded.checked_add(count).ok_or(-5)?;if encoded>2048{return Err(-5);}let start=total;let(mut px,mut py)=(0i32,0i32);
     for _ in 0..count{
      px=px.checked_add(q.int().ok_or(-5)?).ok_or(-5)?;py=py.checked_add(q.int().ok_or(-5)?).ok_or(-5)?;
      if !(0..=8192/h.grid).contains(&px)||!(0..=8192/h.grid).contains(&py){return Err(-5);}bounds[0]=bounds[0].min(px as u16);bounds[1]=bounds[1].min(py as u16);bounds[2]=bounds[2].max(px as u16);bounds[3]=bounds[3].max(py as u16);let wx=(cx+h.minx)*8192+px*h.grid;let wy=(cy+h.miny)*8192+py*h.grid;
      let x=233+(wx-c.x)/c.scale;let y=220+(wy-c.y)/c.scale;let point=[x as i16,y as i16];
      if kind<=1&&c.scale<=64{
       let d=(x-233) as i64*(x-233) as i64+(y-220) as i64*(y-220) as i64;
       if d<best{best=d;best_name=name;info.length=length;info.distance=c.fix.map_or(u32::MAX,|(fx,fy)|{let dx=(wx-fx) as i64;let dy=(wy-fy) as i64;(sqrt((dx*dx+dy*dy) as u64) as i64*ground(fy)/1000) as u32});}
      }
      if total==start||s.points[total-1]!=point{s.points[total]=point;total+=1;}
     }
     if !closed&&total-start>=2{let color=if kind==0{if flags&1!=0{0x8c91}else{0x3409}}else if kind==1{0x8c91}else{0x335b};for i in start+1..total{let a=s.points[i-1];let z=s.points[i];
      if kind<=1&&name!=0&&c.scale<=64 {let ax=a[0] as i64-233;let ay=a[1] as i64-220;let dx=z[0] as i64-a[0] as i64;let dy=z[1] as i64-a[1] as i64;let square=dx*dx+dy*dy;
       if square>0 {let t=(-ax*dx-ay*dy).clamp(0,square);let px=ax+dx*t/square;let py=ay+dy*t/square;let d=px*px+py*py;
        if d<label_distance{label_distance=d;label_point=Some([(px+233) as i16,(py+220) as i16]);}
        if d<best {best=d;best_name=name;info.length=length;info.distance=c.fix.map_or(u32::MAX,|(fx,fy)|{let wx=c.x as i64+px*c.scale as i64;let wy=c.y as i64+py*c.scale as i64;let dx=wx-fx as i64;let dy=wy-fy as i64;(sqrt((dx*dx+dy*dy) as u64) as i64*ground(fy)/1000) as u32});}
       }
      }
      line(&mut draw,a[0] as i32,a[1] as i32,z[0] as i32,z[1] as i32,color,c.clip);
     }}
     if closed&&total>start{s.ends[rings]=total as u16;rings+=1;}
    }
    if q.p!=b.len(){return Err(-5);}s.boxes[cache_i][index]=bounds;
    if closed{
     let color=if kind==4{0x9e3b}else{0xb675};
     let first=s.points[..total].iter().map(|p|p[1] as i32).min().unwrap_or(0).max(c.clip[1]);let last=s.points[..total].iter().map(|p|p[1] as i32).max().unwrap_or(-1).min(c.clip[3]);
     for yy in first..=last{let(mut cuts,mut start,mut ring)=(0usize,0usize,0usize);
      for i in 0..total{let a=s.points[i];let is_end=i+1==s.ends[ring] as usize;let ay=a[1] as i32;let j=if is_end{start}else{i+1};if j>=total{return Err(-5);}let z=s.points[j];let by=z[1] as i32;
       if (ay<=yy&&by>yy)||(by<=yy&&ay>yy){if cuts==s.cuts.len(){return Err(-5);}s.cuts[cuts]=(a[0] as i32+(z[0] as i32-a[0] as i32)*(yy-ay)/(by-ay)) as i16;cuts+=1;}if is_end{start=i+1;ring+=1;}
      }
      s.cuts[..cuts].sort_unstable();for pair in s.cuts[..cuts].chunks_exact(2){let left=(pair[0] as i32).max(c.clip[0]);let right=(pair[1] as i32).min(c.clip[2]);if left<=right{draw(left as i16,yy as i16,(right-left+1) as u16,1,color);}}
     }
    }
    if !closed&&kind<=1&&name>0&&c.scale<=32&&total>0&&s.label_count<12 {
     let point=label_point.unwrap_or(s.points[total/2]);let text=s.name(r,h,name)?;let n=text.iter().position(|&b|b==0).unwrap_or(32).min(24);let width=(n*8+12) as i32;
     let x=point[0] as i32;let y=point[1] as i32;
     if x-width/2>c.clip[0]&&x+width/2<c.clip[2]&&y-12>c.clip[1]&&y+12<c.clip[3]&&!(x>285&&y>305) {
      let collision=s.labels[..s.label_count].iter().any(|l|{let w=(l.name.iter().position(|&b|b==0).unwrap_or(32).min(24)*8+12) as i32;l.name==text||((l.x as i32-x).abs()<(w+width)/2&&(l.y as i32-y).abs()<26)});
      if !collision{s.labels[s.label_count]=Label{x:point[0],y:point[1],name:text};s.label_count+=1;}
     }
    }
    info.features=info.features.saturating_add(1);
   }
   if !c.overlay{s.indexed[cache_i]=true;}
  }
 }}
 if best<24*24&&best_name!=0{info.name=s.name(r,h,best_name)?;}
 Ok(info)
}

#[cfg(test)]
mod tests {
 use super::*;
 struct File {bytes:Vec<u8>,body_reads:usize,body_at:usize}
 impl Read for File {fn read(&mut self,at:u32,out:&mut[u8])->bool{let at=at as usize;let Some(data)=self.bytes.get(at..at+out.len())else{return false;};out.copy_from_slice(data);if at==self.body_at{self.body_reads+=1;}true}}
 fn scratch()->Box<Scratch>{let mut p=Box::<Scratch>::new_uninit();unsafe{core::ptr::write_bytes(p.as_mut_ptr(),0,1);p.assume_init()}}
 fn fixture(codec:u32)->(Header,File){
  // A real decoder input: one named road, two vertices, one stored zlib block.
  let raw=vec![16,0,1,0,1,0,120,0,0,0,0,1,2,0,0,200,1,0];
  // Record is 16 bytes, excluding its two-byte length prefix.
  assert_eq!(raw.len(),18);
  let n=raw.len() as u16;let mut packed=vec![0x78,0x01,0x01];packed.extend(n.to_le_bytes());packed.extend((!n).to_le_bytes());packed.extend(&raw);
  let(mut a,mut b)=(1u32,0u32);for &v in &raw{a=(a+v as u32)%65521;b=(b+a)%65521;}packed.extend(((b<<16)|a).to_be_bytes());
  let data=136usize;let mut bytes=vec![0;data];bytes[104..113].copy_from_slice(b"Test Road");
  bytes.extend((packed.len() as u16).to_le_bytes());bytes.extend(n.to_le_bytes());bytes.extend(crc32(0,&raw).to_le_bytes());
  if codec==2 {for v in [0u16,0,100,0,1,32]{bytes.extend(v.to_le_bytes());}}
  let body_at=bytes.len();bytes.extend(packed);bytes[64..68].copy_from_slice(&(data as u32).to_le_bytes());let span=(bytes.len()-data) as u32;bytes[68..72].copy_from_slice(&span.to_le_bytes());
  let h=Header{size:bytes.len() as u32,minx:0,miny:0,w:1,h:1,names:72,n:2,data:data as u32,trails:0,grid:4,codec};
  (h,File{bytes,body_reads:0,body_at})
 }
 fn camera(x:i32,scale:i32)->Camera{Camera{x,y:0,scale,clip:[8,94,457,350],fix:None,overlay:false}}
 #[test] fn both_codecs_draw_and_cache_the_same_named_road(){
  for codec in [1,2]{let(h,mut f)=fixture(codec);let mut s=scratch();let mut colors=Vec::new();let info=render(&mut f,h,&mut s,camera(200,1),|_,_,_,_,c|colors.push(c)).unwrap();assert_eq!(info.features,1);assert!(colors.contains(&0x8c91));assert_eq!(&info.name[..9],b"Test Road");assert_eq!(s.label_count,1);assert_eq!(f.body_reads,1);
   render(&mut f,h,&mut s,camera(200,1),|_,_,_,_,_|{}).unwrap();assert_eq!(f.body_reads,1,"warm frames must not decompress or reread a page");
   f.bytes[f.body_at+7]^=1;s.clear_pages();assert_eq!(render(&mut f,h,&mut s,camera(200,1),|_,_,_,_,_|{}).err(),Some(-5));
  }
 }
 #[test] fn spatial_and_scale_culling_do_not_read_the_page_body(){let(h,mut f)=fixture(2);let mut s=scratch();for c in [camera(3000,1),camera(200,64)]{let info=render(&mut f,h,&mut s,c,|_,_,_,_,_|panic!("culled geometry was drawn")).unwrap();assert_eq!(info.features,0);}assert_eq!(f.body_reads,0);}
 #[test] fn invalid_page_bounds_are_rejected(){let(h,mut f)=fixture(2);f.bytes[148..150].copy_from_slice(&2049u16.to_le_bytes());assert_eq!(render(&mut f,h,&mut scratch(),camera(200,1),|_,_,_,_,_|{}).err(),Some(-5));assert_eq!(f.body_reads,0);}
 #[test] fn cached_record_bounds_preserve_pixels_and_cull_offscreen_geometry(){let(h,mut f)=fixture(1);let mut s=scratch();let mut cold=Vec::new();let mut warm=Vec::new();render(&mut f,h,&mut s,camera(200,1),|x,y,w,h,c|cold.push((x,y,w,h,c))).unwrap();render(&mut f,h,&mut s,camera(200,1),|x,y,w,h,c|warm.push((x,y,w,h,c))).unwrap();assert_eq!(cold,warm);let info=render(&mut f,h,&mut s,camera(3000,1),|_,_,_,_,_|panic!("offscreen record drawn")).unwrap();assert_eq!(info.features,0);assert_eq!(f.body_reads,1);}
}
