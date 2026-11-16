#!/usr/bin/env python3
import asyncio
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import time
import struct
import zlib
import sys

import argparse
parser=argparse.ArgumentParser(description='Verify packages on a disposable JX402 ARM guest, never physical BLE')
for name in ['stock-nor','patched-app','qemu','rom','fixtures','netsimd']:
    parser.add_argument('--'+name,type=Path,required=True)
args=parser.parse_args()
root = Path(__file__).resolve().parents[1]
wp = root / 'firmware/wp2-apps'
sys.path.insert(0,str(wp))
cmf = args.fixtures.parent
out = root / f'build/arm-proof/{time.time_ns()}'
out.mkdir(parents=True, exist_ok=True)

def free_port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

async def install_code(hci):
    from wp2apps import h4, install, link
    async with h4.gatt_over_h4(hci, mtu=247) as gatt:
        session = link.Session()
        await session.open_channel(gatt)
        stub = await install.stub(session)
        previous_version=None
        if old_path:=os.environ.get('WATCH_PREVIOUS_LOADER'):
            old=Path(old_path).read_bytes()
            old_slot=await install.install(session,old)
            previous_version=(await install.info(session,old_slot)).version
        loader_slot = await install.install(session, (wp / 'target/loader.wp2app').read_bytes())
        app_slot = await install.install(session, (wp / 'target/trail-map.wp2app').read_bytes())
        found = await install.listing(session)
        assert loader_slot == 255 and found[255].kind == 1
        assert found[app_slot].name == 'trail-map'
        # Prove transfer failures cannot commit an incomplete or corrupt replacement.
        data = (wp / 'target/trail-map.wp2app').read_bytes()
        await install._call(session, install.BEGIN, struct.pack('<BII', app_slot, len(data), zlib.crc32(data)))
        await install._call(session, install.DATA, struct.pack('<I', 0) + data[:128])
        assert await install.info(session, app_slot) == found[app_slot]  # INFO aborts staging.
        broken = bytearray(data)
        broken[-1] ^= 1
        try:
            await install.upload(session, app_slot, bytes(broken))
        except ValueError as error:
            assert 'CRC' in str(error) or 'INVALID' in str(error), error
        else:
            raise AssertionError('Corrupt package was accepted')
        assert await install.info(session, app_slot) == found[app_slot]
        assert await install.install(session, data) == app_slot
        assert (await install.listing(session))[255] == found[255]
        return {'interrupted_transfer_preserved_app': True, 'corrupt_transfer_preserved_app': True,
                'same_name_update_reused_slot': True, 'loader_unchanged_by_app_update': True,
                'result': 'packages_confirmed_by_arm_guest' , 'stub_version': stub.version,
                'loader_slot': loader_slot, 'app_slot': app_slot,
                'loader_sha256': hashlib.sha256((wp/'target/loader.wp2app').read_bytes()).hexdigest(), 'loader_version':found[255].version, 'loader_upgrade_from':previous_version,
                'app_sha256': hashlib.sha256(data).hexdigest(), 'app_name': found[app_slot].name, 'app_version': found[app_slot].version}

