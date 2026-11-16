#!/usr/bin/env python3
import os,socket,subprocess,time,json
from pathlib import Path
root=Path(__file__).resolve().parents[1]
out=root/'build/watch-channel-check';out.mkdir(parents=True,exist_ok=True)
with socket.socket() as s:s.bind(('127.0.0.1',0));port=s.getsockname()[1]
env=dict(os.environ,WATCH_SIM_PORT=str(port))

with (out/'simulator.log').open('w') as log:
 p=subprocess.Popen(['scripts/sim','trail-map','--headless','--fresh','--realtime','--tcp',str(port),'--store',str(out/'store'),'--frames',str(out),'--every-show','--until','15000','--do','wait 4000; down 200 200; wait 50; move 260 220; wait 50; move 300 230; up 300 230'],cwd=root/'firmware/wp2-apps',env=env,stdout=log,stderr=log)
 try:
  for _ in range(300):
   if p.poll() is not None:raise RuntimeError((out/'simulator.log').read_text())
   try:
    with socket.create_connection(('127.0.0.1',port),.1):break
   except OSError:time.sleep(.05)
  else:raise RuntimeError('Simulator did not start')
  subprocess.run(['swift','test','--filter','testMapOverLiveWatchSimulator'],cwd=root/'ios/CompanionCore',env=env,check=True)
  time.sleep(1)
 finally:
  p.terminate()
  try:p.wait(timeout=5)
  except subprocess.TimeoutExpired:p.kill();p.wait()
logs=[json.loads(line) for line in (out/'log.jsonl').read_text().splitlines()]
assert any(row.get('ev')=='save' for row in logs), 'Watch did not persist snapshot'
print('Swift → Rust watch simulator: map confirmed and persisted')
