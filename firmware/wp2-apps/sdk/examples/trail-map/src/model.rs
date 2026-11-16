pub const CAP:usize=3648;
pub const HEADER:usize=48;
pub const MAX_SEGMENTS:usize=400;
pub const STORE_CAP:usize=72+crate::places::CAP;
pub fn u16le(b:&[u8],i:usize)->u16 {u16::from_le_bytes([b[i],b[i+1]])}
pub fn i16le(b:&[u8],i:usize)->i16 {i16::from_le_bytes([b[i],b[i+1]])}
pub fn u32le(b:&[u8],i:usize)->u32 {u32::from_le_bytes(b[i..i+4].try_into().unwrap())}
pub fn i32le(b:&[u8],i:usize)->i32 {i32::from_le_bytes(b[i..i+4].try_into().unwrap())}
pub fn crc_extend(mut c:u32,b:&[u8])->u32 {for &x in b {c^=x as u32;for _ in 0..8 {c=(c>>1)^(0xedb88320&0u32.wrapping_sub(c&1));}}c}
pub fn crc32(b:&[u8])->u32 {!crc_extend(!0,b)}
pub fn valid(b:&[u8])->bool {
 if b.len()<HEADER||(&b[..4]!=b"TM01"&&&b[..4]!=b"TM02") {return false;}
 let n=u16le(b,12) as usize;
 n<=MAX_SEGMENTS&&b.len()==HEADER+9*n&&(1..=60000).contains(&u16le(b,14))&&i32le(b,4).unsigned_abs()<=21_000_000&&i32le(b,8).unsigned_abs()<=21_000_000&&b[16..48].iter().all(|x|*x==0||(32..=126).contains(x))&&(0..n).all(|i|b[HEADER+9*i+8]<=4)
}
#[derive(Clone,Copy,Debug,PartialEq)]
pub struct Fix {pub x:i32,pub y:i32,pub accuracy:u16,pub received:u32,pub epoch:u32,pub age:u32,pub live:bool,pub satellites:Option<u8>,pub watch:bool}
impl Fix {
 pub fn fresh(&self,now:u32)->bool {self.live&&self.age<10&&now.wrapping_sub(self.received)<10_000}
 pub fn age(&self,now:u32)->u32 {self.age.saturating_add(now.wrapping_sub(self.received)/1000)}
}
pub struct Model {
 pub data:[u8;HEADER],pub len:usize,pending:[u8;HEADER],want:usize,got:usize,crc:u32,id:u16,running_crc:u32,bad_segment:bool,
 pub pan_x:i32,pub pan_y:i32,pub scale:i32,pub fix:Option<Fix>,
 pub drag:Option<(i16,i16,i32,i32)>,pub browsing:bool,pub preview:bool,pub raster:crate::raster::Raster,pub gps_on:bool,pub offline:bool,pub follow:bool,pub places:crate::places::Places,pub progress:crate::progress::Progress,pub place_want:usize,pub place_got:usize,
}
impl Model {
 pub const fn new()->Self {Self{data:[0;HEADER],len:0,pending:[0;HEADER],want:0,got:0,crc:0,id:0,running_crc:!0,bad_segment:false,pan_x:0,pan_y:0,scale:40000,fix:None,drag:None,browsing:false,preview:false,raster:crate::raster::Raster::new(),gps_on:false,offline:false,follow:true,places:crate::places::Places::new(),progress:crate::progress::Progress::new(),place_want:0,place_got:0}}
 pub fn watch_fix(&mut self,g:cmf_wp2_app::WatchGps,now:u32)->bool {
  let on_changed=self.gps_on!=g.on;self.gps_on=g.on;if !g.known{return on_changed;}
  if !g.live {let mut changed=on_changed;if let Some(f)=self.fix.as_mut().filter(|f|f.watch){changed|=f.live;f.live=false;f.satellites=None;}return changed;}
  let before=self.fix;self.fix=Some(Fix{x:g.x,y:g.y,accuracy:1000,received:now,epoch:0,age:g.age_ms/1000,live:g.live,satellites:g.satellites,watch:true});
  if self.offline&&self.follow {let scale=if self.len==0{16}else{self.scale};self.data.fill(0);self.data[..4].copy_from_slice(b"TM02");self.data[4..8].copy_from_slice(&g.x.to_le_bytes());self.data[8..12].copy_from_slice(&g.y.to_le_bytes());self.data[14..16].copy_from_slice(&(scale as u16).to_le_bytes());self.data[16..30].copy_from_slice(b"Offline trails");self.len=HEADER;self.reset();}
  before.map(|f|(f.x,f.y,f.live,f.satellites,f.watch))!=self.fix.map(|f|(f.x,f.y,f.live,f.satellites,f.watch))
 }
 pub fn restore(&mut self,n:usize) {self.len=if n<=HEADER&&valid(&self.data[..n]) {n}else{0};self.reset();}
 pub fn restore_store(&mut self,b:&[u8]) {let (data,len,fix)=decode_store(b);self.data=data;self.len=len;self.fix=fix;self.places.restore(place_tail(b));self.reset();}
 pub fn restore_staged(&mut self,n:usize) {let (data,len,fix)=decode_store(&self.raster.workspace()[..n]);self.data=data;self.len=len;self.fix=fix;self.places.restore(place_tail(&self.raster.workspace()[..n]));self.reset();}
 pub fn adopt_raster_camera(&mut self) {self.data.fill(0);self.data[..4].copy_from_slice(b"TM02");self.data[4..8].copy_from_slice(&self.raster.x.to_le_bytes());self.data[8..12].copy_from_slice(&self.raster.y.to_le_bytes());self.data[14..16].copy_from_slice(&(self.raster.scale as u16).to_le_bytes());self.data[16..25].copy_from_slice(b"Saved map");self.len=HEADER;self.reset();self.browsing=true;}
 pub fn store(&self,b:&mut [u8;STORE_CAP])->usize {
  b[..self.len].copy_from_slice(&self.data[..self.len]);if self.len>0 {let (x,y)=self.viewport();b[4..8].copy_from_slice(&x.to_le_bytes());b[8..12].copy_from_slice(&y.to_le_bytes());b[14..16].copy_from_slice(&(self.scale as u16).to_le_bytes());}
  let mut n=self.len;if let Some(f)=self.fix {let s=&mut b[n..n+24];s.fill(0);s[..4].copy_from_slice(b"TF01");s[4..8].copy_from_slice(&f.x.to_le_bytes());s[8..12].copy_from_slice(&f.y.to_le_bytes());s[12..14].copy_from_slice(&f.accuracy.to_le_bytes());s[16..20].copy_from_slice(&f.epoch.to_le_bytes());let c=crc32(&s[..20]);s[20..24].copy_from_slice(&c.to_le_bytes());n+=24;}
  if self.places.count>0||self.places.crc!=0 {n+=self.places.store(&mut b[n..]);}n
 }
 pub fn reset(&mut self) {self.pan_x=0;self.pan_y=0;self.scale=if self.len>0 {u16le(&self.data,14) as i32}else{40000};}
 pub fn viewport(&self)->(i32,i32) {(if self.len>0 {i32le(&self.data,4)}else{-14_100_000}+self.pan_x,if self.len>0 {i32le(&self.data,8)}else{-6_500_000}+self.pan_y)}
 pub fn start_drag(&mut self,x:i16,y:i16) {if (8..=457).contains(&x)&&(94..=350).contains(&y) {self.drag=Some((x,y,self.pan_x,self.pan_y));}}
 pub fn move_drag(&mut self,x:i16,y:i16)->bool {
  let Some((sx,sy,px,py))=self.drag else{return false;};
  if !(0..=465).contains(&x)||!(0..=465).contains(&y)||((x-sx).abs()<4&&(y-sy).abs()<4&&self.pan_x==px&&self.pan_y==py) {return false;}
  let cx=if self.len>0 {i32le(&self.data,4)}else{-14_100_000};let cy=if self.len>0 {i32le(&self.data,8)}else{-6_500_000};
  let nx=(px-(x-sx) as i32*self.scale).clamp(-21_000_000-cx,21_000_000-cx);let ny=(py-(y-sy) as i32*self.scale).clamp(-21_000_000-cy,21_000_000-cy);
  let changed=(nx,ny)!=(self.pan_x,self.pan_y);self.pan_x=nx;self.pan_y=ny;self.browsing|=changed;if changed{self.follow=false;}changed
 }
 pub fn request(&self)->[u8;14] {let (x,y)=self.viewport();let mut b=[84,77,1,0x11,0,0,0,0,0,0,0,0,0,0];b[4..8].copy_from_slice(&x.to_le_bytes());b[8..12].copy_from_slice(&y.to_le_bytes());b[12..14].copy_from_slice(&(self.scale as u16).to_le_bytes());b}
 pub fn needs_detail(&self)->bool {let r=&self.raster;let (x,y)=self.viewport();!r.valid||r.scale!=self.scale||(r.x-x).abs()>self.scale*8||(r.y-y).abs()>self.scale*8}
 pub fn fresh(&self,now:u32)->bool {self.fix.is_some_and(|f|f.fresh(now))}
 pub fn accept(&mut self,b:&[u8],now:u32)->(u8,bool) {
  if b.len()<4||&b[..3]!=b"TM\x01" {return (1,false);}
  if (0x20..=0x22).contains(&b[3]) {self.place_want=0;let r=self.raster.accept(b);if r.0==0{match b[3]{0x20=>self.progress.begin(1,u16le(b,6) as u32,0,now),0x21=>self.progress.received(u16le(b,6) as u32+(b.len()-8) as u32,now),_=>{self.progress.phase=2;self.progress.at=now;}}}else{self.progress.finish(false,now);}return r;}
  match b[3] {
   1 if b.len()==12=>{self.want=0;self.got=0;self.id=u16le(b,4);let n=u16le(b,6) as usize;if !(HEADER..=CAP).contains(&n) {return (1,false);}self.want=n;self.crc=u32le(b,8);self.running_crc=!0;self.bad_segment=false;(0,false)},
   2 if b.len()>8&&b.len()<=128=>{let off=u16le(b,6) as usize;if self.want==0||u16le(b,4)!=self.id||off!=self.got||b.len()-8>self.want-self.got {return (2,false);}let payload=&b[8..];for (i,&v) in payload.iter().enumerate() {let p=off+i;if p<HEADER {self.pending[p]=v;}else if (p-HEADER)%9==8&&v>4 {self.bad_segment=true;}}self.running_crc=crc_extend(self.running_crc,payload);self.got+=payload.len();(0,false)},
   3 if b.len()==6=>{if self.want==0||u16le(b,4)!=self.id||self.got!=self.want {return (2,false);}if !self.running_crc!=self.crc||self.bad_segment||(&self.pending[..4]!=b"TM01"&&&self.pending[..4]!=b"TM02")||u16le(&self.pending,12) as usize>MAX_SEGMENTS||HEADER+9*u16le(&self.pending,12) as usize!=self.want||!(1..=60000).contains(&u16le(&self.pending,14))||i32le(&self.pending,4).unsigned_abs()>21_000_000||i32le(&self.pending,8).unsigned_abs()>21_000_000||!self.pending[16..48].iter().all(|x|*x==0||(32..=126).contains(x)) {self.want=0;return (3,false);}let old=self.viewport();let origin=(old.0-self.pan_x,old.1-self.pan_y);let scale=self.scale;self.data.copy_from_slice(&self.pending);self.data[3]=b'2';self.data[12]=0;self.data[13]=0;self.len=HEADER;self.want=0;if self.browsing {self.pan_x=old.0-i32le(&self.data,4);self.pan_y=old.1-i32le(&self.data,8);if let Some((x,y,px,py))=self.drag {self.drag=Some((x,y,px+origin.0-i32le(&self.data,4),py+origin.1-i32le(&self.data,8)));}self.scale=scale;}else{self.reset();}(0,true)},
   4 if b.len()==14=>self.accept_fix(b,now,true,None,0,0),
   6 if b.len()==24&&b[14]<=1&&(b[15]==255||b[15]<=100)=>self.accept_fix(b,now,b[14]==1,if b[15]==255 {None}else{Some(b[15])},u32le(b,16),u32le(b,20)),
   5 if b.len()==4=>{if let Some(ref mut f)=self.fix {if !f.watch {f.live=false;f.satellites=None;}}(0,false)},
   _=>(1,false),
  }
 }
 fn accept_fix(&mut self,b:&[u8],now:u32,live:bool,satellites:Option<u8>,epoch:u32,age:u32)->(u8,bool) {
  let x=i32le(b,4);let y=i32le(b,8);let accuracy=u16le(b,12);
  if x.unsigned_abs()>21_000_000||y.unsigned_abs()>21_000_000||!(1..=1000).contains(&accuracy) {return (1,false);}
  if self.fix.is_some_and(|f|f.watch&&f.fresh(now)){return (0,false);}
  self.fix=Some(Fix{x,y,accuracy,received:now,epoch,age,live,satellites,watch:false});(0,false)
 }
 pub fn segment_point(&self,x:i16,y:i16)->(i32,i32) {
  let factor=if self.data[3]==b'2' {u16le(&self.data,14) as i64}else{64};
  self.point((i32le(&self.data,4) as i64+x as i64*factor/64) as i32,(i32le(&self.data,8) as i64+y as i64*factor/64) as i32)
 }
 pub fn point(&self,x:i32,y:i32)->(i32,i32) {
  // Validated Mercator coordinates and camera differences fit in i32. The
  // Cortex-M has hardware i32 division; i64 division invokes a software helper.
  let (cx,cy)=self.viewport();
  (233+((x-cx)/self.scale).clamp(-100_000,100_000),220+((y-cy)/self.scale).clamp(-100_000,100_000))
 }
}
fn place_tail(b:&[u8])->&[u8]{let n=if b.len()>=HEADER&&(&b[..4]==b"TM01"||&b[..4]==b"TM02"){HEADER+9*u16le(b,12) as usize}else{0};let n=if b.get(n..n+4)==Some(b"TF01"){n+24}else{n};b.get(n..).unwrap_or(&[])}
fn decode_store(b:&[u8])->([u8;HEADER],usize,Option<Fix>) {
  let mut data=[0;HEADER];let mut len=0;let mut fix=None;
  let n=if b.len()>=HEADER&&(&b[..4]==b"TM01"||&b[..4]==b"TM02") {HEADER+9*(u16le(b,12) as usize)}else{0};
  if n<=CAP&&n<=b.len()&&valid(&b[..n]) {data.copy_from_slice(&b[..HEADER]);data[3]=b'2';data[12]=0;data[13]=0;len=HEADER;}
  if b.len()>=n+24 {let f=&b[n..];if &f[..4]==b"TF01"&&crc32(&f[..20])==u32le(f,20) {let x=i32le(f,4);let y=i32le(f,8);let accuracy=u16le(f,12);if x.unsigned_abs()<=21_000_000&&y.unsigned_abs()<=21_000_000&&(1..=1000).contains(&accuracy) {fix=Some(Fix{x,y,accuracy,received:0,epoch:u32le(f,16),age:u32::MAX,live:false,satellites:None,watch:false});}}}
 (data,len,fix)
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn interrupted_corrupt_and_malformed_keep_saved_map() {
  let mut m=Model::new();let mut blob=[0;HEADER];blob[..4].copy_from_slice(b"TM01");blob[14]=8;m.data[..HEADER].copy_from_slice(&blob);m.restore(HEADER);
  assert_eq!(m.accept(b"TM\x01\x01\x01\0\x30\0\0\0\0\0",0),(0,false));assert_eq!(m.accept(b"TM\x01\x03\x01\0",0),(2,false));assert_eq!(m.len,HEADER);
  let mut chunk=vec![b'T',b'M',1,2,1,0,0,0];chunk.extend(blob);m.accept(&chunk,0);assert_eq!(m.accept(b"TM\x01\x03\x01\0",0),(3,false));assert_eq!(&m.data[4..HEADER],&blob[4..]);
  for n in 0..129 {let b=vec![255;n];assert_eq!(m.accept(&b,0),(1,false));}
 }
 #[test] fn last_known_survives_loss_and_restart() {
  let mut m=Model::new();m.accept(b"TM\x01\x04\0\0\0\0\0\0\0\0\x0a\0",u32::MAX-5);assert!(m.fresh(20));assert!(!m.fresh(10000));assert!(m.fix.is_some());
  m.accept(b"TM\x01\x05",30);assert!(!m.fresh(30));assert!(m.fix.is_some());
  let mut b=[0;STORE_CAP];let n=m.store(&mut b);let mut restored=Model::new();restored.restore_store(&b[..n]);assert!(restored.fix.is_some());assert!(!restored.fresh(0));
  b[10]^=1;let mut broken=Model::new();broken.restore_store(&b[..n]);assert!(broken.fix.is_none());
 }
 #[test] fn unknown_satellite_count_is_never_zero() {
  let mut m=Model::new();let mut b=vec![84,77,1,6];b.extend(0i32.to_le_bytes());b.extend(0i32.to_le_bytes());b.extend(10u16.to_le_bytes());b.extend([1,255]);b.extend(1_800_000_000u32.to_le_bytes());b.extend(0u32.to_le_bytes());assert_eq!(m.accept(&b,10),(0,false));assert_eq!(m.fix.unwrap().satellites,None);
  b[15]=8;assert_eq!(m.accept(&b,20),(0,false));assert_eq!(m.fix.unwrap().satellites,Some(8));b[15]=101;assert_eq!(m.accept(&b,30),(1,false));assert_eq!(m.fix.unwrap().satellites,Some(8));
 }
}
#[cfg(test)] mod drag_tests {
 use super::*;
 #[test] fn dragging_tracks_finger_and_taps_stay_still() {let mut m=Model::new();m.data[..4].copy_from_slice(b"TM01");m.data[14]=8;m.len=HEADER;m.scale=8;m.start_drag(200,200);assert!(!m.move_drag(202,201));assert!(m.move_drag(240,180));assert_eq!((m.pan_x,m.pan_y),(-320,160));assert!(m.move_drag(280,180));assert_eq!((m.pan_x,m.pan_y),(-640,160));assert_eq!(i32le(&m.request(),4),-640);assert!(m.move_drag(200,200));assert_eq!((m.pan_x,m.pan_y),(0,0));m.drag=None;assert!(!m.move_drag(300,200));}
 #[test] fn stale_transfer_cannot_reset_newer_pan() {let mut m=Model::new();m.data[..4].copy_from_slice(b"TM01");m.data[14]=8;m.len=HEADER;m.scale=8;m.browsing=true;m.pan_x=800;let mut b=[0;HEADER];b[..4].copy_from_slice(b"TM01");b[14]=8;b[4..8].copy_from_slice(&100i32.to_le_bytes());let crc=crc32(&b);let mut begin=[84,77,1,1,1,0,48,0,0,0,0,0];begin[8..12].copy_from_slice(&crc.to_le_bytes());m.accept(&begin,0);let mut chunk=vec![84,77,1,2,1,0,0,0];chunk.extend(b);m.accept(&chunk,0);assert_eq!(m.accept(b"TM\x01\x03\x01\0",0),(0,true));assert_eq!(m.viewport().0,800);assert_eq!(m.pan_x,700);}
}

