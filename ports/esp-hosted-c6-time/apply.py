#!/usr/bin/env python3
"""Apply time-only experiment to a disposable HTTPS-overlay Hosted checkout."""
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent
REVISION = '0e8d0e3f0c2723deaf15441200cb4d8c53fea230'

def replace(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f'expected one marker in {path}')
    path.write_text(text.replace(old, new))

def main():
    if len(sys.argv) != 2:
        raise SystemExit('usage: apply.py /path/to/disposable-esp-hosted-checkout')
    source = Path(sys.argv[1]).resolve()
    head = subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip()
    if head != REVISION:
        raise SystemExit(f'unexpected Hosted revision {head}')
    main_dir = source / 'slave/main'
    for name in ('nihos_time_wire.h', 'nihos_time_wire.c', 'nihos_time_service.h', 'nihos_time_service.c'):
        if (main_dir / name).exists():
            raise SystemExit(f'target already exists: {main_dir / name}')
    cmake = main_dir / 'CMakeLists.txt'
    marker = 'if(CONFIG_NIHOS_HTTPS_SERVICE)\n'
    replace(cmake, marker, 'if(CONFIG_NIHOS_TIME_SERVICE)\n\tlist(APPEND COMPONENT_SRCS nihos_time_wire.c nihos_time_service.c)\nendif()\n\n' + marker)
    config = main_dir / 'Kconfig.projbuild'
    marker = '\n\n\tconfig NIHOS_HTTPS_SERVICE\n'
    replace(config, marker, '\n\n\tconfig NIHOS_TIME_SERVICE\n\t\tbool "nihos experimental SNTP snapshot"\n\t\tdepends on ESP_HOSTED_NETWORK_SPLIT_ENABLED && ESP_HOSTED_ENABLE_PEER_DATA_TRANSFER && !NIHOS_HTTPS_SERVICE\n\t\tdefault n\n\t\thelp\n\t\t\tUnauthenticated C6 time snapshot over CustomRpc.\n' + marker)
    app = main_dir / 'esp_hosted_coprocessor.c'
    marker = '#ifdef CONFIG_NIHOS_HTTPS_SERVICE\n#include "nihos_https_service.h"\n#endif\n'
    replace(app, marker, marker + '#ifdef CONFIG_NIHOS_TIME_SERVICE\n#include "nihos_time_service.h"\n#endif\n')
    marker = '#ifdef CONFIG_NIHOS_HTTPS_SERVICE\n\tESP_ERROR_CHECK(nihos_https_service_init());\n#endif\n'
    replace(app, marker, marker + '#ifdef CONFIG_NIHOS_TIME_SERVICE\n\tESP_ERROR_CHECK(nihos_time_service_init());\n#endif\n')
    for name in ('nihos_time_wire.h', 'nihos_time_wire.c', 'nihos_time_service.h', 'nihos_time_service.c'):
        shutil.copyfile(ROOT / name, main_dir / name)
    print('Applied experimental time service; enable it in sdkconfig and disable HTTPS')

if __name__ == '__main__':
    main()
