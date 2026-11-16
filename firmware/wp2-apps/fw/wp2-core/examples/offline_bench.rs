//! Exercise the production native renderer with a local pack; no BLE or device access.
use std::{fs, time::Instant};
use wp2_core::offline::{self, Camera, Header, Read, Scratch};
struct Source {bytes: Vec<u8>, reads: usize, bytes_read: usize}
impl Read for Source {
    fn read(&mut self, at: u32, out: &mut [u8]) -> bool {
        let Some(b) = self.bytes.get(at as usize..at as usize + out.len()) else {return false};
        out.copy_from_slice(b); self.reads += 1; self.bytes_read += b.len(); true
    }
}
fn main() {
    let args: Vec<String> = std::env::args().collect();
    let bytes = fs::read(args.get(1).expect("map file argument")).unwrap();
    let h = Header::parse(&bytes[..64]).unwrap();
    let tile = (0..h.w * h.h).max_by_key(|&i| offline::u32le(&bytes, 68 + i as usize * 8)).unwrap();
    let x = args.get(2).map(|v|v.parse().unwrap()).unwrap_or((h.minx + (tile % h.w) as i32) * 8192 + 4096);
    let y = args.get(3).map(|v|v.parse().unwrap()).unwrap_or((h.miny + (tile / h.w) as i32) * 8192 + 4096);
    let mut source = Source {bytes, reads: 0, bytes_read: 0};
    let mut scratch = Box::<Scratch>::new_uninit();
    unsafe {std::ptr::write_bytes(scratch.as_mut_ptr(), 0, 1)};
    let mut scratch = unsafe {scratch.assume_init()};
    let mut pixels = vec![0u16; 466 * 466];
    for scale in [1, 2, 4, 8, 16, 32, 64, 128] {
        for pass in 0..2 {
            source.reads = 0; source.bytes_read = 0; pixels.fill(0); let mut calls = 0;
            let t = Instant::now();
            let info = offline::render(&mut source, h, &mut scratch,
                Camera {x, y, scale, clip: [8,94,457,350], fix: None, overlay: false},
                |x,y,w,h,c| {calls+=1; for row in y as usize..y as usize + h as usize {
                    pixels[row*466+x as usize..row*466+x as usize+w as usize].fill(c);
                }}).unwrap();
            println!("{{\"scale\":{scale},\"pass\":{pass},\"micros\":{},\"reads\":{},\"bytes_read\":{},\"draw_calls\":{calls},\"features\":{}}}",t.elapsed().as_micros(),source.reads,source.bytes_read,info.features);
        }
    }
}
