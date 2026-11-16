use crate::model::{u16le,u32le,i32le,crc32};
pub const RECORD_CAP:usize=32768;
pub const META:usize=32;
pub const CAP:usize=RECORD_CAP-META;
pub const WIDTH:i32=450;pub const HEIGHT:i32=257;
pub const PALETTE:[u16;16]=[0xCEFE,0xF75B,0xC6F7,0xB675,0x9E3B,0xFFFF,0xB5B5,0x3409,0x335B,0x1924,0x8C91,0xF7BD,0xDEB9,0xEA63,0x73CE,0xBDD5];
pub struct Raster {buffers:[[u8;RECORD_CAP];2],active:usize,pub len:usize,pub valid:bool,pub x:i32,pub y:i32,pub scale:i32,pub image_crc:u32,want:usize,got:usize,crc:u32,id:u16,next_x:i32,next_y:i32,next_scale:i32}
impl Raster {
 pub const fn new()->Self {Self{buffers:[[0;RECORD_CAP];2],active:0,len:0,valid:false,x:0,y:0,scale:1,image_crc:0,want:0,got:0,crc:0,id:0,next_x:0,next_y:0,next_scale:1}}
 pub fn accept(&mut self,b:&[u8])->(u8,bool) {
  match b[3] {
   0x20 if b.len()==22=>{
    let n=u16le(b,6) as usize;let x=i32le(b,12);let y=i32le(b,16);let scale=u16le(b,20) as i32;
    if !(1..=CAP).contains(&n)||x.unsigned_abs()>21_000_000||y.unsigned_abs()>21_000_000||!(1..=60000).contains(&scale) {return (1,false);}
    self.want=n;self.got=0;self.id=u16le(b,4);self.crc=u32le(b,8);self.next_x=x;self.next_y=y;self.next_scale=scale;(0,false)
   },
   0x21 if b.len()>8&&b.len()<=128=>{let off=u16le(b,6) as usize;if self.want==0||u16le(b,4)!=self.id||off!=self.got||b.len()-8>self.want-self.got {return (2,false);}self.buffers[self.active^1][META+off..META+off+b.len()-8].copy_from_slice(&b[8..]);self.got+=b.len()-8;(0,false)},
   0x22 if b.len()==6=>{
    if self.want==0||u16le(b,4)!=self.id||self.got!=self.want {return (2,false);}
    let n=self.want;self.want=0;
    if crc32(&self.buffers[self.active^1][META..META+n])!=self.crc||!valid(&self.buffers[self.active^1][META..META+n]) {return (3,false);}
    self.active^=1;self.len=n;self.image_crc=self.crc;self.x=self.next_x;self.y=self.next_y;self.scale=self.next_scale;self.valid=true;(0,true)
   },
   _=>(1,false)
  }
 }
}
pub fn valid(b:&[u8])->bool {
 if b.is_empty(){return false;}
 if b[0]==1 {return b.len()==5+(WIDTH as usize*HEIGHT as usize).div_ceil(4)&&b[1..5].iter().all(|c|*c<15);}
 if b[0]!=0 {return false;}
 let mut i=1;let mut pixels=0;
 while i<b.len() {
  let v=b[i];i+=1;
  let count=if v>>4==15 {let n=(v&15) as usize+1;if i+n>b.len()||b[i..i+n].iter().any(|c|c>>4==15||c&15==15){return false;}i+=n;n*2}
  else if v&15==15 {if i==b.len(){return false;}let n=16+b[i] as usize;i+=1;n}else{1+(v&15) as usize};
  pixels+=count;if pixels>WIDTH as usize*HEIGHT as usize {return false;}
 }
 pixels==WIDTH as usize*HEIGHT as usize
}
pub struct Runs<'a> {data:&'a [u8],offset:usize,literals:usize,low:Option<u8>,pixel:usize}
impl Raster {
 pub fn workspace(&mut self)->&mut [u8] {&mut self.buffers[self.active^1]}
 pub fn record(&mut self,sequence:u32)->&[u8] {
  let h=&mut self.buffers[self.active][..META];h.fill(0);h[..4].copy_from_slice(b"TM07");h[4..8].copy_from_slice(&self.x.to_le_bytes());h[8..12].copy_from_slice(&self.y.to_le_bytes());h[12..14].copy_from_slice(&(self.scale as u16).to_le_bytes());h[14..16].copy_from_slice(&(self.len as u16).to_le_bytes());h[16..20].copy_from_slice(&self.image_crc.to_le_bytes());h[20..24].copy_from_slice(&sequence.to_le_bytes());&self.buffers[self.active][..META+self.len]
 }
 pub fn restore_record(&mut self,n:usize)->bool {
  if !(META+1..=RECORD_CAP).contains(&n) {return false;}
  let b=&self.buffers[self.active^1];let x=i32le(b,4);let y=i32le(b,8);let scale=u16le(b,12) as i32;let len=u16le(b,14) as usize;let crc=u32le(b,16);
  if &b[..4]!=b"TM07"||len+META!=n||x.unsigned_abs()>21_000_000||y.unsigned_abs()>21_000_000||!(1..=60000).contains(&scale)||crc32(&b[META..n])!=crc||!valid(&b[META..n]) {return false;}
  self.active^=1;self.len=len;self.x=x;self.y=y;self.scale=scale;self.image_crc=crc;self.valid=true;self.want=0;true
 }
 pub fn bytes(&self)->&[u8] {&self.buffers[self.active][META..META+self.len]}
 #[cfg(test)] pub fn fixture(&mut self,b:&[u8]) {self.buffers[self.active][META..META+b.len()].copy_from_slice(b);self.len=b.len();self.image_crc=crc32(b);}
 pub fn runs(&self)->Runs<'_> {Runs{data:self.bytes(),offset:1,literals:0,low:None,pixel:0}}}
impl Iterator for Runs<'_> {
 type Item=(u8,i64);
 fn next(&mut self)->Option<Self::Item> {
  if self.data[0]==1 {
   let total=(WIDTH*HEIGHT) as usize;if self.pixel==total {return None;}
   let at=|i:usize| self.data[1+((self.data[5+i/4]>>(6-2*(i%4)))&3) as usize];
   let color=at(self.pixel);let start=self.pixel;self.pixel+=1;while self.pixel<total&&at(self.pixel)==color {self.pixel+=1;}
   return Some((color,(self.pixel-start) as i64));
  }
  if let Some(c)=self.low.take(){return Some((c,1));}
  loop {
   if self.literals>0 {let b=self.data[self.offset];self.offset+=1;self.literals-=1;self.low=Some(b&15);return Some((b>>4,1));}
   if self.offset==self.data.len(){return None;}
   let v=self.data[self.offset];self.offset+=1;
   if v>>4==15 {self.literals=(v&15) as usize+1;continue;}
   let count=if v&15==15 {let n=16+self.data[self.offset] as i64;self.offset+=1;n}else{1+(v&15) as i64};return Some((v>>4,count));
  }
 }
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn bounded_decoder_rejects_partial_oversized_and_short_frame() {assert!(!valid(&[15]));assert!(!valid(&[0]));let mut d=vec![15,255];while d.len()<1000 {d.extend([15,255]);}assert!(!valid(&d));}
 #[test] fn accepts_exact_native_sized_artwork() {let mut n=WIDTH*HEIGHT;let mut d=vec![0];while n>0 {let run=n.min(271);if run>=16 {d.extend([15,(run-16) as u8]);}else{d.push((run-1) as u8);}n-=run;}assert!(valid(&d));d.push(0);assert!(!valid(&d));}
}
#[cfg(test)] mod literal_tests {
 use super::*;
 #[test] fn literal_stream_preserves_both_nibbles_and_rejects_missing_bytes() {
  let mut r=Raster::new();let mut d=vec![0,0xF1,0x12,0x34];let mut left=WIDTH*HEIGHT-4;
  while left>0 {let n=left.min(271);if n>=16 {d.extend([0x1F,(n-16) as u8]);}else{d.push(0x10|(n-1) as u8);}left-=n;}
  assert!(valid(&d));r.fixture(&d);let values:Vec<_>=r.runs().collect();assert_eq!(&values[..4],&[(1,1),(2,1),(3,1),(4,1)]);assert_eq!(values.iter().map(|p|p.1).sum::<i64>(),(WIDTH*HEIGHT) as i64);
  assert!(!valid(&[0,0xF0]));assert!(!valid(&[0,0xF0,0x1F]));
 }
}
#[cfg(test)] mod packed_tests {
 use super::*;
 #[test] fn packed_dense_artwork_is_bounded_and_complete() {
  let mut r=Raster::new();let n=5+(WIDTH as usize*HEIGHT as usize).div_ceil(4);let mut b=vec![0;n];b[..5].copy_from_slice(&[1,1,5,7,9]);b[5..].fill(0x1B);r.fixture(&b);
  assert!(valid(&b));let runs:Vec<_>=r.runs().collect();assert_eq!(&runs[..4],&[(1,1),(5,1),(7,1),(9,1)]);assert_eq!(runs.iter().map(|p|p.1).sum::<i64>(),(WIDTH*HEIGHT) as i64);
  assert!(!valid(&b[..n-1]));b[1]=15;assert!(!valid(&b));
 }
}

