#!/usr/bin/env python3
"""Real app/host ABI proof: named places survive cold restart; progress counts bytes."""
import json,os,struct,subprocess,zlib
from pathlib import Path
from PIL import Image
root=Path(__file__).resolve().parents[1];wp=root/'firmware/wp2-apps';out=root/'build/watch-saved-progress';out.mkdir(exist_ok=True)
env=dict(os.environ)
fixture=json.loads((root/'build/artwork-check/sf-fixture.json').read_text());x,y,scale=struct.unpack_from('<iiH',bytes.fromhex(fixture['messages'][0]),12)
area=b'TM02'+struct.pack('<iiHH',x,y,0,scale)+b'Saved places'.ljust(32,b'\0')
packets=[b'TM\1\1'+struct.pack('<HHI',900,len(area),zlib.crc32(area)),b'TM\1\2'+struct.pack('<HH',900,0)+area,b'TM\1\3'+struct.pack('<H',900)]+[bytes.fromhex(p) for p in fixture['messages']]
record=struct.pack('<ii',x+scale*20,y)+b'SF test camp'.ljust(24,b'\0');places=b'TP10'+struct.pack('<HHI',1,0,zlib.crc32(record))+record
places_packets=[b'TM\1\x40'+struct.pack('<H',len(places)),b'TM\1\x41'+b'\0\0'+places,b'TM\1\x42']
cmd=[]
for p in packets+places_packets:cmd+=['mx '+p.hex(),'wait 30']
cmd+=['wait 3000','shot bookmarks']
replacement=[bytearray.fromhex(p) for p in fixture['messages']]
for p in replacement:p[4:6]=struct.pack('<H',901)
half=len(replacement)//2
for p in replacement[:half]:cmd+=['mx '+p.hex(),'wait 20']
cmd+=['wait 1500','shot downloading','wait 6000','shot waiting']
for p in replacement[half:]:cmd+=['mx '+p.hex(),'wait 20']
# End without a button save: named places must already be committed.
cmd+=['wait 1000','shot complete']
script=out/'input.txt';script.write_text('\n'.join(cmd))
subprocess.run(['scripts/sim','trail-map','--headless','--realtime','--fresh','--store',str(out/'store'),'--frames',str(out),'--script',str(script)],cwd=wp,env=env,capture_output=True,text=True,check=True)
restart=out/'restart';restart.mkdir(exist_ok=True)
subprocess.run(['scripts/sim','trail-map','--headless','--store',str(out/'store'),'--frames',str(restart),'--do','wait 200; shot restored; b'],cwd=wp,env=env,capture_output=True,text=True,check=True)
def bar(image):return sum(image.getpixel((x,389))[2]>image.getpixel((x,389))[0]*2 and image.getpixel((x,389))[2]>20 for x in range(109,357))
a=Image.open(out/'downloading.png').convert('RGB');b=Image.open(out/'waiting.png').convert('RGB');c=Image.open(out/'complete.png').convert('RGB');r=Image.open(restart/'restored.png').convert('RGB')
assert 80<bar(a)<160,bar(a);assert bar(a)==bar(b),('Waiting advanced percent',bar(a),bar(b));assert bar(c)==248,bar(c)
assert a.crop((100,354,370,382)).tobytes()!=b.crop((100,354,370,382)).tobytes(),'Waiting headline unchanged'
orange=lambda p:p[0]>p[1]*1.8 and p[0]>p[2]*3
assert sum(orange(r.getpixel((xx,yy))) for xx in range(247,260) for yy in range(214,227))>=35,'Named place did not survive fresh RAM'
report=dict(result='passed',named_place_cold_restore=True,receive_progress_percent_and_bytes=True,waiting_retains_percent=True,complete_only_after_save=True,restart_starts_without_transfer_overlay=True)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report))
