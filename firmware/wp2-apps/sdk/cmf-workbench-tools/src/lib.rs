#![cfg_attr(not(test), no_std)]

use cmf_wp2_app::{Api,BUTTON,CROWN,PAUSE,RESUME,TOUCH_UP};

#[derive(Clone,Copy,PartialEq,Debug)]
pub enum Kind {Stopwatch,Intervals,Counter}

#[derive(Default,Debug)]
pub struct Stopwatch {pub running:bool, accumulated:u64, started:u32, pub lap:Option<u64>}
impl Stopwatch {
    pub fn elapsed(&self,now:u32)->u64 {self.accumulated+if self.running {now.wrapping_sub(self.started) as u64}else{0}}
    pub fn toggle(&mut self,now:u32) {if self.running {self.accumulated=self.elapsed(now);}else{self.started=now;}self.running=!self.running;}
    pub fn reset(&mut self) {if !self.running {*self=Self::default();}}
    pub fn mark(&mut self,now:u32) {self.lap=Some(self.elapsed(now));}
}

pub struct Intervals {pub work:u32,pub rest:u32,pub rounds:u32,pub remaining:u32,pub round:u32,pub resting:bool,pub running:bool,pub finished:bool,at:u32}
impl Default for Intervals {fn default()->Self {Self{work:30,rest:15,rounds:5,remaining:30_000,round:1,resting:false,running:false,finished:false,at:0}}}
impl Intervals {
    pub fn reset(&mut self) {self.remaining=self.work*1000;self.round=1;self.resting=false;self.running=false;self.finished=false;}
    pub fn toggle(&mut self,now:u32) {self.tick(now);if self.finished {self.reset();}self.running=!self.running;self.at=now;}
    pub fn tick(&mut self,now:u32)->bool {
        if !self.running{return false;}let mut elapsed=now.wrapping_sub(self.at);self.at=now;let mut changed=false;
        while elapsed>=self.remaining {
            elapsed-=self.remaining;changed=true;
            if self.resting {self.round+=1;self.resting=false;self.remaining=self.work*1000;}
            else if self.round>=self.rounds {self.running=false;self.finished=true;self.remaining=0;return true;}
            else {self.resting=true;self.remaining=self.rest*1000;}
        }
        self.remaining-=elapsed;changed
    }
    pub fn adjust(&mut self,field:u8,delta:i16) {if self.running{return;}match field {0=>self.work=(self.work as i32+delta as i32*5).clamp(5,3600) as u32,1=>self.rest=(self.rest as i32+delta as i32*5).clamp(5,3600) as u32,_=>self.rounds=(self.rounds as i32+delta as i32).clamp(1,99) as u32}self.reset();}
}

