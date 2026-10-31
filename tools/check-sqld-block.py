#!/usr/bin/env python3
"""The real normal SD owner capability with copied buffers and modeled MMIO."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shlex
import sys
import tempfile
from normal_fs_build import build, ROOT
spec=importlib.util.spec_from_file_location('normal_check',ROOT/'tools/check-normal-fs.py')
check=importlib.util.module_from_spec(spec);spec.loader.exec_module(check)
with tempfile.TemporaryDirectory(prefix='sqld-block-') as folder:
    work=Path(folder)
    objects,source=build(work,native=False,sqld_host_test=True)
    executable=check.link(work,objects)
    if len(sys.argv)>1:
        fixture=Path(sys.argv[1]).resolve()
    else:
        writer=work/'writer'
        check.execute([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-O1','-DNIHOS_FIXTURE_WRITER=1','-I'+str(ROOT/'probes/fatfs-disk'),'-I'+str(source),ROOT/'probes/fatfs-disk/make_fixture.c',ROOT/'probes/fatfs-disk/host_disk.c',source/'ff.c',source/'ffunicode.c','-o',writer])
        fixture=work/'fat16.img';check.execute([writer,fixture,'fat16'])
    before=hashlib.sha256(fixture.read_bytes()).hexdigest()
    result=json.loads(check.execute([executable,fixture,'raw-capability']).stdout)
    if before!=hashlib.sha256(fixture.read_bytes()).hexdigest():raise ValueError('fixture mutated')
    print(json.dumps(result))
