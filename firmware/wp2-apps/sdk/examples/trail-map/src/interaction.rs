//! Interaction deadlines use the monotonic clock, including its u32 wrap.
pub const AWAKE_MS:u32=120_000;
pub const FRAME_MS:u32=60;
pub fn zoom(scale:i32,delta:i16)->i32 {
 const LEVELS:&[i32]=&[1,2,3,4,6,8,12,16,24,32,48,64,96,128,192,256,384,512,768,1024,1536,2048,3072,4096,6000,8192,12288,16384,24576,32768,40000,49152,60000];
 if delta>0 {*LEVELS.iter().rev().find(|&&s|s<scale).unwrap_or(&1)}else{*LEVELS.iter().find(|&&s|s>scale).unwrap_or(&60000)}
}
pub struct Wake {until:Option<u32>}
impl Wake {
 pub const fn new()->Self {Self{until:None}}
 pub fn touch(&mut self,now:u32)->bool {let changed=self.until.is_none();self.until=Some(now.wrapping_add(AWAKE_MS));changed}
 pub fn off(&mut self) {self.until=None;}
 pub fn wait(&self,now:u32)->u32 {self.until.map_or(u32::MAX,|t|(t.wrapping_sub(now) as i32).max(0) as u32)}
 pub fn expire(&mut self,now:u32)->bool {if self.wait(now)==0 {self.off();true}else{false}}
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn input_renews_wake_but_messages_do_not() {let mut w=Wake::new();assert!(w.touch(0));assert!(!w.touch(119_000));assert!(!w.expire(120_001));assert_eq!(w.wait(120_001),118_999);assert!(w.expire(239_000));assert!(!w.expire(240_000));assert_eq!(w.wait(240_000),u32::MAX);assert!(w.touch(240_001));w.off();assert_eq!(w.wait(240_002),u32::MAX);}
 #[test] fn zoom_is_reversible_and_capped() {for scale in [1,2,8,128,6000,40000,49152] {assert_eq!(zoom(zoom(scale,-1),1),scale);}assert_eq!(zoom(1,1),1);assert_eq!(zoom(60000,-1),60000);}
 #[test] fn deadline_survives_clock_wrap() {let mut w=Wake::new();w.touch(u32::MAX-1000);assert_eq!(w.wait(0),118_999);assert!(w.expire(119_000));}
}
