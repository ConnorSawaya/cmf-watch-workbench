//! Always-available Census state outlines, including Alaska and Hawaii.
use crate::{model::{Model,u16le,i16le,i32le},view::{Surface,Bounds,line,text,MAP},raster::PALETTE};
const DATA:&[u8]=include_bytes!("us-states.bin");
// Largest ring is Alaska (1131 points). This bounded temporary exists only
// while drawing and is disjoint from the bookmark/save stack frames.
fn point(m:&Model,cx:i32,cy:i32,offset:usize)->(i32,i32) {m.point(cx+i16le(DATA,offset) as i32*256,cy+i16le(DATA,offset+2) as i32*256)}
fn cached(p:&[(i16,i16)],i:usize,m:&Model,cx:i32,cy:i32,start:usize)->(i32,i32) {let (x,y)=p[i];if x==i16::MIN {point(m,cx,cy,start+4*i)}else{(x as i32,y as i32)}}
#[inline(never)]
fn polygon(s:&mut impl Surface,m:&Model,cx:i32,cy:i32,start:usize,n:usize,color:u16,clip:Bounds) {
 let mut projection=[(0i16,0i16);1131];let projected=&mut projection;assert!(n<=projected.len());
 let (mut top,mut bottom,mut left,mut right)=(i32::MAX,i32::MIN,i32::MAX,i32::MIN);
 for i in 0..n {let (x,y)=point(m,cx,cy,start+4*i);projected[i]=if x>i16::MIN as i32&&x<=i16::MAX as i32&&y>=i16::MIN as i32&&y<=i16::MAX as i32 {(x as i16,y as i16)}else{(i16::MIN,0)};top=top.min(y);bottom=bottom.max(y);left=left.min(x);right=right.max(x);}
 if right<clip.x||left>clip.r||bottom<clip.y||top>clip.b {return;}
 let mut n=n;
 if projected[..n].iter().all(|p|p.0!=i16::MIN) {
  let mut used=0;for i in 0..n {if used==0||projected[i]!=projected[used-1] {projected[used]=projected[i];used+=1;}}n=used;
 }

 for y in top.max(clip.y)..=bottom.min(clip.b) {
  let mut xs=[0i32;64];let mut count=0;let mut a=cached(projected,n-1,m,cx,cy,start);
  for i in 0..n {let b=cached(projected,i,m,cx,cy,start);if (a.1<=y&&b.1>y)||(b.1<=y&&a.1>y) {if count<xs.len(){xs[count]=(a.0 as i64+(y-a.1) as i64*(b.0-a.0) as i64/(b.1-a.1) as i64) as i32;count+=1;}}a=b;}
  xs[..count].sort_unstable();for p in xs[..count].chunks_exact(2) {let x=p[0].max(clip.x);let end=p[1].min(clip.r);if end>=x {s.rect(x,y,end-x+1,1,color);}}
 }
 let mut a=cached(projected,n-1,m,cx,cy,start);for i in 0..n {let b=cached(projected,i,m,cx,cy,start);line(s,a.0,a.1,b.0,b.1,PALETTE[10],clip);a=b;}
}
pub fn draw(s:&mut impl Surface,m:&Model,clip:Bounds) {
 #[cfg(test)] let _guard={static LOCK:std::sync::Mutex<()>=std::sync::Mutex::new(());LOCK.lock().unwrap()};
 let mut off=1;let mut labels=[Bounds{x:0,y:0,r:0,b:0};51];let mut used=0;
 for _ in 0..DATA[0] {
  let cx=i32le(DATA,off);let cy=i32le(DATA,off+4);let abbr=&DATA[off+8..off+10];let parts=u16le(DATA,off+10) as usize;off+=12;
  let color=if abbr==b"CA"&&m.scale>=1500 {PALETTE[2]}else{PALETTE[1]};
  for _ in 0..parts {let n=u16le(DATA,off) as usize;off+=2;polygon(s,m,cx,cy,off,n,color,clip);off+=n*4;}
  if m.scale>=1500 {let (x,y)=m.point(cx,cy);if x>MAP.x+16&&x<MAP.r-16&&y>MAP.y+8&&y<MAP.b-20 {let box_=Bounds{x:x-14,y:y-10,r:x+14,b:y+10};if !labels[..used].iter().any(|b|b.x<=box_.r&&b.r>=box_.x&&b.y<=box_.b&&b.b>=box_.y) {labels[used]=box_;used+=1;text(s,x-10,y-8,core::str::from_utf8(abbr).unwrap_or(""),0,if abbr==b"CA"{PALETTE[13]}else{PALETTE[9]});}}}
 }
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn all_states_dc_alaska_and_hawaii_are_embedded() {
  assert_eq!(DATA[0],51);let mut off=1;let mut names=vec![];
  for _ in 0..DATA[0] {names.push(&DATA[off+8..off+10]);let n=u16le(DATA,off+10);off+=12;for _ in 0..n {let len=u16le(DATA,off) as usize;assert!((4..=1131).contains(&len));off+=2+len*4;}}
  assert_eq!(off,DATA.len());for name in [b"AK",b"HI",b"CA",b"NY",b"DC"] {assert!(names.contains(&name.as_slice()));}
 }
}
