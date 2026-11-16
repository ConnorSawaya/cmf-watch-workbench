//! Small atomic set of named bookmarks, independent of raster image eviction.
use crate::model::{crc32,i32le,u16le,u32le};
pub const LIMIT:usize=32;pub const RECORD:usize=32;pub const CAP:usize=12+LIMIT*RECORD;
#[derive(Clone,Copy)]pub struct Places {bytes:[u8;LIMIT*RECORD],pub count:usize,pub crc:u32}
impl Places {
 pub const fn new()->Self{Self{bytes:[0;LIMIT*RECORD],count:0,crc:0}}
 pub fn valid(b:&[u8])->bool{b.len()>=12&&&b[..4]==b"TP10"&&u16le(b,4) as usize<=LIMIT&&u16le(b,6)==0&&b.len()==12+u16le(b,4) as usize*RECORD&&crc32(&b[12..])==u32le(b,8)&&b[12..].chunks_exact(RECORD).all(|p|i32le(p,0).unsigned_abs()<=21_000_000&&i32le(p,4).unsigned_abs()<=21_000_000&&p[8..].iter().all(|c|*c==0||(32..=126).contains(c)))}
 pub fn restore(&mut self,b:&[u8]){if Self::valid(b){self.count=u16le(b,4) as usize;self.crc=u32le(b,8);self.bytes[..self.count*RECORD].copy_from_slice(&b[12..]);}}
 pub fn store(&self,out:&mut[u8])->usize{let n=self.count*RECORD;out[..12].fill(0);out[..4].copy_from_slice(b"TP10");out[4..6].copy_from_slice(&(self.count as u16).to_le_bytes());out[8..12].copy_from_slice(&crc32(&self.bytes[..n]).to_le_bytes());out[12..12+n].copy_from_slice(&self.bytes[..n]);12+n}
 pub fn iter(&self)->impl Iterator<Item=(i32,i32,&str)> {self.bytes[..self.count*RECORD].chunks_exact(RECORD).map(|p|{let n=p[8..].iter().position(|c|*c==0).unwrap_or(24);(i32le(p,0),i32le(p,4),core::str::from_utf8(&p[8..8+n]).unwrap_or("Saved place"))})}
 pub fn notice(&self)->[u8;10]{let c=self.crc.to_le_bytes();[84,77,1,0x44,self.count as u8,0,c[0],c[1],c[2],c[3]]}
}
#[cfg(test)]mod tests{use super::*;
 #[test]fn validates_entire_bookmark_set_before_replacing(){let mut b=vec![0u8;44];b[..4].copy_from_slice(b"TP10");b[4]=1;b[12..16].copy_from_slice(&100i32.to_le_bytes());b[20..24].copy_from_slice(b"Camp");let c=crc32(&b[12..]);b[8..12].copy_from_slice(&c.to_le_bytes());let mut p=Places::new();p.restore(&b);assert_eq!(p.iter().next(),Some((100,0,"Camp")));b[20]^=1;p.restore(&b);assert_eq!(p.iter().next(),Some((100,0,"Camp")));let mut out=[0;CAP];let n=p.store(&mut out);assert!(Places::valid(&out[..n]));}
}