#[cfg(test)] mod metadata_tests {
 use super::*;
 fn transfer(m:&mut Model,b:&[u8],id:u16)->(u8,bool) {
  let mut begin=vec![84,77,1,1];begin.extend(id.to_le_bytes());begin.extend((b.len() as u16).to_le_bytes());begin.extend(crc32(b).to_le_bytes());assert_eq!(m.accept(&begin,0),(0,false));
  for (i,c) in b.chunks(120).enumerate() {let mut p=vec![84,77,1,2];p.extend(id.to_le_bytes());p.extend(((i*120) as u16).to_le_bytes());p.extend(c);assert_eq!(m.accept(&p,0),(0,false));}
  let mut end=vec![84,77,1,3];end.extend(id.to_le_bytes());m.accept(&end,0)
 }
 fn legacy()->Vec<u8> {let mut b=vec![0;CAP];b[..4].copy_from_slice(b"TM01");b[4..8].copy_from_slice(&100i32.to_le_bytes());b[12..14].copy_from_slice(&400u16.to_le_bytes());b[14]=8;for i in 0..400 {b[HEADER+i*9+8]=(i%5) as u8;}b}
 #[test] fn old_full_snapshots_stream_into_camera_metadata_and_validate_all_kinds() {
  let mut m=Model::new();let mut b=legacy();assert_eq!(transfer(&mut m,&b,1),(0,true));assert_eq!(m.len,HEADER);assert_eq!(m.viewport(),(100,0));assert_eq!(&m.data[..4],b"TM02");assert_eq!(u16le(&m.data,12),0);
  b[4..8].copy_from_slice(&200i32.to_le_bytes());b[CAP-1]=5;assert_eq!(transfer(&mut m,&b,2),(3,false));assert_eq!(m.viewport(),(100,0));
 }
 #[test] fn old_maximum_saved_map_and_last_position_migrate() {
  let mut b=legacy();let mut f=[0u8;24];f[..4].copy_from_slice(b"TF01");f[4..8].copy_from_slice(&200i32.to_le_bytes());f[12]=5;let crc=crc32(&f[..20]);f[20..24].copy_from_slice(&crc.to_le_bytes());b.extend(f);
  let mut m=Model::new();m.restore_store(&b);assert_eq!(m.len,HEADER);assert_eq!(m.viewport(),(100,0));assert_eq!(m.fix.unwrap().x,200);assert!(!m.fresh(0));let mut out=[0u8;STORE_CAP];assert_eq!(m.store(&mut out),72);
 }
}
