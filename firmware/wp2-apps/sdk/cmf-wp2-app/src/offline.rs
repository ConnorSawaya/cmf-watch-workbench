//! Optional fixed-path offline map service (loader v4).
use crate::Api;
static mut CMD:[u8;24]=[0;24];static mut DATA:[u8;128]=[0;128];static mut FRAME:[u8;80]=[0;80];
impl Api {
 fn map_request(&self,op:u8,ptr:u64,len:usize,offset:u32)->i32 {
  if self.abi_minor<2{return -95;}let b=unsafe{&mut *(&raw mut CMD)};b[..8].copy_from_slice(&[0x15,20,0,0,op,0,0,0]);b[8..16].copy_from_slice(&ptr.to_le_bytes());b[16..20].copy_from_slice(&(len as u32).to_le_bytes());b[20..24].copy_from_slice(&offset.to_le_bytes());(self.lv_submit)(b.as_ptr(),b.len())
 }
 pub fn offline_info(&self)->Option<[u8;24]>{let b=unsafe{&mut *(&raw mut DATA)};if self.map_request(0,b.as_mut_ptr() as u64,24,0)!=0{return None;}Some(b[..24].try_into().unwrap())}
 pub fn offline_begin(&self,b:&[u8])->i32{if b.len()!=12{return -22;}let data=unsafe{&mut *(&raw mut DATA)};data[..12].copy_from_slice(b);self.map_request(1,data.as_ptr() as u64,12,0)}
 pub fn offline_write(&self,offset:u32,b:&[u8])->i32{if b.len()>120{return -22;}let data=unsafe{&mut *(&raw mut DATA)};data[..b.len()].copy_from_slice(b);self.map_request(2,data.as_ptr() as u64,b.len(),offset)}
 pub fn offline_commit(&self)->i32{self.map_request(3,0,0,0)}
 pub fn offline_draw(&self,x:i32,y:i32,scale:i32,clip:[i32;4],fix:Option<(i32,i32)>,overlay:bool)->Option<[u8;40]>{let b=unsafe{&mut *(&raw mut FRAME)};b.fill(0);b[29]=overlay as u8;for(i,n)in [x,y,scale,clip[0],clip[1],clip[2],clip[3]].iter().enumerate(){b[i*4..i*4+4].copy_from_slice(&n.to_le_bytes());}if let Some((x,y))=fix{b[28]=1;b[32..36].copy_from_slice(&x.to_le_bytes());b[36..40].copy_from_slice(&y.to_le_bytes());}if self.map_request(6,b.as_mut_ptr() as u64,80,0)!=1{return None;}Some(b[40..80].try_into().unwrap())}
}
