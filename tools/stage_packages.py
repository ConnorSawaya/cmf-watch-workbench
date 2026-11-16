#!/usr/bin/env python3
"""Bundle only exact packages confirmed by the disposable ARM-guest report."""
import argparse,hashlib,json,shutil,struct,zlib
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def stage(proof_path):
    proof=json.loads(proof_path.read_text())
    if proof.get('result')!='arm_packages_verified':raise ValueError('A completed ARM package report is required')
    records=[]
    for record in proof['packages']:
        name=record['name']
        if not name or any(c not in 'abcdefghijklmnopqrstuvwxyz0123456789-_' for c in name):raise ValueError('Invalid package name')
        source=ROOT/'firmware/wp2-apps/target'/f'{name}.wp2app';b=source.read_bytes()
        if hashlib.sha256(b).hexdigest()!=record['sha256']:raise ValueError(f'{name}: package changed after testing')
        if b[:4]!=b'WP2A' or zlib.crc32(b[:52])!=struct.unpack_from('<I',b,52)[0] or zlib.crc32(b[64:])!=struct.unpack_from('<I',b,48)[0]:raise ValueError('Package checksum mismatch')
        if name not in ('loader','trail-map') and not all(record.get(k) for k in ('arm_launch','arm_input','arm_button_exit')):raise ValueError(f'{name}: incomplete runtime evidence')
        records.append(dict(name=name,kind=b[6],version=struct.unpack_from('<I',b,32)[0],bytes=len(b),sha256=record['sha256']))
    if not {'loader','trail-map'}.issubset(r['name'] for r in records):raise ValueError('Loader and map evidence are required')
    for folder in [ROOT/'ios/TrailCompanion/Resources',ROOT/'android/app/src/main/assets/generated']:
        folder.mkdir(parents=True,exist_ok=True)
        for record in records:shutil.copy2(ROOT/'firmware/wp2-apps/target'/f"{record['name']}.wp2app",folder/f"{record['name']}.wp2app")
        (folder/'tested-packages.json').write_text(json.dumps(records,indent=2)+'\n')
    print('Staged',len(records),'exact ARM-reviewed packages')

if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--proof',type=Path,required=True);args=p.parse_args();stage(args.proof)
