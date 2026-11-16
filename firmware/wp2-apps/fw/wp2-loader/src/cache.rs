//! Two copies per bounded cache entry. A cut/failed write never replaces the
//! latest valid copy; only a complete checksum-checked record is returned.
use wp2_core::{cache as c,fs,layout::stub_ram,pkg::crc32};
use core::sync::atomic::{AtomicU32,Ordering};
static OWNER:AtomicU32=AtomicU32::new(0);
pub fn start(name:&[u8;24]) {OWNER.store(crc32(0,name),Ordering::Relaxed);}
fn head(path:&[u8],owner:u32)->Option<(usize,u32,u32)> {let mut f=[0;0x2C];if fs::open(&mut f,path,fs::READ)<0 {return None;}let mut h=[0;c::HEADER];let r=if fs::read_exact(&mut f,&mut h) {c::parse(&h,owner)}else{None};fs::close(&mut f);r}
fn read(path:&[u8],owner:u32,out:&mut [u8],peek:bool)->i32 {
 let mut f=[0;0x2C];if fs::open(&mut f,path,fs::READ)<0 {return 0;}
 let mut h=[0;c::HEADER];let mut result=-5;
 if fs::read_exact(&mut f,&mut h) {if let Some((len,crc,_))=c::parse(&h,owner) {
  if !peek&&out.len()<len {result=-1;}else {
   let mut scratch=[0;256];let mut left=len;let mut got=0;let mut sum=0;let mut ok=true;
   while left>0 {let n=left.min(scratch.len());if !fs::read_exact(&mut f,&mut scratch[..n]) {ok=false;break;}sum=crc32(sum,&scratch[..n]);let copy=n.min(out.len().saturating_sub(got));if copy>0 {out[got..got+copy].copy_from_slice(&scratch[..copy]);}got+=n;left-=n;}
   let mut tail=[0];if ok&&sum==crc&&fs::read(&mut f,&mut tail)==0 {result=len as i32;}
  }
 }}
 fs::close(&mut f);result
}
fn order(slot:u8,index:u8,owner:u32)->[bool;2] {let a=head(&c::path(slot,index,false),owner);let b=head(&c::path(slot,index,true),owner);if b.is_some_and(|b|a.is_none_or(|a|c::newer(b.2,a.2))) {[true,false]}else{[false,true]}}
pub fn handle(r:c::Request)->i32 {
 let ram=stub_ram();let slot=ram.running_slot;if slot>=8 {return -5;}
 if r.op==0 {return c::PROBE;}
 let owner=OWNER.load(Ordering::Relaxed);
 if r.op==4 {for i in 0..c::SLOTS as u8 {for copy in [false,true] {fs::unlink(&c::path(slot,i,copy));}}return 0;}
 if r.ptr>usize::MAX as u64 {return -22;}
 let p=r.ptr as usize;let base=ram.app_block as usize;let size=ram.app_size as usize;
 if p<base||p-base>size||r.len>size-(p-base) {return -22;}
 if r.op==1||r.op==2 {
  let out=unsafe{core::slice::from_raw_parts_mut(p as *mut u8,r.len)};let mut last=0;
  for copy in order(slot,r.index,owner) {let n=read(&c::path(slot,r.index,copy),owner,out,r.op==1);if n>0 {return n;}if n<0 {last=n;}}
  return last;
 }
 let data=unsafe{core::slice::from_raw_parts(p as *const u8,r.len)};
 // Validate existing copies using a small streaming buffer before choosing the
 // inactive one. Even a previously interrupted write remains recoverable.
 let mut meta=[0;c::META];let mut active=None;
 for copy in order(slot,r.index,owner) {let path=c::path(slot,r.index,copy);if read(&path,owner,&mut meta,true)>0 {active=head(&path,owner).map(|h|(copy,h.2));break;}}
 let target=active.map_or(false,|a|!a.0);let generation=active.map_or(1,|a|a.1.wrapping_add(1));let path=c::path(slot,r.index,target);
 fs::unlink(&path);let Some((free,unit))=fs::free_space(&path) else{return -5;};if !c::room(free,unit,r.len) {return -28;}let mut file=[0;0x2C];if fs::open(&mut file,&path,fs::WRITE|fs::CREATE)<0 {return -5;}
 let h=c::header(owner,generation,data);let ok=fs::write(&mut file,&h)==h.len() as i32&&fs::write(&mut file,data)==data.len() as i32;
 let closed=fs::close(&mut file);if !ok||closed<0 {fs::unlink(&path);return -5;}0
}
