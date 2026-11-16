"""Production native-map input/render/restart checks in a disposable ARM guest."""
import asyncio,struct,subprocess,zlib

async def verify_map(hci,q,send,byte_at,report,root,wp,out,free_port):
    from wp2apps import h4,link,channel,firmware
    from tests.e2e.harness import APP_BLOCK_OFF
    from watch_arm_debug import call
    payload=(root/'build/demo/demo-map.wp2map').read_bytes()
    assert struct.unpack_from('<I',payload,52)[0]==2,'Rebuild the public demo with codec 2'
    symbols=subprocess.check_output(['xcrun','nm',str(wp/'sdk/target/thumbv7em-none-eabi/release/trail-map')],text=True)
    perf_offset=next(int(line.split()[0],16) for line in symbols.splitlines() if line.endswith(' MAP_PERF'))
    def word(at):return int(q.hmp(f'xp /1wx {at:#x}')['return'].split()[-1],16)
    def pixels():return (out/'guest/frame.ppm').read_bytes().split(b'\n',3)[3]
    if byte_at(0x3800FAF4)&3:await send('c 1','c 0',pause=2)
    call(q,free_port(),out/'open-map.py',0x101898BD,0xF0,0)
    await send('c 1','c 0',pause=2)
    call(q,free_port(),out/'awake-map.py',0x101898BD,0xF0,0)
    await send('t 1 200 180','t 0 200 180',pause=2)
    async with h4.gatt_over_h4(hci,mtu=247) as gatt:
        s=link.Session();await s.open_channel(gatt)
        if byte_at(0x3800FAF4)&3:
            await send('c 1','c 0',pause=2)
            call(q,free_port(),out/'reopen-map.py',0x101898BD,0xF0,0)
            await send('t 1 200 180','t 0 200 180',pause=2)
        assert (await channel.ping(s)).running_slot!=255
        async def ack(prefix):
            for _ in range(48):
                d=(await channel.recv(s,8)).data
                if d[:len(prefix)]==prefix:return d
            raise AssertionError('Map acknowledgement missing')
        async def bulk(op,data=b''):
            await channel.send(s,b'TM\1'+bytes([op])+data)
            d=await ack(b'TM\1'+bytes([op+128]));n=struct.unpack_from('<i',d,4)[0]
            assert n>=0,('Native map transfer refused',op,n)
            return n
        offset=await bulk(0x30,struct.pack('<III',len(payload),zlib.crc32(payload),1))
        while offset<len(payload):
            end=min(offset+1856,len(payload))
            while offset<end:
                at=min(offset+116,end)
                await channel.send(s,b'TM\1\x31'+struct.pack('<I',offset)+bytes([int(at==end)])+payload[offset:at]);offset=at
            d=await ack(b'TM\1\xb1');assert struct.unpack_from('<i',d,4)[0]==offset
        assert await bulk(0x32)==0
        # Public historical Monaco road geometry, never a live location.
        x,y,scale=824818,-5423984,4
        area=b'TM02'+struct.pack('<iiHH',x,y,0,scale)+b'Monaco example'.ljust(32,b'\0')
        await channel.send(s,b'TM\1\1'+struct.pack('<HHI',903,len(area),zlib.crc32(area)));await ack(b'TM\1\x80')
        await channel.send(s,b'TM\1\2'+struct.pack('<HH',903,0)+area)
        await channel.send(s,b'TM\1\3'+struct.pack('<H',903));d=await ack(b'TM\1\x80');assert d[-1]==0
        await asyncio.sleep(2)
        first=pixels();assert len(first)==466*466*3
        colors={first[(row*466+col)*3:(row*466+col)*3+3] for row in range(110,300) for col in range(30,435)}
        assert len(colors)>=5,('Native map did not draw map detail and labels',len(colors))
        (out/'trail-map-native.ppm').write_bytes((out/'guest/frame.ppm').read_bytes())
        await send('t 1 180 210','t 1 220 210','t 1 260 230','t 0 260 230',pause=1)
        assert pixels()!=first,'Native map ignored swipe panning'
        await send('r 80','r 80','r -80','r -80',pause=1)
        assert (await channel.ping(s)).running_slot!=255,'Zoom exited or crashed the map'
        perf=word(firmware.STUB_RAM+APP_BLOCK_OFF)+perf_offset
        timings=[word(perf+4*i) for i in range(3)]
        assert timings[0]>=3 and timings[2]<1000,('Map render stalled',timings)
        await send('c 1','c 0',pause=1)
        assert (await channel.ping(s)).running_slot==255
        await send('t 1 200 180','t 0 200 180',pause=2)
        assert (await channel.ping(s)).running_slot!=255
        assert len({pixels()[(row*466+col)*3:(row*466+col)*3+3] for row in range(110,300) for col in range(30,435)})>=5
        await send('c 1','c 0',pause=1)
        assert (await channel.ping(s)).running_slot==255
        await send('c 1','c 0',pause=1)
        report.update(arm_native_codec2_render=True,arm_native_swipe_pan=True,
                      arm_native_crown_zoom=True,arm_native_restart_without_phone_artwork=True,
                      arm_native_frames=timings[0],arm_native_last_render_ms=timings[1],
                      arm_native_max_render_ms=timings[2])
