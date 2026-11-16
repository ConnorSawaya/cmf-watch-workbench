//! Loader v3 optional cache service, through the unchanged ABI 1.2 entry.
use crate::Api;
const PROBE:i32=0x43414331;
// lv_submit's command record must be in the app block, not on its 8 KiB stack.
// Apps have one thread; this synchronous service cannot re-enter the app.
static mut COMMAND:[u8;20]=[0;20];
impl Api {
 fn cache_request(&self,op:u8,index:u8,ptr:u64,len:usize)->i32 {
  if self.abi_minor<2 {return -95;}
  let b=unsafe{&mut *(&raw mut COMMAND)};b[..8].copy_from_slice(&[0x14,16,0,0,op,index,0,0]);b[8..16].copy_from_slice(&ptr.to_le_bytes());b[16..20].copy_from_slice(&(len as u32).to_le_bytes());(self.lv_submit)(b.as_ptr(),b.len())
 }
 pub fn cache_available(&self)->bool {self.cache_request(0,0,0,0)==PROBE}
 /// Read a 32-byte record descriptor, returning the complete stored length.
 pub fn cache_peek(&self,index:u8,buf:&mut [u8])->i32 {if buf.len()<32 {return -1;}self.cache_request(1,index,buf.as_mut_ptr() as u64,32)}
 /// Read a complete checksum-verified record into an app-owned buffer.
 pub fn cache_get(&self,index:u8,buf:&mut [u8])->i32 {self.cache_request(2,index,buf.as_mut_ptr() as u64,buf.len())}
 /// Atomically replace one of eight records (32..=32768 bytes).
 pub fn cache_put(&self,index:u8,data:&[u8])->i32 {self.cache_request(3,index,data.as_ptr() as u64,data.len())}
 pub fn cache_clear(&self)->i32 {self.cache_request(4,0,0,0)}
}
