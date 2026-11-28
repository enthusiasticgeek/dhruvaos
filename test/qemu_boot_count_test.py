#!/usr/bin/env python3
"""QEMU regression test: the boot counter must increase by one per boot.

Before 2026-11-28 crashlog_boot_increment ran while DharaFS's background
recovery scan was still active; a lookup for a path not yet indexed then
returns "not found", so the counter read 0 and wrote 1 on every such boot
(real HW: every crash record said "boot 1"). The increment is now deferred
to task_e's first pass after the scan completes. Three boots on one card
must report boot_count 1, 2, 3 in `diagnose`.

Usage: python3 test/qemu_boot_count_test.py build/dhruva.elf
"""
import sys,os,tempfile,re
sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "test"))
import qemu_dharafs_index_eviction_test as ev
sd=os.path.join(tempfile.mkdtemp(),"sd.img"); open(sd,"wb").truncate(64<<20)
counts=[]
for b in (1,2,3):
    q,st=ev.boot(sys.argv[1],sd); cmd=ev.make_cmd(q,st)
    cmd("",b"zz",8)
    out=cmd("diagnose",b"svc_preempt",20)
    m=re.search(r"boot_count: (\d+)",out); counts.append(int(m.group(1)) if m else None)
    print("boot",b,[l.strip() for l in out.splitlines() if "boot_count" in l])
    cmd("shutdown",b"SAFE TO POWER OFF",60); q.kill(); q.wait()
print("PASS" if counts==[1,2,3] else f"FAIL {counts}")
sys.exit(0 if counts==[1,2,3] else 1)
