#!/usr/bin/env python3
"""Place GCC's immutable alignment metadata in the test image's Flash rodata."""
from pathlib import Path
import re
import subprocess
import sys

objdump, objcopy, path = sys.argv[1:]
path = Path(path)
listing = subprocess.check_output([objdump, '-h', str(path)], text=True)
names = re.findall(r'^\s*\d+\s+((?:\.data\.\.Lubsan_data|\.sdata\.\.Lubsan_type)\d+)\s', listing, re.M)
all_ubsan = re.findall(r'^\s*\d+\s+(\S*Lubsan_\S*)\s', listing, re.M)
if not names or len(names) != len(set(names)) or set(names) != set(all_ubsan):
    raise SystemExit('missing, duplicate or unrecognized GCC UBSan metadata sections')
output = path.with_suffix('.readonly.o')
command = [objcopy]
for name in names:
    target = '.rodata.nihos_' + name.split('Lubsan_', 1)[1]
    command += ['--rename-section', name + '=' + target + ',alloc,load,readonly,data,contents']
subprocess.run(command + [str(path), str(output)], check=True)
after = subprocess.check_output([objdump, '-h', str(output)], text=True)
if re.search(r'^\s*\d+\s+(?:\.data\.\.Lubsan_data|\.sdata\.\.Lubsan_type)\d+\s', after, re.M):
    raise SystemExit('writable UBSan metadata remains')
output.replace(path)
print(f'Placed {len(names)} GCC UBSan metadata sections in test Flash rodata')