include!("font-data.rs");
const FONT:&[u8]=include_bytes!("font-data.bin");
const BG:u16=0x0000;const FG:u16=0xef7d;const DIM:u16=0x8c51;const ORANGE:u16=0xeb05;
fn text(api:&Api,x:i16,y:i16,t:&str,size:usize,c:u16) {
    let mut x=x;
    for ch in t.bytes() {
        let (offset,w,h,advance)=GLYPHS[size*95+(ch.clamp(32,126)-32) as usize];let offset=offset as usize;
        for row in 0..h as usize {let mut col=0;while col<w as usize {
            let alpha=(FONT[offset+(row*w as usize+col)/4]>>(6-2*((row*w as usize+col)%4)))&3;let start=col;col+=1;
            while col<w as usize && ((FONT[offset+(row*w as usize+col)/4]>>(6-2*((row*w as usize+col)%4)))&3)==alpha {col+=1;}
            if alpha>0 {let a=alpha as u16;let color=(((c>>11)*a/3)<<11)|((((c>>5)&63)*a/3)<<5)|((c&31)*a/3);api.rect(x+start as i16,y+row as i16,(col-start) as u16,1,color);}
        }}
        x+=advance as i16;
    }
}
fn width(t:&str,size:usize)->i16 {t.bytes().map(|c|GLYPHS[size*95+(c.clamp(32,126)-32) as usize].3 as i16).sum()}
fn center(api:&Api,y:i16,t:&str,size:usize,c:u16){text(api,233-width(t,size)/2,y,t,size,c);}
struct Label {data:[u8;64],len:usize}
impl Label {
    fn new()->Self {Self{data:[0;64],len:0}}
    fn add(&mut self,s:&str){let n=s.len().min(self.data.len()-self.len);self.data[self.len..self.len+n].copy_from_slice(&s.as_bytes()[..n]);self.len+=n;}
    fn number(&mut self,mut n:u64){let mut b=[0;20];let mut i=20;loop {i-=1;b[i]=b'0'+(n%10) as u8;n/=10;if n==0 {break;}}self.add(core::str::from_utf8(&b[i..]).unwrap_or("?"));}
    fn value(&self)->&str {core::str::from_utf8(&self.data[..self.len]).unwrap_or("")}
}
fn time_label(ms:u64)->Label {let seconds=ms/1000;let mut b=Label::new();if seconds>=3600{b.number(seconds/3600);b.add(":");}if seconds/60%60<10{b.add("0");}b.number(seconds/60%60);b.add(":");if seconds%60<10{b.add("0");}b.number(seconds%60);b}
fn digits(api:&Api,s:&str,y:i16) {
    const SEG:[u8;10]=[0x3f,0x06,0x5b,0x4f,0x66,0x6d,0x7d,0x07,0x7f,0x6f];
    let total=s.bytes().map(|b|if b==b':'{20}else{54}).sum::<i16>();let mut x=233-total/2;
    for b in s.bytes() {if b==b':'{api.rect(x+5,y+20,7,7,ORANGE);api.rect(x+5,y+48,7,7,ORANGE);x+=20;continue;}
        if !b.is_ascii_digit(){continue;}let mask=SEG[(b-b'0') as usize];
        for (i,(dx,dy,w,h)) in [(6,0,32,5),(38,5,5,29),(38,38,5,29),(6,67,32,5),(1,38,5,29),(1,5,5,29),(6,33,32,5)].into_iter().enumerate(){if mask&(1<<i)!=0 {api.rect(x+dx,y+dy,w,h,FG);}}
        x+=54;
    }
}
fn buttons(api:&Api,left:&str,right:&str){api.rect(60,324,168,51,0x18e3);api.rect(238,324,168,51,0x18e3);text(api,144-width(left,1)/2,338,left,1,FG);text(api,322-width(right,1)/2,338,right,1,FG);}

