import ctypes
import json
import os
from pathlib import Path
import subprocess
reports=[]
for ambient in ('full','minimal'):
    for scalar in (False,True):
        for variant in ('baseline','candidate'):
            env=os.environ.copy() if ambient=='full' else {k:v for k,v in os.environ.items() if k.upper() in ('SYSTEMROOT','WINDIR','PATH','TEMP','TMP')}
            env.pop('JSIMD_FORCENONE',None)
            if scalar:env['JSIMD_FORCENONE']='1'
            p=subprocess.Popen([str(Path(variant+'-profile.exe').resolve())],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,env=env)
            kernel=ctypes.WinDLL('kernel32',use_last_error=True)
            kernel.SetProcessAffinityMask.argtypes=[ctypes.c_void_p,ctypes.c_size_t]
            kernel.SetPriorityClass.argtypes=[ctypes.c_void_p,ctypes.c_ulong]
            if not kernel.SetProcessAffinityMask(int(p._handle),1) or not kernel.SetPriorityClass(int(p._handle),0x80):raise ctypes.WinError(ctypes.get_last_error())
            out,err=p.communicate(timeout=90)
            if p.returncode or err.strip():raise RuntimeError(out+'\n'+err)
            row={'variant':variant,'ambient':ambient,'scalar':scalar,**json.loads(out)};reports.append(row);print(json.dumps(row),flush=True)
Path('reports/profile.json').write_text(json.dumps(reports,indent=2)+'\n')
