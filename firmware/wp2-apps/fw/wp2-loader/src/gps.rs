//! Stock GPS service ownership. Location values are never logged in diagnostics.
use core::sync::atomic::{AtomicBool,AtomicU32,AtomicI32,Ordering};
use crate::app;
static WANT:AtomicBool=AtomicBool::new(false);static ON:AtomicBool=AtomicBool::new(false);
static FIX:AtomicBool=AtomicBool::new(false);static AT:AtomicU32=AtomicU32::new(0);
static X:AtomicI32=AtomicI32::new(0);static Y:AtomicI32=AtomicI32::new(0);static SATS:AtomicU32=AtomicU32::new(255);
const OWNER:u32=1;
// The stock command wrapper's "wait" flag does not install a completion
// callback. Supply the stock ROM semaphore callback explicitly. Semaphores
// live in reserved permanent stub RAM so a late ROM acknowledgement can never
// touch a released loader block (StubRam is asserted <=0xE00).
fn control(op:u8)->i32 {
 let sem=(wp2_core::layout::STUB_RAM+0xF00+op as u32*0x20) as *mut u8;
 let rc=stock!(0x101DAE77,fn(*mut u8,u32,u32)->i32)(sem,0,1);if rc<0{return rc;}
 let mut msg=[0u8;20];msg[2]=0x23;msg[3]=op;msg[4]=OWNER as u8;
 msg[12..16].copy_from_slice(&0x101AC72Fu32.to_le_bytes());msg[16..20].copy_from_slice(&(sem as u32).to_le_bytes());
 if stock!(0x101464B5,fn(*const u8,*const u8)->bool)(b"gps_service\0".as_ptr(),msg.as_ptr()) {
  stock!(0x101BE203,fn(*mut u8,i32)->i32)(sem,3000)
 }else{-16}
}
fn sample(ptr:*const u8) {
 if !ON.load(Ordering::Acquire)||ptr.is_null(){return;}
 // The stock service writes this shared snapshot on its own thread. Force
 // fresh loads rather than borrowing its concurrently updated memory.
 let mut snapshot=[0u8;104];for i in (0..104).step_by(4){snapshot[i..i+4].copy_from_slice(&unsafe{(ptr.add(i) as *const u32).read_volatile()}.to_le_bytes());}
 let b=&snapshot;let word=|i|u32::from_le_bytes(b[i..i+4].try_into().unwrap());
 let double=|i|u64::from_le_bytes(b[i..i+8].try_into().unwrap());
 if word(0x4c)!=1 {FIX.store(false,Ordering::Release);SATS.store(255,Ordering::Relaxed);return;}
 let (Some(lat),Some(lon))=(wp2_core::gps::micro(double(0x38)),wp2_core::gps::micro(double(0x40))) else{return;};
 if let Some((x,y))=wp2_core::gps::project(lat,lon) {X.store(x,Ordering::Relaxed);Y.store(y,Ordering::Relaxed);SATS.store(word(0x50).min(100),Ordering::Relaxed);AT.store(app::millis(),Ordering::Relaxed);FIX.store(true,Ordering::Release);}
}
pub fn request(on:bool)->i32 {WANT.store(on,Ordering::Release);0}
pub fn tick(running:bool,paused:bool) {
 let want=WANT.load(Ordering::Acquire)&&running&&!paused;
 if ON.load(Ordering::Acquire)&&unsafe{(0x380445AC as *const u32).read_volatile()}!=0x10101BED {ON.store(false,Ordering::Release);FIX.store(false,Ordering::Release);}
 if want==ON.load(Ordering::Acquire){return;}
 if want {
  // Only start an idle receiver with its normal stock listener. Read the
  // stock data snapshot; never register a pointer into unloadable code.
  if unsafe{(0x380443F5 as *const u8).read_volatile()}!=0||unsafe{(0x380445AC as *const u32).read_volatile()}!=0x10101BED{return;}
  FIX.store(false,Ordering::Release);ON.store(true,Ordering::Release);
  let rc=control(0);
  if rc<0 {ON.store(false,Ordering::Release);let _=control(1);}
 }else{
  ON.store(false,Ordering::Release);FIX.store(false,Ordering::Release);SATS.store(255,Ordering::Relaxed);
  if unsafe{(0x380445AC as *const u32).read_volatile()}!=0x10101BED{return;}
  // Keep the stock listener registered; it never calls into loader memory.
  let _=control(1);
 }
}
pub fn stop(){WANT.store(false,Ordering::Release);tick(false,false);}
pub fn read(out:&mut [u8])->i32 {
 if out.len()!=24{return -22;}
 if ON.load(Ordering::Acquire)&&unsafe{(0x380443F5 as *const u8).read_volatile()}==OWNER as u8 {sample(0x3800CD80 as *const u8);}
 out.fill(0);out[0]=ON.load(Ordering::Acquire) as u8;
 let at=AT.load(Ordering::Relaxed);let age=app::millis().wrapping_sub(at);let live=FIX.load(Ordering::Acquire)&&age<10_000;
 out[1]=live as u8;out[2]=if live{SATS.load(Ordering::Relaxed) as u8}else{255};out[3]=(at!=0) as u8;
 out[4..8].copy_from_slice(&X.load(Ordering::Relaxed).to_le_bytes());out[8..12].copy_from_slice(&Y.load(Ordering::Relaxed).to_le_bytes());out[12..16].copy_from_slice(&age.to_le_bytes());0
}
pub fn handle(b:&[u8])->i32 {
 if b.len()!=20||b[..4]!=[0x16,16,0,0]||b[5..8]!=[0,0,0]{return -22;}
 let p=u64::from_le_bytes(b[8..16].try_into().unwrap());let n=u32::from_le_bytes(b[16..20].try_into().unwrap()) as usize;
 if b[4]<=1&&p==0&&n==0{return request(b[4]==1);}
 if b[4]!=2||n!=24||p>usize::MAX as u64{return -22;}
 let r=wp2_core::layout::stub_ram();let base=r.app_block as usize;let size=r.app_size as usize;let p=p as usize;
 if p<base||p-base>size||n>size-(p-base){return -22;}
 read(unsafe{core::slice::from_raw_parts_mut(p as *mut u8,n)})
}
