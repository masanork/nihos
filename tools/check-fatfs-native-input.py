#!/usr/bin/env python3
"""Execute the native C fixture decoder and guarded FatFs reader on host only."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[1]


def check(manifest):
    fixture = json.loads(manifest.read_text())
    work = Path(tempfile.mkdtemp(prefix='c-decode-', dir=manifest.parent))
    probe = work / 'probe.c'
    probe.write_text(r'''
#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "nihos_fatfs_disk.h"
#include "nihos_fatfs_backend.h"
extern int nih_fatfs_fixture_read(void *, uint32_t, uint8_t[512]);
extern int nih_fatfs_fixture_bind(void *, uint64_t);
extern uint32_t nih_fatfs_fixture_sectors(void);
static unsigned callbacks;
void nih_fatfs_fixture_after_read(void) { callbacks++; }
int main(int argc, char **argv) {
    assert(argc == 2);
    FILE *out = fopen(argv[1], "wbx"); assert(out);
    uint8_t sector[512];
    uint32_t sectors = nih_fatfs_fixture_sectors();
    for (uint32_t i = 0; i < sectors; i++) {
        assert(nih_fatfs_fixture_read(NULL, i, sector) == 0);
        assert(fwrite(sector, 1, 512, out) == 512);
    }
    assert(fclose(out) == 0 && callbacks == sectors);
    assert(nih_fatfs_fixture_read(NULL, sectors, sector) != 0);
    assert(nih_fatfs_fixture_read(NULL, 0, NULL) != 0);
    assert(callbacks == sectors);
    nih_fatfs_disk disk = {0};
    assert(nih_fatfs_fixture_bind(&disk, 1) == 0);
    uint32_t bytes = nih_fatfs_backend_bytes();
    void *workspace = calloc(1, bytes); assert(workspace);
    nih_fatfs_backend *fs = nih_fatfs_backend_init(workspace, bytes, &disk, 1); assert(fs);
    assert(nih_fatfs_backend_mount(fs, 1) == 0);
    uint64_t identity = 0, token = 0;
    assert(nih_fatfs_backend_lookup(fs, 1, 1, "Memo.txt", 8, &identity) == 0);
    assert(nih_fatfs_backend_open(fs, 1, identity, &token) == 0);
    uint8_t output[4096]; uint32_t got = 0, eof = 0;
    assert(nih_fatfs_backend_read(fs, 1, token, 0, output, sizeof output, &got, &eof) == 0);
    assert(got == 24 && eof == 1 && memcmp(output, "nihos read-only fixture\n", 24) == 0);
    assert(nih_fatfs_backend_close(fs, 1, token) == 0);
    assert(nih_fatfs_backend_destroy(fs, 1) == 0);
    free(workspace);
    return 0;
}
''')
    source = Path(fixture['source_directory'])
    executable = work / 'probe'
    command = [*shlex.split(os.environ.get('CC', 'cc')), '-std=c11', '-O1', '-Wall', '-Wextra', '-Werror',
        '-I' + str(ROOT / 'include'), '-I' + str(ROOT / 'probes/fatfs-disk'), '-I' + str(source),
        '-I' + str(Path(fixture['header']).parent),
        '-Dnih_ro_open=nih_fatfs_guard_open', '-Dnih_ro_directory=nih_fatfs_guard_directory',
        '-Dnih_ro_status_name=nih_fatfs_guard_status_name', str(probe),
        *(str(ROOT / path) for path in ('src/platform/native/fatfs_fixture.c',
            'src/platform/native/fatfs_fixture_disk.c', 'src/storage/fatfs_disk.c',
            'src/storage/fatfs_backend.c', 'probes/fatfs-disk/safety.c')),
        str(source / 'ffunicode.c'), '-o', str(executable)]
    subprocess.run(command, check=True)
    decoded = work / 'decoded.img'
    subprocess.run([str(executable), str(decoded)], check=True, timeout=30)
    checksum = hashlib.sha256(decoded.read_bytes()).hexdigest()
    if checksum != fixture['image_sha256']:
        raise ValueError('Actual C decoder differs from pinned logical image')
    result = {'evidence': 'host C decoder and guarded FatFs; no native task or SD execution',
        'image_sha256': checksum, 'sectors': fixture['image_bytes'] // 512,
        'memo_bytes': 24, 'invalid_lba_and_null_output_rejected': True,
        'executable_sha256': hashlib.sha256(executable.read_bytes()).hexdigest()}
    output = work / 'result.json'
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(output)


if __name__ == '__main__':
    check(Path(sys.argv[1]).resolve())
