//! Integer-only decoding/projection of the stock JX402 GNSS callback.
pub fn micro(bits:u64)->Option<i32> {
 if bits&0x7fff_ffff_ffff_ffff==0{return Some(0);}
 let exponent=((bits>>52)&2047) as i32;if exponent==0||exponent==2047{return None;}
 let e=exponent-1023;if !(-30..=8).contains(&e){return None;}
 let mantissa=((bits&((1u64<<52)-1))|(1u64<<52))>>16;
 let n=(mantissa*1_000_000)>>(36-e);if n>180_000_000{return None;}
 Some(if bits>>63!=0{-(n as i32)}else{n as i32})
}
pub fn project(lat:i32,lon:i32)->Option<(i32,i32)> {
 if lat.unsigned_abs()>85_000_000||lon.unsigned_abs()>180_000_000{return None;}
 // sin(phi), then atanh(sin(phi)). Fixed Q30; bounded precision for ordinary map use.
 // Extra terms preserve useful precision through the continental US/Alaska.
 let q=1i64<<30;let a=lat as i64*3_373_259_426/180_000_000;let a2=a*a/q;
 let mut sin=a;let mut term=a;
 for n in 1..=7 {term=-term*a2/q/((2*n)*(2*n+1));sin+=term;}
 let s2=sin*sin/q;let mut p=sin;let mut value=p;
 for n in 1..=4096 {p=p*s2/q;value+=p/(2*n+1);if p.abs()<2{break;}}
 let x=lon as i64*11_131_949/100_000_000;let y=-value*6_378_137/q;
 Some((x as i32,y as i32))
}
#[cfg(test)] mod tests {
 use super::*;
 #[test] fn public_fixture_and_coordinate_limits() {
  assert!((micro(51.4779f64.to_bits()).unwrap()-51_477_900).abs()<2);
  assert!((micro((0.0005f64).to_bits()).unwrap()-500).abs()<2);
  let (x,y)=project(51_477_900,500).unwrap();assert!((x-55).abs()<3);assert!(y<0);
  for lat in [0,32_000_000,42_000_000,65_000_000,80_000_000] {let (_,y)=project(lat,0).unwrap();let expected=-6_378_137.*((std::f64::consts::PI/4.+(lat as f64/1e6).to_radians()/2.).tan()).ln();assert!((y as f64-expected).abs()<100.,"{lat}: {y} vs {expected}");}
  assert!(project(86_000_000,0).is_none());assert!(micro(f64::NAN.to_bits()).is_none());
 }
}
