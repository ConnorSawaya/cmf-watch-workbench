//! Bounded, app-owned disk cache service. No paths or arbitrary file access.
use crate::pkg::crc32;
pub const SLOTS:usize=8;
pub const MAX:usize=32768;
pub const META:usize=32;
pub const HEADER:usize=24;
pub fn room(free:u64,unit:u32,len:usize)->bool {unit>0&&len<=MAX&&free>=128*1024+len as u64+HEADER as u64+2*unit as u64}
pub const PROBE:i32=0x43414331;
#[derive(Clone,Copy,Debug,PartialEq)]
pub struct Request {pub op:u8,pub index:u8,pub ptr:u64,pub len:usize}
pub fn request(b:&[u8])->Option<Request> {
 if b.len()!=20||b[..4]!=[0x14,16,0,0]||b[4]>4||b[5]>=SLOTS as u8||b[6..8]!=[0,0] {return None;}
 let r=Request{op:b[4],index:b[5],ptr:u64::from_le_bytes(b[8..16].try_into().ok()?),len:u32::from_le_bytes(b[16..20].try_into().ok()?) as usize};
 let valid=match r.op {0|4=>r.ptr==0&&r.len==0,1=>r.ptr!=0&&r.len==META,2=>r.ptr!=0&&(META..=MAX).contains(&r.len),3=>r.ptr!=0&&(META..=MAX).contains(&r.len),_=>false};
 valid.then_some(r)
}
pub fn header(owner:u32,generation:u32,data:&[u8])->[u8;HEADER] {let mut h=[0;HEADER];h[..4].copy_from_slice(b"WC01");h[4..8].copy_from_slice(&(data.len() as u32).to_le_bytes());h[8..12].copy_from_slice(&crc32(0,data).to_le_bytes());h[12..16].copy_from_slice(&owner.to_le_bytes());h[16..20].copy_from_slice(&generation.to_le_bytes());let crc=crc32(0,&h[..20]);h[20..].copy_from_slice(&crc.to_le_bytes());h}
pub fn parse(h:&[u8;HEADER],owner:u32)->Option<(usize,u32,u32)> {let word=|i|u32::from_le_bytes(h[i..i+4].try_into().unwrap());let len=word(4) as usize;(&h[..4]==b"WC01"&&word(12)==owner&&(META..=MAX).contains(&len)&&word(20)==crc32(0,&h[..20])).then(||(len,word(8),word(16)))}
pub fn newer(a:u32,b:u32)->bool {(a.wrapping_sub(b) as i32)>0}
pub fn path(slot:u8,index:u8,copy:bool)->[u8;24] {let mut p=*b"/NAND:/wp2apps/c0_0.dat\0";p[16]=b'0'+slot;p[18]=b'0'+index;if copy {p[20..23].copy_from_slice(b"new");}p}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn bounded_headers_owner_and_paths() {let d=[4;META];let h=header(7,1,&d);assert_eq!(parse(&h,7),Some((META,crc32(0,&d),1)));assert!(parse(&h,8).is_none());for slot in 0..8 {for index in 0..8 {let p=path(slot,index,false);assert_eq!(p[16],b'0'+slot);assert_eq!(p[18],b'0'+index);assert_eq!(&p[20..23],b"dat");assert_eq!(&path(slot,index,true)[20..23],b"new");}}}
 #[test] fn reserve_and_generation_wrap() {let needed=128*1024+MAX+HEADER+2*4096;assert!(room(needed as u64,4096,MAX));assert!(!room(needed as u64-1,4096,MAX));assert!(!room(u64::MAX,0,MAX));assert!(!room(u64::MAX,4096,MAX+1));assert!(newer(0,u32::MAX));}
 #[test] fn malformed_requests_cannot_escape_fixed_cache() {let mut b=[0u8;20];b[..4].copy_from_slice(&[0x14,16,0,0]);assert_eq!(request(&b).unwrap().op,0);b[5]=8;assert!(request(&b).is_none());b[5]=0;b[4]=3;assert!(request(&b).is_none());b[8]=1;b[16..20].copy_from_slice(&(MAX as u32+1).to_le_bytes());assert!(request(&b).is_none());b[16..20].copy_from_slice(&(MAX as u32).to_le_bytes());assert!(request(&b).is_some());}
}