pub fn run(api:&'static Api,kind:Kind)->i32 {
    let mut watch=Stopwatch::default();let mut intervals=Intervals::default();let mut count=0u32;let mut record=[0;8];let mut field=0u8;
    if kind==Kind::Counter && api.load(&mut record)==8 && record[..4]==*b"CT01" {count=u32::from_le_bytes(record[4..8].try_into().unwrap()).min(999999);}
    let mut dirty=false;let mut save_at=api.now();let mut paused=false;let mut vibration=None;let mut redraw=true;let mut last_frame=0;let mut wake_at=api.now();api.keep_screen_on(true);
    loop {
        let now=api.now();
        if intervals.tick(now) && !paused {let _=api.vibrate(350,31);vibration=Some(now);redraw=true;}
        if vibration.is_some_and(|at|now.wrapping_sub(at)>=30){api.vibrate(0,31);vibration=None;}
        if dirty&&now.wrapping_sub(save_at)>=1000 {record[..4].copy_from_slice(b"CT01");record[4..].copy_from_slice(&count.to_le_bytes());if api.save(&record)==0{dirty=false;redraw=true;}save_at=now;}
        if now.wrapping_sub(wake_at)>=120_000 {api.keep_screen_on(false);}
        if !paused && (redraw || ((watch.running||intervals.running)&&now.wrapping_sub(last_frame)>=100)) {
            last_frame=now;redraw=false;api.rect(0,0,466,466,BG);
            center(api,57,match kind{Kind::Stopwatch=>"STOPWATCH",Kind::Intervals=>"INTERVALS",Kind::Counter=>"COUNTER"},1,DIM);
            api.rect(199,97,68,3,ORANGE);
            match kind {
                Kind::Stopwatch=>{
                    center(api,135,if watch.running{"Running"}else{"Paused"},1,ORANGE);digits(api,time_label(watch.elapsed(now)).value(),193);
                    if let Some(lap)=watch.lap {let mut b=Label::new();b.add("Lap  ");b.add(time_label(lap).value());center(api,285,b.value(),0,DIM);}
                    buttons(api,if watch.running{"Pause"}else{"Start"},if watch.running{"Lap"}else{"Reset"});
                    center(api,405,"Button to close",0,DIM);
                },
                Kind::Intervals=>{
                    let mut b=Label::new();b.add(if intervals.finished{"Complete"}else if intervals.resting{"Rest"}else{"Work"});b.add("  ");b.number(intervals.round as u64);b.add(" / ");b.number(intervals.rounds as u64);center(api,131,b.value(),1,ORANGE);
                    digits(api,time_label((intervals.remaining as u64+999)/1000*1000).value(),188);
                    let mut b=Label::new();b.add(match field{0=>"Work ",1=>"Rest ",_=>"Rounds "});b.number(match field{0=>intervals.work,1=>intervals.rest,_=>intervals.rounds} as u64);if field<2{b.add("s");}center(api,281,b.value(),0,DIM);
                    buttons(api,if intervals.running{"Pause"}else{"Start"},"Reset");center(api,405,"Tap setting; crown to edit",0,DIM);
                },
                Kind::Counter=>{let mut b=Label::new();b.number(count as u64);digits(api,b.value(),193);center(api,135,"Tap + or turn the crown",0,ORANGE);buttons(api,"-","+");center(api,405,if dirty{"Saving..."}else{"Saved on watch"},0,DIM);},
            }
            api.show();
        }
        let Some(e)=api.event(if paused{1000}else{50}) else{continue};
        match e.kind {
            BUTTON=>break,
            PAUSE=>{paused=true;api.vibrate(0,31);vibration=None;api.keep_screen_on(false);},
            RESUME=>{paused=false;wake_at=api.now();api.keep_screen_on(true);redraw=true;},
            TOUCH_UP|CROWN if !paused=>{
                wake_at=api.now();api.keep_screen_on(true);redraw=true;
                match kind {
                    Kind::Stopwatch if e.kind==TOUCH_UP=>{if e.y>=320&&e.x>=238 {if watch.running{watch.mark(now);}else{watch.reset();}}else{watch.toggle(now);}},
                    Kind::Intervals=>{if e.kind==CROWN{intervals.adjust(field,e.delta);}else if e.y>=270&&e.y<318{field=(field+1)%3;}else if e.y>=320&&e.x>=238{intervals.reset();}else{intervals.toggle(now);}},
                    Kind::Counter=>{let delta=if e.kind==CROWN{e.delta as i32}else if e.y>=320&&e.x<233{-1}else{1};let next=(count as i32+delta).clamp(0,999999) as u32;if count!=next{count=next;dirty=true;}},
                    _=>{},
                }
            },
            _=>{},
        }
    }
    if dirty {record[..4].copy_from_slice(b"CT01");record[4..].copy_from_slice(&count.to_le_bytes());api.save(&record);}
    api.vibrate(0,31);api.keep_screen_on(false);0
}

#[cfg(test)] mod tests {
    use super::*;
    #[test] fn stopwatch_pause_lap_and_wrap(){let mut s=Stopwatch::default();s.toggle(u32::MAX-99);assert_eq!(s.elapsed(100),200);s.mark(100);s.toggle(200);assert_eq!(s.elapsed(500),300);assert_eq!(s.lap,Some(200));s.reset();assert_eq!(s.elapsed(600),0);}
    #[test] fn timer_transitions_and_catches_up(){let mut t=Intervals::default();t.work=5;t.rest=5;t.rounds=2;t.reset();t.toggle(0);assert!(t.tick(6000));assert!(t.resting);assert_eq!(t.remaining,4000);assert!(t.tick(15000));assert!(t.finished);assert!(!t.running);}
    #[test] fn timer_pause_preserves_remaining(){let mut t=Intervals::default();t.toggle(0);t.toggle(4000);assert_eq!(t.remaining,26000);t.tick(10000);assert_eq!(t.remaining,26000);t.toggle(12000);t.tick(14000);assert_eq!(t.remaining,24000);}
    #[test] fn editor_stays_bounded(){let mut t=Intervals::default();t.adjust(0,-300);assert_eq!(t.work,5);t.adjust(1,30000);assert_eq!(t.rest,3600);t.adjust(2,300);assert_eq!(t.rounds,99);}
}
