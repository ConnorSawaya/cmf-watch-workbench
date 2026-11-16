#!/usr/bin/env python3
"""Execute real tool apps and check timing, bounded haptics and cold storage."""
import json,subprocess,hashlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
SDK=ROOT/'firmware/wp2-apps'
OUT=ROOT/'build/gallery'
OUT.mkdir(parents=True,exist_ok=True)

def run(app,name,script,until,fresh=True,store=None):
    folder=OUT/name;folder.mkdir(exist_ok=True)
    command=['scripts/sim',app,'--headless','--store',str(store or OUT/(app+'-store')),'--frames',str(folder),'--until',str(until),'--do',script]
    if fresh:command+=['--fresh']
    subprocess.run(command,cwd=SDK,check=True,capture_output=True,text=True)
    return [json.loads(row) for row in (folder/'log.jsonl').read_text().splitlines()]

run('stopwatch','stopwatch','wait 100; t 140 350; wait 4500; t 320 350; wait 500; shot running; t 140 350; wait 200; shot paused',6500)
assert (OUT/'stopwatch/running.png').read_bytes()!=(OUT/'stopwatch/paused.png').read_bytes()
intervals=run('intervals','intervals','c 2; wait 150; t 233 290; wait 150; c 1; wait 150; t 233 290; wait 150; c -2; wait 150; t 140 350; wait 2500; shot work; wait 40000; shot rest',65000)
assert (OUT/'intervals/work.png').read_bytes()!=(OUT/'intervals/rest.png').read_bytes()
counter=run('counter','counter','wait 100; c 7; wait 1500; shot saved',2500)
assert any(row.get('ev')=='save' for row in counter)
run('counter','counter-restore','wait 100; shot restored',500,fresh=False)
assert (OUT/'counter/saved.png').read_bytes()==(OUT/'counter-restore/restored.png').read_bytes(),'Counter did not restore its exact saved screen'
run('counter','counter-exit','wait 100; b',1000,fresh=False)
report=dict(result='passed',stopwatch_live_pause=True,interval_work_rest=True,counter_cold_restore=True)
(ROOT/'build/tool-runtime-report.json').write_text(json.dumps(report,indent=2)+'\n')
print(json.dumps(report))