#[cfg(test)] mod replacement_tests {
 use super::*;
 fn frame(color:u8)->Vec<u8> {let mut d=vec![0];let mut left=WIDTH*HEIGHT;while left>0 {let n=left.min(271);if n>=16 {d.extend([color<<4|15,(n-16) as u8]);}else{d.push(color<<4|(n-1) as u8);}left-=n;}d}
 fn begin(d:&[u8],id:u16,crc:u32)->Vec<u8> {let mut b=vec![84,77,1,0x20];b.extend(id.to_le_bytes());b.extend((d.len() as u16).to_le_bytes());b.extend(crc.to_le_bytes());b.extend(99i32.to_le_bytes());b.extend(100i32.to_le_bytes());b.extend(8u16.to_le_bytes());b}
 fn chunks(r:&mut Raster,d:&[u8],id:u16) {for (i,p) in d.chunks(120).enumerate() {let mut b=vec![84,77,1,0x21];b.extend(id.to_le_bytes());b.extend(((i*120) as u16).to_le_bytes());b.extend(p);assert_eq!(r.accept(&b),(0,false));}}
 #[test] fn partial_corrupt_and_replaced_transfer_keep_the_complete_picture() {
  let old=frame(7);let new=frame(5);let mut r=Raster::new();r.fixture(&old);r.valid=true;r.x=42;r.scale=8;
  assert_eq!(r.accept(&begin(&new,1,crc32(&new))),(0,false));assert!(r.valid);assert_eq!(r.x,42);assert_eq!(r.bytes(),old);
  chunks(&mut r,&new,1);assert_eq!(r.bytes(),old);assert_eq!(r.x,42);
  // A subsequent begin cancels the old staging area. A bad checksum cannot
  // promote it or replace the active camera or image.
  r.accept(&begin(&new,2,crc32(&new)^1));chunks(&mut r,&new,2);assert_eq!(r.accept(&[84,77,1,0x22,2,0]),(3,false));assert!(r.valid);assert_eq!(r.bytes(),old);assert_eq!(r.x,42);
  r.accept(&begin(&new,3,crc32(&new)));chunks(&mut r,&new,3);assert_eq!(r.accept(&[84,77,1,0x22,3,0]),(0,true));assert_eq!(r.bytes(),new);assert_eq!(r.x,99);
 }
}