async def verify_all(hci):
    from wp2apps import h4,link,install,firmware
    from tests.e2e.harness import Qmp
    from watch_arm_debug import call
    report=await install_code(hci)
    q=Qmp(qmp_port)
    async def send(*lines,pause=1):
        for line in lines:
            with (out/'guest/input.txt').open('a') as f:f.write(line+'\n')
            await asyncio.sleep(.25)
        await asyncio.sleep(pause)
    def byte_at(address):return int(q.hmp(f'xp /1bx {address:#x}')['return'].split()[-1],16)
    from verify_arm_map import verify_map
    await verify_map(hci,q,send,byte_at,report,root,wp,out,free_port)
    packages=[]
    async with h4.gatt_over_h4(hci,mtu=247) as gatt:
        session=link.Session();await session.open_channel(gatt)
        for name in ['stopwatch','intervals','counter']:
            # Keep a single app in slot0 so its menu row is deterministic.
            for slot in list(await install.listing(session)):
                if slot<8:await install.remove(session,slot)
            data=(wp/f'target/{name}.wp2app').read_bytes()
            slot=await install.install(session,data)
            assert slot==0
            if byte_at(0x3800FAF4)&3:await send('c 1','c 0',pause=2)
            call(q,free_port(),out/f'open-{name}.py',0x101898BD,0xF0,0)
            await send('c 1','c 0',pause=2)
            call(q,free_port(),out/f'awake-{name}.py',0x101898BD,0xF0,0)
            await asyncio.sleep(2)
            await send('t 1 200 180','t 0 200 180',pause=2)
            assert byte_at(firmware.STUB_RAM+6)==0,name+' did not launch'
            before=(out/'guest/frame.ppm').read_bytes()
            if name=='counter':
                await send('t 1 320 350','t 0 320 350',pause=2)
                tapped=(out/'guest/frame.ppm').read_bytes();assert tapped!=before,'Counter ignored tap'
                await send('r -80',pause=2)
                assert (out/'guest/frame.ppm').read_bytes()!=tapped,'Counter ignored crown'
            else:await send('t 1 145 350','t 0 145 350',pause=2)
            source=out/'guest/frame.ppm'
            after=source.read_bytes();assert before!=after,name+' ignored input'
            (out/f'{name}.ppm').write_bytes(after)
            await send('c 1','c 0',pause=2)
            assert byte_at(firmware.STUB_RAM+6)==255,name+' did not exit'
            # The loader menu closes before the next install.
            await send('c 1','c 0',pause=2)
            packages.append(dict(name=name,sha256=hashlib.sha256(data).hexdigest(),arm_launch=True,arm_input=True,arm_button_exit=True))
    core=[dict(name=n,sha256=hashlib.sha256((wp/f'target/{n}.wp2app').read_bytes()).hexdigest()) for n in ['loader','trail-map']]
    report.update(result='arm_packages_verified',packages=core+packages)
    return report

def main():
    from wp2apps import firmware
    paired = args.stock_nor
    (out / 'nor.bin').write_bytes(firmware.stage_nor(paired.read_bytes(), args.patched_app.read_bytes()))
    hci = free_port()
    global qmp_port
    qmp_port = free_port()
    env = dict(os.environ, DYLD_LIBRARY_PATH=str(args.qemu.parent.parent))
    processes = []
    with (out / 'netsim.log').open('w') as nl, (out / 'guest.log').open('w') as gl:
        try:
            n = subprocess.Popen([str(args.netsimd), '--instance', '90', '--hci-port', str(hci), '--no-cli-ui', '--no-web-ui'], stdout=nl, stderr=nl, start_new_session=True)
            processes.append(n)
            for _ in range(200):
                if n.poll() is not None:
                    raise RuntimeError('Virtual controller exited')
                if subprocess.run(['lsof', '-nP', '-a', '-p', str(n.pid), f'-iTCP:{hci}', '-sTCP:LISTEN'], capture_output=True).returncode == 0:
                    break
                time.sleep(.1)
            else:
                raise RuntimeError('Virtual controller did not listen')
            command = ['uv', 'run', '--locked', 'cmf-watch-utils', 'emu', 'run', '--fixtures', str(args.fixtures), '--qemu', str(args.qemu), '--rom', str(args.rom), '--nor', str(out / 'nor.bin'), '--output', str(out / 'guest'), '--headless', '--seconds', '600', '--charger-connected', '--hci-port', str(hci), '--qmp-port', str(qmp_port), '--audio', 'none']
            guest = subprocess.Popen(command, cwd=wp, env=env, stdout=gl, stderr=gl, start_new_session=True)
            processes.append(guest)
            for _ in range(600):
                uart = out / 'guest/uart0.log'
                if uart.exists() and 'launcher enter' in uart.read_text(errors='replace'):
                    break
                if guest.poll() is not None:
                    raise RuntimeError('Virtual watch exited before launcher')
                time.sleep(.1)
            else:
                raise RuntimeError('Virtual watch did not boot')
            report = asyncio.run(verify_all(hci))
            (out / 'report.json').write_text(json.dumps(report, indent=2))
            (root/'build/arm-proof/report.json').write_text(json.dumps(report,indent=2))
            print(json.dumps(report, indent=2))
        finally:
            for p in reversed(processes):
                if p.poll() is not None:
                    continue
                try:
                    os.killpg(p.pid, signal.SIGTERM)
                except (ProcessLookupError, PermissionError):
                    p.terminate()
                try:
                    p.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    os.killpg(p.pid, signal.SIGKILL)
                    p.wait()

if __name__ == '__main__':
    main()
