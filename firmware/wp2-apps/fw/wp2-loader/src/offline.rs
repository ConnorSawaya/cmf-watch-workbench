//! Fixed-path, resumable map transfer and bounded native rendering.
use core::{ptr,mem,sync::atomic::{AtomicU32,AtomicBool,Ordering}};
use wp2_core::{offline as o,fs,heap,pkg::crc32};
const MAP:&[u8]=b"/NAND:/wp2apps/map.bin\0";const PART:&[u8]=b"/NAND:/wp2apps/map.part\0";const META:&[u8]=b"/NAND:/wp2apps/map.meta\0";const OLD:&[u8]=b"/NAND:/wp2apps/map.old\0";
const DONE:&[u8]=b"/NAND:/wp2apps/map.done\0";
static BLOCK:AtomicU32=AtomicU32::new(0);static OPEN:AtomicBool=AtomicBool::new(false);static OFFSET:AtomicU32=AtomicU32::new(0);static SIZE:AtomicU32=AtomicU32::new(0);static CRC:AtomicU32=AtomicU32::new(0);static SUM:AtomicU32=AtomicU32::new(0);
static mut FILE:fs::File=[0;44];
static VERSION:AtomicU32=AtomicU32::new(0);
fn file()->&'static mut fs::File{unsafe{&mut *(&raw mut FILE)}}
fn scratch()->Option<&'static mut o::Scratch>{let mut p=BLOCK.load(Ordering::Relaxed);if p==0{let b=heap::alloc(heap::RES,mem::size_of::<o::Scratch>() as u32,16);if b.is_null(){return None;}unsafe{ptr::write_bytes(b,0,mem::size_of::<o::Scratch>());}p=b as u32;BLOCK.store(p,Ordering::Relaxed);}Some(unsafe{&mut *(p as *mut o::Scratch)})}
fn head(path:&[u8])->Option<o::Header>{let mut f=[0;44];if fs::open(&mut f,path,fs::READ)<0{return None;}let mut b=[0;64];let h=if fs::read_exact(&mut f,&mut b){o::Header::parse(&b)}else{None};let n=if fs::seek(&mut f,0,2)==0{fs::tell(&mut f)}else{-1};fs::close(&mut f);h.filter(|h|n==h.size as i32)}
fn path()->Option<&'static[u8]>{if head(MAP).is_some(){Some(MAP)}else if head(OLD).is_some(){Some(OLD)}else{None}}
pub fn stop(){if OPEN.swap(false,Ordering::AcqRel){fs::sync(file());fs::close(file());}let p=BLOCK.swap(0,Ordering::Relaxed);if p!=0{unsafe{heap::free(heap::RES,p as *mut u8);}}}
fn begin(b:&[u8])->i32{
 if b.len()!=12{return -22;}let size=o::u32le(b,0);let crc=o::u32le(b,4);if !(64..=o::MAX).contains(&size){return -22;}
 if OPEN.load(Ordering::Acquire)&&SIZE.load(Ordering::Relaxed)==size&&CRC.load(Ordering::Relaxed)==crc{return OFFSET.load(Ordering::Relaxed) as i32;}
 if OPEN.swap(false,Ordering::AcqRel){fs::sync(file());fs::close(file());}
 let mut old=[0;12];let mut meta=[0;44];let same=if fs::open(&mut meta,META,fs::READ)>=0{let ok=fs::read_exact(&mut meta,&mut old)&&old==b;fs::close(&mut meta);ok}else{false};
 let mut offset=0;let mut sum=0;
 if same&&fs::open(file(),PART,fs::READ)>=0{let Some(s)=scratch()else{fs::close(file());return -12;};loop{let n=fs::read(file(),&mut s.raw);if n<0{fs::close(file());return -5;}if n==0{break;}if offset+n as u32>size{offset=0;sum=0;break;}sum=crc32(sum,&s.raw[..n as usize]);offset+=n as u32;}fs::close(file());}
 if offset==size&&sum!=crc{fs::unlink(PART);offset=0;sum=0;}
 if !same{fs::unlink(PART);fs::unlink(META);if fs::open(&mut meta,META,fs::WRITE|fs::CREATE)<0{return -5;}let ok=fs::write(&mut meta,b)==12;fs::close(&mut meta);if !ok{return -5;}}
 let Some((free,unit))=fs::free_space(PART)else{return -5;};if free<(size-offset) as u64+128*1024+2*unit as u64{return -28;}
 if fs::open(file(),PART,fs::WRITE|fs::CREATE)<0||fs::seek(file(),offset as i32,0)<0{return -5;}
 SIZE.store(size,Ordering::Relaxed);CRC.store(crc,Ordering::Relaxed);VERSION.store(o::u32le(b,8),Ordering::Relaxed);SUM.store(sum,Ordering::Relaxed);OFFSET.store(offset,Ordering::Relaxed);OPEN.store(true,Ordering::Release);offset as i32
}
fn write(offset:u32,b:&[u8])->i32{if !OPEN.load(Ordering::Acquire)||offset!=OFFSET.load(Ordering::Relaxed)||b.len()>120||b.len() as u32>SIZE.load(Ordering::Relaxed)-offset{return -22;}if fs::write(file(),b)!=b.len() as i32{OPEN.store(false,Ordering::Release);fs::close(file());return -5;}SUM.store(crc32(SUM.load(Ordering::Relaxed),b),Ordering::Relaxed);let next=offset+b.len() as u32;OFFSET.store(next,Ordering::Relaxed);if offset/32768!=next/32768&&fs::sync(file())<0{return -5;}next as i32}
fn commit()->i32{if !OPEN.load(Ordering::Acquire){return -5;}if OFFSET.load(Ordering::Relaxed)!=SIZE.load(Ordering::Relaxed)||SUM.load(Ordering::Relaxed)!=CRC.load(Ordering::Relaxed){OPEN.store(false,Ordering::Release);fs::close(file());return -5;}if fs::sync(file())<0{return -5;}OPEN.store(false,Ordering::Release);if fs::close(file())<0||head(PART).is_none(){return -5;}fs::unlink(OLD);let had=head(MAP).is_some();if had&&fs::rename(MAP,OLD)<0{return -5;}if fs::rename(PART,MAP)<0{if had{fs::rename(OLD,MAP);}return -5;}fs::unlink(OLD);let mut done=[0;12];done[..4].copy_from_slice(&SIZE.load(Ordering::Relaxed).to_le_bytes());done[4..8].copy_from_slice(&CRC.load(Ordering::Relaxed).to_le_bytes());done[8..12].copy_from_slice(&VERSION.load(Ordering::Relaxed).to_le_bytes());let mut f=[0;44];fs::unlink(DONE);if fs::open(&mut f,DONE,fs::WRITE|fs::CREATE)>=0{fs::write(&mut f,&done);fs::close(&mut f);}0}
struct Reader{f:fs::File}
impl o::Read for Reader{fn read(&mut self,at:u32,out:&mut[u8])->bool{fs::seek(&mut self.f,at as i32,0)==0&&fs::read_exact(&mut self.f,out)}}
fn draw(b:&mut[u8])->i32{
 if b.len()!=80{return -22;}let Some(path)=path()else{return -2;};let Some(h)=head(path)else{return -5;};let Some(s)=scratch()else{return -12;};let w=|i|o::u32le(b,i) as i32;
 let c=o::Camera{x:w(0),y:w(4),scale:w(8),clip:[w(12),w(16),w(20),w(24)],fix:(b[28]!=0).then(||(w(32),w(36))),overlay:b[29]!=0};
 let mut reader=Reader{f:[0;44]};if fs::open(&mut reader.f,path,fs::READ)<0{return -5;}
 let result=o::render(&mut reader,h,s,c,|x,y,w,h,color|crate::ui::canvas().fill_rect(x,y,w,h,color));fs::close(&mut reader.f);
 match result{Ok(info)=>{b[40..72].copy_from_slice(&info.name);b[72..76].copy_from_slice(&info.length.to_le_bytes());b[76..80].copy_from_slice(&info.distance.to_le_bytes());crate::ui::mark(wp2_core::gfx::rect_box(c.clip[0] as i16,c.clip[1] as i16,(c.clip[2]-c.clip[0]+1) as u16,(c.clip[3]-c.clip[1]+1) as u16));1},Err(e)=>e}
}
pub fn handle(cmd:&[u8])->i32{
 if cmd.len()!=24||cmd[..4]!=[0x15,20,0,0]||cmd[5..8]!=[0,0,0]{return -22;}let op=cmd[4];let p=u64::from_le_bytes(cmd[8..16].try_into().unwrap());let n=o::u32le(cmd,16) as usize;let offset=o::u32le(cmd,20);
 if op==3&&n==0&&p==0{return commit();}if op==4&&n==0&&p==0{stop();return 0;}
 let ram=wp2_core::layout::stub_ram();let base=ram.app_block as usize;let size=ram.app_size as usize;
 if p>usize::MAX as u64{return -22;}let p=p as usize;
 if p<base||p-base>size||n>size-(p-base){return -22;}let b=unsafe{core::slice::from_raw_parts_mut(p as *mut u8,n)};
 match op{0 if n==24=>{b.fill(0);let free=fs::free_space(MAP).map_or(0,|v|v.0.min(u32::MAX as u64) as u32);b[..4].copy_from_slice(&free.to_le_bytes());if let Some(h)=path().and_then(head){b[4..8].copy_from_slice(&h.size.to_le_bytes());b[8..12].copy_from_slice(&h.trails.to_le_bytes());let mut f=[0;44];if fs::open(&mut f,DONE,fs::READ)>=0{let mut done=[0;12];if fs::read_exact(&mut f,&mut done)&&o::u32le(&done,0)==h.size{b[16..24].copy_from_slice(&done[4..12]);}fs::close(&mut f);}}b[12..16].copy_from_slice(&OFFSET.load(Ordering::Relaxed).to_le_bytes());0},1=>begin(b),2=>write(offset,b),6=>draw(b),_=>-22}
}
