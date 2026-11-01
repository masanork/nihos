#!/usr/bin/env python3
"""Compile the patched loader's actual counter decoder against independent cases."""
import pathlib
import re
import subprocess
import sys
import tempfile

source = (pathlib.Path(sys.argv[1]) / "src/esp_loader.c").read_text()
helper = re.search(r"static uint32_t byte_popcnt\(uint8_t byte\)\s*\{.*?^\}", source, re.S | re.M)
assignment = re.search(r"security_info->usb_disabled\s*=[^;]*;\s*(.*?)\s*security_info->dcache", source, re.S)
if not helper or not assignment:
    raise SystemExit("Unable to locate the loader security decoder")
program = r'''#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
HELPER
int main(void) {
    struct { uint8_t flash_crypt_cnt; uint8_t key_purposes[7]; } resp;
    struct { bool flash_encryption_enabled; } out, *security_info = &out;
    for (unsigned i=0; i<256; i++) for (unsigned pattern=0; pattern<4; pattern++) {
        resp.flash_crypt_cnt=i;
        for (unsigned k=0; k<7; k++) resp.key_purposes[k]=(pattern==0?0:pattern==1?255:pattern==2?1:k*17);
        ASSIGNMENT
        if (out.flash_encryption_enabled != (__builtin_popcount(i) & 1)) return 1;
    }
    puts("all 1024 security decoder cases passed");
    return 0;
}'''.replace("HELPER", helper.group()).replace("ASSIGNMENT", assignment.group(1))
with tempfile.TemporaryDirectory(prefix="c6-security-parity-") as tmp:
    path = pathlib.Path(tmp)
    (path / "test.c").write_text(program)
    subprocess.run(["cc", "-std=c11", "-Wall", "-Wextra", "-Werror", str(path / "test.c"), "-o", str(path / "test")], check=True)
    subprocess.run([str(path / "test")], check=True)
