#!/usr/bin/env python3
"""Pack licensed BSP panel commands; --verify-c compares against a C compiler."""
from pathlib import Path
import argparse
import hashlib
import json
import re
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
TABLES = [('ili9881c', 'disp_init_data.h'), ('st7123', 'disp_init_data_1.h'),
          ('st7121', 'disp_init_data_st7121.h')]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--verify-c', action='store_true')
    args = parser.parse_args()
    manifest = {}
    for name, filename in TABLES:
        source = ROOT / 'third_party/tab5-panel-init' / filename
        text = re.sub(r'/\*.*?\*/|//[^\n]*', '', source.read_text(), flags=re.S)
        body = text[text.index('= {') + 3:text.rindex('};')]
        pattern = r'\{\s*(0x[\da-fA-F]+|\d+)\s*,\s*(?:\(uint8_t\s*\[\s*\]\)\s*\{([^{}]*)\}|NULL)\s*,\s*(\d+)\s*,\s*(\d+)\s*\}'
        matches = list(re.finditer(pattern, body))
        assert matches and not re.sub(pattern, '', body).strip(' \n\r\t,'), source
        packed = bytearray()
        for match in matches:
            cmd, values, size, delay = match.groups()
            payload = bytes(int(x.strip(), 0) for x in (values or '').split(',') if x.strip())
            size, delay = int(size), int(delay)
            assert size <= len(payload) and size <= 255 and delay <= 1000
            packed += struct.pack('<BBH', int(cmd, 0), size, delay) + payload[:size]
        if args.verify_c:
            with tempfile.TemporaryDirectory() as temporary:
                cfile = Path(temporary) / 'verify.c'
                executable = Path(temporary) / 'verify'
                cfile.write_text('''#include <stdint.h>
#include <stdio.h>
typedef struct { int cmd; const void *data; unsigned data_bytes; unsigned delay_ms; } st7123_lcd_init_cmd_t;
typedef st7123_lcd_init_cmd_t ili9881c_lcd_init_cmd_t;
''' + f'#include "{source}"\n' + f'''int main(void) {{
for (unsigned i=0;i<sizeof(disp_init_data_{name})/sizeof(disp_init_data_{name}[0]);i++) {{
const st7123_lcd_init_cmd_t *p=&disp_init_data_{name}[i];
putchar(p->cmd);putchar(p->data_bytes);putchar(p->delay_ms&255);putchar(p->delay_ms>>8);
fwrite(p->data,1,p->data_bytes,stdout); }} return 0; }}''')
                subprocess.run(['cc', '-std=c11', str(cfile), '-o', str(executable)], check=True)
                assert subprocess.check_output([str(executable)]) == packed, source
        destination = ROOT / f'src/board/tab5/panel_data/{name}.bin'
        destination.write_bytes(packed)
        manifest[name] = {'source': str(source.relative_to(ROOT)),
                          'source_sha256': hashlib.sha256(source.read_bytes()).hexdigest(),
                          'commands': len(matches), 'packed_bytes': len(packed),
                          'packed_sha256': hashlib.sha256(packed).hexdigest()}
    (ROOT / 'src/board/tab5/panel_data/manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    print(json.dumps(manifest, indent=2))


if __name__ == '__main__':
    main()
