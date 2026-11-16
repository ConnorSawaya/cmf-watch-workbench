#!/usr/bin/env python3
"""Exercise the exact Trail Map logic with persisted data and watch input events."""
import json
import os
from pathlib import Path
import subprocess
import struct,zlib
root=Path(__file__).resolve().parents[1]
out=root/'build/watch-runtime-check'
out.mkdir(parents=True,exist_ok=True)
env=dict(os.environ)
subprocess.run(['cargo','test','-p','trail-map','--target','aarch64-apple-darwin'],cwd=root/'firmware/wp2-apps/sdk',env=env,check=True)
fixture=json.loads((root/'build/artwork-check/monaco-fixture.json').read_text())
start=bytes.fromhex(fixture['messages'][0]);x,y,scale=struct.unpack_from('<iiH',start,12)
area=b'TM02'+struct.pack('<iiHH',x,y,0,scale)+b'Runtime test'.ljust(32,b'\0')
packets=[b'TM\1\1'+struct.pack('<HHI',900,len(area),zlib.crc32(area)),b'TM\1\2'+struct.pack('<HH',900,0)+area,b'TM\1\3'+struct.pack('<H',900)]
preamble='; '.join('mx '+p.hex()+'; wait 30' for p in packets)+'; '+'; '.join('mx '+p+'; wait 20' for p in fixture['messages'])
if list((root/'build/watch-channel-check/store').glob('cache*.dat')):preamble=''
script=(preamble+'; ' if preamble else '')+'wait 100; shot restored; down 96 70; up 96 70; down 350 70; up 350 70; down 233 220; up 233 220; down 233 220; up 233 220; down 233 400; up 233 400; wait 100; shot tapped; down 200 200; wait 50; move 260 220; wait 50; shot dragging; move 300 230; up 300 230; wait 100; shot pan; c 1; wait 100; shot zoom; p; wait 100; p; wait 100; shot resumed; b'
run=subprocess.run(['scripts/sim','trail-map','--headless','--store',str(root/'build/watch-channel-check/store'),'--frames',str(out),'--do',script],cwd=root/'firmware/wp2-apps',env=env,capture_output=True,text=True,check=True)
logs=[json.loads(line) for line in (out/'log.jsonl').read_text().splitlines()]
end=next(x for x in logs if x['ev']=='end')
assert end['reason']=='exit' and end['code']==0
assert any(x['ev']=='load' for x in logs)
assert any(x['ev']=='pause' for x in logs) and any(x['ev']=='resume' for x in logs)
assert (out/'restored.png').read_bytes()==(out/'tapped.png').read_bytes(),'Tapping the header, map or footer must not zoom or move the camera'
assert (out/'restored.png').read_bytes()!=(out/'dragging.png').read_bytes()
assert (out/'dragging.png').read_bytes()!=(out/'pan.png').read_bytes()
assert (out/'pan.png').read_bytes()!=(out/'zoom.png').read_bytes()
# Long virtual time proves the active-use lease is renewed by input, expires
# after inactivity, and releases on pause/exit. No real-time sleeping required.
wakeout=out/'wake';wakeout.mkdir(exist_ok=True)
wakescript='wait 119000; down 200 200; wait 50; move 230 200; up 230 200; wait 119000; shot active; wait 2000; p; wait 100; p; wait 100; b'
subprocess.run(['scripts/sim','trail-map','--headless','--frames',str(wakeout),'--do',wakescript,'--until','250000'],cwd=root/'firmware/wp2-apps',env=env,capture_output=True,text=True,check=True)
wake=[json.loads(line) for line in (wakeout/'log.jsonl').read_text().splitlines()]
locks=[x for x in wake if x['ev']=='keep_screen_on']
assert locks[0]['on'] and locks[0]['t']<100
assert not any(not x['on'] for x in locks if x['t']<239000),locks
assert any(not x['on'] and 239000<=x['t']<=240500 for x in locks),locks
assert any(x['on'] and x['t']>240000 for x in locks),locks
assert locks[-1]['on']==False and next(x for x in wake if x['ev']=='end')['reason']=='exit'
# 24 rapid crown detents should update the final camera with far fewer frames.
burstout=out/'burst';burstout.mkdir(exist_ok=True)
burst='wait 100; '+ '; '.join(['c 1; wait 5']*24)+'; wait 300; shot zoomed; '+ '; '.join(['c -1; wait 5']*40)+'; wait 300; shot overview; b'
subprocess.run(['scripts/sim','trail-map','--headless','--frames',str(burstout),'--do',burst],cwd=root/'firmware/wp2-apps',env=env,capture_output=True,text=True,check=True)
burstlogs=[json.loads(line) for line in (burstout/'log.jsonl').read_text().splitlines()]
end=next(x for x in burstlogs if x['ev']=='end')
assert end['reason']=='exit' and end['shows']<16,end
assert (burstout/'zoomed.png').read_bytes()!=(burstout/'overview.png').read_bytes()
report=dict(result='passed',saved_map_restored=True,touch_does_not_zoom_or_recenter=True,pan_changes_frame=True,crown_zoom_changes_frame=True,pause_resume=True,button_exits_cleanly=True,input_renews_two_minute_wake=True,idle_pause_exit_release_wake=True,rapid_crown_shows=end['shows'],rapid_crown_detents=64)
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report,indent=2))
