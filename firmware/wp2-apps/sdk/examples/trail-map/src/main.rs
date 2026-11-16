#![cfg_attr(any(target_os="none",wp2_sim),no_main,cfg_attr(target_os="none",no_std))]
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod model;
mod places;
mod progress;
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod view;
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod raster;
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod states;
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod interaction;
#[cfg_attr(not(target_os="none"),allow(dead_code))] mod cache;
#[cfg(not(any(target_os="none",wp2_sim)))] fn main() {}
#[cfg(any(target_os="none",wp2_sim))] mod device {
 use cmf_wp2_app::{Api,BUTTON,CROWN,TOUCH_DOWN,TOUCH_MOVE,TOUCH_UP,MESSAGE,PAUSE,RESUME,MSG_MAX};
 use crate::{cache::MapCache,model::{Model,STORE_CAP},view,interaction::{Wake,FRAME_MS,zoom}};
 cmf_wp2_app::entry!(main);
 static mut STATE:Model=Model::new();
 static mut CACHE:MapCache=MapCache::new();
 // Non-personal emulator counters: frames, last/max rendering milliseconds.
 #[unsafe(no_mangle)] static mut MAP_PERF:[u32;3]=[0;3];
 impl view::Surface for &Api {fn rect(&mut self,x:i32,y:i32,w:i32,h:i32,c:u16) {if w>0&&h>0 {Api::rect(self,x as i16,y as i16,w as u16,h as u16,c);}}fn offline(&mut self,m:&Model,clip:view::Bounds,overlay:bool)->Option<[u8;40]>{let(x,y)=m.viewport();let result=self.offline_draw(x,y,m.scale,[clip.x,clip.y,clip.r,clip.b],m.fix.map(|f|(f.x,f.y)),overlay);if result.is_some()&&!m.preview {if let Some(labels)=self.offline_labels(){view::native_labels(self,&labels,clip);}}result}}
 fn offline_status(api:&Api,m:&mut Model){if let Some(info)=api.offline_info(){m.offline=crate::model::u32le(&info,4)>0;let mut b=[0;28];b[..4].copy_from_slice(&[84,77,1,0x34]);b[4..].copy_from_slice(&info);let _=api.send(&b);}}
 #[inline(never)]
 fn save(api:&Api,m:&Model)->i32 {let mut b=[0;STORE_CAP];let n=m.store(&mut b);api.save(&b[..n])}
 fn paint(api:&Api,m:&Model,full:bool) {let start=api.now();if full {view::full(&mut &*api,m,start);}else{view::map(&mut &*api,m,start,view::MAP);}api.show();let ms=api.now().wrapping_sub(start);unsafe{let p=&mut *(&raw mut MAP_PERF);p[0]+=1;p[1]=ms;p[2]=p[2].max(ms);}}
 fn cached(api:&Api,m:&Model,cache:&MapCache) {if m.raster.valid&&m.viewport()==(m.raster.x,m.raster.y)&&m.scale==m.raster.scale {let _=api.send(&MapCache::notice(m));}else{let _=api.send(&m.request());}let _=api.send(&cache.status());}
 #[inline(never)]
 fn places(api:&Api,m:&mut Model,msg:&[u8])->i32 {match msg[3]{
  0x40 if msg.len()==6=>{let n=crate::model::u16le(msg,4) as usize;if !(12..=crate::places::CAP).contains(&n){return -22;}m.place_want=n;m.place_got=0;0},
  0x41 if msg.len()>6=>{let offset=crate::model::u16le(msg,4) as usize;let data=&msg[6..];if m.place_want==0||offset!=m.place_got||data.len()>m.place_want-m.place_got{return -22;}m.raster.workspace()[offset..offset+data.len()].copy_from_slice(data);m.place_got+=data.len();m.place_got as i32},
  0x42 if msg.len()==4=>{let want=m.place_want;if want==0||m.place_got!=want||!crate::places::Places::valid(&m.raster.workspace()[..want]){return -22;}let mut b=[0;STORE_CAP];let n=m.store(&mut b);let prior=if m.places.count>0||m.places.crc!=0{12+m.places.count*crate::places::RECORD}else{0};let end=n-prior;b[end..end+want].copy_from_slice(&m.raster.workspace()[..want]);let rc=api.save(&b[..end+want]);if rc==0{m.places.restore(&b[end..end+want]);m.place_want=0;}rc},_=>-22}}
 fn main(api:&'static Api)->i32 {
  let mut wake=Wake::new();wake.touch(api.now());api.keep_screen_on(true);
  let m=unsafe{&mut *(&raw mut STATE)};let n=api.load(m.raster.workspace());if n>0 {m.restore_staged(n as usize);}
  let cache=unsafe{&mut *(&raw mut CACHE)};let restored=cache.boot(api,m);
  let _=api.watch_gps(true);let mut gps_at=api.now().wrapping_sub(1000);
  offline_status(api,m);let _=api.send(&m.places.notice());
  api.own_back(true);paint(api,m,true);let _=api.send(b"TM\x01\x10");if restored {cached(api,m,cache);}else{let _=api.send(&cache.status());}
  let mut buf=[0u8;MSG_MAX];let mut paused=false;let mut live=m.fresh(api.now());let mut last_save=0u32;let mut saved_fix=None;let mut age_bucket=u32::MAX;let mut gesture_at=api.now();let mut request_at=0u32;
  let mut queued=None;let mut dirty=false;let mut full=false;let mut frame_at=api.now();let mut cache_pending=false;let mut cache_lookup=false;let mut status_at=0u32;let mut progress_key=(0,0,0,0);
  loop {
   let now=api.now();
   if !paused&&now.wrapping_sub(status_at)>=200{status_at=now;let p=m.progress;let key=(p.phase,p.done/1000,p.percent(),p.visible(now) as u8+2*p.waiting(now) as u8);if key!=progress_key{progress_key=key;view::status(&mut &*api,m,now);api.show();}}
   if let Some(f)=m.fix.filter(|f|f.watch&&f.fresh(now)) {let moved=saved_fix.is_none_or(|(x,y):(i32,i32)|(f.x-x).abs()+(f.y-y).abs()>100);if saved_fix.is_none()||(now.wrapping_sub(last_save)>60_000&&moved)||now.wrapping_sub(last_save)>300_000 {if save(api,m)==0 {last_save=now;saved_fix=Some((f.x,f.y));}}}
   if !paused&&now.wrapping_sub(gps_at)>=1000 {gps_at=now;let old=view::marker_bounds(m);let camera=m.viewport();if let Some(g)=api.watch_gps_read(){let on=g.on;let sat=g.satellites.unwrap_or(255);let changed=m.watch_fix(g,now);if camera!=m.viewport(){dirty=true;}else if changed&&!dirty {view::position_update(&mut &*api,m,now,old);api.show();}let _=api.send(&[84,77,1,0x17,on as u8,m.fix.is_some_and(|f|f.watch&&f.fresh(now)) as u8,sat]);}}
   if wake.expire(now) {api.keep_screen_on(false);}
   if !paused {
    if m.preview&&m.drag.is_none()&&now.wrapping_sub(gesture_at)>120 {m.preview=false;dirty=true;}
    if cache_lookup&&m.drag.is_none()&&now.wrapping_sub(gesture_at)>120 {cache_lookup=false;if cache.select(api,m){cached(api,m,cache);dirty=true;}}
    if cache_pending&&!dirty&&m.drag.is_none()&&now.wrapping_sub(gesture_at)>600 {if cache.save(api,m) {let _=api.send(&cache.status());}cache_pending=false;if m.progress.kind==1&&m.progress.phase==2{m.progress.finish(cache.available&&cache.last_error==0,api.now());}}
    // Consume a burst into one camera update; do not queue a repaint per detent.
    if dirty&&now.wrapping_sub(frame_at)>=FRAME_MS {paint(api,m,full);dirty=false;full=false;frame_at=api.now();live=m.fresh(frame_at);}
    if m.browsing&&m.drag.is_none()&&m.needs_detail()&&now.wrapping_sub(gesture_at)>300&&now.wrapping_sub(request_at)>1000 {if api.send(&m.request())==0 {request_at=now;}}
   }
   let mut wait=if paused {u32::MAX}else{wake.wait(now)};
   if !paused {wait=wait.min(if m.progress.visible(now){200}else{1000});if dirty {wait=wait.min(FRAME_MS.saturating_sub(now.wrapping_sub(frame_at)));}if cache_pending||cache_lookup||m.preview||m.browsing&&m.needs_detail() {wait=wait.min(100);}}
   let Some(e)=queued.take().or_else(||api.event(wait)) else {
    let now=api.now();let bucket=m.fix.map_or(u32::MAX,|f|f.age(now)/60);
    if !paused&&!dirty {if m.fresh(now)!=live {if !m.fresh(now) {_=save(api,m);}view::position_update(&mut &*api,m,now,view::marker_bounds(m));api.show();live=m.fresh(now);}else if !live&&bucket!=age_bucket {view::status(&mut &*api,m,now);api.show();}}
    age_bucket=bucket;continue;
   };
   if !paused&&matches!(e.kind,CROWN|TOUCH_DOWN|TOUCH_MOVE|TOUCH_UP) {if wake.touch(api.now()) {api.keep_screen_on(true);}}
   match e.kind {
    BUTTON if e.delta==1=>continue,
    BUTTON=>{let _=api.watch_gps(false);api.keep_screen_on(false);if cache_pending||cache.last_error!=0 {cache.save(api,m);}if m.len>0||m.fix.is_some() {_=save(api,m);}return 0;},
    PAUSE=>{paused=true;m.drag=None;wake.off();api.keep_screen_on(false);},
    RESUME=>{paused=false;wake.touch(api.now());api.keep_screen_on(true);dirty=true;full=true;let _=api.send(b"TM\x01\x10");cached(api,m,cache);},
    MESSAGE if !paused=>{
     let old=view::marker_bounds(m);let mut changed=false;
     while let Some(msg)=api.recv(&mut buf) {
      if msg.len()>=4&&msg[..3]==[84,77,1]&&(0x40..=0x43).contains(&msg[3]){let op=msg[3];if op==0x43{let _=api.send(&m.places.notice());continue;}let rc=places(api,m,msg);let mut ack=[84,77,1,op+0x80,0,0,0,0];ack[4..].copy_from_slice(&rc.to_le_bytes());let _=api.send(&ack);if op==0x42&&rc==0{let _=api.send(&m.places.notice());dirty=true;}continue;}
      if msg.len()>=4&&msg[..3]==[84,77,1]&&(0x30..=0x33).contains(&msg[3]) {
       let op=msg[3];if op==0x33{offline_status(api,m);continue;}
       let result=match op{0x30 if msg.len()==16=>api.offline_begin(&msg[4..]),0x31 if msg.len()>9=>api.offline_write(crate::model::u32le(msg,4),&msg[9..]),0x32 if msg.len()==4=>api.offline_commit(),_=>-22};
       if result>=0{match op{0x30=>m.progress.begin(2,crate::model::u32le(msg,4),result as u32,api.now()),0x31=>m.progress.received(result as u32,api.now()),_=>m.progress.finish(true,api.now())}}else{m.progress.finish(false,api.now());}
       wake.touch(api.now());api.keep_screen_on(true);
       if op!=0x31||msg.get(8)==Some(&1)||result<0 {let mut ack=[84,77,1,op+0x80,0,0,0,0];ack[4..8].copy_from_slice(&result.to_le_bytes());let _=api.send(&ack);}
       if op==0x32&&result==0{offline_status(api,m);dirty=true;full=true;}continue;
      }
      if msg.len()>=4&&(0x20..=0x22).contains(&msg[3]){wake.touch(api.now());api.keep_screen_on(true);}
      if msg==b"TM\x01\x13" {let _=api.send(&cache.status());continue;}
      let before=m.fix;let (status,commit)=m.accept(msg,api.now());
      if msg.len()>=6&&(msg[3]==1||msg[3]==3||msg[3]==0x20||msg[3]==0x22) {let mut ack=[b'T',b'M',1,0x80,msg[4],msg[5],status];if commit&&msg[3]==3&&save(api,m)!=0 {ack[6]=4;}let _=api.send(&ack);}
      if status==0 {
       dirty|=commit;full|=commit&&msg[3]==3;cache_pending|=commit&&msg[3]==0x22;
       let invalidate=msg[3]==5&&before.is_some_and(|f|f.live);
       changed|=before.map(|f|(f.x,f.y,f.accuracy,f.fresh(api.now()),f.satellites))!=m.fix.map(|f|(f.x,f.y,f.accuracy,f.fresh(api.now()),f.satellites))||invalidate;
       if let Some(f)=m.fix {let moved=saved_fix.is_none_or(|(x,y):(i32,i32)|(f.x-x).abs()+(f.y-y).abs()>100);if saved_fix.is_none()||invalidate||(api.now().wrapping_sub(last_save)>60_000&&moved)||api.now().wrapping_sub(last_save)>300_000 {if save(api,m)==0 {last_save=api.now();saved_fix=Some((f.x,f.y));}}}
      }
     }
     if changed&&!dirty {view::position_update(&mut &*api,m,api.now(),old);api.show();live=m.fresh(api.now());}
    },
    CROWN if !paused=>{
     let mut next=zoom(m.scale,e.delta);
     // Drain queued crown events before rendering an obsolete camera.
     for _ in 0..24 {let Some(event)=api.event(0) else{break;};if event.kind==CROWN {next=zoom(next,event.delta);}else{queued=Some(event);break;}}
     if next!=m.scale {m.scale=next;m.browsing=true;m.preview=true;m.drag=None;gesture_at=api.now();cache_lookup=true;dirty=true;}
    },
    TOUCH_DOWN if !paused=>{m.start_drag(e.x,e.y);},
    TOUCH_MOVE if !paused=>{if m.move_drag(e.x,e.y) {m.preview=true;gesture_at=api.now();dirty=true;}},
    TOUCH_UP if !paused=>{m.drag=None;gesture_at=api.now();cache_lookup=true;},
    _=>{},
   }
  }
 }
}
