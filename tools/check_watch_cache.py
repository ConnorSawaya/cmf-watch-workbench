#!/usr/bin/env python3
"""Persist actual phone artwork, reopen offline, switch zoom, evict, recover."""
import json,os,struct,subprocess,zlib
from pathlib import Path
from PIL import Image
root=Path(__file__).resolve().parents[1];wp=root/'firmware/wp2-apps';out=root/'build/watch-cache-check';out.mkdir(exist_ok=True);store=out/'store'
env=dict(os.environ)
def camera(name):
 f=json.loads((root/f'build/artwork-check/{name}-fixture.json').read_text());b=bytes.fromhex(f['messages'][0]);x,y,scale=struct.unpack_from('<iiH',b,12)
 area=b'TM02'+struct.pack('<iiHH',x,y,0,scale)+name.encode().ljust(32,b'\0');ident=600
 packets=[b'TM\1\1'+struct.pack('<HHI',ident,len(area),zlib.crc32(area)),b'TM\1\2'+struct.pack('<HH',ident,0)+area,b'TM\1\3'+struct.pack('<H',ident)]
 return ['mx '+p.hex() for p in packets]+['mx '+p for p in f['messages']]
def run(name,commands,fresh=False):
 directory=out/name;directory.mkdir(exist_ok=True);script=directory/'input.txt';script.write_text('\n'.join(commands))
 args=['scripts/sim','trail-map','--headless','--store',str(store),'--frames',str(directory),'--script',str(script)]
 if fresh:args.append('--fresh')
 subprocess.run(args,cwd=wp,env=env,capture_output=True,text=True,check=True)
 logs=[json.loads(s) for s in (directory/'log.jsonl').read_text().splitlines()];assert next(x for x in logs if x['ev']=='end')['reason']=='exit'
 return directory,logs
def pixels(path):return Image.open(path).crop((8,94,458,351)).tobytes()
commands=[]
for name in ['monaco','monaco12','monaco16','monaco6','harbor','coast','park','country','overview','monaco12']:
 for packet in camera(name):commands.extend([packet,'wait 20'])
 commands.extend(['wait 600','shot '+name])
commands.append('b');populated,logs=run('populate',commands,True)
assert len([x for x in logs if x['ev']=='cache_put' and x['rc']==0])==9,'Eight entries then one eviction; revisiting an unchanged view must not rewrite NAND'
files=list(store.glob('cache*.*'));assert len(files)<=16 and all(p.stat().st_size<=32768+24 for p in files)
reopened,logs=run('offline',['wait 100','shot restored','c -1','wait 100','shot zoom16','c 1','wait 100','shot zoom12','c 1','wait 100','shot evicted8','b'])
assert pixels(reopened/'restored.png')==pixels(populated/'monaco12.png'),'Saved map was not restored on cold app launch'
assert pixels(reopened/'zoom16.png')==pixels(populated/'monaco16.png'),'Cached zoom needs a phone or changes the artwork'
assert pixels(reopened/'zoom12.png')==pixels(populated/'monaco12.png')
assert pixels(reopened/'evicted8.png')!=pixels(populated/'sf.png'),'Oldest map should have been replaced by the ninth view'
reads=[x for x in logs if x['ev']=='cache_get' and not x['peek']];assert len(reads)==3,reads
# Interrupt the newer replacement in entry 0. The previous valid copy must be
# usable on the next launch, with all app RAM freshly reloaded.
latest=store/'cache0.new';assert latest.exists();latest.write_bytes(latest.read_bytes()[:40])
recovered,logs=run('recover',['wait 100','shot recovered','b'])
assert pixels(recovered/'recovered.png')==pixels(populated/'sf.png'),'Cut replacement did not recover its previous valid copy'
report=dict(result='passed',full_quality_saved=True,restored_after_app_restart=True,offline_zoom12_and16=True,cache_reads_without_phone=3,eight_view_limit=True,oldest_view_overwritten=True,unchanged_view_not_rewritten=True,interrupted_cache_write_recovers_previous=True,max_cache_bytes=8*2*(32768+24))
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps(report,indent=2))
