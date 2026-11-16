//! Optional local stock GNSS service (loader v4). No diagnostic location logging.
use crate::Api;
static mut CMD:[u8;20]=[0;20];static mut READING:[u8;24]=[0;24];
#[derive(Clone,Copy)]pub struct WatchGps {pub on:bool,pub live:bool,pub known:bool,pub satellites:Option<u8>,pub x:i32,pub y:i32,pub age_ms:u32}
impl Api {
 fn gps_request(&self,op:u8,ptr:u64,len:u32)->i32 {
  if self.abi_minor<2{return -95;}
  let b=unsafe{&mut *(&raw mut CMD)};b[..8].copy_from_slice(&[0x16,16,0,0,op,0,0,0]);b[8..16].copy_from_slice(&ptr.to_le_bytes());b[16..20].copy_from_slice(&len.to_le_bytes());(self.lv_submit)(b.as_ptr(),b.len())
 }
 pub fn watch_gps(&self,on:bool)->i32 {self.gps_request(on as u8,0,0)}
 pub fn watch_gps_read(&self)->Option<WatchGps> {
  let b=unsafe{&mut *(&raw mut READING)};if self.gps_request(2,b.as_mut_ptr() as u64,24)!=0{return None;}
  let word=|i|u32::from_le_bytes(b[i..i+4].try_into().unwrap());Some(WatchGps{on:b[0]!=0,live:b[1]!=0,known:b[3]!=0,satellites:(b[2]<=100).then_some(b[2]),x:word(4) as i32,y:word(8) as i32,age_ms:word(12)})
 }
}
