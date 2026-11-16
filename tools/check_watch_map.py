#!/usr/bin/env python3
"""Validate every bounded watch-map page before publishing or installation."""
import argparse,json,struct,zlib,hashlib
from pathlib import Path
def check(path):
 with path.open('rb') as f:
  h=f.read(64);assert len(h)==64 and h[:8]==b'WP2MAP1\0' and zlib.crc32(h[:60])==struct.unpack_from('<I',h,60)[0]
  version,size,minx,miny,w,height,names,n,data,trails,grid,cell,codec=struct.unpack_from('<IIiiHHIIIIIII',h,8)
  assert version==codec==1 and size==path.stat().st_size and size<=9200000 and cell==8192 and grid in (4,8,16)
  assert names==64+w*height*8 and data==names+n*32 and data<size
  entries=[struct.unpack('<II',f.read(8)) for _ in range(w*height)];f.seek(names);labels=f.read(n*32)
  assert len(labels)==n*32 and all(all(32<=c<=126 for c in s.split(b'\0')[0]) for s in [labels[i:i+32] for i in range(0,len(labels),32)])
  pages=records=vertices=0;spans=[]
  for off,length in entries:
   if length==0:assert off==0;continue
   assert data<=off<size and length<=size-off;spans.append((off,off+length));end=off+length;f.seek(off)
   while f.tell()<end:
    packed,raw,crc=struct.unpack('<HHI',f.read(8));assert 0<packed<=16512 and 0<raw<=16384 and packed<=end-f.tell()
    body=zlib.decompress(f.read(packed));assert len(body)==raw and zlib.crc32(body)==crc;pages+=1;p=0
    while p<raw:
     length=struct.unpack_from('<H',body,p)[0];p+=2;assert 10<=length<=raw-p
     record=body[p:p+length];name=struct.unpack_from('<H',record,2)[0];assert name<n and record[0]<=4 and record[8] in (0,1)
     q=9
     def uint():
      nonlocal q
      value=shift=0
      while True:
       assert q<len(record);byte=record[q];q+=1;assert shift<28 or byte<=15
       value|=(byte&127)<<shift
       if byte<128:return value
       shift+=7;assert shift<=28
     parts=uint();assert parts<=2048;points=0
     for _ in range(parts):
      count=uint();points+=count;assert points<=2048;x=y=0
      for _ in range(count):
       dx=uint();dy=uint();x+=(dx>>1)^-(dx&1);y+=(dy>>1)^-(dy&1)
       assert 0<=x<=cell//grid and 0<=y<=cell//grid
     assert q==len(record);vertices+=points;records+=1;p+=length
    assert p==raw
   assert f.tell()==end
  spans.sort();assert spans[0][0]==data and spans[-1][1]==size and all(a[1]==b[0] for a,b in zip(spans,spans[1:]))
 return dict(result='passed',bytes=size,sha256=hashlib.sha256(path.read_bytes()).hexdigest(),trail_source_segments=trails,names=n,pages=pages,tile_records=records,vertices=vertices,grid_projected_metres=grid,projected_cell_bounds=[minx*cell,miny*cell,(minx+w)*cell,(miny+height)*cell],validation_only=True,overlap='Source segments may overlap; not unique trails')
if __name__=='__main__':
 p=argparse.ArgumentParser(description=__doc__);p.add_argument('pack',type=Path);p.add_argument('--publish',type=Path);a=p.parse_args();r=check(a.pack)
 if a.publish:
  assert not a.publish.exists();a.pack.rename(a.publish);path=a.publish
 else:path=a.pack
 path.with_suffix('.validation.json').write_text(json.dumps(r,indent=2)+'\n');print(json.dumps(r,indent=2))
