#!/usr/bin/env python3
"""Render real public map fixtures through the exact watch app, including the wire decoder."""
import json,struct,zlib,subprocess,os
from pathlib import Path
from PIL import Image,ImageDraw
root=Path(__file__).resolve().parents[1]
wp=root/'firmware/wp2-apps'
env=dict(os.environ)
for name in ['overview','monaco','harbor','coast','park','country']:
 fixture=json.loads((root/f'build/artwork-check/{name}-fixture.json').read_text())
 begin=bytes.fromhex(fixture['messages'][0]);x,y,scale=struct.unpack_from('<iiH',begin,12)
 area=b'TM02'+struct.pack('<iiHH',x,y,0,scale)+name.encode().ljust(32,b'\0')
 packets=[b'TM\1\1'+struct.pack('<HHI',900,len(area),zlib.crc32(area)),b'TM\1\2'+struct.pack('<HH',900,0)+area,b'TM\1\3'+struct.pack('<H',900)]
 commands=[]
 for p in packets:commands.extend(['mx '+p.hex(),'wait 30'])
 for p in fixture['messages']:commands.extend(['mx '+p,'wait 20'])
 commands.extend(['wait 4000','shot artwork'])
 # A partial replacement followed by a full repaint used to expose the sparse
 # wire drawing. Repaint while receiving and after checksum rejection.
 replacement=bytearray(begin);replacement[4:6]=struct.pack('<H',501)
 first=bytearray(bytes.fromhex(fixture['messages'][1]));first[4:6]=struct.pack('<H',501)
 commands.extend(['mx '+replacement.hex(),'wait 30','mx '+first.hex(),'p','wait 100','p','wait 100','shot receiving'])
 bad=[]
 for i,hexdata in enumerate(fixture['messages']):
  packet=bytearray(bytes.fromhex(hexdata));packet[4:6]=struct.pack('<H',502)
  if i==0:packet[8]^=1
  bad.extend(['mx '+packet.hex(),'wait 20'])
 commands.extend(bad+['p','wait 100','p','wait 100','shot rejected'])
 commands.extend(['down 180 210' ,'wait 60','move 220 230','up 220 230','wait 60','shot pan','b'])
 out=root/f'build/watch-artwork-{name}';out.mkdir(exist_ok=True)
 script=out/'input.txt';script.write_text('\n'.join(commands))
 subprocess.run(['scripts/sim','trail-map','--headless','--fresh','--store',str(out/'store'),'--script',str(script),'--frames',str(out)],cwd=wp,env=env,capture_output=True,text=True,check=True)
 logs=[json.loads(s) for s in (out/'log.jsonl').read_text().splitlines()]
 reference=Image.open(root/f'build/artwork-check/{name}.png').convert('RGB')
 actual=Image.open(out/'artwork.png').convert('RGB')
 matches=0;count=0
 for yy in range(210):
  for xx in range(450):
   x=xx+8;y=yy+94
   if (x-233)**2+(y-233)**2>=232**2:continue
   a=reference.getpixel((xx,yy));b=actual.getpixel((x,y))
   matches+=tuple(c//q for c,q in zip(a,(8,4,8)))==tuple(c//q for c,q in zip(b,(8,4,8)));count+=1
 assert matches==count,(name,'phone/watch artwork pixel mismatch',matches,count)
 for phase in ['receiving','rejected']:
  assert Image.open(out/f'{phase}.png').crop((8,94,458,351)).tobytes()==actual.crop((8,94,458,351)).tobytes(),(name,phase,'lost complete image during update')
 baseline=root/f'build/quality-map-baseline/{name}-v5.png'
 if baseline.exists():
  previous=Image.open(baseline)
  # V8 intentionally removes the two touch-to-change-region labels. All other
  # font pixels must still match the original lossless font coverage exactly.
  previous=previous.copy();draw=ImageDraw.Draw(previous);paper=previous.getpixel((233,10))
  for box in [(94,59,120,84),(346,59,374,84)]:draw.rectangle(box,fill=paper)
  # V9 intentionally replaces the status/footer with a compact icon and trail
  # details. The unchanged title/subtitle glyph coverage remains a golden check.
  for box in [(0,0,466,94)]:assert previous.crop(box).tobytes()==actual.crop(box).tobytes(),(name,'font coverage changed')
 assert (out/'artwork.png').read_bytes()!=(out/'pan.png').read_bytes(),name
 print(name,'watch artwork and pan rendered')
(root/'build/watch-artwork-report.json').write_text(json.dumps(dict(result='passed',native_pixels_match_phone_artwork=True,partial_and_corrupt_replacement_keep_artwork=True,font_pixels_unchanged=True,regions=['Monaco overview','Monaco','Harbor','Coast','Park','Country'])))
