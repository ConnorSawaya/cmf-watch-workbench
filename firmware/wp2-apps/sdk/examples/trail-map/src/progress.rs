//! Receiver-confirmed bytes. Packet arrival renews the timer, never the percent.
#[derive(Clone,Copy)]pub struct Progress{pub kind:u8,pub phase:u8,pub done:u32,pub total:u32,pub at:u32}
impl Progress{
 pub const fn new()->Self{Self{kind:0,phase:0,done:0,total:0,at:0}}
 pub fn begin(&mut self,kind:u8,total:u32,done:u32,now:u32){*self=Self{kind,phase:1,done:done.min(total),total,at:now};}
 pub fn received(&mut self,n:u32,now:u32){self.done=n.min(self.total);self.at=now;self.phase=if self.done==self.total{2}else{1};}
 pub fn finish(&mut self,ok:bool,now:u32){self.phase=if ok{3}else{4};self.at=now;}
 pub fn visible(self,now:u32)->bool{self.total>0&&(self.phase<=2||now.wrapping_sub(self.at)<2500)}
 pub fn percent(self)->u32{if self.total==0{0}else if self.phase==3{100}else{(self.done as u64*100/self.total as u64).min(99) as u32}}
 pub fn waiting(self,now:u32)->bool{self.phase<=2&&now.wrapping_sub(self.at)>5000}
}
#[cfg(test)]mod tests{use super::*;
 #[test]fn resume_wait_and_completion_are_truthful(){let mut p=Progress::new();p.begin(2,1000,250,u32::MAX-100);assert_eq!(p.percent(),25);assert!(p.waiting(6000));p.received(1000,7000);assert_eq!(p.percent(),99);p.finish(false,7001);assert_ne!(p.percent(),100);p.begin(2,1000,1000,8000);p.finish(true,8001);assert_eq!(p.percent(),100);assert!(!p.visible(11000));}
}
