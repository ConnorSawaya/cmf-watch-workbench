"""LLDB helpers for the disposable emulator only. Never used for physical BLE."""
import json,subprocess
from pathlib import Path

def call(qmp,port,script_path,fn,*args,memory=None):
    # Same temporary call frame as the upstream test harness: stop at a thread's
    # mutex entry, preserve all registers, return to scratch Thumb spin, restore.
    code='''import lldb
lldb.debugger.SetAsync(False)
p=lldb.debugger.GetSelectedTarget().GetProcess()
t=lldb.debugger.GetSelectedTarget()
e=lldb.SBError()
awake=p.ReadUnsignedFromMemory(0x38037d14,4,e)
if 0x38000000<=awake<0x38800000:p.WriteMemory(awake,b"\\xff"*4,e)
b=t.BreakpointCreateByAddress(0x101be218)
p.Continue()
th=p.GetSelectedThread();f=th.GetFrameAtIndex(0)
names=["r"+str(i) for i in range(13)]+["sp","lr","pc","xpsr"]
saved={n:f.FindRegister(n).GetValueAsUnsigned() for n in names}
t.BreakpointDelete(b.GetID())
spin=0x3871fec0
p.WriteMemory(spin,b"\\xfe\\xe7",e)
assert e.Success(),str(e)
def reg(n,v):
 assert f.FindRegister(n).SetValueFromCString(hex(v)),n
for i,a in enumerate(ARGS):reg("r"+str(i),a)
reg("sp",(saved["sp"]-256)&~7);reg("lr",spin|1);reg("pc",FN&~1);reg("xpsr",saved["xpsr"]|0x1000000)
b=t.BreakpointCreateByAddress(spin)
p.Continue()
f=p.GetSelectedThread().GetFrameAtIndex(0)
assert f.FindRegister("pc").GetValueAsUnsigned()==spin,"call did not return"
for n,v in saved.items():reg(n,v)
t.BreakpointDelete(b.GetID())
p.Detach()
'''.replace('ARGS',repr(list(args))).replace('FN',str(fn))
    if memory:
        writes=''.join(f'p.WriteMemory({address},{data!r},e)\nassert e.Success(),str(e)\n' for address,data in memory.items())
        code=code.replace('b=t.BreakpointCreateByAddress(0x101be218)',writes+'b=t.BreakpointCreateByAddress(0x101be218)')
    # Stub scratch is derived from the real shared layout, rather than a RAM guess.
    from wp2apps.firmware import STUB_RAM
    code=code.replace('spin=0x3871fec0',f'spin={STUB_RAM+0xE00}')
    script_path=Path(script_path);script_path.write_text(code)
    qmp.hmp(f'gdbserver tcp::{port}')
    try:
        result=subprocess.run(['xcrun','lldb','--batch','-o',f'gdb-remote 127.0.0.1:{port}','-o',f'script exec(open({str(script_path)!r}).read())'],capture_output=True,text=True,timeout=60)
        script_path.with_suffix('.log').write_text(result.stdout+result.stderr)
        assert result.returncode==0 and 'Traceback' not in result.stdout+result.stderr,result.stdout+result.stderr
    finally:qmp.hmp('gdbserver none')
