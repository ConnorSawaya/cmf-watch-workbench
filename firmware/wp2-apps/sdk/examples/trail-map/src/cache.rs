//! Eight complete, overwriteable map views in the loader's bounded NAND cache.
use cmf_wp2_app::Api;
use crate::{model::{Model,u16le,u32le,i32le},raster::{META,CAP}};
#[derive(Clone,Copy)] struct Entry {valid:bool,x:i32,y:i32,scale:i32,crc:u32,sequence:u32}
impl Entry {
 const fn empty()->Self {Self{valid:false,x:0,y:0,scale:1,crc:0,sequence:0}}
 fn parse(b:&[u8],n:usize)->Self {
  if b.len()<META||&b[..4]!=b"TM07"||u16le(b,14) as usize+META!=n||u16le(b,14) as usize>CAP||i32le(b,4).unsigned_abs()>21_000_000||i32le(b,8).unsigned_abs()>21_000_000||!(1..=60000).contains(&u16le(b,12)) {return Self::empty();}
  Self{valid:true,x:i32le(b,4),y:i32le(b,8),scale:u16le(b,12) as i32,crc:u32le(b,16),sequence:u32le(b,20)}
 }
}
pub struct MapCache {entries:[Entry;8],pub available:bool,pub hits:u16,pub writes:u16,pub last_error:i16,sequence:u32}
impl MapCache {
 pub const fn new()->Self {Self{entries:[Entry::empty();8],available:false,hits:0,writes:0,last_error:0,sequence:0}}
 pub fn boot(&mut self,api:&Api,m:&mut Model)->bool {
  self.available=api.cache_available();if !self.available {return false;}
  let mut newest=None;
  for i in 0..8 {let b=m.raster.workspace();let n=api.cache_peek(i as u8,&mut b[..META]);if n>0 {self.entries[i]=Entry::parse(b,n as usize);let e=self.entries[i];if e.valid&&newest.is_none_or(|j:usize|(e.sequence.wrapping_sub(self.entries[j].sequence) as i32)>0) {newest=Some(i);self.sequence=e.sequence;}}}
  if self.select(api,m) {m.browsing=true;return true;}
  if let Some(i)=newest {if self.load(api,m,i) {m.adopt_raster_camera();return true;}}false
 }
 fn load(&mut self,api:&Api,m:&mut Model,index:usize)->bool {
  let b=m.raster.workspace();let n=api.cache_get(index as u8,b);if n<=0 {self.entries[index].valid=false;return false;}
  let entry=Entry::parse(b,n as usize);if !entry.valid||!m.raster.restore_record(n as usize) {self.entries[index].valid=false;return false;}
  self.entries[index]=entry;self.hits=self.hits.saturating_add(1);true
 }
 pub fn select(&mut self,api:&Api,m:&mut Model)->bool {
  if !self.available||!m.needs_detail() {return false;}let (x,y)=m.viewport();let mut best=None;
  for i in 0..8 {let e=self.entries[i];if !e.valid||e.scale!=m.scale||(e.x-x).abs()>m.scale*160||(e.y-y).abs()>m.scale*90 {continue;}
   let distance=(e.x-x).abs()+(e.y-y).abs();if best.is_none_or(|(d,_)|distance<d) {best=Some((distance,i));}
  }
  let Some((_,i))=best else{return false;};let e=self.entries[i];if m.raster.valid&&(e.x,e.y,e.scale,e.crc)==(m.raster.x,m.raster.y,m.raster.scale,m.raster.image_crc) {return false;}self.load(api,m,i)
 }
 pub fn save(&mut self,api:&Api,m:&mut Model)->bool {
  let r=&mut m.raster;if !self.available||!r.valid {return false;}
  if self.entries.iter().any(|e|e.valid&&(e.x,e.y,e.scale,e.crc)==(r.x,r.y,r.scale,r.image_crc)) {return false;}
  let index=self.entries.iter().position(|e|e.valid&&(e.x,e.y,e.scale)==(r.x,r.y,r.scale)).or_else(||self.entries.iter().position(|e|!e.valid)).unwrap_or_else(||{let mut old=0;for i in 1..8 {if (self.entries[i].sequence.wrapping_sub(self.entries[old].sequence) as i32)<0 {old=i;}}old});
  let sequence=self.sequence.wrapping_add(1);let record=r.record(sequence);let entry=Entry::parse(record,record.len());
  let result=api.cache_put(index as u8,record);if result!=0 {self.last_error=result as i16;return true;}self.last_error=0;
  self.entries[index]=entry;self.sequence=sequence;self.writes=self.writes.saturating_add(1);true
 }
 pub fn status(&self)->[u8;13] {let h=self.hits.to_le_bytes();let w=self.writes.to_le_bytes();let e=self.last_error.to_le_bytes();[84,77,1,0x14,self.available as u8,self.entries.iter().filter(|e|e.valid).count() as u8,8,h[0],h[1],w[0],w[1],e[0],e[1]]}
 pub fn notice(m:&Model)->[u8;18] {let r=&m.raster;let mut b=[0;18];b[..4].copy_from_slice(&[84,77,1,0x12]);b[4..8].copy_from_slice(&r.x.to_le_bytes());b[8..12].copy_from_slice(&r.y.to_le_bytes());b[12..14].copy_from_slice(&(r.scale as u16).to_le_bytes());b[14..18].copy_from_slice(&r.image_crc.to_le_bytes());b}
}
